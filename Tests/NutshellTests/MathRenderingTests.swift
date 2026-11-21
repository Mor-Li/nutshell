import AppKit
import WebKit
import XCTest
@testable import Nutshell

/// 数学公式：模型写的 $…$、$$…$$、\(…\)、\[…\] 要排成公式，
/// 钱数、代码里的 $ 不能被误当成公式。
@MainActor
final class MathRenderingTests: XCTestCase {

    private var controller: ExplainWindowController!
    private var page: WKWebView!
    private var sessionID = ""

    private static let answer = #"""
    行内公式 $E = mc^2$ 和 \(a_i^2 + b_i^2\)，还有下标别被当成斜体：$x_1 + x_2$。

    $$
    \sum_{i=1}^{n} i = \frac{n(n+1)}{2}
    $$

    \[
    \begin{aligned} f(x) &= x^2 \\ g(x) &= \sqrt{x} \end{aligned}
    \]

    价格从 $5 涨到 $10，这句里没有公式。

    代码里的 `echo $HOME` 也不是公式。

    ```bash
    echo $PATH $HOME
    ```
    """#

    override func setUp() async throws {
        try requireSandboxedHome()
        var config = Config()
        config.baseURL = "https://llm.test/v1"
        config.model = "test-model"
        config.apiKey = "test-not-a-real-key"
        controller = ExplainWindowController(config: config)
        page = try XCTUnwrap(findView(WKWebView.self, in: controller.panel.contentView!))

        sessionID = SessionStore.newID()
        controller.restore(StoredSession(
            id: sessionID, title: "公式", createdAt: Date(), updatedAt: Date(), model: "test-model",
            transcript: "\n\n<!--ns-user-->\n讲讲公式\n<!--/ns-user-->\n\n" + Self.answer,
            messages: [
                StoredMessage(.user(.text("讲讲公式"))),
                StoredMessage(.assistant(Self.answer)),
            ]
        ))
        await waitUntil("页面渲染出正文") { await self.js("document.querySelectorAll('.md-block').length") == "1" }
    }

    override func tearDown() async throws {
        controller.close()
        SessionStore.delete(sessionID)
    }

    private func js(_ script: String) async -> String {
        let result = try? await page.evaluateJavaScript(script)
        return result.map { "\($0)" } ?? ""
    }

    func testKatexIsLoaded() async {
        let type = await js("typeof katex")
        XCTAssertEqual(type, "object")
    }

    func testAllFourDelimitersBecomeFormulas() async {
        // 两个 $…$、一个 \(…\) 是行内，$$…$$ 和 \[…\] 各一个独占一行
        let inline = await js("document.querySelectorAll('.katex:not(.katex-display .katex)').length")
        let display = await js("document.querySelectorAll('.katex-display').length")
        XCTAssertEqual(inline, "3")
        XCTAssertEqual(display, "2")
        let errors = await js("document.querySelectorAll('.katex-error').length")
        XCTAssertEqual(errors, "0", "有公式没排出来")
    }

    func testFormulaInternalsAreNotEatenByMarkdown() async {
        // x_1 + x_2 里的下划线不能被 markdown 当成斜体
        let ems = await js("document.querySelectorAll('.md-block em').length")
        XCTAssertEqual(ems, "0")
        // aligned 里的 \\ 换行要保住：排出来是两行
        // （KaTeX 顺带输出一份 MathML，数它的 <mtr> 行最省事）
        let rows = await js("document.querySelectorAll('.katex-display')[1].querySelectorAll('mtr').length")
        XCTAssertEqual(rows, "2")
    }

    func testMoneyAndCodeStayPlainText() async {
        let text = await js("document.getElementById('md').innerText")
        XCTAssertTrue(text.contains("价格从 $5 涨到 $10"), text)
        XCTAssertTrue(text.contains("echo $HOME"), text)
        XCTAssertTrue(text.contains("echo $PATH $HOME"), text)
        let inCode = await js("document.querySelectorAll('code .katex, pre .katex').length")
        XCTAssertEqual(inCode, "0")
    }

    /// 设了 NUTSHELL_SNAPSHOT=目录 就把渲染结果存成图，方便人眼看一下
    func testSnapshotForHumans() async throws {
        guard let dir = ProcessInfo.processInfo.environment["NUTSHELL_SNAPSHOT"] else { return }
        let image = try await page.takeSnapshot(configuration: nil)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("math.png"))
    }
}
