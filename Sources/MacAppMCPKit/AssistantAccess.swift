import AppKit
import Foundation
import Security

/// Where the key lives: the Keychain normally; memory for demo builds and screenshots.
public enum AssistantKeyStore {
    case keychain
    case memory(String)
}

/// The app's "Let AI assistants read <App>" switch and everything behind it: the server, its port and key,
/// which tool groups are on, and when an assistant last asked. Off until the person turns it on.
@MainActor
public final class AssistantAccess: ObservableObject {
    public let appName: String
    /// The name assistants know it by ("myapp"): lowercase, no spaces.
    public let serverName: String
    public let groups: [ToolGroup]
    /// The bridge tool's file name in the app's Contents/Helpers (see MacAppMCPBridge), if the app embeds one.
    public let helperName: String?
    /// The App Group file and Claude Desktop extension (see `DesktopSetup`), if the app embeds a bridge tool.
    public let desktop: DesktopSetup?
    /// Everything the app offers; only tools in groups that are on are listed.
    public var tools: [MCPTool] = []

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isRunning = false
    @Published public private(set) var port: UInt16
    @Published public private(set) var key: String
    @Published public private(set) var enabledGroups: Set<String>
    @Published public private(set) var lastAsked: Date?
    @Published public private(set) var lastClient: String?
    /// When each assistant (by the name it connects with) last asked.
    @Published public private(set) var connections: [String: Date]
    /// Why the server isn't running, when it should be.
    @Published public private(set) var problem: String?

    private let defaultPort: UInt16
    private let instructions: String
    private let version: String
    private let keyStore: AssistantKeyStore
    private let defaults: UserDefaults
    private var server: MCPServer?

    public init(appName: String, serverName: String, defaultPort: UInt16, groups: [ToolGroup],
                instructions: String, version: String = "1.0", helperName: String? = nil,
                desktop: DesktopSetup? = nil, keyStore: AssistantKeyStore = .keychain, defaults: UserDefaults = .standard) {
        self.appName = appName
        self.serverName = serverName
        self.groups = groups
        self.helperName = helperName
        self.desktop = desktop
        self.defaultPort = defaultPort
        self.instructions = instructions
        self.version = version
        self.keyStore = keyStore
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        port = UInt16(exactly: defaults.integer(forKey: Self.portKey)).flatMap { $0 == 0 ? nil : $0 } ?? defaultPort
        enabledGroups = (defaults.stringArray(forKey: Self.groupsKey)).map(Set.init)
            ?? Set(groups.filter(\.isOnByDefault).map(\.id))
        lastAsked = defaults.object(forKey: Self.lastAskedKey) as? Date
        lastClient = defaults.string(forKey: Self.lastClientKey)
        connections = defaults.dictionary(forKey: Self.connectionsKey) as? [String: Date] ?? [:]
        switch keyStore {
        case .memory(let k): key = k
        case .keychain: key = ""
        }
    }

    // MARK: What the settings show

    public var url: String { "http://127.0.0.1:\(port)/mcp" }

    /// One line for Claude Code's Terminal. With the bridge tool it has no key or port in it, so Reset Key
    /// and a new port don't break it; without one it connects over HTTP with the key.
    public var claudeCodeCommand: String {
        if let bridge {
            return "claude mcp add --scope user \(bridge.name) -- \(Self.shellQuoted(bridge.command)) \(bridge.name)"
        }
        return "claude mcp add --scope user --transport http \(serverName) \(url) --header \"Authorization: Bearer \(key)\""
    }

    /// Where the bridge tool is inside this copy of the app, if it embeds one.
    public var helperPath: String? {
        helperName.map { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\($0)").path }
    }

    /// For Claude Desktop's config file (Settings → Developer → Edit Config): it starts the bridge tool.
    /// With an App Group the tool reads the port and key itself, so there's no key in it.
    public var claudeDesktopJSON: String? {
        guard let helperPath else { return nil }
        let how = desktop.map { "\"args\": [\"\($0.name)\"]" }
            ?? "\"env\": { \"MACAPPMCP_PORT\": \"\(port)\", \"MACAPPMCP_KEY\": \"\(key)\" }"
        return """
        {
          "mcpServers": {
            "\(desktop?.name ?? serverName)": {
              "command": "\(helperPath)",
              \(how)
            }
          }
        }
        """
    }

    /// Whether "Add to Claude Desktop" can work: this copy has the bridge tool and an App Group.
    public var canAddToClaudeDesktop: Bool {
        desktop != nil && helperPath.map(FileManager.default.isExecutableFile(atPath:)) == true
    }

    public var hasClaudeDesktop: Bool { ClaudeDesktop.appURL != nil }

    public static var claudeDesktopDownload: URL { ClaudeDesktop.download }

    /// The bridge tool's command for apps that start MCP servers as programs, with no key in it.
    private var bridge: (command: String, name: String)? {
        guard let desktop, let helperPath, canAddToClaudeDesktop else { return nil }
        return (helperPath, desktop.name)
    }

    public var hasVSCode: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil }

    public static var vsCodeDownload: URL { URL(string: "https://code.visualstudio.com/download")! }

    /// VS Code's install link: it opens VS Code, which asks the person to install the server.
    public var vsCodeInstallURL: URL? {
        guard let bridge else { return nil }
        let server: [String: Any] = ["name": bridge.name, "type": "stdio", "command": bridge.command, "args": [bridge.name]]
        guard let data = try? JSONSerialization.data(withJSONObject: server, options: [.sortedKeys, .withoutEscapingSlashes]),
              let query = String(decoding: data, as: UTF8.self)
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "vscode:mcp/install?" + query)
    }

    /// For VS Code's mcp.json ("MCP: Open User Configuration"), inside "servers".
    public var vsCodeJSON: String? {
        guard let bridge else { return nil }
        return """
        "\(bridge.name)": {
          "type": "stdio",
          "command": "\(bridge.command)",
          "args": ["\(bridge.name)"]
        }
        """
    }

    /// One line for Codex's Terminal (the Codex CLI and IDE extension share ~/.codex/config.toml).
    public var codexCommand: String? {
        guard let bridge else { return nil }
        return "codex mcp add \(bridge.name) -- \(Self.shellQuoted(bridge.command)) \(bridge.name)"
    }

    private static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }
            ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Makes the extension and opens it in Claude Desktop, which asks the person to install it.
    /// Adding it again (after moving the app) replaces the old one.
    public func addToClaudeDesktop() async throws {
        guard let desktop, let helperPath else { throw MCPToolError("This copy of \(appName) can't set up Claude Desktop.") }
        let file = try ClaudeDesktop.makeExtension(setup: desktop, appName: appName, version: version,
                                                   helperPath: helperPath, tools: tools)
        try await ClaudeDesktop.open(file)
    }

    /// What most MCP apps take in their settings file.
    public var configJSON: String {
        """
        {
          "\(serverName)": {
            "type": "http",
            "url": "\(url)",
            "headers": { "Authorization": "Bearer \(key)" }
          }
        }
        """
    }

    // MARK: Changing it

    /// Starts the server if the switch is on (call once at launch).
    public func startIfEnabled() {
        if isEnabled { start() }
    }

    public func setEnabled(_ on: Bool) {
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop(); removeConnectionFile() }
    }

    public func setGroup(_ id: String, on: Bool) {
        if on { enabledGroups.insert(id) } else { enabledGroups.remove(id) }
        defaults.set(Array(enabledGroups).sorted(), forKey: Self.groupsKey)
    }

    /// A new key: every assistant set up with the old one has to be set up again.
    public func resetKey() {
        key = Self.newKey()
        if case .keychain = keyStore { Keychain.save(key, account: serverName) }
        if isEnabled { stop(); start() }
    }

    // MARK: Server

    private func start() {
        guard server == nil else { return }
        loadKey()
        problem = nil
        listen(port: port, attemptsLeft: 10)
    }

    private func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }

    /// Tries `port`, then the next ones up if it's taken, and remembers the one that worked.
    private func listen(port: UInt16, attemptsLeft: Int) {
        let server = MCPServer(name: appName, version: version, instructions: instructions, key: key)
        server.tools = { [weak self] in
            guard let self else { return [] }
            return self.tools.filter { self.enabledGroups.contains($0.group) }
        }
        server.onRequest = { [weak self] client in self?.asked(by: client) }
        self.server = server
        server.start(port: port) { [weak self] error in
            guard let self, self.server === server else { return }
            if let error {
                server.stop()
                self.server = nil
                if attemptsLeft > 1, port < .max {
                    self.listen(port: port + 1, attemptsLeft: attemptsLeft - 1)
                } else {
                    self.problem = "Couldn't start: \(error.localizedDescription)"
                }
                return
            }
            self.port = port
            self.defaults.set(Int(port), forKey: Self.portKey)
            self.isRunning = true
            self.writeConnectionFile()
        }
    }

    /// The port and key for the bridge tool, readable only by this app and its tool (and this Mac's user).
    private func writeConnectionFile() {
        guard let file = desktop?.connectionFile,
              let data = try? JSONSerialization.data(withJSONObject: ["port": Int(port), "key": key]) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            problem = "Couldn't save the setup for Claude Desktop: \(error.localizedDescription)"
        }
    }

    private func removeConnectionFile() {
        guard let file = desktop?.connectionFile else { return }
        try? FileManager.default.removeItem(at: file)
    }

    private func asked(by client: String?) {
        let now = Date()
        lastAsked = now
        defaults.set(now, forKey: Self.lastAskedKey)
        if let client {
            lastClient = client
            defaults.set(client, forKey: Self.lastClientKey)
            connections[client] = now
            defaults.set(connections, forKey: Self.connectionsKey)
        }
    }

    // MARK: Which assistants have connected

    /// When an assistant of this kind last asked, and the name it connected with.
    public func lastAsked(by kind: AssistantKind) -> (date: Date, client: String)? {
        connections.filter { AssistantKind(client: $0.key) == kind }
            .max { $0.value < $1.value }
            .map { ($0.value, $0.key) }
    }

    /// "Cursor, Zed" for Other apps.
    public func otherClients() -> [String] {
        let names = connections.keys.filter { AssistantKind(client: $0) == .other }.map(AssistantKind.displayName)
        return Array(Set(names)).sorted()
    }

    public var connectedCount: Int { AssistantKind.allCases.filter { lastAsked(by: $0) != nil }.count }

    /// Takes an assistant off the list (after removing the app from it). It comes back if it asks again.
    public func forget(_ kind: AssistantKind) {
        connections = connections.filter { AssistantKind(client: $0.key) != kind }
        defaults.set(connections, forKey: Self.connectionsKey)
    }

    private func loadKey() {
        guard key.isEmpty, case .keychain = keyStore else { return }
        if let saved = Keychain.load(account: serverName) {
            key = saved
        } else {
            key = Self.newKey()
            Keychain.save(key, account: serverName)
        }
    }

    /// 32 random bytes as hex, after a short prefix so it's recognizable in a config file.
    private static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "lmcp_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static let enabledKey = "macAppMCP.enabled"
    private static let portKey = "macAppMCP.port"
    private static let groupsKey = "macAppMCP.groups"
    private static let lastAskedKey = "macAppMCP.lastAsked"
    private static let lastClientKey = "macAppMCP.lastClient"
    private static let connectionsKey = "macAppMCP.connections"
}

/// The key as a generic password in the app's own Keychain.
private enum Keychain {
    static var service: String { (Bundle.main.bundleIdentifier ?? "MacAppMCPKit") + ".assistant-key" }

    static func load(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
