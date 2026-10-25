import Foundation
import Network

/// Tiny HTTP listener for privacy tests: each accepted connection counts as one hit.
final class LocalHitServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "memopila.hit-server")
    private let lock = NSLock()
    private var _hits = 0
    private var _port: Int = 0

    var hits: Int {
        lock.lock()
        defer { lock.unlock() }
        return _hits
    }

    var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return _port
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    static func start() async throws -> LocalHitServer {
        let server = try LocalHitServer()
        for _ in 0..<100 {
            if server.port > 0 { return server }
            try await Task.sleep(for: .milliseconds(20))
        }
        server.stop()
        throw URLError(.timedOut)
    }

    private init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = self.listener.port else { return }
            self.lock.lock()
            self._port = Int(port.rawValue)
            self.lock.unlock()
        }
        listener.start(queue: queue)
    }

    func resetHits() {
        lock.lock()
        _hits = 0
        lock.unlock()
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] _, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            self.lock.lock()
            self._hits += 1
            self.lock.unlock()
            let response = Data("HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
