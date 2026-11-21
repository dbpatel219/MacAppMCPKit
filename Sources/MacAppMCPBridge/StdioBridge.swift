import Foundation

/// For assistants that start MCP servers as programs (Claude Desktop): reads JSON-RPC messages, one per line,
/// from standard input, passes each to the app's server on 127.0.0.1, and writes the answers to standard output.
/// The app embeds a tiny tool whose `main.swift` calls `StdioBridge.run(appName:appGroup:name:)`.
///
/// It finds the app's port and key in the file the app keeps in their shared App Group
/// (`<group>/MacAppMCPKit/<name>.json`, see `DesktopSetup`), read again for every message so Reset Key
/// and a new port need no setup. The first argument, if any, replaces `name` (a demo copy's own file).
/// `MACAPPMCP_PORT` and `MACAPPMCP_KEY` in the environment win, for apps without an App Group.
public enum StdioBridge {
    public static func run(appName: String, appGroup: String? = nil, name: String? = nil) -> Never {
        let name = CommandLine.arguments.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 } ?? name
        let file = appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            .flatMap { dir in name.map { dir.appendingPathComponent("MacAppMCPKit/\($0).json") } }
        let session = URLSession(configuration: .ephemeral)
        // Passed along so the app knows which assistant is asking, even after it restarts.
        var mcpSession: String?
        var client: String?

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let id = message?["id"]
            if message?["method"] as? String == "initialize" {
                client = ((message?["params"] as? [String: Any])?["clientInfo"] as? [String: Any])?["name"] as? String
            }
            guard let (port, key) = connection(file) else {
                if let id, !(id is NSNull) {
                    write(error(id: id, message: "AI assistants are turned off in \(appName). Open \(appName)'s settings, turn on “Let AI assistants read \(appName)”, and try again."))
                }
                continue
            }
            let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.httpBody = Data(line.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let mcpSession { request.setValue(mcpSession, forHTTPHeaderField: "Mcp-Session-Id") }
            if let client { request.setValue(client, forHTTPHeaderField: "X-MacAppMCPKit-Client") }

            let (data, status, failure, newSession) = send(request, session)
            if let newSession { mcpSession = newSession }
            if let id, !(id is NSNull) {
                if let data, status == 200 {
                    write(data)
                } else {
                    let why = failure != nil
                        ? "\(appName) isn't open. Open \(appName) and try again."
                        : status == 401 ? "The key doesn't match. Set this up again from \(appName)'s settings."
                        : "\(appName) answered with HTTP \(status)."
                    write(error(id: id, message: why))
                }
            }
        }
        exit(0)
    }

    /// The port and key: from the environment if set, else the app's file.
    private static func connection(_ file: URL?) -> (Int, String)? {
        let env = ProcessInfo.processInfo.environment
        if let key = env["MACAPPMCP_KEY"], !key.isEmpty, let port = env["MACAPPMCP_PORT"].flatMap(Int.init) {
            return (port, key)
        }
        guard let file, let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int, let key = object["key"] as? String, !key.isEmpty else { return nil }
        return (port, key)
    }

    /// One request, waiting for the answer (the assistant sends one message at a time over stdio anyway).
    private static func send(_ request: URLRequest, _ session: URLSession) -> (Data?, Int, Error?, String?) {
        let done = DispatchSemaphore(value: 0)
        var result: (Data?, Int, Error?, String?) = (nil, 0, nil, nil)
        session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            result = (data, http?.statusCode ?? 0, error, http?.value(forHTTPHeaderField: "Mcp-Session-Id"))
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private static func error(id: Any, message: String) -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func write(_ data: Data) {
        // One message per line: the server's JSON has no raw newlines.
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
