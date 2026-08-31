import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = Config()
    private var statusItem: NSStatusItem!
    private var server: TriggerServer?

    /// 屏幕上开着的浮窗们，谁后弹的谁排在尾巴上。
    /// 每扇窗自带一段对话和一条 LLM 通道（见 ExplainWindowController），
    /// 这里只负责开新窗、记名册、销名册。
    private var windows: [ExplainWindowController] = []

    /// ⌘W 全局热键。只要还有浮窗在册就借着，最后一扇关掉立刻归还。
    /// 收归到这儿统一管，是因为多扇窗各自去注册同一个 ⌘W 的话，
    /// 一次按键会把所有窗的回调全敲响——按一下全关光，那就闹笑话了。
    private let closeHotKey = CloseHotKey()

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ConfigStore.load()

        buildEditMenu()
        buildStatusItem()
        startServer()
        ConfigStore.warmUpAPIKey(config)   // 提前去 shell 里把 key 捞好
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    // MARK: - 隐形的主菜单

    /// 装一个带「文件」「编辑」两项的主菜单。
    ///
    /// macOS 有条不太直觉的规矩：`Cmd+C`、`Cmd+V` 这些键**不是输入框自己处理的**，
    /// 而是系统拿着按键去主菜单里找"谁绑了这个快捷键"，找到了才把 copy:／paste:
    /// 发给光标所在的控件。这程序不进 Dock、不占菜单栏，压根没建过主菜单，
    /// 于是这些键一按就石沉大海——普通字打得进去（那是输入框自己收的），
    /// 一碰 Cmd 组合键就没反应。
    ///
    /// 挂上这个菜单就通了。程序是 accessory 类型，这个菜单栏不会显示出来，
    /// 纯粹是给系统查快捷键用的。
    private func buildEditMenu() {
        let edit = NSMenu(title: "编辑")
        // undo:／redo: 在 Swift 里没有对应的方法声明可以指，只能写字符串
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "粘贴为纯文本",
                     action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        edit.addItem(.separator())
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit

        // 「关闭窗口 ⌘W」备胎：浮窗露脸时 ⌘W 走的是全局热键（closeHotKey），
        // 轮不到菜单；万一热键没注册上，点过浮窗之后按 ⌘W 由这条顺着
        // responder 链找到那扇窗的 performClose 关窗
        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "关闭窗口",
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem()
        fileItem.submenu = file

        let main = NSMenu()
        main.addItem(fileItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - 菜单栏

    private func buildStatusItem() {
        guard config.showMenuBarIcon else {
            statusItem = nil
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: "text.bubble", accessibilityDescription: "Nutshell"
        )
        statusItem.button?.toolTip = "Nutshell —— 选中内容，一键讲人话"

        let menu = NSMenu()
        menu.addItem(withTitle: "现在解读一下", action: #selector(triggerFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        let modelItem = NSMenuItem(title: "模型：\(config.model)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        let portItem = NSMenuItem(title: "触发端口：\(config.port)", action: nil, keyEquivalent: "")
        portItem.isEnabled = false
        menu.addItem(portItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "打开配置文件", action: #selector(openConfig), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "重新加载配置", action: #selector(reloadConfigFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "复制 BTT 触发命令", action: #selector(copyTriggerCommand), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Nutshell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    @objc private func triggerFromMenu() { handleTrigger() }

    @objc private func openConfig() {
        ConfigStore.save(config)   // 保证文件存在
        NSWorkspace.shared.open(ConfigStore.fileURL)
    }

    @objc private func reloadConfigFromMenu() { reloadConfig(silent: false) }

    /// - Parameter silent: 从命令行 `/reload` 过来的不弹框——你在终端里已经看到回执了，
    ///   再弹个窗抢焦点纯属添乱。
    private func reloadConfig(silent: Bool) {
        let oldPort = config.port
        config = ConfigStore.load()

        if config.port != oldPort {
            server?.stop()
            didReportServerFailure = false
            startServer()
        }
        // 字号之类的改动，下次开窗生效最省事。窗全拆了，每扇手上那段各自存进历史。
        // close 会回调 onClosed 改 windows 数组，for-in 遍历的是进循环时的那份快照，不冲突
        for controller in windows { controller.close() }

        buildStatusItem()
        if !silent { notify("配置已重新加载", "模型：\(config.model)") }
    }

    @objc private func copyTriggerCommand() {
        let command = "curl -s http://127.0.0.1:\(config.port)/explain"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        notify("命令已复制", "粘到 BTT 的 Execute Terminal Command 里")
    }

    private func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 触发通道

    private func startServer() {
        let server = TriggerServer(
            port: config.port,
            onTrigger: { [weak self] path in
                Task { @MainActor in
                    // /reload 是没有菜单栏时重新加载配置的入口
                    if path.hasPrefix("/reload") {
                        self?.reloadConfig(silent: true)
                    } else if path.hasPrefix("/history") {
                        self?.showHistoryFromTrigger()
                    } else {
                        self?.handleTrigger()
                    }
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in self?.reportServerFailure(message) }
            }
        )
        do {
            try server.start()
            self.server = server
        } catch {
            notify("启动失败", error.localizedDescription)
        }
    }

    /// 端口起不来是致命的（快捷键彻底失灵），但别反复弹框烦人，报一次就够
    private var didReportServerFailure = false
    private func reportServerFailure(_ message: String) {
        guard !didReportServerFailure else { return }
        didReportServerFailure = true
        statusItem?.button?.image = NSImage(
            systemSymbolName: "exclamationmark.bubble", accessibilityDescription: "Nutshell 出问题了"
        )
        notify("Nutshell 起不来", message)
    }

    // MARK: - 主流程

    /// 按一下快捷键就弹一扇**新**窗，解读此刻剪贴板里的东西。
    ///
    /// 以前这里是个开关（开着就关、关着就开）；现在窗口可以同时开好几扇——
    /// 选中一段、按一下，再选中另一段、再按一下，两份解读并排摆着对照看。
    /// 关窗不再占用触发键，交给每扇窗自己的 ✗ / Esc / ⌘W。
    private func handleTrigger() {
        let mouse = NSEvent.mouseLocation
        let controller = spawnWindow()
        controller.beginFromClipboard(frame: placementFrame(near: mouse))
    }

    /// 造一扇新窗并记进名册。挂两条回传线：关窗除名、点小钟弹历史菜单。
    private func spawnWindow() -> ExplainWindowController {
        let controller = ExplainWindowController(config: config)
        controller.onClosed = { [weak self] controller in
            guard let self else { return }
            self.windows.removeAll { $0 === controller }
            self.refreshCloseHotKey()
        }
        controller.onHistoryMenu = { [weak self] controller, button in
            self?.showHistoryMenu(for: controller, from: button)
        }
        windows.append(controller)
        refreshCloseHotKey()
        return controller
    }

    /// 新窗该摆哪：先按老规矩贴着鼠标算；要是跟已有的窗几乎叠在一起
    /// （鼠标没挪窝就又按了一下），往右下错开一步，像发牌一样摞出层次，
    /// 底下那扇的标题栏始终露着，看得见也点得着。
    private func placementFrame(near mouse: NSPoint) -> NSRect {
        let size = NSSize(width: config.window.width, height: config.window.height)
        var frame = PopoverPanel.frame(near: mouse, size: size, gap: config.window.gap)

        let taken = windows.map { $0.panel.frame }
        var attempts = 0
        while attempts < 12,
              taken.contains(where: { abs($0.minX - frame.minX) < 16 && abs($0.maxY - frame.maxY) < 16 }) {
            frame.origin.x += 28
            frame.origin.y -= 28
            attempts += 1
        }
        // 错着错着出了屏，就整个夹回来——宁可叠着也别让窗掉到屏幕外头去
        return PopoverPanel.clamp(frame, near: mouse)
    }

    /// 有窗在册就把 ⌘W 借过来，一扇不剩立刻还回去
    private func refreshCloseHotKey() {
        if windows.isEmpty {
            closeHotKey.unregister()
        } else {
            closeHotKey.register { [weak self] in self?.closeFrontWindow() }
        }
    }

    /// ⌘W 关哪扇：你点过的那扇（key window）优先；都没点过就关最新弹的。
    /// 一扇一扇按，一摞窗从上往下依次收干净。
    private func closeFrontWindow() {
        if let key = NSApp.keyWindow,
           let owner = windows.first(where: { $0.panel === key }) {
            owner.close()
            return
        }
        windows.last?.close()
    }

    // MARK: - 历史

    /// 菜单是替哪扇窗弹的。菜单是模态的，同一时刻只会开一张，存一个就够。
    /// 挑当前条打勾、恢复历史、开新对话，都落在这扇窗上。
    private weak var historyMenuOwner: ExplainWindowController?

    /// 顶栏那个小钟点开的清单。按今天／昨天／更早分堆，这扇窗手上那条前面打勾。
    private func showHistoryMenu(for owner: ExplainWindowController, from button: NSButton) {
        historyMenuOwner = owner

        let menu = NSMenu()
        menu.addItem(actionItem("＋ 新对话（重读剪贴板）", #selector(startNewConversation)))

        let sessions = SessionStore.list()
        guard !sessions.isEmpty else {
            menu.addItem(.separator())
            menu.addItem(labelItem("还没有存下来的对话"))
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
            return
        }

        let shown = Array(sessions.prefix(max(1, config.historyMenuCount)))
        var currentGroup = ""
        for summary in shown {
            let group = Self.groupTitle(for: summary.updatedAt)
            if group != currentGroup {
                menu.addItem(.separator())
                menu.addItem(labelItem(group))
                currentGroup = group
            }

            let item = actionItem(
                "\(summary.title)   \(Self.timeTitle(for: summary.updatedAt))",
                #selector(openHistoryItem(_:))
            )
            item.representedObject = summary.id
            item.state = summary.id == owner.currentSessionID ? .on : .off
            // 不清掉默认的 ⌘，下面那条 Option 备选项不会生效
            item.keyEquivalentModifierMask = []
            menu.addItem(item)

            // 按住 Option，上面那条就变成删除——mac 上惯用的"把危险操作藏一层"的手法
            let remove = actionItem("删除「\(summary.title)」", #selector(deleteHistoryItem(_:)))
            remove.representedObject = summary.id
            remove.isAlternate = true
            remove.keyEquivalentModifierMask = .option
            menu.addItem(remove)
        }

        menu.addItem(.separator())
        let rest = sessions.count - shown.count
        let folderTitle = rest > 0
            ? "共 \(sessions.count) 条，另外 \(rest) 条没列出来 · 在访达中打开"
            : "共 \(sessions.count) 条 · 在访达中打开"
        menu.addItem(actionItem(folderTitle, #selector(revealHistoryFolder)))
        menu.addItem(actionItem("清空历史…", #selector(clearHistory)))

        // 菜单从按钮正下方掉出来（按钮坐标系 y 朝上，所以往下是负的）
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
    }

    /// 从外面直接叫出历史清单（`curl …/history`）。
    /// 有窗就挂在最上面那扇的小钟上；一扇都没有就先支一扇空窗——菜单得有地方挂。
    private func showHistoryFromTrigger() {
        let owner: ExplainWindowController
        if let key = NSApp.keyWindow, let match = windows.first(where: { $0.panel === key }) {
            owner = match
        } else if let last = windows.last {
            owner = last
        } else {
            owner = spawnWindow()
            owner.showPlaceholder(frame: placementFrame(near: NSEvent.mouseLocation))
        }
        // 窗刚支起来，等这一轮布局跑完再弹，菜单才知道自己该出现在哪
        DispatchQueue.main.async { owner.panel.openHistoryMenu() }
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// 纯粹当小标题用的灰字，点不动
    private func labelItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func startNewConversation() {
        historyMenuOwner?.restartFromClipboard()
    }

    @objc private func openHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }

        // 这段对话已经开在别的窗里了？把那扇提到前面来就行——
        // 同一段开两份的话，俩窗会往同一个存档文件里写，互相踩脚
        if let existing = windows.first(where: { $0.currentSessionID == id }),
           existing !== historyMenuOwner {
            existing.panel.orderFrontRegardless()
            return
        }

        guard let stored = SessionStore.load(id) else {
            notify("这条历史打不开了", "对话文件可能被删了：\(id).json")
            return
        }
        historyMenuOwner?.restore(stored)
    }

    @objc private func deleteHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        SessionStore.delete(id)
        // 删的正好是哪扇窗手上那条，那扇窗就当没存过——再答一轮也不会把文件写回来
        for controller in windows { controller.forgetSession(id) }
    }

    @objc private func revealHistoryFolder() {
        try? FileManager.default.createDirectory(
            at: SessionStore.directory, withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([SessionStore.directory])
    }

    @objc private func clearHistory() {
        let count = SessionStore.list().count
        let alert = NSAlert()
        alert.messageText = "清空全部 \(count) 条历史对话？"
        alert.informativeText = "会把 ~/.config/nutshell/sessions/ 里的对话文件全删掉，删了找不回来。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "算了")
        // 别让手快按下的回车把历史一把清了：回车留给"算了"
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SessionStore.clear()
        for controller in windows { controller.forgetAnySession() }
    }

    // MARK: - 时间怎么写

    private static func groupTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return "更早"
    }

    private static func timeTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return clockFormat.string(from: date)
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return dayFormat.string(from: date)
        }
        return fullDayFormat.string(from: date)
    }

    // DateFormatter 建一个要好几百微秒，菜单一开就是几十次，做成常驻的省下这份钱
    private static let clockFormat = makeFormat("HH:mm")
    private static let dayFormat = makeFormat("M月d日")
    private static let fullDayFormat = makeFormat("yyyy年M月d日")

    private static func makeFormat(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = pattern
        return formatter
    }
}
