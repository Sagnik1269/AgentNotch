import Foundation

struct CommandRun: Identifiable, Equatable {
    let id = UUID()
    var command: String
    var exitCode: Int
    var duration: Double
    var cwd: String
    var finishedAt: Date
    var appBundleID: String?

    var succeeded: Bool { exitCode == 0 }
    var folder: String { (cwd as NSString).lastPathComponent }
}

/// Long-running shell commands reported by the zsh integration.
@MainActor
final class CommandsModel: ObservableObject {
    static let shared = CommandsModel()

    @Published private(set) var recent: [CommandRun] = []
    @Published private(set) var lastEventAt: Date?

    func handle(_ json: [String: Any], bundleID: String?) {
        guard let command = json["command"] as? String, !command.isEmpty else { return }
        lastEventAt = Date()
        let run = CommandRun(
            command: command,
            exitCode: (json["exit"] as? NSNumber)?.intValue ?? 0,
            duration: (json["duration"] as? NSNumber)?.doubleValue ?? 0,
            cwd: json["cwd"] as? String ?? "",
            finishedAt: Date(),
            appBundleID: bundleID
        )
        if !run.cwd.isEmpty { CIModel.shared.track(directory: run.cwd) }

        let settings = AppSettings.shared
        guard run.duration >= settings.commandAlertThreshold else { return }

        recent.insert(run, at: 0)
        if recent.count > 25 { recent.removeLast(recent.count - 25) }

        if settings.quietWhenFocused && AlertCenter.isFrontmost(bundleID: run.appBundleID) { return }
        let duration = AgentsModel.formatDuration(run.duration)
        AlertCenter.shared.post(NotchAlert(
            icon: run.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill",
            tint: run.succeeded ? .green : .red,
            title: AgentsModel.oneLine(run.command, max: 48),
            subtitle: run.succeeded
                ? "Finished in \(duration) · \(run.folder)"
                : "Failed (exit \(run.exitCode)) after \(duration) · \(run.folder)"
        ))
    }

    func clear() { recent.removeAll() }
}
