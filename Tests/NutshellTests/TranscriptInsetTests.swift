import AppKit
import WebKit
import XCTest
@testable import Nutshell

/// 正文那块网页和底部打字区的配合。
///
/// 要守住的事：拖分隔线、输入框长高，都不许改网页视图的大小，
/// 只告诉页面"底下让出多高"。改大小的做法出过"线上面一块空白"的毛病，
/// 来龙去脉见 MarkdownView.extendPage。
@MainActor
final class TranscriptInsetTests: XCTestCase {

    private var panel: PopoverPanel!
    private var transcript: MarkdownView!
    private var page: WKWebView!
    private var input: InputTextView!
    private var divider: DividerHandle!

    override func setUp() async throws {
        panel = PopoverPanel(size: NSSize(width: 460, height: 520))
        transcript = MarkdownView(fontSize: 14.5)
        panel.install(
            markdownView: transcript, modelName: "test",
            onCopy: {}, onClose: {}, onSubmit: { _ in }, onHistory: { _ in }
        )
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.orderFrontRegardless()

        let root = try XCTUnwrap(panel.contentView)
        page = try XCTUnwrap(findView(WKWebView.self, in: root))
        input = try XCTUnwrap(findView(InputTextView.self, in: root))
        divider = try XCTUnwrap(findView(DividerHandle.self, in: root))

        transcript.restore(markdown: (1...80).map { "第 \($0) 段，随便写点字把页面撑长。" }.joined(separator: "\n\n"))
        await waitUntil("页面渲染出来") { await self.js("document.getElementById('md').children.length") > 0 }
        layout()
    }

    override func tearDown() async throws { panel.close() }

    private func layout() { panel.contentView?.layoutSubtreeIfNeeded() }

    private func js(_ script: String) async -> Double {
        ((try? await page.evaluateJavaScript(script)) as? NSNumber)?.doubleValue ?? -1
    }

    private func dragDivider(by dy: CGFloat) {
        let start = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, _ y: CGFloat) {
            panel.sendEvent(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: start.x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!)
        }
        mouse(.leftMouseDown, start.y)
        for step in 1...5 { mouse(.leftMouseDragged, start.y + dy * CGFloat(step) / 5); layout() }
        mouse(.leftMouseUp, start.y + dy)
        layout()
    }

    /// 页面里能滚动的那块，高度应该正好等于正文区域露出来的高度
    private func assertPageFitsVisibleArea(file: StaticString = #filePath, line: UInt = #line) async {
        let visible = transcript.bounds.height
        await waitUntil("页面的可视高度跟上（应为 \(visible)）", file: file, line: line) {
            abs(await self.js("document.getElementById('scroll').clientHeight") - visible) <= 1
        }
    }

    func testPageRunsToWindowBottomUnderTheComposer() async {
        let root = panel.contentView!
        XCTAssertEqual(page.frame.height, root.bounds.height - 28, accuracy: 1, "网页应从顶栏一直铺到窗口底")
        XCTAssertLessThan(transcript.bounds.height, page.frame.height)
        await assertPageFitsVisibleArea()
    }

    func testDraggingDividerNeverResizesThePage() async {
        let size = page.frame.size
        dragDivider(by: 150)
        XCTAssertEqual(page.frame.size, size)
        await assertPageFitsVisibleArea()

        dragDivider(by: -100)
        XCTAssertEqual(page.frame.size, size)
        await assertPageFitsVisibleArea()

        let inner = await js("window.innerHeight")
        XCTAssertEqual(inner, size.height, accuracy: 1)
    }

    func testGrowingInputNeverResizesThePage() async {
        let size = page.frame.size
        input.insertText((1...6).map { "第 \($0) 行" }.joined(separator: "\n"), replacementRange: input.selectedRange())
        layout()
        XCTAssertEqual(page.frame.size, size)
        await assertPageFitsVisibleArea()
    }

    func testStaysAtBottomWhenComposerGrows() async {
        // restore 之后停在最后一句上
        dragDivider(by: 180)
        await assertPageFitsVisibleArea()
        let gap = await js("(function(){var s=document.getElementById('scroll');return s.scrollHeight-s.scrollTop-s.clientHeight})()")
        XCTAssertLessThan(gap, 2, "打字区变高之后，最后几行不该被挡到线下面")
    }

    func testClicksBelowTheLineGoToTheComposerNotThePage() {
        let inInput = input.convert(NSPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
        let hit = panel.contentView?.hitTest(inInput)
        XCTAssertTrue(hit === input, "点在输入框上，点中的却是 \(String(describing: hit))")
    }
}
