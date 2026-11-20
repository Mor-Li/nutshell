import AppKit

/// 冒在鼠标旁边的那个小浮窗。
///
/// 用 NSPanel 而不是普通窗口，关键在 `.nonactivatingPanel`：
/// 它可以浮在最上层、可以点、可以滚，但**不会把你当前用的 app 切到后台**——
/// 你在 Safari 里选段话弹出它，Safari 依旧是前台，Dock 不跳，command-tab 顺序不变。
final class PopoverPanel: NSPanel, NSTextViewDelegate {

    /// 允许成为 key window，这样窗口里的文字能选中、能 Cmd+C 拷走。
    /// 但显示时我们用 orderFrontRegardless()，所以它不会主动来抢——你点它才给。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private let header = NSView()
    private var historyButton: NSButton!
    private let modelLabel = NSTextField(labelWithString: "")
    private let inputScroll = NSScrollView()
    private let inputView = InputTextView.make(fontSize: 13)
    private let divider = DividerHandle()

    /// 输入框的高度。平时跟着内容走，见 updateInputHeight()
    private var inputHeight: NSLayoutConstraint!
    /// 你拽分隔线定下的高度。有值就照它来，nil 就是"跟着内容自动长"
    private var manualInputHeight: CGFloat?
    private var dragStartHeight: CGFloat = 0
    /// 模型正在回答。这时候可以先打字，但回车不发
    private var isBusy = false

    private static let idlePlaceholder = "接着问点什么…（回车发送，⇧回车换行）"
    private static let busyPlaceholder = "正在回答…可以先打字"
    /// 没拽过分隔线时，输入框最多自动长到这么多行，再多就在框里滚
    private static let autoGrowLines: CGFloat = 8
    /// 输入框再怎么长，上面的正文至少留这么高
    private static let minTranscriptHeight: CGFloat = 60
    private var onClose: (() -> Void)?
    private var onCopy: (() -> Void)?
    private var onSubmit: ((String) -> Void)?
    private var onHistory: ((NSButton) -> Void)?

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        level = .floating
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // 切到别的桌面/全屏 app 时也跟着走
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 窗口最小也得装得下顶栏、几行正文和一行输入框
        contentMinSize = NSSize(width: 280, height: 150)

        // 系统那三颗红绿灯在这么小的浮窗上太抢戏，自己画
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        buildContent()
    }

    // MARK: - 内容

    private let effectView = NSVisualEffectView()
    private(set) var markdownView: MarkdownView!

    private func buildContent() {
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        contentView = effectView

        header.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(header)

        // 左边这个小钟就是历史入口，点开是一张最近对话的清单
        historyButton = makeButton(
            symbol: "clock.arrow.circlepath", tooltip: "历史对话", action: #selector(historyTapped)
        )
        header.addSubview(historyButton)

        modelLabel.font = .systemFont(ofSize: 11, weight: .medium)
        modelLabel.textColor = .tertiaryLabelColor
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(modelLabel)

        let copyButton = makeButton(symbol: "doc.on.doc", tooltip: "复制全文", action: #selector(copyTapped))
        let closeButton = makeButton(symbol: "xmark", tooltip: "关闭 (⌘W / Esc)", action: #selector(closeTapped))

        let buttons = NSStackView(views: [copyButton, closeButton])
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(buttons)

        // 底部追问输入框：多行文本框套一层滚动容器，高度由 updateInputHeight() 说了算
        inputView.placeholder = Self.idlePlaceholder
        inputView.delegate = self
        // 窗口变宽变窄时折行会变，内容高度跟着变，得重新量
        inputView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(inputFrameChanged),
            name: NSView.frameDidChangeNotification, object: inputView
        )

        inputScroll.documentView = inputView
        inputScroll.drawsBackground = false
        inputScroll.borderType = .noBorder
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.scrollerStyle = .overlay
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(inputScroll)

        // 正文和输入框之间那根线，按住能上下拖
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.toolTip = "上下拖动调整输入框高度，双击恢复自动"
        divider.onDragBegan = { [weak self] in
            guard let self else { return }
            self.dragStartHeight = self.inputScroll.frame.height
        }
        divider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.manualInputHeight = self.dragStartHeight + delta
            self.updateInputHeight()
            // 存夹过之后的值：拖到头了再往回拖，要立刻跟手，不能先空走一段
            self.manualInputHeight = self.inputHeight.constant
        }
        divider.onDoubleClick = { [weak self] in
            self?.manualInputHeight = nil
            self?.updateInputHeight()
        }
        effectView.addSubview(divider)

        // 优先级压在"窗口保持原大小"之下：输入框想长高时只能去挤正文，不许把整扇窗撑大
        inputHeight = inputScroll.heightAnchor.constraint(equalToConstant: inputView.singleLineHeight)
        inputHeight.priority = NSLayoutConstraint.Priority(490)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: effectView.topAnchor),
            header.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),

            historyButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            historyButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            modelLabel.leadingAnchor.constraint(equalTo: historyButton.trailingAnchor, constant: 5),
            modelLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            // 标题长了也不许挤到右边那两个按钮头上
            modelLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),

            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            // 线画在这个视图的正中间，上下各多出 5pt 是给鼠标抓的
            divider.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 11),
            divider.bottomAnchor.constraint(equalTo: inputScroll.topAnchor, constant: -2),

            // 文本框自己还有 4pt 的内边距，所以字的左边缘仍然落在 16pt 上，和正文对齐
            inputScroll.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 12),
            inputScroll.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
            inputScroll.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -9),
            inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: inputView.singleLineHeight),
            inputHeight,
        ])
    }

    // MARK: - 输入框

    /// 回车发送。模型还在回答时不发，响一声提示，字留在框里等答完再按。
    private func submitInput() {
        guard !isBusy else {
            NSSound.beep()
            return
        }
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputView.string = ""
        // 这条发出去了，拽出来的高度也跟着作废，下一条重新从一行开始自动长
        manualInputHeight = nil
        updateInputHeight()
        onSubmit?(text)
    }

    /// 等回复的时候回车不发，免得连着发好几条把对话搅乱。
    /// 框本身不锁：趁它回答的工夫可以先把下一句打好。
    func setInputEnabled(_ enabled: Bool) {
        isBusy = !enabled
        inputView.placeholder = enabled ? Self.idlePlaceholder : Self.busyPlaceholder
    }

    /// 算一遍输入框现在该多高。
    ///
    /// 没拽过分隔线：内容几行就几行，最多 autoGrowLines 行，再多在框里滚。
    /// 拽过：就按拽出来的高度。
    /// 两种情况最后都要夹一下：最矮一行，最高不能把上面的正文挤没。
    private func updateInputHeight() {
        guard inputHeight != nil else { return }
        let oneLine = inputView.singleLineHeight
        let wanted = manualInputHeight
            ?? min(inputView.contentHeight, oneLine + inputView.lineHeight * (Self.autoGrowLines - 1))

        // 正文现在比下限多出来的那部分，就是输入框还能再吃掉的空间
        var ceiling = CGFloat.greatestFiniteMagnitude
        if let transcript = markdownView, transcript.frame.height > 0 {
            ceiling = inputScroll.frame.height + max(0, transcript.frame.height - Self.minTranscriptHeight)
        }
        let target = max(oneLine, min(wanted, ceiling)).rounded()
        if abs(inputHeight.constant - target) > 0.5 { inputHeight.constant = target }
    }

    @objc private func inputFrameChanged() { updateInputHeight() }

    func textDidChange(_ notification: Notification) { updateInputHeight() }

    /// 输入框里的几个特殊按键。
    /// 用输入法打字时回车是"上屏"，那一下系统自己消化掉了，走不到这里，不会误发。
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)   // ⇧回车：老老实实换行
            } else {
                submitInput()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // 多行文本框默认把 Esc 当成"弹补全菜单"，这里改回关窗
            onClose?()
            return true
        default:
            return false
        }
    }

    /// 点浮窗任意位置就把光标送进输入框——省得你还得瞄准那一条细缝去点。
    ///
    /// 但鼠标正落在正文上时不抢：那多半是要划字拷贝，
    /// 光标被抢到输入框的话，Cmd+C 拷到的就是输入框里的空气了。
    override func becomeKey() {
        super.becomeKey()

        guard let markdownView, let contentView else {
            makeFirstResponder(inputView)
            return
        }
        let point = contentView.convert(mouseLocationOutsideOfEventStream, from: nil)
        guard !markdownView.frame.contains(point) else { return }

        makeFirstResponder(inputView)
    }

    private func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    /// 装上正文视图。分开做是因为字号来自配置，得等配置读出来。
    func install(markdownView view: MarkdownView, modelName: String,
                 onCopy: @escaping () -> Void,
                 onClose: @escaping () -> Void,
                 onSubmit: @escaping (String) -> Void,
                 onHistory: @escaping (NSButton) -> Void) {
        self.markdownView = view
        self.onCopy = onCopy
        self.onClose = onClose
        self.onSubmit = onSubmit
        self.onHistory = onHistory
        setModelName(modelName)

        view.translatesAutoresizingMaskIntoConstraints = false
        // 垫在分隔线下面：正文一直铺到线上，但线上下那圈"抓手"得盖在正文上头才点得着
        effectView.addSubview(view, positioned: .below, relativeTo: divider)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: header.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: divider.centerYAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minTranscriptHeight),
        ])
        // 里面的网页固定铺到窗口底，拖线、输入框长高都不改它的大小，原因见 extendPage
        view.extendPage(toBottomOf: effectView.bottomAnchor)
    }

    func setModelName(_ name: String) {
        modelName = name
        refreshModelLabel()
    }

    /// 顶栏模型名后面跟上"这段对话用了多少 / 一共能用多少"，比如 `gemini-4-argon · 2.8万 / 100万 token`。
    /// 还没答过（0）就只显示模型名
    func setTokenUsage(_ used: Int, of window: Int) {
        tokenUsage = (used, window)
        refreshModelLabel()
    }

    private var modelName = ""
    /// 顶栏那行字现在显示的是什么，测试用
    var modelLabelText: String { modelLabel.stringValue }
    private var tokenUsage: (used: Int, window: Int) = (0, 0)

    private func refreshModelLabel() {
        guard tokenUsage.used > 0 else { modelLabel.stringValue = modelName; return }
        modelLabel.stringValue = "\(modelName) · \(Self.tokenText(tokenUsage.used)) / "
            + "\(Self.tokenText(tokenUsage.window)) token"
    }

    /// 9500 → "9500"，28201 → "2.8万"，1000000 → "100万"
    static func tokenText(_ n: Int) -> String {
        guard n >= 10_000 else { return "\(n)" }
        let wan = Double(n) / 10_000
        return wan >= 100 || wan == wan.rounded()
            ? "\(Int(wan.rounded()))万"
            : String(format: "%.1f万", wan)
    }

    @objc private func copyTapped() { onCopy?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func historyTapped(_ sender: NSButton) { onHistory?(sender) }

    /// 让外面也能叫出这张清单（`curl …/history`，或者 BTT 再绑一个手势）。
    /// 菜单得挂在那个小钟上，所以先确保它的位置已经算出来了。
    func openHistoryMenu() {
        contentView?.layoutSubtreeIfNeeded()
        onHistory?(historyButton)
    }

    /// Esc 关窗。只在面板是 key（点过浮窗）时收得到；
    /// 没点过的话请按 ⌘W——那个是全局热键，浮窗露着脸就管用。
    /// Esc 故意不做成全局的：vim、全屏视频这些地方 Esc 各有各的用处，抢了要出人命。
    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// 主菜单「关闭窗口 ⌘W」顺着 responder 链走到这儿。
    /// 平时轮不到它（全局热键在系统层就把 ⌘W 截了）；
    /// 万一热键没注册上，点过浮窗之后按 ⌘W 还有这条路兜着。
    override func performClose(_ sender: Any?) { onClose?() }

    // MARK: - 定位

    /// 算出浮窗该待在哪儿。
    ///
    /// 默认贴在鼠标右下方（像个 tooltip）。右边塞不下就翻到左边，
    /// 下边塞不下就翻到上边，最后再夹进屏幕可用区域里，保证整个窗口都看得见。
    static func frame(near mouse: NSPoint, size: NSSize, gap: CGFloat) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        // 没有屏幕信息就原地放着，总比崩了强
        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: mouse, size: size)
        }

        let margin: CGFloat = 8

        // Cocoa 的 y 轴朝上，所以"鼠标下方"是 y 变小
        var x = mouse.x + gap
        var y = mouse.y - gap - size.height

        if x + size.width > visible.maxX - margin {
            x = mouse.x - gap - size.width          // 右边不够 → 翻到左边
        }
        if y < visible.minY + margin {
            y = mouse.y + gap                        // 下边不够 → 翻到上边
        }

        // 翻完还是越界（屏幕太小 / 鼠标贴着角落），就直接夹回来
        return clamp(NSRect(x: x, y: y, width: size.width, height: size.height), near: mouse)
    }

    /// 夹进鼠标所在屏幕的可用区域，保证整个窗口都看得见。
    /// 多窗口发牌式错位（AppDelegate 那边）错到屏幕边上时也用它兜底。
    static func clamp(_ frame: NSRect, near mouse: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }

        let margin: CGFloat = 8
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX + margin), visible.maxX - frame.width - margin)
        frame.origin.y = min(max(frame.minY, visible.minY + margin), visible.maxY - frame.height - margin)
        return frame
    }

    /// 摆到算好的位置并显示出来。用 orderFrontRegardless 而不是 makeKeyAndOrderFront，
    /// 这样不会打断你正在做的事。
    /// 位置由 AppDelegate 算——它知道屏幕上还开着哪几扇窗，好错开摆放。
    func present(at frame: NSRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
    }
}
