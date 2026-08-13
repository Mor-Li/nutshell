import Foundation

/// 存盘用的一条消息。
///
/// `ChatMessage.Content` 是带关联值的枚举，自动生成的 Codable 会拧出一坨嵌套 JSON，
/// 将来手动翻这些文件时很难读。这里摊平成"一段文字 + 可选的几张图"，肉眼可读。
struct StoredMessage: Codable {
    var role: String            // "user" / "assistant"
    var text: String
    var images: [StoredImage]?

    struct StoredImage: Codable {
        var base64: String
        var mimeType: String
    }

    init(_ message: ChatMessage) {
        role = message.role
        switch message.content {
        case .text(let body):
            text = body
            images = nil
        case .multimodal(let body, let payloads):
            text = body
            images = payloads.map { .init(base64: $0.base64, mimeType: $0.mimeType) }
        }
    }

    /// 变回能直接发给模型的形态
    var chatMessage: ChatMessage {
        guard let images, !images.isEmpty else {
            return ChatMessage(role: role, content: .text(text))
        }
        let payloads = images.map {
            CapturedInput.ImagePayload(base64: $0.base64, mimeType: $0.mimeType)
        }
        return ChatMessage(role: role, content: .multimodal(text: text, images: payloads))
    }
}

/// 一次完整的对话，落盘的样子。
struct StoredSession: Codable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var model: String

    /// 浮窗里显示的那份 markdown 全文。切回来时直接喂给 MarkdownView 就复原了，
    /// 不用再从 messages 重新拼一遍（拼出来的排版跟当时未必一致）。
    var transcript: String

    /// 发给模型的完整消息列表（含图）。切回来接着聊靠的是它。
    var messages: [StoredMessage]
}

/// 菜单里要显示的那点信息。
///
/// 单独存一份 index.json 是有原因的：带图的会话一条能有好几兆（base64 图片），
/// 每次点开菜单都把它们全解析一遍太亏了。索引只有标题和时间，读起来是瞬间的事。
struct SessionSummary: Codable {
    var id: String
    var title: String
    var updatedAt: Date
}

// MARK: - 读写

/// 对话存在 `~/.config/nutshell/sessions/`，一次对话一个 JSON 文件。
///
/// **只增不删**：程序不会替你清理任何历史，攒多少留多少。
/// 想删就自己进那个文件夹删，或者用历史菜单里的删除项。
enum SessionStore {

    static var directory: URL {
        ConfigStore.directory.appendingPathComponent("sessions", isDirectory: true)
    }

    private static var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    private static func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601   // 文件里的时间人眼能读
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 文件名前半截就是时间，`ls` 一下自然按时间排好；后面缀四位随机，
    /// 免得同一秒里连开两次对话撞车。
    static func newID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(format: "%04x", UInt16.random(in: UInt16.min...UInt16.max))
        return formatter.string(from: Date()) + "-" + suffix
    }

    // MARK: 列表

    /// 按时间倒序列出所有对话。索引里指着的文件要是没了（被手动删了），顺手跳过。
    static func list() -> [SessionSummary] {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? decoder.decode([SessionSummary].self, from: data)
        else { return [] }

        return items
            .filter { FileManager.default.fileExists(atPath: fileURL($0.id).path) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func load(_ id: String) -> StoredSession? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? decoder.decode(StoredSession.self, from: data)
    }

    // MARK: 写入

    static func save(_ session: StoredSession) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(session) else { return }

        // 先落正文再更新索引。反过来的话，中间那一瞬索引会指着一个还不存在的文件
        try? data.write(to: fileURL(session.id), options: .atomic)

        var summaries = list().filter { $0.id != session.id }
        summaries.insert(
            SessionSummary(id: session.id, title: session.title, updatedAt: session.updatedAt),
            at: 0
        )
        writeIndex(summaries)
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(id))
        writeIndex(list().filter { $0.id != id })
    }

    /// 只清 sessions 目录，config.json 不动
    static func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func writeIndex(_ summaries: [SessionSummary]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(summaries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: 标题

    /// 拿输入的头一句话当标题——菜单里扫一眼就知道是哪次。
    static func makeTitle(from input: CapturedInput) -> String {
        switch input {
        case .text(let body):
            let title = condense(body)
            return title.isEmpty ? "无题" : title

        case .images(let images, let note):
            let prefix = images.count > 1 ? "图片 ×\(images.count)" : "图片"
            let extra = note.map { condense($0) } ?? ""
            return extra.isEmpty ? prefix : "\(prefix) · \(extra)"
        }
    }

    /// 把多行文本压成一行短句：换行和连续空格全并成一个空格，超长就截断
    static func condense(_ text: String, limit: Int = 28) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}
