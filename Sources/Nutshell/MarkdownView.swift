import AppKit
import WebKit

/// 浮窗里显示内容的那块。本质是个 WKWebView，跑着内嵌的 viewer.html + marked.js。
///
/// 为什么不用 SwiftUI 原生的 markdown：系统那个 `AttributedString(markdown:)` 只认粗体斜体链接，
/// 标题、列表、代码块、表格统统不支持——而模型回复里这些天天出现。
final class MarkdownView: NSView {

    private let webView: WKWebView
    private var isPageReady = false

    /// 点了页面里那个「重试」按钮
    var onRetry: (() -> Void)?

    /// 网页的下沿贴着谁。默认贴自己的下沿，装进浮窗后改成一直铺到窗口底，见 extendPage
    private var pageBottom: NSLayoutConstraint!
    /// 上一次告诉页面"底下让出多高"，没变就不重复说
    private var lastBottomInset: CGFloat = -1

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
        // 网页可以比自己高（见 extendPage），超出自己下沿的那截裁掉不显示
        clipsToBounds = true
        pageBottom = webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            pageBottom,
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        webView.loadHTMLString(Self.pageHTML(fontSize: fontSize), baseURL: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 跟底部打字区的配合

    /// 让网页一直铺到 `anchor`（浮窗的最底边），不再跟着自己的下沿伸缩。
    ///
    /// 为什么这么绕：底部输入框会长高、分隔线能拖，正文这块的高度就跟着变。
    /// 如果每次都去改网页视图的大小，网页那边有时跟不上，线往下拖回去之后
    /// 多出来的那一截会空着不画（2026-11-16 用户遇到的"线上面一块空白"）。
    /// 所以网页视图的大小固定不动：它始终从顶栏铺到窗口底，被打字区挡住的那截
    /// 由本视图裁掉，再明确告诉页面"底下让出多高"，页面自己把内容和滚动条收到线以上。
    func extendPage(toBottomOf anchor: NSLayoutYAxisAnchor) {
        pageBottom.isActive = false
        pageBottom = webView.bottomAnchor.constraint(equalTo: anchor)
        pageBottom.isActive = true
    }

    override func layout() {
        super.layout()
        // 网页比自己露出来的部分高出多少，页面底部就让出多少
        let inset = max(0, webView.frame.height - bounds.height).rounded()
        guard inset != lastBottomInset else { return }
        lastBottomInset = inset
        run("window.nsBottomInset(\(inset))")
    }

    // MARK: - 对外接口

    /// 开始新一轮：清空内容，显示"正在琢磨…"
    func beginThinking(label: String) {
        beginRound(markdown: "", label: label)
    }

    /// 刚发出一问：把已有内容（含刚问的那个气泡）铺上去，
    /// 在底下显示"正在琢磨"的小点，等第一个字回来。
    func beginRound(markdown: String, label: String) {
        flushTimer?.invalidate()
        flushTimer = nil
        latestMarkdown = markdown
        lastFlush = .distantPast
        run("window.nsRender(\(Self.jsString(markdown))); window.nsState('thinking', \(Self.jsString(label)))")
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

    /// 把一张图登记进页面的图片簿。正文里只放 `![ns-img](id)` 这么一行小占位，
    /// 页面画气泡时按 id 把真图取出来贴上——base64 只过桥一次，
    /// 不然流式刷新每 50ms 全文重发一遍，几百 KB 的图跟着来回跑。
    func registerImage(id: String, dataURL: String) {
        run("window.nsImage(\(Self.jsString(id)), \(Self.jsString(dataURL)))")
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

        func resource(_ name: String, _ ext: String) -> String {
            let url = bundle.url(forResource: "Resources/\(name)", withExtension: ext)
                ?? bundle.url(forResource: name, withExtension: ext)
            return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }

        // KaTeX 排数学公式，字体已经由 scripts/vendor_katex.py 转成 base64 写进 CSS
        return template
            .replacingOccurrences(of: "/*__KATEX_CSS__*/", with: resource("katex.inline.min", "css"))
            .replacingOccurrences(of: "/*__MARKED_JS__*/", with: resource("marked.min", "js"))
            .replacingOccurrences(of: "/*__KATEX_JS__*/", with: resource("katex.min", "js"))
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

        // 「重试」按钮也是同一个路数：页面跳一个假地址，我们在这儿截住当成信号
        if url.scheme == "nutshell-retry" {
            onRetry?()
            decisionHandler(.cancel)
            return
        }

        // 首次 loadHTMLString 放行，其它跳转一律拦下（这小窗不是浏览器）
        decisionHandler(url.scheme == "about" ? .allow : .cancel)
    }
}
