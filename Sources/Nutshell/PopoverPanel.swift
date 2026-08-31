import AppKit

/// 冒在鼠标旁边的那个小浮窗。
///
/// 用 NSPanel 而不是普通窗口，关键在 `.nonactivatingPanel`：
/// 它可以浮在最上层、可以点、可以滚，但**不会把你当前用的 app 切到后台**——
/// 你在 Safari 里选段话弹出它，Safari 依旧是前台，Dock 不跳，command-tab 顺序不变。
final class PopoverPanel: NSPanel {

    /// 允许成为 key window，这样窗口里的文字能选中、能 Cmd+C 拷走。
    /// 但显示时我们用 orderFrontRegardless()，所以它不会主动来抢——你点它才给。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private let header = NSView()
    private var historyButton: NSButton!
    private let modelLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private let divider = NSBox()
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

        // 底部追问输入框
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(divider)

        inputField.placeholderString = "接着问点什么…（回车发送）"
        inputField.font = .systemFont(ofSize: 13)
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.target = self
        inputField.action = #selector(inputSubmitted)
        inputField.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(inputField)

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

            divider.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -8),

            inputField.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            inputField.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
            inputField.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -11),
        ])
    }

    @objc private func inputSubmitted() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""
        onSubmit?(text)
    }

    /// 等回复的时候把输入框锁上，免得连着发好几条把对话搅乱
    func setInputEnabled(_ enabled: Bool) {
        inputField.isEnabled = enabled
        inputField.placeholderString = enabled ? "接着问点什么…（回车发送）" : "正在回答…"
    }

    /// 点浮窗任意位置就把光标送进输入框——省得你还得瞄准那一条细缝去点。
    ///
    /// 但鼠标正落在正文上时不抢：那多半是要划字拷贝，
    /// 光标被抢到输入框的话，Cmd+C 拷到的就是输入框里的空气了。
    override func becomeKey() {
        super.becomeKey()

        guard let markdownView, let contentView else {
            makeFirstResponder(inputField)
            return
        }
        let point = contentView.convert(mouseLocationOutsideOfEventStream, from: nil)
        guard !markdownView.frame.contains(point) else { return }

        makeFirstResponder(inputField)
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
        modelLabel.stringValue = modelName

        view.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: header.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: divider.topAnchor),
        ])
    }

    func setModelName(_ name: String) { modelLabel.stringValue = name }

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
