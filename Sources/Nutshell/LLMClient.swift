import Foundation

/// 一轮对话里的一条消息。
struct ChatMessage {
    enum Content {
        case text(String)
        /// 一段说明文字 + 若干张图（截图、图片文件、扫描版 PDF 渲染出来的页）
        case multimodal(text: String, images: [CapturedInput.ImagePayload])
    }

    let role: String        // "user" / "assistant"
    let content: Content

    static func user(_ content: Content) -> ChatMessage { .init(role: "user", content: content) }
    static func assistant(_ text: String) -> ChatMessage { .init(role: "assistant", content: .text(text)) }
}

/// 调 LLM 网关（OpenAI 兼容的 /chat/completions），边收边吐字。
///
/// 用流式（stream）是刻意的：gemini-3.1-pro 这种推理模型会先"在心里想一会儿"，
/// 非流式的话你得盯着空白框干等十几秒；流式至少能第一时间看到字往外蹦。
actor LLMClient {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var task: Task<Void, Never>?

    /// 取消正在跑的请求（比如用户关掉了浮窗、或者又按了一次快捷键）
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// - Parameters:
    ///   - onDelta: 每收到一小段文字回调一次（已经在主线程）
    ///   - onFinish: 结束回调，error 为 nil 表示正常收完
    func stream(
        messages: [ChatMessage],
        config: Config,
        apiKey: String,
        onDelta: @escaping @MainActor (String) -> Void,
        onFinish: @escaping @MainActor (Error?) -> Void
    ) {
        cancel()
        task = Task {
            do {
                try await run(messages: messages, config: config, apiKey: apiKey, onDelta: onDelta)
                await MainActor.run { onFinish(nil) }
            } catch is CancellationError {
                // 用户主动取消，不算错误，什么都不做
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { onFinish(error) }
            }
        }
    }

    /// 把一条消息拼成请求体里的 content。
    /// 纯文字就是个字符串；带图的走 OpenAI 那套 content 数组格式（text + image_url），
    /// 网关会把它翻译成 Gemini 的多模态调用。
    private func encode(_ content: ChatMessage.Content) -> Any {
        switch content {
        case .text(let body):
            return body

        case .multimodal(let text, let images):
            var parts: [[String: Any]] = [["type": "text", "text": text]]
            for image in images {
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64)"],
                ])
            }
            return parts
        }
    }

    private func run(
        messages chatMessages: [ChatMessage],
        config: Config,
        apiKey: String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                + "/chat/completions") else {
            throw Failure(message: "配置里的 baseURL 不合法：\(config.baseURL)")
        }

        var messages: [[String: Any]] = []
        if !config.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": config.systemPrompt])
        }
        for message in chatMessages {
            messages.append(["role": message.role, "content": encode(message.content)])
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "stream": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 错误响应不是 SSE，把 body 收干净了好报错
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw Failure(message: describe(status: http.statusCode, body: raw,
                                            envVar: config.apiKeyEnvVar))
        }

        var sawAnyContent = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }

            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // 网关有时把错误也塞在 SSE 流里
            if let err = json["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "未知错误"
                throw Failure(message: msg)
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String,
                  !piece.isEmpty
            else { continue }

            sawAnyContent = true
            await MainActor.run { onDelta(piece) }
        }

        if !sawAnyContent {
            throw Failure(message: "模型没吐出任何内容。多半是推理 token 把预算吃光了，"
                          + "或者选中的内容触发了内容过滤。可以试试换个模型。")
        }
    }

    /// - Parameter envVar: 报错时把用户自己配的那个变量名写进去，
    ///   别让人对着一个跟自己配置对不上的名字排查
    private func describe(status: Int, body: String, envVar: String) -> String {
        let snippet = body.count > 500 ? String(body.prefix(500)) + "…" : body
        switch status {
        case 401:
            return "401 认证失败——API key 不对或者已作废。\n"
                 + "先在终端跑 `source ~/.zshrc && echo ${\(envVar): -4}` 对一下 key 的尾号。\n\n\(snippet)"
        case 429:
            return "429 被限流了，等几秒再按一次。\n\n\(snippet)"
        case 404:
            return "404 找不到这个模型：\(snippet)\n模型名可能拼错了，或者没在网关白名单里。"
        default:
            return "HTTP \(status)\n\n\(snippet)"
        }
    }
}
