import AppKit
import Foundation

/// How the app's bridge tool finds it without a key in anyone's config: the app writes its port and key
/// to a file in an App Group container it shares with the tool (see MacAppMCPBridge). Assistants that start
/// the tool (Claude Desktop) then only need its location, so Reset Key and a new port don't break them.
public struct DesktopSetup {
    /// An App Group both the app and its bridge tool have in their entitlements ("TEAMID.com.example.app").
    public let appGroup: String
    /// The connection file's and the Claude Desktop extension's name ("myapp"): lowercase, digits, dashes.
    /// A demo copy uses its own ("myapp-demo") so it never replaces the real one.
    public let name: String
    /// What Claude Desktop shows ("My App").
    public let displayName: String
    public let author: String
    public let homepage: URL?

    public init(appGroup: String, name: String, displayName: String, author: String, homepage: URL? = nil) {
        self.appGroup = appGroup
        self.name = name
        self.displayName = displayName
        self.author = author
        self.homepage = homepage
    }

    /// Where the port and key go: <group container>/MacAppMCPKit/<name>.json.
    var connectionFile: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("MacAppMCPKit/\(name).json")
    }
}

/// Claude Desktop's one-click install: a .mcpb extension (a zip with manifest.json) that starts the
/// bridge tool inside this copy of the app. Opening it shows Claude Desktop's own Install window.
enum ClaudeDesktop {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let download = URL(string: "https://claude.ai/download")!

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Writes <tmp>/MacAppMCPKit/<name>.mcpb.
    static func makeExtension(setup: DesktopSetup, appName: String, version: String, helperPath: String,
                              tools: [MCPTool]) throws -> URL {
        var manifest: [String: Any] = [
            "manifest_version": "0.3",
            "name": setup.name,
            "display_name": setup.displayName,
            "version": semver(version),
            "description": "Lets Claude read \(appName) on this Mac: read-only, and only while \(appName) is open.",
            "author": ["name": setup.author],
            "server": [
                "type": "binary",
                // Claude Desktop wants an entry point in the extension; the command below runs the app's own copy.
                "entry_point": "server/bridge",
                "mcp_config": ["command": helperPath, "args": [setup.name], "env": [String: String]()],
            ],
            "tools": tools.map { ["name": $0.name, "description": $0.description] },
            "compatibility": ["platforms": ["darwin"]],
        ]
        if let homepage = setup.homepage { manifest["homepage"] = homepage.absoluteString }
        var files: [(String, Data)] = []
        if let icon = iconPNG() {
            manifest["icon"] = "icon.png"
            files.append(("icon.png", icon))
        }
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        files.insert(("manifest.json", json), at: 0)
        files.append(("server/bridge", Data("\(appName) runs the bridge inside \(appName).app: \(helperPath)\n".utf8)))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacAppMCPKit", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(setup.name).mcpb")
        try Zip.archive(files).write(to: file, options: .atomic)
        return file
    }

    /// Opens the extension in Claude Desktop, which asks the person to install it.
    static func open(_ file: URL) async throws {
        guard let app = appURL else { throw MCPToolError("Claude Desktop isn't on this Mac.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
    }

    /// "2.3" → "2.3.0": extensions need three numbers.
    private static func semver(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init).filter { Int($0) != nil }
        while parts.count < 3 { parts.append("0") }
        return parts.prefix(3).joined(separator: ".")
    }

    /// The app's icon at 256 points, for Claude Desktop's extension list.
    private static func iconPNG() -> Data? {
        let size = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSApp.applicationIconImage.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Just enough zip for an extension: files stored as they are (no compression), UTF-8 names.
enum Zip {
    static func archive(_ files: [(path: String, data: Data)]) -> Data {
        var out = Data(), central = Data()
        for (path, data) in files {
            let name = Data(path.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            let common = le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)   // version, UTF-8, stored, 1980-01-01
                + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(UInt16(name.count)) + le16(0)
            out += le32(0x0403_4b50) + common + name + data
            central += le32(0x0201_4b50) + le16(0x0314) + common + le16(0) + le16(0) + le16(0)
                + le32(0o100644 << 16) + le32(offset) + name
        }
        let count = le16(UInt16(files.count))
        return out + central + le32(0x0605_4b50) + le16(0) + le16(0) + count + count
            + le32(UInt32(central.count)) + le32(UInt32(out.count)) + le16(0)
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
