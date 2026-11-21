import Foundation

/// The assistants the settings list, and which one an MCP client name ("claude-ai") belongs to.
public enum AssistantKind: String, CaseIterable, Identifiable {
    case claudeDesktop, claudeCode, vsCode, codex, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode: return "Claude Code"
        case .vsCode: return "VS Code"
        case .codex: return "Codex"
        case .other: return "Other apps"
        }
    }

    /// From the name an assistant sends when it connects (`clientInfo.name`).
    public init(client: String) {
        let name = client.lowercased()
        if name.contains("claude-code") || name.contains("claude code") { self = .claudeCode }
        else if name.contains("claude") { self = .claudeDesktop }   // Claude Desktop says "claude-ai"
        else if name.contains("cursor") { self = .other }            // Cursor is built on VS Code
        else if name.contains("visual studio code") || name.contains("vscode") { self = .vsCode }
        else if name.contains("codex") { self = .codex }
        else { self = .other }
    }

    /// How an unknown client shows in "Other apps": "cursor-vscode" → "Cursor".
    static func displayName(_ client: String) -> String {
        let name = client.lowercased()
        if name.contains("cursor") { return "Cursor" }
        if name.contains("zed") { return "Zed" }
        if name.contains("windsurf") { return "Windsurf" }
        return client
    }
}
