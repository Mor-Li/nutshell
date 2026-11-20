import AppKit
import WebKit
import XCTest
@testable import Nutshell

/// 测试共用的小工具。
///
/// 这里的测试都不把窗口摆上屏幕：浮窗照常创建、照常排版，只是不显示，
/// 所以跑测试的时候不会弹窗，也不会抢键盘。

/// 在一棵视图树里找出第一个指定类型的视图
func findView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
    if let hit = root as? T { return hit }
    for child in root.subviews {
        if let hit = findView(type, in: child) { return hit }
    }
    return nil
}

/// 测试会存对话。必须先把"家目录"指到临时文件夹（`make test` 会做这件事），
/// 不然测试用的假对话会混进真实的历史里。没指就直接判失败，一条都不跑。
func requireSandboxedHome(file: StaticString = #filePath, line: UInt = #line) throws {
    guard ConfigStore.directory.path.contains("nutshell-tests") else {
        XCTFail("请用 `make test` 跑测试，它会把存档目录指到临时文件夹", file: file, line: line)
        throw XCTSkip("存档目录没有隔离")
    }
}

/// 每隔一小会儿看一眼条件成立没有，成立就返回，超时判失败
@MainActor
func waitUntil(
    _ what: String, timeout: TimeInterval = 5,
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(30))
    }
    XCTFail("等了 \(timeout) 秒也没等到：\(what)", file: file, line: line)
}

// MARK: - 假的模型接口

/// 把发往 `llm.test` 的请求截下来，按剧本回话，不碰真实网络。
///
/// 剧本是一串"要吐的字"，外加一个开关：吐完之后是正常收尾，还是假装网断了。
final class FakeLLM: URLProtocol {

    nonisolated(unsafe) static var pieces: [String] = []
    nonisolated(unsafe) static var dropAtEnd = false
    /// 收尾前补一块用量（total_tokens），跟真网关开了 include_usage 时一样，那块的 choices 是空的
    nonisolated(unsafe) static var usageTotal: Int?
    /// 每次请求里发给模型的消息列表，按先后记下来，供测试核对
    nonisolated(unsafe) static var requests: [[[String: Any]]] = []

    static func install() { URLProtocol.registerClass(FakeLLM.self) }

    static func script(_ pieces: [String], dropAtEnd: Bool = false, usageTotal: Int? = nil) {
        self.pieces = pieces
        self.dropAtEnd = dropAtEnd
        self.usageTotal = usageTotal
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "llm.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if let body = Self.readBody(request),
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let messages = json["messages"] as? [[String: Any]] {
            Self.requests.append(messages)
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        for piece in Self.pieces {
            let chunk: [String: Any] = ["choices": [["delta": ["content": piece]]]]
            let line = String(data: try! JSONSerialization.data(withJSONObject: chunk), encoding: .utf8)!
            client?.urlProtocol(self, didLoad: Data("data: \(line)\n\n".utf8))
        }

        // 收尾晚一拍再来：真实的断网也是字先到、过一会儿连接才断。
        // 紧跟着报错的话，系统会把还没来得及交出去的那几个字一起扔掉。
        if let total = Self.usageTotal {
            let chunk: [String: Any] = ["choices": [Any](), "usage": ["total_tokens": total]]
            let line = String(data: try! JSONSerialization.data(withJSONObject: chunk), encoding: .utf8)!
            client?.urlProtocol(self, didLoad: Data("data: \(line)\n\n".utf8))
        }

        let drop = Self.dropAtEnd
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
            if drop {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    /// 请求体到了这一层是一条流，得自己读出来
    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
