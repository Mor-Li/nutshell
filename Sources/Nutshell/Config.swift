import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  PROMPT —— 这里就是发给模型的那句话，随便改。
//  {content} 会被替换成你选中的文字。前后各说一遍要求是刻意的（夹心结构），
//  长文本时模型更容易记住到底让它干嘛。
// ─────────────────────────────────────────────────────────────────────────────

let DEFAULT_PROMPT_TEMPLATE = """
用通俗易懂的大白话讲一下下面讲的是什么东西：

{content}

用通俗易懂的大白话讲一下上面讲的是什么东西。
"""

/// 剪贴板里是图片（截图、图片文件、扫描版 PDF）时用这句，没有 {content} 可填。
let DEFAULT_IMAGE_PROMPT = """
用通俗易懂的大白话讲一下这张图里讲的是什么东西。
"""

// ─────────────────────────────────────────────────────────────────────────────

struct WindowConfig: Codable {
    var width: Double = 460
    var height: Double = 520
    var fontSize: Double = 14.5
    /// 浮窗离鼠标多远（像素）
    var gap: Double = 16
}

struct Config: Codable {
    /// 任何 OpenAI 兼容的 `/chat/completions` 都能用——官方、自建网关、
    /// 公司内部代理、本机跑的 Ollama，改这一行就行。
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "gpt-5.4"

    /// 留空则去你的 shell 环境里读 `apiKeyEnvVar` 那个变量。
    /// 这样换 key 之后不用动这个文件。
    var apiKey: String = ""
    var apiKeyEnvVar: String = "OPENAI_API_KEY"

    var maxTokens: Int = 32768
    var temperature: Double = 0.6

    /// BTT 用 curl 打这个端口来触发。挑了个冷门号，免得跟别的本地服务撞车。
    var port: UInt16 = 8823

    var promptTemplate: String = DEFAULT_PROMPT_TEMPLATE
    var imagePromptTemplate: String = DEFAULT_IMAGE_PROMPT
    /// 系统提示词，留空就不发
    var systemPrompt: String = ""

    var window = WindowConfig()

    /// 菜单栏那个小图标。默认不显示——这工具是按快捷键用的，图标纯占地方。
    /// 关着的时候，重载配置走 `curl 127.0.0.1:<port>/reload`，退出走 `pkill -x Nutshell`。
    var showMenuBarIcon: Bool = false

    /// 一次最多发多少字符给模型，超了截断（防止手滑全选一本书）
    var maxInputChars: Int = 40000

    /// 一次最多带几张图（选中一堆图片文件时防爆）
    var maxImages: Int = 6

    /// 扫描版 PDF（提不出文字层）最多渲染前几页当图片看
    var maxScannedPDFPages: Int = 3

    /// 图片发出去前压到最长边不超过多少像素，0 = 不压。
    /// 压一下能省不少 token，模型看字也基本不受影响。
    var maxImageDimension: Double = 1600

    /// 历史菜单里最多列几条。
    /// 只管菜单显示——**磁盘上的对话一条都不会删**，列不下的去
    /// `~/.config/nutshell/sessions/` 里翻（菜单底下有直达访达的入口）。
    var historyMenuCount: Int = 30
}

// MARK: - 宽容解码

extension Config {

    /// 手写解码：JSON 里缺哪个字段，就拿默认值补上。
    ///
    /// 自动生成的那份不是这个脾气——少一个 key 它就整个解码失败，而
    /// `ConfigStore.load()` 一解码失败就会拿全新的默认配置**覆盖掉原文件**。
    /// 也就是说：程序一升级、多出一个新字段，你辛苦调的 prompt 就被抹平了。
    /// 有了这段，以后加多少字段都不会动你的配置。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()

        func read<T: Decodable>(_ key: CodingKeys, _ orElse: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? orElse
        }

        baseURL             = read(.baseURL, fallback.baseURL)
        model               = read(.model, fallback.model)
        apiKey              = read(.apiKey, fallback.apiKey)
        apiKeyEnvVar        = read(.apiKeyEnvVar, fallback.apiKeyEnvVar)
        maxTokens           = read(.maxTokens, fallback.maxTokens)
        temperature         = read(.temperature, fallback.temperature)
        port                = read(.port, fallback.port)
        promptTemplate      = read(.promptTemplate, fallback.promptTemplate)
        imagePromptTemplate = read(.imagePromptTemplate, fallback.imagePromptTemplate)
        systemPrompt        = read(.systemPrompt, fallback.systemPrompt)
        window              = read(.window, fallback.window)
        showMenuBarIcon     = read(.showMenuBarIcon, fallback.showMenuBarIcon)
        maxInputChars       = read(.maxInputChars, fallback.maxInputChars)
        maxImages           = read(.maxImages, fallback.maxImages)
        maxScannedPDFPages  = read(.maxScannedPDFPages, fallback.maxScannedPDFPages)
        maxImageDimension   = read(.maxImageDimension, fallback.maxImageDimension)
        historyMenuCount    = read(.historyMenuCount, fallback.historyMenuCount)
    }
}

extension WindowConfig {

    /// 同上：窗口这几项少写哪个都不影响其它设置
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = WindowConfig()

        func read<T: Decodable>(_ key: CodingKeys, _ orElse: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? orElse
        }

        width    = read(.width, fallback.width)
        height   = read(.height, fallback.height)
        fontSize = read(.fontSize, fallback.fontSize)
        gap      = read(.gap, fallback.gap)
    }
}

// MARK: - 读写

enum ConfigStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nutshell", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    /// 读配置。文件不存在就写一份默认的出来，方便用户直接改。
    static func load() -> Config {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? decoder.decode(Config.self, from: data) {
            return cfg
        }
        let fresh = Config()
        save(fresh)
        return fresh
    }

    static func save(_ config: Config) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// 读出来的 key 缓存住。去 shell 里捞一次要 source 整个 zshrc，几百毫秒，
    /// 不能每次按快捷键都来一遍。
    private static var cachedKey: String?

    /// 拿 API key：配置文件里写死的优先，否则去 shell 里读环境变量。
    ///
    /// - Parameter forceRefresh: key 轮换后旧的会 401，那时候强制重读一次。
    static func resolveAPIKey(_ config: Config, forceRefresh: Bool = false) -> String? {
        if !config.apiKey.isEmpty { return config.apiKey }
        if !forceRefresh, let cachedKey, !cachedKey.isEmpty { return cachedKey }

        // 注意别用 `zsh -lc`：那是非交互式 login shell，压根不读 ~/.zshrc
        //（zsh 的规矩是 .zshrc 只给交互式 shell 用），而 key 恰恰定义在 zshrc 引的文件里。
        // 所以这里显式 source 一把。
        let script = """
        source ~/.zshrc >/dev/null 2>&1
        source ~/.bashrc >/dev/null 2>&1
        printf %s "$\(config.apiKeyEnvVar)"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            cachedKey = key
            return key.isEmpty ? nil : key
        } catch {
            return nil
        }
    }

    /// 提前把 key 捞好放着，别等到按快捷键那一刻才卡半秒
    static func warmUpAPIKey(_ config: Config) {
        DispatchQueue.global(qos: .utility).async {
            _ = resolveAPIKey(config)
        }
    }
}
