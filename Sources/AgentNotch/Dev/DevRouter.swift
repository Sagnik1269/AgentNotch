import Foundation

/// Routes local event-server requests to the dev models.
///
///   POST /v1/claude   Claude Code hook JSON (forwarded as-is by agentnotch-claude-hook)
///   POST /v1/command  {"command","exit","duration","cwd"} from the zsh integration
///   POST /v1/notify   {"title","subtitle"?,"icon"? (SF Symbol),"tint"? (green|red|orange|blue|white)}
///   GET  /v1/health
///   GET  /v1/status   JSON snapshot of sessions, recent commands, CI and the current alert
@MainActor
enum DevRouter {
    static func handle(_ request: EventServer.Request) -> EventServer.Response {
        let bundleID = AlertCenter.bundleID(bundleHeader: request.headers["x-bundle-id"],
                                            termProgram: request.headers["x-term-program"])
        switch (request.method, request.path) {
        case ("GET", "/v1/health"):
            return .init(body: "ok")

        case ("GET", "/v1/status"):
            return .init(body: statusJSON())

        case ("POST", "/v1/claude"):
            guard let json = object(request.body) else { return .init(status: 400, body: "expected JSON object") }
            AgentsModel.shared.handle(json, bundleID: bundleID)
            return .init()

        case ("POST", "/v1/command"):
            guard let json = object(request.body) else { return .init(status: 400, body: "expected JSON object") }
            CommandsModel.shared.handle(json, bundleID: bundleID)
            return .init()

        case ("POST", "/v1/notify"):
            guard let json = object(request.body), let title = json["title"] as? String, !title.isEmpty else {
                return .init(status: 400, body: "expected {\"title\": \"…\"}")
            }
            let tint: NotchAlert.Tint = switch json["tint"] as? String {
            case "green": .green
            case "red": .red
            case "orange": .orange
            case "blue": .blue
            default: .white
            }
            AlertCenter.shared.post(NotchAlert(
                icon: json["icon"] as? String ?? "bell.fill",
                tint: tint,
                title: String(title.prefix(80)),
                subtitle: String((json["subtitle"] as? String ?? "").prefix(120))
            ))
            return .init()

        default:
            return .init(status: 404, body: "not found")
        }
    }

    /// Read-only snapshot of what the notch currently knows, for scripts and debugging.
    private static func statusJSON() -> String {
        let stateNames: [AgentSession.State: String] = [.waiting: "waiting", .working: "working", .done: "done", .idle: "idle"]
        let payload: [String: Any] = [
            "sessions": AgentsModel.shared.sessions.map {
                ["project": $0.project, "state": stateNames[$0.state] ?? "", "detail": $0.detail]
            },
            "commands": CommandsModel.shared.recent.prefix(5).map {
                ["command": $0.command, "exit": $0.exitCode, "duration": $0.duration]
            },
            "ci": CIModel.shared.runs.map {
                ["repo": $0.repoName, "branch": $0.branch, "status": $0.status, "conclusion": $0.conclusion]
            },
            "alert": AlertCenter.shared.current.map { ["title": $0.title, "subtitle": $0.subtitle] } ?? NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
