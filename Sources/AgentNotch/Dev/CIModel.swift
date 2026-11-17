import AppKit

struct CIRun: Identifiable, Equatable {
    var id: Int
    var repoPath: String
    var branch: String
    var workflow: String
    var title: String
    var status: String       // queued | in_progress | completed | waiting | requested | pending
    var conclusion: String   // success | failure | cancelled | skipped | … (empty while running)
    var url: String
    var updatedAt: Date?

    var repoName: String { (repoPath as NSString).lastPathComponent }
    var isRunning: Bool { status != "completed" }
    var succeeded: Bool { conclusion == "success" }
}

/// GitHub Actions status for the branches you're working on, via the GitHub CLI (`gh`).
/// Repos are discovered from the directories of Claude sessions and shell commands.
@MainActor
final class CIModel: ObservableObject {
    static let shared = CIModel()

    enum GHStatus: Equatable { case unknown, missing, loggedOut, ready }

    @Published private(set) var runs: [CIRun] = []
    @Published private(set) var ghStatus: GHStatus = .unknown

    private struct Repo {
        var path: String
        var branch: String
        var lastFetch: Date = .distantPast
        var lastUsed: Date = Date()
        var unsupportedUntil: Date?
    }

    private var repos: [String: Repo] = [:]
    private var latest: [String: CIRun] = [:] { didSet { publish() } }
    private var resolving: Set<String> = []
    private var timer: Timer?
    private var ghPath: String?

    private static let maxRepos = 4

    func start() {
        ghPath = ProcessRunner.find("gh")
        Task { await checkGH() }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func checkGH() async {
        guard let gh = ghPath ?? ProcessRunner.find("gh") else { ghStatus = .missing; return }
        ghPath = gh
        let result = await ProcessRunner.run(gh, ["auth", "status"], timeout: 10)
        ghStatus = result.ok ? .ready : .loggedOut
    }

    /// Called with any working directory we hear about; resolves it to a git repo and branch.
    func track(directory: String) {
        guard !resolving.contains(directory) else { return }
        resolving.insert(directory)
        Task {
            defer { resolving.remove(directory) }
            guard let git = ProcessRunner.find("git") else { return }
            let top = await ProcessRunner.run(git, ["-C", directory, "rev-parse", "--show-toplevel"], timeout: 5)
            guard top.ok else { return }
            let path = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let head = await ProcessRunner.run(git, ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 5)
            let branch = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.ok, !branch.isEmpty, branch != "HEAD" else { return }

            if var repo = repos[path] {
                if repo.branch != branch {
                    repo.branch = branch
                    repo.lastFetch = .distantPast
                    latest[path] = nil
                }
                repo.lastUsed = Date()
                repos[path] = repo
            } else {
                repos[path] = Repo(path: path, branch: branch)
                if repos.count > Self.maxRepos,
                   let oldest = repos.values.min(by: { $0.lastUsed < $1.lastUsed }) {
                    repos[oldest.path] = nil
                    latest[oldest.path] = nil
                }
                tick()
            }
        }
    }

    func open(_ run: CIRun) {
        if let url = URL(string: run.url) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Polling

    private func tick() {
        guard ghStatus == .ready, let gh = ghPath else { return }
        let now = Date()
        for (path, repo) in repos {
            if let until = repo.unsupportedUntil, until > now { continue }
            let running = latest[path]?.isRunning ?? false
            let interval: TimeInterval = running ? 20 : 120
            guard now.timeIntervalSince(repo.lastFetch) >= interval else { continue }
            repos[path]?.lastFetch = now
            Task { await fetch(path: path, branch: repo.branch, gh: gh) }
        }
    }

    private func fetch(path: String, branch: String, gh: String) async {
        let fields = "databaseId,status,conclusion,workflowName,displayTitle,url,headBranch,updatedAt"
        let result = await ProcessRunner.run(gh, ["run", "list", "--branch", branch, "--limit", "1", "--json", fields],
                                             in: path, timeout: 20)
        guard result.ok else {
            // Not a GitHub repo, no Actions, or offline: back off for a while.
            repos[path]?.unsupportedUntil = Date().addingTimeInterval(600)
            return
        }
        guard let data = result.stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let item = array.first else {
            latest[path] = nil
            return
        }
        let run = CIRun(
            id: (item["databaseId"] as? NSNumber)?.intValue ?? 0,
            repoPath: path,
            branch: item["headBranch"] as? String ?? branch,
            workflow: item["workflowName"] as? String ?? "",
            title: item["displayTitle"] as? String ?? "",
            status: item["status"] as? String ?? "",
            conclusion: item["conclusion"] as? String ?? "",
            url: item["url"] as? String ?? "",
            updatedAt: (item["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        )
        let previous = latest[path]
        latest[path] = run

        // Announce a run that we watched go from running to finished.
        if let previous, previous.id == run.id, previous.isRunning, !run.isRunning {
            AlertCenter.shared.post(NotchAlert(
                icon: run.succeeded ? "checkmark.seal.fill" : "xmark.seal.fill",
                tint: run.succeeded ? .green : .red,
                title: "\(run.repoName) · \(run.workflow) \(run.succeeded ? "passed" : run.conclusion)",
                subtitle: "\(run.branch): \(run.title)"
            ))
        }
    }

    private func publish() {
        runs = latest.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }
}
