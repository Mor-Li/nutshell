import AppKit
import WebKit
import XCTest
@testable import Nutshell

/// 没答成之后的「重试」按钮：什么时候出现，点了以后退回到哪儿、重新发的是什么。
///
/// 模型接口是假的（FakeLLM），按剧本回话或者假装断网，全程不联网。
@MainActor
final class RetryTests: XCTestCase {

    private var controller: ExplainWindowController!
    private var page: WKWebView!
    private var sessionID = ""

    private static let bubbleQ1 = "\n\n<!--ns-user-->\n第一问\n<!--/ns-user-->\n\n"

    override func setUp() async throws {
        try requireSandboxedHome()
        FakeLLM.install()
        FakeLLM.requests = []

        controller = makeController()
        page = try XCTUnwrap(findView(WKWebView.self, in: controller.panel.contentView!))

        // 先摆好一段已经聊完一轮的对话，后面的测试都从"再追问一句"开始
        sessionID = SessionStore.newID()
        controller.restore(StoredSession(
            id: sessionID, title: "测试", createdAt: Date(), updatedAt: Date(), model: "test-model",
            transcript: Self.bubbleQ1 + "第一问的回答",
            messages: [
                StoredMessage(.user(.text("第一问"))),
                StoredMessage(.assistant("第一问的回答")),
            ]
        ))
    }

    override func tearDown() async throws {
        controller.close()
        SessionStore.delete(sessionID)
    }

    private func makeController() -> ExplainWindowController {
        var config = Config()
        config.baseURL = "https://llm.test/v1"
        config.model = "test-model"
        config.apiKey = "test-not-a-real-key"
        config.rateLimitRetries = 0
        return ExplainWindowController(config: config)
    }

    // MARK: - 操作

    /// 在输入框里打一句，按回车
    private func ask(_ question: String, in target: ExplainWindowController? = nil) throws {
        let panel = (target ?? controller).panel
        let input = try XCTUnwrap(findView(InputTextView.self, in: panel.contentView!))
        input.insertText(question, replacementRange: input.selectedRange())
        _ = panel.textView(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func js(_ script: String, in view: WKWebView? = nil) async -> String {
        let result = try? await (view ?? page).evaluateJavaScript(script)
        return result.map { "\($0)" } ?? ""
    }

    private func retryButtonCount(in view: WKWebView? = nil) async -> Int {
        Int(await js("document.querySelectorAll('.retry-btn').length", in: view)) ?? -1
    }

    private func clickRetry(in view: WKWebView? = nil) async {
        _ = await js("document.querySelector('.retry-btn').click(); 0", in: view)
    }

    private func pageText(in view: WKWebView? = nil) async -> String {
        await js("document.getElementById('md').innerText", in: view)
    }

    private var stored: StoredSession? { SessionStore.load(sessionID) }

    /// 等这一轮收尾：存盘里的消息条数到了预期
    private func waitForMessages(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("存盘里有 \(count) 条消息", file: file, line: line) {
            self.stored?.messages.count == count
        }
    }

    /// 追问一句，中途断网，等它收尾
    private func askAndFail() async throws {
        FakeLLM.script(["答到一半"], dropAtEnd: true)
        try ask("第二问")
        await waitForMessages(4)
        await waitUntil("页面上出现重试按钮") { await self.retryButtonCount() == 1 }
    }

    // MARK: - 测试

    func testFailureKeepsPartialAnswerAndShowsRetry() async throws {
        try await askAndFail()

        let session = try XCTUnwrap(stored)
        XCTAssertTrue(session.transcript.contains("答到一半"))
        XCTAssertTrue(session.transcript.contains("⚠️ 中断了"))
        XCTAssertTrue(session.transcript.hasSuffix("<!--ns-failed-->"))

        let text = await pageText()
        XCTAssertTrue(text.contains("答到一半"))
        XCTAssertTrue(text.contains("重试"))
        XCTAssertFalse(text.contains("ns-failed"), "记号是给程序看的，不该显示出来")
    }

    // MARK: - token 用量

    func testTokenUsageShowsInHeaderAndIsSaved() async throws {
        FakeLLM.script(["第二问的回答"], usageTotal: 28_201)
        try ask("第二问")
        await waitForMessages(4)
        await waitUntil("存盘里记下了用量") { self.stored?.tokens == 28_201 }
        XCTAssertEqual(controller.panel.modelLabelText, "test-model · 2.8万 / 100万 token")

        // 从历史里重新打开，顶栏照样显示
        let reopened = makeController()
        defer { reopened.close() }
        reopened.restore(try XCTUnwrap(stored))
        XCTAssertEqual(reopened.panel.modelLabelText, "test-model · 2.8万 / 100万 token")
    }

    func testHeaderShowsOnlyModelBeforeAnyUsage() {
        XCTAssertEqual(controller.panel.modelLabelText, "test-model")
    }

    func testTokenTextFormat() {
        XCTAssertEqual(PopoverPanel.tokenText(925), "925")
        XCTAssertEqual(PopoverPanel.tokenText(9_999), "9999")
        XCTAssertEqual(PopoverPanel.tokenText(28_201), "2.8万")
        XCTAssertEqual(PopoverPanel.tokenText(30_000), "3万")
        XCTAssertEqual(PopoverPanel.tokenText(1_000_000), "100万")
        XCTAssertEqual(PopoverPanel.tokenText(1_234_567), "123万")
    }

    func testRetryRedoesTheLastQuestionCleanly() async throws {
        try await askAndFail()

        FakeLLM.script(["这回", "答完整了"])
        await clickRetry()
        await waitUntil("重试的回答存盘") { self.stored?.transcript.contains("这回答完整了") == true }

        let session = try XCTUnwrap(stored)
        XCTAssertFalse(session.transcript.contains("答到一半"), "半截回答应该被抹掉")
        XCTAssertFalse(session.transcript.contains("中断了"))
        XCTAssertFalse(session.transcript.contains("ns-failed"))
        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(session.messages.last?.text, "这回答完整了")
        // 问题只出现一次，没有因为重试多出一个气泡
        XCTAssertEqual(session.transcript.components(separatedBy: "第二问").count - 1, 1)

        // 重发给模型的历史里，不能带着上次那条半截回答
        let resent = try XCTUnwrap(FakeLLM.requests.last)
        XCTAssertEqual(resent.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(resent.last?["content"] as? String, "第二问")

        await waitUntil("重试按钮消失") { await self.retryButtonCount() == 0 }
    }

    func testRetryThatFailsAgainDoesNotPileUpErrors() async throws {
        try await askAndFail()

        FakeLLM.script(["又断了"], dropAtEnd: true)
        await clickRetry()
        await waitUntil("第二次失败存盘") { self.stored?.transcript.contains("又断了") == true }

        let session = try XCTUnwrap(stored)
        XCTAssertEqual(session.transcript.components(separatedBy: "中断了").count - 1, 1)
        XCTAssertFalse(session.transcript.contains("答到一半"))
        XCTAssertEqual(session.messages.count, 4)
        await waitUntil("还是只有一个重试按钮") { await self.retryButtonCount() == 1 }
    }

    func testAskingSomethingElseDismissesRetry() async throws {
        try await askAndFail()

        FakeLLM.script(["第三问的回答"])
        try ask("第三问")
        await waitForMessages(6)

        await waitUntil("重试按钮消失") { await self.retryButtonCount() == 0 }
        let text = await pageText()
        XCTAssertTrue(text.contains("答到一半"), "没重试的话，之前的半截回答照旧留着")
        XCTAssertFalse(text.contains("ns-failed"))
    }

    func testRetryStillThereAfterReopeningFromHistory() async throws {
        try await askAndFail()

        // 换一扇新窗，从存盘里把这段对话翻出来
        let reopened = makeController()
        let reopenedPage = try XCTUnwrap(findView(WKWebView.self, in: reopened.panel.contentView!))
        reopened.restore(try XCTUnwrap(stored))
        await waitUntil("翻出来的对话也有重试按钮") { await self.retryButtonCount(in: reopenedPage) == 1 }

        FakeLLM.script(["从历史里重试成功"])
        await clickRetry(in: reopenedPage)
        await waitUntil("重试的回答存盘") { self.stored?.transcript.contains("从历史里重试成功") == true }
        XCTAssertEqual(stored?.messages.count, 4)
        reopened.close()
    }

    func testNoRetryButtonOnAHealthyAnswer() async throws {
        FakeLLM.script(["正常答完"])
        try ask("第二问")
        await waitForMessages(4)
        let count = await retryButtonCount()
        XCTAssertEqual(count, 0)
    }
}
