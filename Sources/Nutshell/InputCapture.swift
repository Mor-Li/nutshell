import AppKit
import PDFKit
import UniformTypeIdentifiers

/// 抓到手的东西，最后只有两种形态：一堆文字，或者一堆图。
enum CapturedInput {
    case text(String)
    case images([ImagePayload], note: String?)

    struct ImagePayload {
        let base64: String
        let mimeType: String
    }
}

struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 看看剪贴板里现在躺着什么，决定"这次到底要给模型看什么"。
///
/// 复制这一步由你自己完成（Cmd+C，或者 BTT 里顺手带一下），程序只负责读最新的剪贴板内容。
/// 好处是全程不需要任何系统权限——读剪贴板是白给的。
///
/// 按这个顺序认：
///   • 文件      → 按后缀分流（PDF 提文字 / 图片走看图 / 文本类直接读 / Word 之类交给 textutil）
///   • 图片数据  → 截图直接走看图
///   • 纯文字    → 就是它了
enum InputCapture {

    static func capture(config: Config) throws -> CapturedInput {
        try interpret(NSPasteboard.general, config: config)
    }

    // MARK: - 看看剪贴板里到底是什么

    static func interpret(_ pasteboard: NSPasteboard, config: Config) throws -> CapturedInput {
        // 1) 文件：注意必须排在图片前面判断，
        //    因为 NSImage 见到图片文件的 URL 也会"认领"，那样就丢了 PDF 分支
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return try readFiles(urls, config: config)
        }

        // 2) 图片数据：Cmd+Shift+4 截图直接落在这里
        if let image = NSImage(pasteboard: pasteboard),
           let payload = encode(image, config: config) {
            return .images([payload], note: nil)
        }

        // 3) 纯文字
        if let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .text(truncate(text, limit: config.maxInputChars))
        }

        throw CaptureError(message: "剪贴板是空的。\n\n先复制点东西——一段文字、一个 PDF、一张图、一个文件都行——再按快捷键。")
    }

    // MARK: - 文件

    private static func readFiles(_ urls: [URL], config: Config) throws -> CapturedInput {
        var texts: [String] = []
        var images: [CapturedInput.ImagePayload] = []
        var notes: [String] = []
        var skipped: [String] = []

        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension.lowercased())

            if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
                let result = readPDF(url, config: config)
                switch result {
                case .text(let body):
                    texts.append(label(url, body))
                case .images(let payloads, let note):
                    images.append(contentsOf: payloads)
                    if let note { notes.append(note) }
                case .none:
                    skipped.append("\(url.lastPathComponent)（PDF 打不开或者是空的）")
                }
                continue
            }

            if let type, type.conforms(to: .image) {
                if images.count >= config.maxImages { continue }
                if let image = NSImage(contentsOf: url), let payload = encode(image, config: config) {
                    images.append(payload)
                } else {
                    skipped.append("\(url.lastPathComponent)（这张图读不出来）")
                }
                continue
            }

            if let body = readAsText(url, type: type) {
                texts.append(label(url, body))
            } else {
                skipped.append("\(url.lastPathComponent)（不认识这个类型）")
            }
        }

        if !images.isEmpty {
            var note = notes.joined(separator: "\n")
            // 图片和文字同时有的时候，文字也一并塞进 note 里带上，别丢
            if !texts.isEmpty {
                note += (note.isEmpty ? "" : "\n\n") + texts.joined(separator: "\n\n")
            }
            return .images(Array(images.prefix(config.maxImages)),
                           note: note.isEmpty ? nil : truncate(note, limit: config.maxInputChars))
        }

        if !texts.isEmpty {
            return .text(truncate(texts.joined(separator: "\n\n"), limit: config.maxInputChars))
        }

        throw CaptureError(message: "这些文件都读不了：\n" + skipped.joined(separator: "\n"))
    }

    private static func label(_ url: URL, _ body: String) -> String {
        "【\(url.lastPathComponent)】\n\(body)"
    }

    // MARK: - PDF

    private enum PDFResult {
        case text(String)
        case images([CapturedInput.ImagePayload], note: String?)
        case none
    }

    private static func readPDF(_ url: URL, config: Config) -> PDFResult {
        guard let doc = PDFDocument(url: url) else { return .none }

        // 有文字层就直接提字，又快又省钱
        if let body = doc.string?.trimmingCharacters(in: .whitespacesAndNewlines), body.count > 40 {
            return .text(body)
        }

        // 提不出字 = 扫描件（整页就是一张图）。那就渲染成图，让模型看图说话。
        let pageCount = min(doc.pageCount, config.maxScannedPDFPages)
        guard pageCount > 0 else { return .none }

        var payloads: [CapturedInput.ImagePayload] = []
        for index in 0..<pageCount {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // 2 倍渲染，不然扫描件上的小字糊成一团
            let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            if let payload = encode(thumbnail, config: config) { payloads.append(payload) }
        }

        guard !payloads.isEmpty else { return .none }
        let note = "（\(url.lastPathComponent) 是扫描版 PDF，没有文字层，"
                 + "所以是按图片在看，共 \(doc.pageCount) 页、这里取了前 \(payloads.count) 页）"
        return .images(payloads, note: note)
    }

    // MARK: - 文本类文件

    private static func readAsText(_ url: URL, type: UTType?) -> String? {
        let ext = url.pathExtension.lowercased()

        // Word / RTF / HTML 这些交给系统自带的 textutil，一行命令就转成纯文本
        if ["doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"].contains(ext) {
            return runTextutil(url)
        }

        // 剩下的只要是文本家族（源码、json、csv、md、log…）就直接读
        let looksTextual = type?.conforms(to: .text) == true
            || type?.conforms(to: .sourceCode) == true
            || type == nil  // 没有后缀的文件也试一把

        guard looksTextual else { return nil }

        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
            if let body = try? String(contentsOf: url, encoding: encoding) {
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    private static func runTextutil(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (body?.isEmpty ?? true) ? nil : body
    }

    // MARK: - 图片编码

    /// 缩到合理尺寸 + 压成 JPEG + 转 base64。
    /// 统一铺白底，免得带透明通道的图压完变成黑乎乎一片。
    private static func encode(_ image: NSImage, config: Config) -> CapturedInput.ImagePayload? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }

        let limit = CGFloat(config.maxImageDimension)
        let scale = limit > 0 ? min(1, limit / max(width, height)) : 1
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let output = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: output)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        return CapturedInput.ImagePayload(base64: data.base64EncodedString(), mimeType: "image/jpeg")
    }

    // MARK: - 截断

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
            + "\n\n…（太长了，后面 \(text.count - limit) 个字符没发出去）"
    }
}
