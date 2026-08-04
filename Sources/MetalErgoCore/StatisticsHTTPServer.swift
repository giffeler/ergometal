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

    public init(store: StatisticsStore) { self.store = store }

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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            let line = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
            let method = line.count > 0 ? String(line[0]) : ""
            let path = line.count > 1 ? String(line[1]) : ""
            let response = self.response(method: method, path: path)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
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
