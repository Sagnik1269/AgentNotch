import Foundation

/// Installs the hook scripts and wires them into Claude Code and zsh, on request from Settings.
///
/// - Claude Code: adds one AgentNotch hook entry per event to ~/.claude/settings.json, next to any
///   hooks you already have (those are left untouched). A backup is written first.
/// - zsh: appends a marked `source` block to ~/.zshrc (backup first); removal deletes only that block.
@MainActor
final class IntegrationInstaller: ObservableObject {
    static let shared = IntegrationInstaller()

    @Published private(set) var claudeHooksInstalled = false
    @Published private(set) var shellInstalled = false
    @Published var lastError: String?

    let supportDirectory: URL
    var hooksDirectory: URL { supportDirectory.appendingPathComponent("hooks") }
    var socketPath: String { supportDirectory.appendingPathComponent("agentnotch.sock").path }

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    private var zshrcURL: URL { home.appendingPathComponent(".zshrc") }

    private static let claudeHookName = "agentnotch-claude-hook"
    private static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                       "Notification", "Stop", "SessionEnd"]
    private static let claudeCommand =
        "\"$HOME/Library/Application Support/AgentNotch/hooks/\(claudeHookName)\""

    private static let zshBegin = "# >>> AgentNotch >>>"
    private static let zshEnd = "# <<< AgentNotch <<<"
    private static let zshBlock = """
    \(zshBegin)
    [ -f "$HOME/Library/Application Support/AgentNotch/hooks/agentnotch.zsh" ] && source "$HOME/Library/Application Support/AgentNotch/hooks/agentnotch.zsh"
    \(zshEnd)
    """

    private init() {
        supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch")
        refresh()
    }

    // MARK: - Scripts

    /// Copies the bundled hook scripts to Application Support (a stable path, unlike the app bundle).
    func installScripts() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: hooksDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
            guard let source = Bundle.main.resourceURL?.appendingPathComponent("Integrations") else { return }
            for name in try fm.contentsOfDirectory(atPath: source.path) {
                let target = hooksDirectory.appendingPathComponent(name)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source.appendingPathComponent(name), to: target)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
        } catch {
            lastError = "Couldn't install hook scripts: \(error.localizedDescription)"
        }
    }

    func refresh() {
        let settings = (try? String(contentsOf: claudeSettingsURL.resolvingSymlinksInPath(), encoding: .utf8)) ?? ""
        claudeHooksInstalled = settings.contains(Self.claudeHookName)
        let zshrc = (try? String(contentsOf: zshrcURL.resolvingSymlinksInPath(), encoding: .utf8)) ?? ""
        shellInstalled = zshrc.contains(Self.zshBegin)
    }

    // MARK: - Claude Code

    func setClaudeHooks(installed: Bool) {
        do {
            try editClaudeSettings { hooks in
                for event in Self.claudeEvents {
                    var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !Self.isOurs($0) }
                    if installed {
                        groups.append(["hooks": [["type": "command", "command": Self.claudeCommand, "timeout": 2]]])
                    }
                    hooks[event] = groups.isEmpty ? nil : groups
                }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains(claudeHookName) == true
        } ?? false
    }

    private func editClaudeSettings(_ edit: (inout [String: Any]) -> Void) throws {
        let url = claudeSettingsURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw InstallError("~/.claude/settings.json isn't valid JSON, so AgentNotch left it alone.")
                }
                root = parsed
            }
            try backup(url)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        edit(&hooks)
        root["hooks"] = hooks.isEmpty ? nil : hooks

        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - zsh

    func setShellIntegration(installed: Bool) {
        do {
            let url = zshrcURL.resolvingSymlinksInPath()
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if FileManager.default.fileExists(atPath: url.path) { try backup(url) }
            text = Self.removingBlock(from: text)
            if installed {
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                text += "\n" + Self.zshBlock + "\n"
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastError = nil
        } catch {
            lastError = "Couldn't update ~/.zshrc: \(error.localizedDescription)"
        }
        refresh()
    }

    private static func removingBlock(from text: String) -> String {
        guard let start = text.range(of: zshBegin), let end = text.range(of: zshEnd, range: start.upperBound..<text.endIndex)
        else { return text }
        var lower = start.lowerBound
        // Also drop the blank line we added before the block.
        if lower > text.startIndex, text[text.index(before: lower)] == "\n" {
            let prev = text.index(before: lower)
            if prev > text.startIndex, text[text.index(before: prev)] == "\n" { lower = prev }
        }
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        var result = text
        result.removeSubrange(lower..<upper)
        return result
    }

    // MARK: - Helpers

    private func backup(_ url: URL) throws {
        let backupURL = url.appendingPathExtension("agentnotch-backup")
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    struct InstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
