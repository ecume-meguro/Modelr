import Foundation
import Network

/// Minimal in-process HTTP/1.1 server on loopback for DownloadManager tests.
/// Serves registered payloads with Range support, and can misbehave on demand:
/// truncate a body mid-flight (connection kill), ignore Range (200 restart),
/// or drip the body in delayed chunks (pause windows).
final class TestHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-http-server")
    private let lock = NSLock()

    private var files: [String: Data] = [:]
    /// path → serve only this many body bytes, then kill the connection.
    private var truncations: [String: Int] = [:]
    /// Respond 200 + full body even when the client sends Range.
    var ignoreRange = false
    /// Split the body in two sends with this delay between them.
    var chunkDelay: TimeInterval = 0

    struct Request: Equatable {
        let path: String
        let rangeStart: Int64?
    }
    private var requestLog: [Request] = []

    let port: UInt16

    /// Indirection so the connection handler can be installed BEFORE start()
    /// (required by NWListener) while still binding to self after init.
    private final class HandlerBox: @unchecked Sendable {
        var handle: ((NWConnection) -> Void)?
    }
    private let handlerBox = HandlerBox()

    init() throws {
        listener = try NWListener(using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        let box = handlerBox
        listener.newConnectionHandler = { connection in
            box.handle?(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let p = listener.port?.rawValue else {
            throw NSError(domain: "TestHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        port = p
        handlerBox.handle = { [weak self] connection in
            self?.handle(connection)
        }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: configuration

    func serve(_ path: String, _ data: Data) {
        lock.lock(); files[path] = data; lock.unlock()
    }

    func truncate(_ path: String, afterBodyBytes n: Int) {
        lock.lock(); truncations[path] = n; lock.unlock()
    }

    func clearTruncation(_ path: String) {
        lock.lock(); truncations[path] = nil; lock.unlock()
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return requestLog
    }

    func url(for path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    // MARK: connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(connection, head: head)
            } else {
                self.receiveRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.split(separator: "\r\n").map(String.init)
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        var path = String(parts[1])
        if path.hasPrefix("/") { path.removeFirst() }
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path

        var rangeStart: Int64?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("range:"), let eq = line.firstIndex(of: "=") {
                let spec = line[line.index(after: eq)...]
                if let dash = spec.firstIndex(of: "-"), let start = Int64(spec[..<dash]) {
                    rangeStart = start
                }
            }
        }

        let (payload, truncateAt, honorRange): (Data?, Int?, Bool) = {
            lock.lock(); defer { lock.unlock() }
            requestLog.append(Request(path: path, rangeStart: rangeStart))
            return (files[path], truncations[path], !ignoreRange)
        }()

        guard let full = payload else {
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        var status = "200 OK"
        var body = full
        var extraHeaders = ""
        if let start = rangeStart, honorRange, start > 0, start < Int64(full.count) {
            status = "206 Partial Content"
            body = full.subdata(in: Int(start)..<full.count)
            extraHeaders = "Content-Range: bytes \(start)-\(full.count - 1)/\(full.count)\r\n"
        }

        let header = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n\(extraHeaders)Connection: close\r\n\r\n"

        if let cut = truncateAt, cut < body.count {
            // Send headers + a body prefix, then close (FIN) after a beat so the
            // client demonstrably consumes the prefix before seeing the loss —
            // an immediate close can make CFNetwork drop still-buffered body
            // bytes along with the error, leaving nothing on disk.
            let partial = Data(header.utf8) + body.prefix(cut)
            connection.send(content: partial, completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + 0.4) {
                    connection.cancel()
                }
            })
            return
        }

        if chunkDelay > 0, body.count > 1 {
            let mid = body.count / 2
            let first = Data(header.utf8) + body.prefix(mid)
            let second = body.suffix(from: mid)
            let delay = chunkDelay
            connection.send(content: first, completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + delay) {
                    connection.send(content: second, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            })
            return
        }

        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
