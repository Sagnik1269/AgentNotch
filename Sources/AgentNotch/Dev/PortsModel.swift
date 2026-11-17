import AppKit

struct ListeningPort: Identifiable, Hashable {
    var id: String { "\(pid):\(port)" }
    var port: Int
    var pid: Int32
    var process: String
    var isDevServer: Bool
}

/// TCP ports your processes are listening on, refreshed only while the Ports list is visible.
@MainActor
final class PortsModel: ObservableObject {
    static let shared = PortsModel()

    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var hasLoaded = false

    private var timer: Timer?
    private var visibleCount = 0

    /// Call from onAppear / onDisappear of any view that shows ports.
    func setVisible(_ visible: Bool) {
        visibleCount = max(visibleCount + (visible ? 1 : -1), 0)
        if visibleCount > 0, timer == nil {
            refresh()
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if visibleCount == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        Task {
            let result = await ProcessRunner.run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 5)
            ports = Self.parse(result.stdout)
            hasLoaded = true
        }
    }

    func open(_ port: ListeningPort) {
        if let url = URL(string: "http://localhost:\(port.port)") { NSWorkspace.shared.open(url) }
    }

    /// Sends SIGTERM (a polite quit, like Ctrl-C), then refreshes.
    func terminate(_ port: ListeningPort) {
        kill(port.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Parsing `lsof -F pcn`

    private static let systemProcesses: Set<String> = [
        "rapportd", "ControlCenter", "sharingd", "identityservicesd", "AirPlayXPCHelper", "remoted",
        "WiFiAgent", "Spotify", "Dropbox", "AgentNotch", "launchd", "mDNSResponder", "UserEventAgent",
        "ARDAgent", "screensharingd", "Raycast", "Figma Agent", "figma_agent", "Adobe Desktop Service",
        "Creative Cloud", "Logi Options+", "OneDrive", "Google Drive", "Microsoft Teams",
    ]

    private static let devMarkers = [
        "node", "python", "ruby", "java", "deno", "bun", "php", "go", "rails", "puma", "vite", "next",
        "docker", "com.docker", "postgres", "redis", "mongod", "mysqld", "nginx", "caddy", "uvicorn",
        "gunicorn", "flask", "dotnet", "beam", "elixir", "cargo", "swift", "hugo", "jekyll", "ollama",
        "esbuild", "webpack", "jupyter", "streamlit", "kubectl", "ssh", "air", "wrangler", "supabase",
    ]

    static func parse(_ output: String) -> [ListeningPort] {
        var results: [String: ListeningPort] = [:]
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]),
                      port >= 1024, !systemProcesses.contains(command) else { continue }
                let lower = command.lowercased()
                let isDev = devMarkers.contains { lower == $0 || lower.hasPrefix($0) }
                let entry = ListeningPort(port: port, pid: pid, process: command, isDevServer: isDev)
                results[entry.id] = entry // IPv4 and IPv6 listeners collapse into one row
            default: continue
            }
        }
        return results.values.sorted {
            $0.isDevServer != $1.isDevServer ? $0.isDevServer : $0.port < $1.port
        }
    }
}
