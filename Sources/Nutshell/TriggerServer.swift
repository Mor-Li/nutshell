import Foundation
import Network

/// BTT 按下快捷键 → `curl http://127.0.0.1:8787/explain` → 这里收到 → 干活。
///
/// 为什么用一个常驻进程 + HTTP 端口，而不是每次快捷键都启动一个新程序：
/// 启动进程要几百毫秒，还得重新拉起 WebView，按下去要等半天才见窗口。
/// 常驻着就是"按下即出"。
///
/// 只绑 127.0.0.1，同一台机器之外打不进来。
final class TriggerServer {

    struct PortInUse: LocalizedError {
        let port: UInt16
        var errorDescription: String? {
            "端口 \(port) 被别的程序占了。改 ~/.config/nutshell/config.json 里的 port 换一个。"
        }
    }

    private let port: UInt16
    private let onTrigger: (String) -> Void
    private let onFailure: (String) -> Void
    private var listener: NWListener?

    /// - Parameters:
    ///   - onTrigger: 参数是请求路径，比如 "/explain"
    ///   - onFailure: 端口起不来时喊一声。必须喊——否则快捷键按了没反应，
    ///                你只会觉得"这破程序坏了"，根本猜不到是端口被别人占了。
    init(port: UInt16,
         onTrigger: @escaping (String) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.port = port
        self.onTrigger = onTrigger
        self.onFailure = onFailure
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PortInUse(port: port)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 死死绑在回环地址上，别把这个口子开到局域网去
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        // 端口冲突不会在 start() 时抛出，而是稍后从这里冒出来
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error), .waiting(let error):
                NSLog("[Nutshell] 监听 \(self.port) 失败：\(error)")
                self.onFailure(self.describe(error))
            default:
                break
            }
        }

        listener.start(queue: .main)
    }

    private func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return """
            触发端口 \(port) 已经被别的程序占了，Nutshell 收不到快捷键。

            解决办法二选一：
            • 改 ~/.config/nutshell/config.json 里的 port 换个号，然后菜单里「重新加载配置」
            • 先在终端跑 `lsof -nP -iTCP:\(port) -sTCP:LISTEN` 看是谁占的，把它关掉
            """
        }
        return "触发端口 \(port) 起不来：\(error.localizedDescription)"
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            defer {
                // 回一句就完事，不做 keep-alive
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/plain; charset=utf-8\r
                Content-Length: 2\r
                Connection: close\r
                \r
                ok
                """
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }

            guard let self,
                  let data,
                  let request = String(data: data, encoding: .utf8) else { return }

            // 请求行长这样：GET /explain HTTP/1.1
            let path = request
                .split(separator: "\r\n", maxSplits: 1).first?
                .split(separator: " ").dropFirst().first
                .map(String.init) ?? "/"

            self.onTrigger(path)
        }
    }
}
