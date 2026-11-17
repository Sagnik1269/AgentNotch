import Foundation

/// Runs the NowPlayingBridge inside /usr/bin/perl and exchanges JSON lines with it.
/// See Helpers/NowPlayingBridge for why it runs inside perl.
@MainActor
final class NowPlayingService {
    struct Update {
        var pid: Int32
        var playing: Bool
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var timestamp: Double?
        var hasArtwork: Bool
        var artworkData: Data?
    }

    var onUpdate: ((Update) -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 1
    private var stopped = true

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
    }

    func send(_ command: String) {
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        try? handle.write(contentsOf: Data((command + "\n").utf8))
    }

    private func launch() {
        guard let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("nowplaying.pl")
        let dylib = resources.appendingPathComponent("NowPlayingBridge.dylib")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: dylib.path) else {
            NSLog("AgentNotch: now-playing bridge missing from bundle")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [script.path, dylib.path]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleExit() }
            }
        }

        do {
            try proc.run()
            process = proc
            stdinPipe = input
            buffer.removeAll()
        } catch {
            NSLog("AgentNotch: failed to launch now-playing bridge: \(error)")
            handleExit()
        }
    }

    private func handleExit() {
        process = nil
        stdinPipe = nil
        guard !stopped else { return }
        // Restart with backoff if the bridge dies.
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.process == nil else { return }
                self.launch()
            }
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let update = Self.parse(line) {
                restartDelay = 1
                onUpdate?(update)
            }
        }
    }

    private static func parse(_ line: Data) -> Update? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        func double(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
        func string(_ key: String) -> String? {
            guard let s = obj[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        return Update(
            pid: (obj["pid"] as? NSNumber)?.int32Value ?? 0,
            playing: (obj["playing"] as? NSNumber)?.boolValue ?? false,
            title: string("title"),
            artist: string("artist"),
            album: string("album"),
            duration: double("duration"),
            elapsed: double("elapsed"),
            rate: double("rate"),
            timestamp: double("timestamp"),
            hasArtwork: (obj["hasArtwork"] as? NSNumber)?.boolValue ?? false,
            artworkData: (obj["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        )
    }
}
