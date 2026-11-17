import Darwin
import Foundation

/// Minimal HTTP/1.1 server on a Unix domain socket, for local integrations (Claude Code hooks,
/// shell hooks, your own scripts). The socket is created with 0600 permissions inside a 0700
/// directory, so only your user account can connect. No TCP port is opened.
///
///     curl --unix-socket "$HOME/Library/Application Support/AgentNotch/agentnotch.sock" \
///          -d '{"title":"Hello"}' http://localhost/v1/notify
final class EventServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String] // lowercased keys
        let body: Data
    }

    struct Response {
        var status: Int = 200
        var body: String = "ok"
    }

    typealias Handler = @MainActor (Request) -> Response

    let socketPath: String
    var handler: Handler?

    private let queue = DispatchQueue(label: "dev.agentnotch.events")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private static let maxBodyBytes = 8 * 1024 * 1024

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit { stop() }

    func start() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let e = errno; close(fd); throw POSIXError(.init(rawValue: e) ?? .EIO) }
        chmod(socketPath, 0o600)
        guard listen(fd, 32) == 0 else { let e = errno; close(fd); throw POSIXError(.init(rawValue: e) ?? .EIO) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(socketPath)
    }

    // MARK: - Connections (on `queue`)

    private func acceptConnections() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return } // EAGAIN: no more pending
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            Connection(fd: client, server: self).start()
        }
    }

    fileprivate func respond(to request: Request, completion: @escaping @Sendable (Response) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                let response = self?.handler?(request) ?? Response(status: 503, body: "not ready")
                completion(response)
            }
        }
    }

    fileprivate var connectionQueue: DispatchQueue { queue }

    /// One request per connection (Connection: close), which is all curl hooks need.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        weak var server: EventServer?
        private var buffer = Data()
        private var source: DispatchSourceRead?
        private var done = false
        private var sentContinue = false

        init(fd: Int32, server: EventServer) {
            self.fd = fd
            self.server = server
        }

        func start() {
            guard let queue = server?.connectionQueue else { close(fd); return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in self.readAvailable() }
            source.setCancelHandler { [fd] in close(fd) }
            self.source = source
            source.resume()
            // Don't let a stalled client hold a descriptor forever.
            queue.asyncAfter(deadline: .now() + 5) { [self] in self.finish() }
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n > 0 {
                    buffer.append(contentsOf: chunk[0..<n])
                    if buffer.count > EventServer.maxBodyBytes + 64 * 1024 {
                        write(status: 413, body: "too large"); return
                    }
                } else if n == 0 {
                    break // peer closed its write side
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    finish(); return
                }
            }
            tryParse()
        }

        private func tryParse() {
            guard !done, let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            var lines = headerText.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { write(status: 400, body: "bad request"); return }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }

            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length <= EventServer.maxBodyBytes else { write(status: 413, body: "too large"); return }

            let bodyStart = headerEnd.upperBound
            if buffer.count - bodyStart < length {
                if headers["expect"]?.lowercased() == "100-continue", !sentContinue {
                    sentContinue = true
                    sendRaw(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                }
                return // wait for the rest of the body
            }

            let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
            var path = String(requestLine[1])
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            let request = Request(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body)

            done = true
            source?.suspend()
            server?.respond(to: request) { [self] response in
                self.server?.connectionQueue.async { [self] in
                    self.source?.resume()
                    self.write(status: response.status, body: response.body)
                }
            }
        }

        private func write(status: Int, body: String) {
            done = true
            let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large",
                          503: "Service Unavailable"][status] ?? "Error"
            let bodyData = Data(body.utf8)
            var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(bodyData)
            sendRaw(response)
            finish()
        }

        private func sendRaw(_ data: Data) {
            data.withUnsafeBytes { raw in
                var offset = 0
                var attempts = 0
                while offset < raw.count && attempts < 1000 {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n } else if errno == EAGAIN { attempts += 1; usleep(1000) } else { break }
                }
            }
        }

        private func finish() {
            guard let source else { return }
            self.source = nil
            source.cancel()
        }
    }
}
