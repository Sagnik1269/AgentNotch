import Foundation

struct AgentSession: Identifiable, Equatable {
    enum State: Int, Comparable {
        case waiting = 0, working, done, idle   // sort order: needs-you first
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    var cwd: String
    var state: State
    var detail: String
    var lastPrompt: String?
    var turnStartedAt: Date?
    var updatedAt: Date
    var appBundleID: String?

    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude Code" : name
    }
}

/// Claude Code sessions, driven by hook events (see Helpers/Integrations/agentnotch-claude-hook).
@MainActor
final class AgentsModel: ObservableObject {
    static let shared = AgentsModel()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var lastEventAt: Date?

    private var byID: [String: AgentSession] = [:] { didSet { publish() } }
    private var sweepTimer: Timer?

    var waitingCount: Int { sessions.filter { $0.state == .waiting }.count }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }

    private init() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    // MARK: - Hook events

    func handle(_ json: [String: Any], bundleID: String?) {
        guard let id = json["session_id"] as? String, !id.isEmpty,
              let event = json["hook_event_name"] as? String else { return }
        lastEventAt = Date()
        let cwd = json["cwd"] as? String ?? byID[id]?.cwd ?? ""
        var session = byID[id] ?? AgentSession(id: id, cwd: cwd, state: .idle, detail: "Ready",
                                               updatedAt: Date(), appBundleID: bundleID)
        session.cwd = cwd
        session.updatedAt = Date()
        if let bundleID, !bundleID.isEmpty { session.appBundleID = bundleID }
        if !cwd.isEmpty { CIModel.shared.track(directory: cwd) }

        switch event {
        case "SessionStart":
            session.state = .idle
            session.detail = "Ready"

        case "UserPromptSubmit":
            session.state = .working
            session.turnStartedAt = Date()
            session.detail = "Thinking…"
            if let prompt = json["prompt"] as? String {
                session.lastPrompt = Self.oneLine(prompt, max: 90)
            }

        case "PreToolUse":
            session.state = .working
            if session.turnStartedAt == nil { session.turnStartedAt = Date() }
            session.detail = Self.describeTool(json["tool_name"] as? String ?? "",
                                               json["tool_input"] as? [String: Any])

        case "PostToolUse", "PostToolUseFailure":
            if session.state == .waiting { session.state = .working }

        case "Notification":
            let message = json["message"] as? String ?? "Needs your input"
            let type = json["notification_type"] as? String ?? ""
            let isIdleReminder = type == "idle_prompt" || message.localizedCaseInsensitiveContains("waiting for your input")
            // The idle reminder after a finished turn isn't new information; keep "done".
            if isIdleReminder && (session.state == .done || session.state == .idle) { break }
            session.state = .waiting
            session.detail = Self.oneLine(message, max: 90)
            alert(for: session, finished: false)

        case "Stop":
            session.state = .done
            if let start = session.turnStartedAt {
                session.detail = "Finished in " + Self.formatDuration(Date().timeIntervalSince(start))
            } else {
                session.detail = "Finished"
            }
            session.turnStartedAt = nil
            alert(for: session, finished: true)

        case "SessionEnd":
            byID[id] = nil
            return

        default:
            break
        }
        byID[id] = session
    }

    private func alert(for session: AgentSession, finished: Bool) {
        guard AppSettings.shared.showAgents else { return }
        if AppSettings.shared.quietWhenFocused && AlertCenter.isFrontmost(bundleID: session.appBundleID) { return }
        if finished {
            AlertCenter.shared.post(NotchAlert(
                icon: "checkmark.circle.fill", tint: .green,
                title: "\(session.project): Claude finished",
                subtitle: session.lastPrompt ?? session.detail
            ))
        } else {
            AlertCenter.shared.post(NotchAlert(
                icon: "exclamationmark.bubble.fill", tint: .orange,
                title: "\(session.project) needs you",
                subtitle: session.detail
            ))
        }
    }

    func activate(_ session: AgentSession) {
        AlertCenter.activate(bundleID: session.appBundleID)
    }

    func dismiss(_ session: AgentSession) {
        byID[session.id] = nil
    }

    // MARK: - Housekeeping

    private func sweep() {
        let now = Date()
        for (id, s) in byID {
            let age = now.timeIntervalSince(s.updatedAt)
            if (s.state == .done || s.state == .idle) && age > 2 * 3600 {
                byID[id] = nil
            } else if s.state == .working && age > 15 * 60 {
                // No events for a long time: Claude was probably interrupted (Esc/Ctrl-C skips Stop).
                byID[id]?.state = .idle
                byID[id]?.detail = "No activity"
            }
        }
    }

    private func publish() {
        sessions = byID.values.sorted {
            $0.state != $1.state ? $0.state < $1.state : $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: - Formatting

    static func describeTool(_ name: String, _ input: [String: Any]?) -> String {
        func file(_ key: String = "file_path") -> String {
            ((input?[key] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
        }
        switch name {
        case "Bash": return "Running " + oneLine(input?["command"] as? String ?? "a command", max: 60)
        case "Read": return "Reading \(file())"
        case "Edit", "MultiEdit": return "Editing \(file())"
        case "Write": return "Writing \(file())"
        case "NotebookEdit": return "Editing \(file("notebook_path"))"
        case "Grep": return "Searching for " + oneLine(input?["pattern"] as? String ?? "", max: 40)
        case "Glob": return "Finding " + oneLine(input?["pattern"] as? String ?? "files", max: 40)
        case "WebFetch":
            let host = (input?["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a page"
            return "Fetching \(host)"
        case "WebSearch": return "Searching the web"
        case "Task", "Agent": return "Running a subagent"
        case "TodoWrite": return "Updating its plan"
        default:
            if name.hasPrefix("mcp__") {
                return "Using " + (name.split(separator: "_").last.map(String.init) ?? name)
            }
            return name.isEmpty ? "Working" : "Using \(name)"
        }
    }

    static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
