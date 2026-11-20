import AppKit

/// 浮窗底部那一条"打字区"用到的两个小零件：
/// 能自己长高的多行输入框，和输入框上面那根可以拽的分隔线。

// MARK: - 输入框

/// 多行输入框的本体。
///
/// 以前用的是 NSTextField：它天生是单行的，粘一大段进来字会叠在一条细缝里。
/// 换成 NSTextView 之后能正常折行，外面的 PopoverPanel 再按它的内容高度把框撑开。
/// NSTextView 没有自带的占位提示，所以空着的时候自己画一行灰字。
final class InputTextView: NSTextView {

    var placeholder = "" { didSet { needsDisplay = true } }

    /// 手工搭一套老式排版栈（TextKit 1）：量"内容排完占多高"要用到 layoutManager，
    /// 直接说清楚用哪套，省得系统先给新的、被我们一碰又悄悄退回旧的。
    static func make(fontSize: CGFloat) -> InputTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        layout.addTextContainer(container)

        let view = InputTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: container)
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false            // 粘进来的东西一律当纯文字，不带原来的字体颜色
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFontPanel = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 2)

        // 放进滚动容器里的标准姿势：宽度跟着容器走，高度随内容长
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        return view
    }

    /// 一行字有多高
    var lineHeight: CGFloat {
        layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 13)) ?? 16
    }

    /// 只放一行字时整个框要多高
    var singleLineHeight: CGFloat { lineHeight + textContainerInset.height * 2 }

    /// 现在这些字排完版实际要多高
    var contentHeight: CGFloat {
        guard let layoutManager, let textContainer else { return singleLineHeight }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        return max(used, lineHeight) + textContainerInset.height * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        placeholder.draw(
            at: NSPoint(x: origin.x + padding, y: origin.y),
            withAttributes: [
                .font: font ?? .systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
    }

    /// 从空变成有字（或反过来）时，那行灰字要跟着消失或出现
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

// MARK: - 分隔线

/// 正文和输入框之间那根线。按住它上下拖，可以改输入框的高度。
///
/// 线本身只有 1 像素，直接让人去瞄准太难，所以这个视图比线高一圈，
/// 整圈都算"抓得住"的范围。鼠标移上来线会变粗变色，告诉你这里能拽。
final class DividerHandle: NSView {

    /// 刚按下
    var onDragBegan: (() -> Void)?
    /// 拖动中。参数是相对按下那一刻往上挪了多少，往下是负数
    var onDrag: ((CGFloat) -> Void)?
    /// 双击
    var onDoubleClick: (() -> Void)?

    private var startY: CGFloat = 0
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }

    /// 整扇浮窗是"按住空白处就能拖着走"的，这根线得声明自己不算空白，
    /// 不然一拽它，动的是整个窗口
    override var mouseDownCanMoveWindow: Bool { false }

    /// 浮窗还没被点过时，第一下就算数，不用先点一下再拖
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let active = hovering || dragging
        let thickness: CGFloat = active ? 3 : 1
        let color: NSColor = active
            ? .controlAccentColor.withAlphaComponent(0.65)
            : .separatorColor
        color.setFill()
        NSRect(
            x: 0, y: ((bounds.height - thickness) / 2).rounded(),
            width: bounds.width, height: thickness
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // activeAlways：浮窗从不抢前台，不加这个的话只有点过它之后鼠标移上来才有反应
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.resizeUpDown.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !dragging { NSCursor.arrow.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        startY = event.locationInWindow.y
        dragging = true
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        // 窗口坐标的 y 轴朝上，所以往上拖是正数
        onDrag?(event.locationInWindow.y - startY)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        if !hovering { NSCursor.arrow.set() }
    }
}
