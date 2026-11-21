import Foundation

/// One thing an assistant can ask the app. Read-only: a handler looks things up and returns JSON-able values
/// (dictionaries, arrays, strings, numbers, booleans, `NSNull`).
public struct MCPTool {
    public let name: String
    /// The `ToolGroup` it belongs to; turning the group off hides the tool.
    public let group: String
    public let title: String?
    public let description: String
    public let input: [String: MCPParam]
    public let handler: @MainActor (MCPArguments) async throws -> Any

    public init(name: String, group: String, title: String? = nil, description: String,
                input: [String: MCPParam] = [:], handler: @escaping @MainActor (MCPArguments) async throws -> Any) {
        self.name = name
        self.group = group
        self.title = title
        self.description = description
        self.input = input
        self.handler = handler
    }

    var listing: [String: Any] {
        var properties: [String: Any] = [:]
        for (key, param) in input { properties[key] = param.schema }
        var schema: [String: Any] = ["type": "object", "properties": properties]
        let required = input.filter(\.value.required).map(\.key).sorted()
        if !required.isEmpty { schema["required"] = required }
        var out: [String: Any] = ["name": name, "description": description, "inputSchema": schema,
                                  "annotations": ["readOnlyHint": true, "openWorldHint": false]]
        if let title { out["title"] = title }
        return out
    }
}

/// One input to a tool.
public struct MCPParam {
    let type: String
    let description: String
    let options: [String]?
    let required: Bool

    public static func string(_ description: String, options: [String]? = nil, required: Bool = false) -> MCPParam {
        MCPParam(type: "string", description: description, options: options, required: required)
    }
    public static func integer(_ description: String, required: Bool = false) -> MCPParam {
        MCPParam(type: "integer", description: description, options: nil, required: required)
    }
    public static func boolean(_ description: String, required: Bool = false) -> MCPParam {
        MCPParam(type: "boolean", description: description, options: nil, required: required)
    }

    var schema: [String: Any] {
        var out: [String: Any] = ["type": type, "description": description]
        if let options { out["enum"] = options }
        return out
    }
}

/// A tool call's arguments.
public struct MCPArguments {
    public let raw: [String: Any]

    public func string(_ key: String) -> String? {
        guard let s = raw[key] as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
    public func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue ?? (raw[key] as? String).flatMap(Int.init) }
    public func bool(_ key: String) -> Bool? { (raw[key] as? Bool) ?? (raw[key] as? String).map { $0 == "true" } }
}

/// A tool failed in a way the assistant should hear about ("No team named X").
public struct MCPToolError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A switchable set of tools in the settings ("Review queue and pull requests").
public struct ToolGroup: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let detail: String?
    public let isOnByDefault: Bool

    public init(id: String, title: String, detail: String? = nil, isOnByDefault: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isOnByDefault = isOnByDefault
    }
}
