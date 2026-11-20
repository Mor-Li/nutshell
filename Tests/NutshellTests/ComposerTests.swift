import AppKit
import XCTest
@testable import Nutshell

/// 浮窗底部那一条：输入框自己长高、分隔线能拖、回车发送。
@MainActor
final class ComposerTests: XCTestCase {

    private var panel: PopoverPanel!
    private var input: InputTextView!
    private var scroll: NSScrollView!
    private var divider: DividerHandle!
    private var transcript: MarkdownView!
    private var submitted: [String] = []

    override func setUp() async throws {
        submitted = []
        panel = PopoverPanel(size: NSSize(width: 460, height: 520))
        transcript = MarkdownView(fontSize: 14.5)
        panel.install(
            markdownView: transcript, modelName: "test",
            onCopy: {}, onClose: {},
            onSubmit: { [unowned self] text in self.submitted.append(text) },
            onHistory: { _ in }
        )
        // 窗口必须"在场"，系统才肯把鼠标事件分给里面的视图。
        // 所以让它在场但全透明，真实鼠标点不着它，它也不去抢键盘，跑测试时屏幕上什么都看不到。
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.orderFrontRegardless()

        let root = try XCTUnwrap(panel.contentView)
        input = try XCTUnwrap(findView(InputTextView.self, in: root))
        scroll = try XCTUnwrap(input.enclosingScrollView)
        divider = try XCTUnwrap(findView(DividerHandle.self, in: root))
        layout()
    }

    override func tearDown() async throws {
        panel.close()
    }

    private func layout() { panel.contentView?.layoutSubtreeIfNeeded() }

    private func type(_ text: String) {
        input.insertText(text, replacementRange: input.selectedRange())
        layout()
    }

    private func pressReturn() {
        _ = panel.textView(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        layout()
    }

    /// 分隔线正中间在窗口坐标里的位置
    private var dividerCenter: NSPoint {
        divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        )!
        // 走窗口自己的事件分发：谁被点中、拖动归谁，都按真实规矩来
        panel.sendEvent(event)
    }

    /// 按住分隔线往上拖 dy（负数是往下）
    private func dragDivider(by dy: CGFloat) {
        let start = dividerCenter
        mouse(.leftMouseDown, at: start)
        for step in 1...5 {
            mouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y + dy * CGFloat(step) / 5))
            layout()
        }
        mouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y + dy))
        layout()
    }

    // MARK: - 自动长高

    func testStartsAtOneLine() {
        XCTAssertEqual(scroll.frame.height, input.singleLineHeight, accuracy: 1)
    }

    func testGrowsLineByLineWithContent() {
        let one = scroll.frame.height
        type("第一行\n第二行\n第三行")
        XCTAssertEqual(scroll.frame.height, one + input.lineHeight * 2, accuracy: 2)
    }

    func testLongLineWrapsAndGrows() {
        let one = scroll.frame.height
        type(String(repeating: "很长的一句话，", count: 30))
        XCTAssertGreaterThan(scroll.frame.height, one + input.lineHeight)
    }

    func testStopsGrowingAtEightLinesThenScrolls() {
        type((1...40).map { "第 \($0) 行" }.joined(separator: "\n"))
        XCTAssertEqual(scroll.frame.height, input.singleLineHeight + input.lineHeight * 7, accuracy: 2)
        // 字比框高，多出来的在框里滚
        XCTAssertGreaterThan(input.frame.height, scroll.frame.height)
    }

    func testShrinksBackWhenTextIsDeleted() {
        type("一\n二\n三\n四")
        input.selectAll(nil)
        input.insertText("", replacementRange: input.selectedRange())
        layout()
        XCTAssertEqual(scroll.frame.height, input.singleLineHeight, accuracy: 1)
    }

    // MARK: - 回车

    func testReturnSendsAndClears() {
        type("  一加一等于几  \n第二行")
        pressReturn()
        XCTAssertEqual(submitted, ["一加一等于几  \n第二行"])
        XCTAssertEqual(input.string, "")
        XCTAssertEqual(scroll.frame.height, input.singleLineHeight, accuracy: 1)
    }

    func testReturnOnEmptyDoesNothing() {
        type("   ")
        pressReturn()
        XCTAssertTrue(submitted.isEmpty)
    }

    func testReturnWhileAnsweringKeepsTheDraft() {
        panel.setInputEnabled(false)
        type("先打好的下一句")
        pressReturn()
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(input.string, "先打好的下一句")

        panel.setInputEnabled(true)
        pressReturn()
        XCTAssertEqual(submitted, ["先打好的下一句"])
    }

    // MARK: - 分隔线

    func testDividerIsWhatYouGrabAtTheLine() {
        let hit = panel.contentView?.hitTest(dividerCenter)
        XCTAssertTrue(hit === divider, "点在线上，点中的却是 \(String(describing: hit))")
        XCTAssertFalse(divider.mouseDownCanMoveWindow)
    }

    func testDragUpMakesInputTaller() {
        let before = scroll.frame.height
        let transcriptBefore = transcript.frame.height
        let windowBefore = panel.frame
        dragDivider(by: 100)
        XCTAssertEqual(scroll.frame.height, before + 100, accuracy: 1)
        XCTAssertEqual(transcript.frame.height, transcriptBefore - 100, accuracy: 1)
        XCTAssertEqual(panel.frame, windowBefore, "拖的是线，窗口不该跟着动")
    }

    func testDragDownMakesItShorterAgain() {
        dragDivider(by: 100)
        dragDivider(by: -60)
        XCTAssertEqual(scroll.frame.height, input.singleLineHeight + 40, accuracy: 1)
    }

    func testDragCannotSqueezeTranscriptAway() {
        dragDivider(by: 2000)
        XCTAssertEqual(transcript.frame.height, 60, accuracy: 1)
        dragDivider(by: -2000)
        XCTAssertEqual(scroll.frame.height, input.singleLineHeight, accuracy: 1)
    }

    func testDraggedHeightHoldsWhileTyping() {
        dragDivider(by: 30)
        let dragged = scroll.frame.height
        type((1...40).map { "第 \($0) 行" }.joined(separator: "\n"))
        XCTAssertEqual(scroll.frame.height, dragged, accuracy: 1)
    }

    func testDoubleClickGoesBackToAuto() {
        dragDivider(by: 100)
        mouse(.leftMouseDown, at: dividerCenter, clicks: 2)
        mouse(.leftMouseUp, at: dividerCenter, clicks: 2)
        layout()
        XCTAssertEqual(scroll.frame.height, input.singleLineHeight, accuracy: 1)
    }

    func testSendingForgetsDraggedHeight() {
        dragDivider(by: 100)
        type("发出去")
        pressReturn()
        XCTAssertEqual(scroll.frame.height, input.singleLineHeight, accuracy: 1)
    }

    func testShrinkingWindowNeverGrowsItBack() {
        type((1...40).map { "第 \($0) 行" }.joined(separator: "\n"))
        let frame = panel.frame
        layout()
        XCTAssertEqual(panel.frame.size, frame.size, "输入框长高只能挤正文，不能把窗口撑大")
    }
}
