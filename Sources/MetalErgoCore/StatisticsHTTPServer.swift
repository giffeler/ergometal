import Foundation
import Network
import Synchronization

public enum HTTPServerError: Error, LocalizedError {
    case nonLoopback(String)
    case invalidBind(String)
    case listener(String)

    public var errorDescription: String? {
        switch self {
        case .nonLoopback(let host): return "Statistics API may only bind to loopback, not \(host)"
        case .invalidBind(let value): return "Invalid API bind address: \(value)"
        case .listener(let value): return "Statistics listener failed: \(value)"
        }
    }
}

public final class StatisticsHTTPServer: Sendable {
    private let store: StatisticsStore
    private let listener = Mutex<NWListener?>(nil)
    private let queue = DispatchQueue(label: "dev.ergometal.http")
    private let requestTimeout: TimeInterval
    private static let maximumHeaderBytes = 8192

    public convenience init(store: StatisticsStore) {
        self.init(store: store, requestTimeout: 5)
    }

    init(store: StatisticsStore, requestTimeout: TimeInterval) {
        self.store = store
        self.requestTimeout = requestTimeout
    }

    var listeningPort: UInt16? {
        listener.withLock {
            guard let port = $0?.port?.rawValue, port != 0 else { return nil }
            return port
        }
    }

    public func start(bind: String) throws {
        let pieces = bind.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let port = NWEndpoint.Port(pieces[1]) else {
            throw HTTPServerError.invalidBind(bind)
        }
        guard pieces[0] == "127.0.0.1" || pieces[0] == "localhost" else {
            throw HTTPServerError.nonLoopback(pieces[0])
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(pieces[0]), port: port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("ergometal statistics listener: \(error)\n", stderr)
            }
        }
        listener.start(queue: queue)
        self.listener.withLock { $0 = listener }
    }

    public func stop() {
        listener.withLock { listener in
            listener?.cancel()
            listener = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + requestTimeout)
        timeout.setEventHandler {
            connection.cancel()
        }
        timeout.resume()
        receiveHeader(connection, buffer: Data(), timeout: timeout)
    }

    private func receiveHeader(
        _ connection: NWConnection, buffer: Data, timeout: DispatchSourceTimer
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumHeaderBytes) {
            [weak self] data, _, complete, error in
            guard let self else {
                timeout.cancel(); connection.cancel(); return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            let end = buffer.range(of: Data("\r\n\r\n".utf8))?.upperBound
            if let end, end <= Self.maximumHeaderBytes,
               let request = String(data: buffer[..<end], encoding: .utf8) {
                let line = request.components(separatedBy: "\r\n")[0]
                    .split(separator: " ", omittingEmptySubsequences: false)
                let response: Data
                if line.count == 3, !line[0].isEmpty, line[1].hasPrefix("/"),
                   line[2] == "HTTP/1.0" || line[2] == "HTTP/1.1" {
                    response = self.response(method: String(line[0]), path: String(line[1]))
                } else {
                    response = self.http(status: "400 Bad Request", type: "text/plain",
                        body: Data("invalid request line\n".utf8))
                }
                connection.send(content: response, completion: .contentProcessed { _ in
                    timeout.cancel(); connection.cancel()
                })
            } else if buffer.count >= Self.maximumHeaderBytes {
                let response = self.http(status: "431 Request Header Fields Too Large",
                    type: "text/plain", body: Data("request header too large\n".utf8))
                connection.send(content: response, completion: .contentProcessed { _ in
                    timeout.cancel(); connection.cancel()
                })
            } else if complete || error != nil || end != nil {
                timeout.cancel(); connection.cancel()
            } else {
                self.receiveHeader(connection, buffer: buffer, timeout: timeout)
            }
        }
    }

    private func response(method: String, path: String) -> Data {
        guard method == "GET" else { return http(status: "405 Method Not Allowed", type: "text/plain", body: Data("GET only\n".utf8)) }
        switch path {
        case "/v1/status":
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let data = (try? encoder.encode(store.snapshot())) ?? Data("{}".utf8)
            return http(status: "200 OK", type: "application/json", body: data)
        case "/v1/devices":
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return http(status: "200 OK", type: "application/json", body: (try? encoder.encode(MetalAutolykosSolver.devices())) ?? Data("[]".utf8))
        case "/metrics":
            return http(status: "200 OK", type: "text/plain; version=0.0.4", body: Data(store.prometheus().utf8))
        case "/healthz":
            let state = store.snapshot().state
            let healthy = state != .failed
            return http(status: healthy ? "200 OK" : "503 Service Unavailable", type: "application/json",
                        body: Data("{\"ok\":\(healthy),\"state\":\"\(state.rawValue)\"}\n".utf8))
        default:
            return http(status: "404 Not Found", type: "text/plain", body: Data("not found\n".utf8))
        }
    }

    private func http(status: String, type: String, body: Data) -> Data {
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}
