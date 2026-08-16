import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = Config()
    private var statusItem: NSStatusItem!
    private var panel: PopoverPanel?
    private var server: TriggerServer?
    private let llm = LLMClient()

    /// 发给模型的完整对话历史（含剪贴板那段开场白）
    private var conversation: [ChatMessage] = []
    /// 浮窗里已经定稿的内容（前几轮问答）
    private var transcript = ""
    /// 这一轮正在往外蹦的字
    private var accumulated = ""

    /// 手上这段对话在历史里的身份证。答完一轮就按这个 id 覆盖存一次盘。
    private var currentSessionID: String?
    private var currentTitle = ""
    private var currentCreatedAt = Date()

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

    // MARK: - 隐形的编辑菜单

    /// 装一个只有「编辑」一项的主菜单。
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

        let main = NSMenu()
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
        // 字号之类的改动，下次开窗生效最省事。窗要拆了，手上这段先存进历史
        stashCurrentSession()
        panel?.close()
        panel = nil

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

    /// 按一下快捷键会走到这儿。开着就关掉，关着就干活——就是个开关。
    private func handleTrigger() {
        if let panel, panel.isVisible {
            dismiss()
            return
        }

        // 先把窗开出来显示"正在琢磨"，别让人以为按了没反应
        let mouse = NSEvent.mouseLocation
        let panel = ensurePanel()
        accumulated = ""
        panel.markdownView.beginThinking(label: "正在读剪贴板…")
        panel.present(near: mouse, gap: config.window.gap)

        // 让窗口先画出来，再去干读剪贴板和发请求的活
        DispatchQueue.main.async { [weak self] in
            self?.captureAndAsk()
        }
    }

    /// 开一轮新的：读剪贴板，作为对话的第一条消息发出去
    private func captureAndAsk() {
        guard let panel else { return }

        let input: CapturedInput
        do {
            input = try InputCapture.capture(config: config)
        } catch {
            panel.markdownView.showError(error.localizedDescription)
            return
        }

        // 把剪贴板内容套进 prompt 模板，这就是对话的开场白
        let opening: ChatMessage.Content
        switch input {
        case .text(let body):
            opening = .text(config.promptTemplate.replacingOccurrences(of: "{content}", with: body))
            panel.markdownView.beginThinking(label: "\(config.model) 正在琢磨…")

        case .images(let images, let note):
            var instruction = config.imagePromptTemplate
            if let note, !note.isEmpty { instruction += "\n\n补充信息：\n\(note)" }
            opening = .multimodal(text: instruction, images: images)
            panel.markdownView.beginThinking(label: "正在看图（\(images.count) 张）…")
        }

        conversation = [.user(opening)]
        transcript = ""

        // 新的一段对话，发一张新身份证；标题取剪贴板开头那几个字，历史菜单里认得出
        currentSessionID = SessionStore.newID()
        currentTitle = SessionStore.makeTitle(from: input)
        currentCreatedAt = Date()

        send(retryOnAuthFailure: true)
    }

    /// 追问：把新问题接到对话后面再发一次
    private func askFollowUp(_ question: String) {
        guard let panel, !conversation.isEmpty else { return }

        conversation.append(.user(.text(question)))

        // 把问题也显示出来，不然滚上去看只有一堆回答，不知道在答什么
        transcript += "\n\n---\n\n> **你问：** \(question)\n\n"
        panel.markdownView.update(markdown: transcript)
        send(retryOnAuthFailure: true)
    }

    /// - Parameter retryOnAuthFailure: 撞 401 时重新去 shell 捞一次 key 再试。
    ///   key 轮换后旧的会失效，缓存里那个就是废的——不重捞会一直 401。
    private func send(retryOnAuthFailure: Bool) {
        guard let panel else { return }

        guard let apiKey = ConfigStore.resolveAPIKey(config, forceRefresh: !retryOnAuthFailure) else {
            panel.markdownView.showError(
                """
                没找到 API key。

                两个办法二选一：
                1. 在终端确认 `echo $\(config.apiKeyEnvVar)` 有值（Nutshell 会 source 你的 ~/.zshrc 去读）
                2. 直接把 key 写进 ~/.config/nutshell/config.json 的 apiKey 字段
                """
            )
            return
        }

        // transcript 是已经定稿的部分，accumulated 是这一轮正在往外蹦的字
        let settled = transcript
        accumulated = ""
        panel.setInputEnabled(false)

        Task { [config, llm, conversation] in
            await llm.stream(
                messages: conversation,
                config: config,
                apiKey: apiKey,
                onDelta: { [weak self] piece in
                    guard let self else { return }
                    self.accumulated += piece
                    self.panel?.markdownView.update(markdown: settled + self.accumulated)
                },
                onRetry: { [weak self] round, total in
                    guard let self else { return }
                    let seconds = String(format: "%g", config.rateLimitRetryDelay)
                    let note = "⏳ 被限流了，\(seconds) 秒后自动重试（第 \(round)/\(total) 次）…"
                    if settled.isEmpty {
                        self.panel?.markdownView.beginThinking(label: note)
                    } else {
                        // 前面几轮问答还在窗里摆着，别拿"正在琢磨"把它们盖掉
                        self.panel?.markdownView.update(markdown: settled + "\n\n" + note)
                    }
                },
                onFinish: { [weak self] error in
                    guard let self else { return }
                    self.panel?.setInputEnabled(true)

                    guard let error else {
                        self.settleRound(settled: settled)
                        self.panel?.markdownView.finish()
                        self.persistCurrentSession()
                        return
                    }

                    // 一个字都没吐就 401 → key 多半换过了，重捞一次再试
                    if retryOnAuthFailure,
                       self.accumulated.isEmpty,
                       error.localizedDescription.contains("401") {
                        self.panel?.markdownView.beginThinking(label: "key 像是过期了，重新读一次…")
                        self.send(retryOnAuthFailure: false)
                        return
                    }

                    // 已经吐了一半才出错的话，别把已有内容擦掉
                    if self.accumulated.isEmpty && settled.isEmpty {
                        self.panel?.markdownView.showError(error.localizedDescription)
                    } else {
                        self.accumulated += "\n\n⚠️ 中断了：\(error.localizedDescription)"
                        self.settleRound(settled: settled)
                        self.panel?.markdownView.update(markdown: self.transcript)
                        self.panel?.markdownView.finish()
                        self.persistCurrentSession()
                    }
                }
            )
        }
    }

    /// 一轮答完（或者中途断了）的收尾：把这轮蹦出来的字挪进定稿区，
    /// 同时补进发给模型的历史里——不然下次追问，模型不记得自己刚说过什么。
    ///
    /// 收完 `accumulated` 一定是空的，所以"这轮的回答"只会有一个落脚点，
    /// 存盘时不用再去猜它到底在哪边。
    private func settleRound(settled: String) {
        transcript = settled + accumulated
        guard !accumulated.isEmpty else { return }
        conversation.append(.assistant(accumulated))
        accumulated = ""
    }

    private func dismiss() {
        guard let panel, panel.isVisible else { return }
        Task { await llm.cancel() }
        // 正在往外蹦字的时候关窗，把已经蹦出来的半截也存下来，别白问
        stashCurrentSession()
        panel.setInputEnabled(true)
        panel.orderOut(nil)
    }

    // MARK: - 存档

    /// 把手上这段对话写进历史。每答完一轮存一次，覆盖同一个文件。
    private func persistCurrentSession() {
        guard let id = currentSessionID, !transcript.isEmpty else { return }
        SessionStore.save(StoredSession(
            id: id,
            title: currentTitle,
            createdAt: currentCreatedAt,
            updatedAt: Date(),
            model: config.model,
            transcript: transcript,
            messages: conversation.map(StoredMessage.init)
        ))
    }

    /// 要离开这段对话了（关窗、切到别条、开新的）：正在流的话先收尾，再存一次
    private func stashCurrentSession() {
        if !accumulated.isEmpty { settleRound(settled: transcript) }
        persistCurrentSession()
    }

    // MARK: - 浮窗

    private func ensurePanel() -> PopoverPanel {
        if let panel { return panel }

        let size = NSSize(width: config.window.width, height: config.window.height)
        let panel = PopoverPanel(size: size)
        let markdownView = MarkdownView(fontSize: config.window.fontSize)

        panel.install(
            markdownView: markdownView,
            modelName: config.model,
            onCopy: { [weak self] in
                guard let self, let view = self.panel?.markdownView else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(view.currentMarkdown, forType: .string)
            },
            onClose: { [weak self] in self?.dismiss() },
            onSubmit: { [weak self] question in self?.askFollowUp(question) },
            onHistory: { [weak self] button in self?.showHistoryMenu(from: button) }
        )

        self.panel = panel
        return panel
    }

    // MARK: - 历史

    /// 顶栏那个小钟点开的清单。按今天／昨天／更早分堆，当前这条前面打勾。
    private func showHistoryMenu(from button: NSButton) {
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
            item.state = summary.id == currentSessionID ? .on : .off
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

    /// 从外面直接叫出历史清单（`curl …/history`）。窗关着就先支起来——
    /// 菜单得挂在顶栏那个小钟上，没有窗就没地方挂。
    private func showHistoryFromTrigger() {
        let panel = ensurePanel()
        if !panel.isVisible {
            if transcript.isEmpty {
                panel.markdownView.restore(
                    markdown: "从上面那个小钟里挑一段接着聊。\n\n或者复制点东西、按一下快捷键，开段新的。"
                )
            }
            panel.present(near: NSEvent.mouseLocation, gap: config.window.gap)
        }
        // 窗刚支起来，等这一轮布局跑完再弹，菜单才知道自己该出现在哪
        DispatchQueue.main.async { panel.openHistoryMenu() }
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
        guard let panel else { return }
        stashCurrentSession()
        accumulated = ""
        panel.markdownView.beginThinking(label: "正在读剪贴板…")
        DispatchQueue.main.async { [weak self] in self?.captureAndAsk() }
    }

    @objc private func openHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openSession(id)
    }

    @objc private func deleteHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        SessionStore.delete(id)
        // 删的正好是手上这条，那就当它没存过——再答一轮也不会把文件写回来
        if currentSessionID == id { currentSessionID = nil }
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
        currentSessionID = nil
    }

    /// 切到某段旧对话：界面复原成当时的样子，模型那边的上下文也一起接上，
    /// 直接在底下输入框接着问就行。
    private func openSession(_ id: String) {
        guard let stored = SessionStore.load(id) else {
            notify("这条历史打不开了", "对话文件可能被删了：\(id).json")
            return
        }

        stashCurrentSession()
        Task { await llm.cancel() }

        let panel = ensurePanel()
        conversation = stored.messages.map(\.chatMessage)
        transcript = stored.transcript
        accumulated = ""
        currentSessionID = stored.id
        currentTitle = stored.title
        currentCreatedAt = stored.createdAt

        panel.setInputEnabled(true)
        panel.markdownView.restore(markdown: stored.transcript)
        if !panel.isVisible {
            panel.present(near: NSEvent.mouseLocation, gap: config.window.gap)
        }
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
