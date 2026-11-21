import Foundation
import Network

/// An MCP server (Streamable HTTP, JSON responses, no streaming) on 127.0.0.1 only.
/// Every request needs `Authorization: Bearer <key>`; requests from web pages (an Origin that isn't
/// this Mac) are refused, so a site in the browser can't read it either.
@MainActor
final class MCPServer {
    /// Tool calls go to `tools()` each time, so turning a group off takes effect at once.
    var tools: () -> [MCPTool] = { [] }
    var onRequest: (_ client: String?) -> Void = { _ in }

    private let name: String
    private let version: String
    private let instructions: String
    private let key: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "MacAppMCPKit.server")
    /// Which assistant each session is ("claude-code"), from its `initialize`, for "last asked" per assistant.
    private var sessions: [String: String] = [:]

    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let maxBody = 1 << 20
    /// Long enough for a tool that asks the network (the bridge waits 120 seconds too).
    private static let connectionTimeout: TimeInterval = 120

    init(name: String, version: String, instructions: String, key: String) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.key = key
    }

    /// Listens on `port`; calls back with the error (address in use, …) if it can't.
    func start(port: UInt16, ready: @escaping (Error?) -> Void) {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { ready(error); return }
        var reported = false
        listener.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready where !reported: reported = true; ready(nil)
                case .failed(let error) where !reported: reported = true; ready(error)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // One request per connection: anything still open after this (never finished sending) is dropped.
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { connection.cancel() }
        read(connection, buffer: Data())
    }

    /// Reads until the headers and a Content-Length body have arrived, then answers and closes.
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(buffer) {
                    if request.body.count >= request.contentLength {
                        let response = await self.respond(to: request)
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                } else if buffer.count > Self.maxBody {
                    connection.cancel(); return
                }
                if done || error != nil || buffer.count > Self.maxBody { connection.cancel(); return }
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest) async -> Data {
        // A web page that points its own domain at 127.0.0.1 ("DNS rebinding") still sends that domain as Host.
        if let host = request.headers["host"], !Self.isLocalHost(host) {
            return HTTPRequest.response(403, json: ["error": "Only requests to 127.0.0.1 or localhost are allowed."])
        }
        if let origin = request.headers["origin"], !Self.isLocal(origin) {
            return HTTPRequest.response(403, json: ["error": "Requests from web pages aren't allowed."])
        }
        guard request.headers["authorization"].map({ Self.equal($0, "Bearer \(key)") }) == true else {
            return HTTPRequest.response(401, json: ["error": "Missing or wrong key. Copy the setup again from \(name)'s settings."])
        }
        guard request.path.hasPrefix("/mcp") else { return HTTPRequest.response(404, json: ["error": "Not found"]) }
        guard request.method == "POST" else { return HTTPRequest.response(405, json: ["error": "Use POST"]) }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return HTTPRequest.response(400, json: Self.error(nil, -32700, "Parse error"))
        }
        guard let id = message["id"], !(id is NSNull) else {
            return HTTPRequest.response(202, json: nil)   // a notification ("initialized")
        }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "initialize" {
            let name = (params["clientInfo"] as? [String: Any])?["name"] as? String
            let session = UUID().uuidString
            if sessions.count > 200 { sessions.removeAll() }
            if let name { sessions[session] = name }
            onRequest(name)
            return HTTPRequest.response(200, json: await handle(method, params, id: id), headers: ["Mcp-Session-Id": session])
        }
        if method == "tools/call" { onRequest(client(of: request)) }
        return HTTPRequest.response(200, json: await handle(method, params, id: id))
    }

    /// The session's assistant; else the name the bridge tool passes along (it outlives the app's restarts);
    /// else Claude Code's user agent.
    private func client(of request: HTTPRequest) -> String? {
        if let session = request.headers["mcp-session-id"], let name = sessions[session] { return name }
        if let name = request.headers["x-localmcp-client"], !name.isEmpty { return name }
        if request.headers["user-agent"]?.lowercased().contains("claude-code") == true { return "claude-code" }
        return nil
    }

    // MARK: JSON-RPC

    private func handle(_ method: String, _ params: [String: Any], id: Any) async -> [String: Any] {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return Self.result(id, [
                "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "version": version],
                "instructions": instructions,
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": tools().map(\.listing)])
        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            guard let tool = tools().first(where: { $0.name == toolName }) else {
                return Self.result(id, Self.toolText("“\(toolName)” isn't available. It may be turned off in \(name)'s settings.", isError: true))
            }
            do {
                let value = try await tool.handler(MCPArguments(raw: params["arguments"] as? [String: Any] ?? [:]))
                var result = Self.toolText(Self.encode(value), isError: false)
                if let object = value as? [String: Any] { result["structuredContent"] = object }
                return Self.result(id, result)
            } catch {
                return Self.result(id, Self.toolText(error.localizedDescription, isError: true))
            }
        default:
            return Self.error(id, -32601, "Method not found: \(method)")
        }
    }

    private static func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static func toolText(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    nonisolated static func encode(_ value: Any) -> String {
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// "127.0.0.1:7316", "localhost:7316" or "[::1]:7316".
    private static func isLocalHost(_ host: String) -> Bool {
        guard let name = URLComponents(string: "http://\(host)")?.host?.lowercased() else { return false }
        return name == "127.0.0.1" || name == "localhost" || name == "::1" || name == "[::1]"
    }

    private static func isLocal(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Compares without stopping at the first difference, so timing doesn't give the key away.
    private static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Just enough HTTP/1.1: request line, headers (lowercased names), and a Content-Length body.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let contentLength: Int

    /// nil until the headers have all arrived.
    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        contentLength = Int(headers["content-length"] ?? "") ?? 0
        body = Data(data[end.upperBound...].prefix(contentLength))
    }

    static func response(_ status: Int, json: Any?, headers: [String: String] = [:]) -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        let body = json.map { Data(MCPServer.encode($0).utf8) } ?? Data()
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        if status == 405 { head += "Allow: POST\r\n" }
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}
