import AppKit
import WebKit

/// 浮窗里显示内容的那块。本质是个 WKWebView，跑着内嵌的 viewer.html + marked.js。
///
/// 为什么不用 SwiftUI 原生的 markdown：系统那个 `AttributedString(markdown:)` 只认粗体斜体链接，
/// 标题、列表、代码块、表格统统不支持——而模型回复里这些天天出现。
final class MarkdownView: NSView {

    private let webView: WKWebView
    private var isPageReady = false

    /// 页面还没加载好时先攒着，加载完一次性补上
    private var pendingCommands: [String] = []

    // 流式更新节流：模型一个字一个字地吐，不能来一个就重渲染一次
    private var latestMarkdown = ""
    private var lastFlush = Date.distantPast
    private var flushTimer: Timer?
    private let flushInterval: TimeInterval = 0.05

    init(fontSize: Double) {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)

        webView.setValue(false, forKey: "drawsBackground")   // 让底下的毛玻璃透上来
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        webView.loadHTMLString(Self.pageHTML(fontSize: fontSize), baseURL: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 对外接口

    /// 开始新一轮：清空内容，显示"正在琢磨…"
    func beginThinking(label: String) {
        flushTimer?.invalidate()
        latestMarkdown = ""
        lastFlush = .distantPast
        run("window.nsState('thinking', \(Self.jsString(label)))")
    }

    /// 收到新内容（传全量文本，页面负责整体重渲染——比增量拼 DOM 可靠得多）
    func update(markdown: String) {
        latestMarkdown = markdown

        let elapsed = Date().timeIntervalSince(lastFlush)
        if elapsed >= flushInterval {
            flush()
        } else if flushTimer == nil || !(flushTimer?.isValid ?? false) {
            flushTimer = Timer.scheduledTimer(
                withTimeInterval: flushInterval - elapsed, repeats: false
            ) { [weak self] _ in
                self?.flush()
            }
        }
    }

    func finish() {
        flushTimer?.invalidate()
        flushTimer = nil
        flush()
        run("window.nsState('done')")
    }

    /// 把一份存好的对话整个铺上去（切换历史时用）。
    /// 不走流式那套节流——内容是现成的，直接渲染完，顺手滚到最后一句。
    func restore(markdown: String) {
        flushTimer?.invalidate()
        flushTimer = nil
        latestMarkdown = markdown
        lastFlush = Date()
        run("window.nsRestore(\(Self.jsString(markdown)))")
    }

    func showError(_ message: String) {
        flushTimer?.invalidate()
        flushTimer = nil
        run("window.nsError(\(Self.jsString(message)))")
    }

    func setFontSize(_ size: Double) {
        run("window.nsFontSize(\(size))")
    }

    var currentMarkdown: String { latestMarkdown }

    // MARK: - 内部

    private func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        lastFlush = Date()
        run("window.nsState('streaming'); window.nsRender(\(Self.jsString(latestMarkdown)))")
    }

    private func run(_ javascript: String) {
        guard isPageReady else {
            pendingCommands.append(javascript)
            return
        }
        webView.evaluateJavaScript(javascript)
    }

    /// 把 Swift 字符串安全地变成 JS 字面量（引号、换行、Unicode 全交给 JSON 编码器处理）
    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())   // 去掉外层的 [ ]
    }

    /// 把 marked.min.js 塞进 viewer.html 的占位符里，一次性 load 进去。
    /// 全内联的好处：不依赖 file:// 路径，也不需要联网拉 CDN。
    private static func pageHTML(fontSize: Double) -> String {
        let bundle = Bundle.module
        let template = (try? String(
            contentsOf: bundle.url(forResource: "Resources/viewer", withExtension: "html")
                ?? bundle.url(forResource: "viewer", withExtension: "html")!,
            encoding: .utf8
        )) ?? "<p>viewer.html 没打进 app 里</p>"

        let markedURL = bundle.url(forResource: "Resources/marked.min", withExtension: "js")
            ?? bundle.url(forResource: "marked.min", withExtension: "js")
        let marked = markedURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

        return template
            .replacingOccurrences(of: "/*__MARKED_JS__*/", with: marked)
            .replacingOccurrences(of: "--font-size: 14.5px;", with: "--font-size: \(fontSize)px;")
    }
}

// MARK: - 导航拦截

extension MarkdownView: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageReady = true
        for command in pendingCommands { webView.evaluateJavaScript(command) }
        pendingCommands.removeAll()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // 页面里点链接会跳到 nutshell-open:<真实地址>，我们截住它交给系统浏览器
        if url.absoluteString.hasPrefix("nutshell-open:") {
            let raw = String(url.absoluteString.dropFirst("nutshell-open:".count))
            if let target = URL(string: raw), ["http", "https"].contains(target.scheme ?? "") {
                NSWorkspace.shared.open(target)
            }
            decisionHandler(.cancel)
            return
        }

        // 首次 loadHTMLString 放行，其它跳转一律拦下（这小窗不是浏览器）
        decisionHandler(url.scheme == "about" ? .allow : .cancel)
    }
}
