import Foundation

/// Runs a command-line tool off the main thread and collects its output.
enum ProcessRunner {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var ok: Bool { status == 0 }
    }

    /// GUI apps don't inherit your shell's PATH, so include the usual tool locations.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func find(_ tool: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func run(_ executable: String, _ arguments: [String], in directory: String? = nil,
                    timeout: TimeInterval = 20) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPath
                env["GH_PROMPT_DISABLED"] = "1"
                env["NO_COLOR"] = "1"
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice

                do { try process.run() } catch {
                    continuation.resume(returning: Result(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self)
                ))
            }
        }
    }
}
