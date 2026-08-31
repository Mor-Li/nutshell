import AppKit

/// 一扇浮窗 = 一段对话 = 一条自己的 LLM 通道。
///
/// 以前整个程序只有一扇窗，对话状态全堆在 AppDelegate 里，天生只装得下一段对话。
/// 现在每按一次快捷键就开一扇新窗，几段解读可以同时摆在屏幕上对照着看，
/// 所以把"这扇窗手上那段对话"的全部家当（消息历史、正文、正在流的字、存档身份证）
/// 收进这个类，各窗各管各的，互不串线——这边还在蹦字，那边照样能开新的。
@MainActor
final class ExplainWindowController {

    let panel: PopoverPanel
    private let config: Config
    /// 每扇窗自己的通道：关这扇窗只取消这扇窗的请求，别的窗接着流
    private let llm = LLMClient()

    /// 发给模型的完整对话历史（含剪贴板那段开场白）
    private var conversation: [ChatMessage] = []
    /// 浮窗里已经定稿的内容（前几轮问答）
    private var transcript = ""
    /// 这一轮正在往外蹦的字
    private var accumulated = ""

    /// 手上这段对话在历史里的身份证。答完一轮就按这个 id 覆盖存一次盘。
    private(set) var currentSessionID: String?
    private var currentTitle = ""
    private var currentCreatedAt = Date()

    /// 窗关掉之后喊一声，AppDelegate 好把它从名册上划掉、把 ⌘W 该还就还
    var onClosed: ((ExplainWindowController) -> Void)?
    /// 点了顶栏的小钟。历史清单是全局的事（删一条、清空会牵动所有窗），
    /// 菜单由 AppDelegate 统一画，这里只负责喊人并说明是哪扇窗要看
    var onHistoryMenu: ((ExplainWindowController, NSButton) -> Void)?

    init(config: Config) {
        self.config = config

        let size = NSSize(width: config.window.width, height: config.window.height)
        panel = PopoverPanel(size: size)

        let markdownView = MarkdownView(fontSize: config.window.fontSize)
        panel.install(
            markdownView: markdownView,
            modelName: config.model,
            onCopy: { [weak self] in self?.copyTranscript() },
            onClose: { [weak self] in self?.close() },
            onSubmit: { [weak self] question in self?.askFollowUp(question) },
            onHistory: { [weak self] button in
                guard let self else { return }
                self.onHistoryMenu?(self, button)
            }
        )
    }

    // MARK: - 开场的几种方式

    /// 在指定位置支起窗来，读剪贴板，开一段全新的对话
    func beginFromClipboard(frame: NSRect) {
        accumulated = ""
        panel.markdownView.beginThinking(label: "正在读剪贴板…")
        panel.present(at: frame)

        // 让窗口先画出来，再去干读剪贴板和发请求的活
        DispatchQueue.main.async { [weak self] in self?.captureAndAsk() }
    }

    /// 在这扇窗里换一段新对话（历史菜单里的「＋ 新对话」）：
    /// 手上这段先存好、正在跑的请求掐掉，然后重读剪贴板从头来
    func restartFromClipboard() {
        stashCurrentSession()
        Task { await llm.cancel() }
        accumulated = ""
        panel.markdownView.beginThinking(label: "正在读剪贴板…")
        DispatchQueue.main.async { [weak self] in self?.captureAndAsk() }
    }

    /// 把一段历史对话装进这扇窗：界面复原成当时的样子，
    /// 模型那边的上下文也一起接上，直接在底下输入框接着问就行
    func restore(_ stored: StoredSession) {
        stashCurrentSession()
        Task { await llm.cancel() }

        conversation = stored.messages.map(\.chatMessage)
        transcript = stored.transcript
        accumulated = ""
        currentSessionID = stored.id
        currentTitle = stored.title
        currentCreatedAt = stored.createdAt

        panel.setInputEnabled(true)
        panel.markdownView.restore(markdown: stored.transcript)
    }

    /// `curl …/history` 在一扇窗都没有时叫出来的空窗：垫句话，别开着白板
    func showPlaceholder(frame: NSRect) {
        panel.markdownView.restore(
            markdown: "从上面那个小钟里挑一段接着聊。\n\n或者复制点东西、按一下快捷键，开段新的。"
        )
        panel.present(at: frame)
    }

    // MARK: - 收摊

    /// 关窗：停掉正在跑的请求，半截回答也存进历史，然后整扇窗拆掉。
    /// 窗是真拆（不是藏起来），这段对话要再看去历史菜单里找。
    func close() {
        Task { await llm.cancel() }
        stashCurrentSession()
        panel.close()
        onClosed?(self)
    }

    /// 历史里那条被删了：手上的身份证跟着作废，再答一轮也不会把文件写回来
    func forgetSession(_ id: String) {
        if currentSessionID == id { currentSessionID = nil }
    }

    /// 历史整个清空了：不管手上是哪条，一律作废
    func forgetAnySession() {
        currentSessionID = nil
    }

    // MARK: - 主流程

    /// 开一轮新的：读剪贴板，作为对话的第一条消息发出去
    private func captureAndAsk() {
        let input: CapturedInput
        do {
            input = try InputCapture.capture(config: config)
        } catch {
            panel.markdownView.showError(error.localizedDescription)
            return
        }

        // 把剪贴板内容套进 prompt 模板，这就是对话的开场白。
        // 浮窗里则把你选的原文画成右侧气泡——发出去的是模板包装过的，
        // 但你自己看的时候，认的是自己选的那段话，不是那套固定说辞。
        let opening: ChatMessage.Content
        let thinkingLabel: String
        switch input {
        case .text(let body):
            opening = .text(config.promptTemplate.replacingOccurrences(of: "{content}", with: body))
            transcript = Self.userBubble(body)
            thinkingLabel = "\(config.model) 正在琢磨…"

        case .images(let images, let note):
            var instruction = config.imagePromptTemplate
            if let note, !note.isEmpty { instruction += "\n\n补充信息：\n\(note)" }
            opening = .multimodal(text: instruction, images: images)
            var bubble = images.count > 1 ? "📷 图片 ×\(images.count)" : "📷 图片"
            if let note, !note.isEmpty { bubble += "\n" + note }
            transcript = Self.userBubble(bubble)
            thinkingLabel = "正在看图（\(images.count) 张）…"
        }

        conversation = [.user(opening)]
        panel.markdownView.beginRound(markdown: transcript, label: thinkingLabel)

        // 新的一段对话，发一张新身份证；标题取剪贴板开头那几个字，历史菜单里认得出
        currentSessionID = SessionStore.newID()
        currentTitle = SessionStore.makeTitle(from: input)
        currentCreatedAt = Date()

        send(retryOnAuthFailure: true)
    }

    /// 追问：把新问题接到对话后面再发一次
    private func askFollowUp(_ question: String) {
        guard !conversation.isEmpty else { return }

        conversation.append(.user(.text(question)))

        // 问题也画成气泡挂上去，不然滚上去看只有一堆回答，不知道在答什么
        transcript += Self.userBubble(question)
        panel.markdownView.beginRound(markdown: transcript, label: "\(config.model) 正在琢磨…")
        send(retryOnAuthFailure: true)
    }

    /// 把"你说的话"包上标记写进 transcript，viewer.html 认得它，
    /// 会画成右侧的聊天气泡。首尾的空行保证它和前后的 markdown 各成一段。
    private static func userBubble(_ text: String) -> String {
        "\n\n<!--ns-user-->\n\(text)\n<!--/ns-user-->\n\n"
    }

    /// 复制出去的全文别带渲染标记，翻成人能读的样子
    private static func plainTranscript(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "<!--ns-user-->\n", with: "【你问】")
            .replacingOccurrences(of: "<!--ns-user-->", with: "【你问】")
            .replacingOccurrences(of: "\n<!--/ns-user-->", with: "")
            .replacingOccurrences(of: "<!--/ns-user-->", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            Self.plainTranscript(panel.markdownView.currentMarkdown), forType: .string
        )
    }

    /// - Parameter retryOnAuthFailure: 撞 401 时重新去 shell 捞一次 key 再试。
    ///   key 轮换后旧的会失效，缓存里那个就是废的——不重捞会一直 401。
    private func send(retryOnAuthFailure: Bool) {
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
                    self.panel.markdownView.update(markdown: settled + self.accumulated)
                },
                onRetry: { [weak self] round, total in
                    guard let self else { return }
                    let seconds = String(format: "%g", config.rateLimitRetryDelay)
                    let note = "⏳ 被限流了，\(seconds) 秒后自动重试（第 \(round)/\(total) 次）…"
                    if settled.isEmpty {
                        self.panel.markdownView.beginThinking(label: note)
                    } else {
                        // 前面几轮问答还在窗里摆着，别拿"正在琢磨"把它们盖掉
                        self.panel.markdownView.update(markdown: settled + "\n\n" + note)
                    }
                },
                onFinish: { [weak self] error in
                    guard let self else { return }
                    self.panel.setInputEnabled(true)

                    guard let error else {
                        self.settleRound(settled: settled)
                        self.panel.markdownView.finish()
                        self.persistCurrentSession()
                        return
                    }

                    // 一个字都没吐就 401 → key 多半换过了，重捞一次再试
                    if retryOnAuthFailure,
                       self.accumulated.isEmpty,
                       error.localizedDescription.contains("401") {
                        self.panel.markdownView.beginThinking(label: "key 像是过期了，重新读一次…")
                        self.send(retryOnAuthFailure: false)
                        return
                    }

                    // 已经吐了一半才出错的话，别把已有内容擦掉
                    if self.accumulated.isEmpty && settled.isEmpty {
                        self.panel.markdownView.showError(error.localizedDescription)
                    } else {
                        self.accumulated += "\n\n⚠️ 中断了：\(error.localizedDescription)"
                        self.settleRound(settled: settled)
                        self.panel.markdownView.update(markdown: self.transcript)
                        self.panel.markdownView.finish()
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
}
