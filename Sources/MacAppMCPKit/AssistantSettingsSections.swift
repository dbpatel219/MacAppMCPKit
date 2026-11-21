import AppKit
import SwiftUI

/// The "AI assistants" settings, without a page title (the app puts it in its own settings page):
/// the switch, then either what it does and what you could ask, or how to connect, what's shared, and Reset Key.
public struct AssistantSettingsSections: View {
    @ObservedObject var access: AssistantAccess
    let examples: [String]
    /// The switch is a paid feature the person doesn't have: turning it on calls `onLocked` instead.
    let isLocked: Bool
    let onLocked: () -> Void

    /// Rows opened to show their setup.
    @State private var expanded: Set<AssistantKind> = []
    @State private var copied: String?
    @State private var confirmsReset = false
    @State private var desktopState: DesktopState = .idle
    @State private var showsManualDesktop = false
    @State private var showsManualVSCode = false
    @State private var vsCodeOpened = false

    private enum DesktopState: Equatable { case idle, opening, opened, failed(String) }

    public init(access: AssistantAccess, examples: [String], isLocked: Bool = false, onLocked: @escaping () -> Void = {}) {
        self.access = access
        self.examples = examples
        self.isLocked = isLocked
        self.onLocked = onLocked
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Let AI assistants read \(access.appName)").font(.system(size: 13))
                            if isLocked { ProBadge() }
                        }
                        if access.isEnabled && !isLocked { status } else {
                            Text("Claude, Cursor, VS Code or any app that supports MCP can read it. Read-only: they can't change anything. Only apps on this Mac can connect, and only while \(access.appName) is open.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(get: { access.isEnabled && !isLocked },
                                             set: { on in if isLocked { onLocked() } else { access.setEnabled(on) } }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 10)
            }

            if access.isEnabled && !isLocked {
                connect
                shared
                footer
            } else {
                privacyNote
                if !examples.isEmpty { examplesCard }
            }
        }
        .alert("Reset the key?", isPresented: $confirmsReset) {
            Button("Reset Key", role: .destructive) { access.resetKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(access.desktop == nil
                 ? "Assistants set up with the current key stop working until you set them up again."
                 : "Other apps set up with the current key stop working until you set them up again. Claude Desktop, Claude Code, VS Code and Codex keep working.")
        }
    }

    // MARK: Pieces

    @ViewBuilder private var status: some View {
        if let problem = access.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(.red)
        } else {
            HStack(spacing: 5) {
                Circle().fill(access.isRunning ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        guard access.isRunning else { return "Starting…" }
        switch access.connectedCount {
        case 0: return "On · no assistant has asked yet"
        case 1: return "On · 1 assistant connected"
        case let n: return "On · \(n) assistants connected"
        }
    }

    private var privacyNote: some View {
        Label {
            Text("What an assistant reads goes to the company that runs it, under your account with them. Nothing is sent to \(access.appName)'s developer.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5))
    }

    private var examplesCard: some View {
        section("You could ask") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(examples, id: \.self) { Text("“\($0)”") }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
    }

    // MARK: Assistants list

    private var connect: some View {
        VStack(alignment: .leading, spacing: 7) {
            section("Assistants") {
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    VStack(alignment: .leading, spacing: 0) {
                        if index > 0 { Divider() }
                        row(kind)
                        if expanded.contains(kind) {
                            details(kind)
                                .padding(.leading, 38)
                                .padding(.bottom, 12)
                        }
                    }
                }
            }
            privacyNote.padding(.top, 4)
        }
    }

    /// Claude Desktop, VS Code and Codex start the app's bridge tool, so they need a copy that has one.
    private var kinds: [AssistantKind] {
        AssistantKind.allCases.filter { kind in
            switch kind {
            case .claudeDesktop: return access.helperPath != nil
            case .vsCode, .codex: return access.canAddToClaudeDesktop
            default: return true
            }
        }
    }

    private func row(_ kind: AssistantKind) -> some View {
        HStack(spacing: 10) {
            AssistantIcon(kind: kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.system(size: 13))
                rowStatus(kind)
            }
            Spacer(minLength: 8)
            action(kind)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded.contains(kind) ? 90 : 0))
                .frame(width: 14)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggle(kind) }
        .contextMenu {
            if access.lastAsked(by: kind) != nil { Button("Forget \(kind.title)") { access.forget(kind) } }
        }
    }

    @ViewBuilder private func rowStatus(_ kind: AssistantKind) -> some View {
        if let last = access.lastAsked(by: kind) {
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(connectedText(kind, last.date)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else {
            Text(kind == .other ? "Cursor, Zed, anything with MCP" : "Not connected yet")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func connectedText(_ kind: AssistantKind, _ date: Date) -> String {
        let when = date.timeIntervalSinceNow > -60 ? "just now"
            : RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        if kind == .other { return access.otherClients().joined(separator: ", ") + " · last asked \(when)" }
        return "Connected · last asked \(when)"
    }

    /// The row's one button: add, copy, or open the setup.
    @ViewBuilder private func action(_ kind: AssistantKind) -> some View {
        let connected = access.lastAsked(by: kind) != nil
        switch kind {
        case .claudeDesktop:
            if access.canAddToClaudeDesktop && access.hasClaudeDesktop {
                rowButton(desktopState == .opening ? "Opening…" : connected ? "Add Again" : "Add", prominent: !connected) {
                    addToClaudeDesktop()
                }
                .disabled(desktopState == .opening)
            } else {
                rowButton("Show Setup", prominent: false) { toggle(kind) }
            }
        case .claudeCode:
            copyButton("Copy Command", copyID: "code", text: access.claudeCodeCommand, prominent: !connected)
        case .vsCode:
            if access.hasVSCode, let url = access.vsCodeInstallURL {
                rowButton(connected ? "Add Again" : "Add", prominent: !connected) {
                    NSWorkspace.shared.open(url)
                    vsCodeOpened = true
                    expanded.insert(.vsCode)
                }
            } else {
                Link("Get VS Code", destination: AssistantAccess.vsCodeDownload).font(.system(size: 12))
            }
        case .codex:
            if let command = access.codexCommand {
                copyButton("Copy Command", copyID: "codex", text: command, prominent: !connected)
            }
        case .other:
            rowButton(expanded.contains(.other) ? "Hide Setup" : "Show Setup", prominent: false) { toggle(.other) }
        }
    }

    @ViewBuilder private func details(_ kind: AssistantKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .claudeDesktop:
                if access.canAddToClaudeDesktop {
                    if !access.hasClaudeDesktop {
                        HStack(spacing: 6) {
                            note("Claude Desktop isn't on this Mac.")
                            Link("Get Claude Desktop", destination: AssistantAccess.claudeDesktopDownload).font(.system(size: 11))
                        }
                    } else {
                        note("Add opens Claude Desktop, which asks you to confirm: click Install. If you move \(access.appName) to another folder, add it again.")
                    }
                    switch desktopState {
                    case .opened: done("Finish in Claude Desktop: click Install")
                    case .failed(let why): failure(why)
                    default: EmptyView()
                    }
                    DisclosureGroup("Set it up by hand", isExpanded: $showsManualDesktop) { manualDesktop.padding(.top, 4) }
                        .font(.system(size: 11))
                } else {
                    manualDesktop
                }
            case .claudeCode:
                note(access.canAddToClaudeDesktop
                     ? "Run this once in Terminal. Set it up before? Run claude mcp remove \(access.desktop?.name ?? access.serverName) first."
                     : "Run this once in Terminal.")
                codeBox(access.claudeCodeCommand, copyID: "command")
            case .vsCode:
                note("Add opens VS Code, which asks you to confirm: click Install. Then ask in Copilot Chat's Agent mode.")
                if vsCodeOpened { done("Finish in VS Code: click Install") }
                DisclosureGroup("Set it up by hand", isExpanded: $showsManualVSCode) {
                    VStack(alignment: .leading, spacing: 7) {
                        note("In VS Code, run “MCP: Open User Configuration” from the Command Palette and add this inside \"servers\".")
                        if let json = access.vsCodeJSON { codeBox(json, copyID: "vscode") }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 11))
            case .codex:
                note("Run this once in Terminal. The Codex CLI and the Codex IDE extension share it.")
                if let command = access.codexCommand { codeBox(command, copyID: "codexBox") }
            case .other:
                note("Add this to the app's MCP servers, or paste the address and key into its form.")
                codeBox(access.configJSON, copyID: "json") {
                    copyButton("Copy Address", copyID: "url", text: access.url, prominent: false)
                    copyButton("Copy Key", copyID: "key", text: access.key, prominent: false)
                }
            }
            if access.lastAsked(by: kind) != nil {
                Button("Forget \(kind.title)") { access.forget(kind) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .help("Removed \(access.appName) from it? This takes it off the list until it asks again.")
            }
        }
    }

    private var manualDesktop: some View {
        VStack(alignment: .leading, spacing: 7) {
            note("In Claude Desktop, choose Settings → Developer → Edit Config, paste this in and save, then quit and reopen Claude Desktop. If the file already has \"mcpServers\", add just the \"\(access.desktop?.name ?? access.serverName)\" part inside it.")
            if let json = access.claudeDesktopJSON { codeBox(json, copyID: "desktop") }
        }
    }

    private func addToClaudeDesktop() {
        desktopState = .opening
        expanded.insert(.claudeDesktop)
        Task {
            do {
                try await access.addToClaudeDesktop()
                desktopState = .opened
            } catch {
                desktopState = .failed(error.localizedDescription)
            }
        }
    }

    private func toggle(_ kind: AssistantKind) {
        if expanded.contains(kind) { expanded.remove(kind) } else { expanded.insert(kind) }
    }

    private func rowButton(_ title: String, prominent: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(prominent ? .accentColor : .secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func done(_ text: String) -> some View {
        Label(text, systemImage: "arrow.right.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func failure(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
    }

    private var shared: some View {
        section("What assistants can read") {
            ForEach(Array(access.groups.enumerated()), id: \.element.id) { index, group in
                VStack(spacing: 0) {
                    if index > 0 { Divider() }
                    Toggle(isOn: Binding(get: { access.enabledGroups.contains(group.id) },
                                         set: { access.setGroup(group.id, on: $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title).font(.system(size: 13))
                            if let detail = group.detail {
                                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Anyone with the key can read this while \(access.appName) is open.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Reset Key…") { confirmsReset = true }.controlSize(.small)
        }
    }

    // MARK: Building blocks (the same soft cards as the apps' own settings)

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(title)
            card(content)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }

    /// The text with the key shortened, and Copy (which copies all of it).
    private func codeBox<Extra: View>(_ text: String, copyID: String, @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(masked(text))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
            VStack(alignment: .trailing, spacing: 6) {
                copyButton("Copy", copyID: copyID, text: text, prominent: true)
                extra()
            }
        }
    }

    private func copyButton(_ title: String, copyID: String, text: String, prominent: Bool) -> some View {
        Button(copied == copyID ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = copyID
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == copyID { copied = nil } }
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .tint(prominent ? .accentColor : .secondary)
    }

    /// "lmcp_3a9f…c41e": enough to tell keys apart in a screenshot without showing them.
    private func masked(_ text: String) -> String {
        guard access.key.count > 12 else { return text }
        return text.replacingOccurrences(of: access.key, with: access.key.prefix(9) + "…" + access.key.suffix(4))
    }
}

/// A small tile per assistant (generic symbols: no other companies' logos).
private struct AssistantIcon: View {
    let kind: AssistantKind

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(color))
    }

    private var symbol: String {
        switch kind {
        case .claudeDesktop: return "macwindow"
        case .claudeCode: return "terminal"
        case .vsCode: return "chevron.left.forwardslash.chevron.right"
        case .codex: return "apple.terminal"
        case .other: return "ellipsis"
        }
    }

    private var color: Color {
        switch kind {
        case .claudeDesktop, .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .vsCode: return Color(red: 0.18, green: 0.5, blue: 0.93)
        case .codex: return Color(white: 0.35)
        case .other: return Color(white: 0.45)
        }
    }
}

private struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
    }
}
