# MacAppMCPKit

Let AI assistants on the same Mac — Claude Desktop, Claude Code, VS Code, Codex, Cursor, or anything that
speaks [MCP](https://modelcontextprotocol.io) — read your Mac app's data. Read-only, off until the person
turns it on, and only while your app is open.

You write the tools (Swift closures that return JSON-able values). MacAppMCPKit brings the rest:

- **A server**: MCP over HTTP on `127.0.0.1` only, behind a random key kept in the Keychain.
- **A settings page**: an on/off switch, the assistants with whether each has connected and when it last asked,
  one-click setup for Claude Desktop and VS Code, copyable commands for Claude Code and Codex, groups of tools
  the person can turn off, and Reset Key.
- **A bridge tool** you embed in the app, for assistants that start MCP servers as programs. It finds your app
  on its own, so their setup holds no key or port and never goes stale.

It works in sandboxed apps, including on the Mac App Store. Mergable uses it.

## Add it to an app

**1. The package.** Add `https://github.com/dbpatel219/MacAppMCPKit` with Swift Package Manager. The app uses
the `MacAppMCPKit` product; the bridge tool (step 4) uses `MacAppMCPBridge`. macOS 13 or later.

**2. Entitlements.** The app needs `com.apple.security.network.server` (it listens on 127.0.0.1), and an
App Group shared with the bridge tool, prefixed with your team ID:

```xml
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.application-groups</key>
<array><string>TEAMID.com.example.myapp</string></array>
```

**3. The access object and tools.**

```swift
import MacAppMCPKit

let access = AssistantAccess(
    appName: "My App", serverName: "myapp", defaultPort: 7400,
    groups: [ToolGroup(id: "notes", title: "Notes", detail: "Titles and text")],
    instructions: "My App keeps notes. These tools read them.",
    version: "1.0",
    helperName: "myapp-mcp",
    desktop: DesktopSetup(appGroup: "TEAMID.com.example.myapp", name: "myapp",
                          displayName: "My App", author: "Example Inc."))

access.tools = [
    MCPTool(name: "search_notes", group: "notes", description: "Notes whose title or text match a query.",
            input: ["query": .string("Words to look for", required: true)]) { args in
        guard let query = args.string("query") else { throw MCPToolError("Say what to look for.") }
        return ["notes": store.search(query).map { ["title": $0.title, "text": $0.text] }]
    },
]
access.startIfEnabled()
```

Put the settings in your app's settings window:

```swift
AssistantSettingsSections(access: access, examples: ["What did I write about the launch?"])
```

**4. The bridge tool.** Add a command-line tool target named after `helperName`, embedded in the app's
`Contents/Helpers`, sandboxed with `com.apple.security.network.client` and the same App Group. (A sandboxed
tool needs a bundle identifier: set `GENERATE_INFOPLIST_FILE` and `CREATE_INFOPLIST_SECTION_IN_BINARY`.)
Its whole `main.swift`:

```swift
import MacAppMCPBridge
StdioBridge.run(appName: "My App", appGroup: "TEAMID.com.example.myapp", name: "myapp")
```

Without step 2's App Group and step 4, the settings still offer Claude Code and other apps over HTTP with the key.

## How it keeps the data on this Mac

- The server listens on `127.0.0.1` only, so other machines can't reach it.
- Every request needs `Authorization: Bearer <key>`, compared in constant time. Reset Key makes a new one.
- Requests from web pages are refused: an `Origin` that isn't this Mac, or a `Host` that isn't `127.0.0.1` or
  `localhost` (which stops a site pointing its own domain at 127.0.0.1).
- The server only lists and calls the tools you give it, and marks them read-only.
- The bridge reads the port and key from a file in the App Group container, so no assistant's config file
  holds the key.

What an assistant reads goes to whoever runs that assistant; the settings page says so before the person turns
it on. Choose what your tools return with that in mind.

## How assistants connect

| Assistant | Setup in the settings | How it connects |
| --- | --- | --- |
| Claude Desktop | Add → Claude Desktop asks to install an extension | starts the bridge tool |
| VS Code | Add → VS Code asks to install the server | starts the bridge tool |
| Claude Code | `claude mcp add … -- <bridge> <name>` | starts the bridge tool |
| Codex | `codex mcp add … -- <bridge> <name>` | starts the bridge tool |
| Others (Cursor, Zed, …) | JSON with the address and key | HTTP with the key |

Assistants that run in the cloud (ChatGPT, claude.ai on the web) can't reach a server on the Mac.

## Status

Young: used in one shipping app. MacAppMCPKit speaks MCP protocol versions 2025-06-18, 2025-03-26 and
2024-11-05, tools only (no resources, prompts or streaming).

## License

MIT. See [LICENSE](LICENSE).
