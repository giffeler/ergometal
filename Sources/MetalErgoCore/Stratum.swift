import Foundation
import Network

public struct ErgoStratumJob: Sendable {
    public let generation: UInt64
    public let id: String
    public let height: Int
    public let message: [UInt8]
    public let version: Int
    public let target: UInt256
    public let cleanJobs: Bool
    public let extraNoncePrefix: [UInt8]
    public let extraNonce2Size: Int
    public let receivedAt: Date
}

public enum StratumEvent: Sendable {
    case connected
    case authorized
    case disconnected(String)
    case difficulty(Double)
    case job(ErgoStratumJob)
    case shareResult(id: Int, accepted: Bool, message: String?)
    case protocolError(String)
}

public enum StratumError: Error, LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case invalidJob(String)
    case notReady

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "Invalid Stratum URL: \(value)"
        case .unsupportedScheme(let value): return "Unsupported Stratum URL scheme: \(value)"
        case .invalidJob(let value): return "Invalid Ergo Stratum job: \(value)"
        case .notReady: return "Stratum client has not received subscription data and a job"
        }
    }
}

/// Miningcore-compatible Ergo Stratum v1 client. It deliberately exposes events
/// rather than owning the solver so stale-work policy stays in the orchestrator.
public final class ErgoStratumClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (StratumEvent) -> Void

    private let queue = DispatchQueue(label: "dev.ergometal.stratum")
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let user: String
    private let password: String
    private let handler: EventHandler
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextID = 10
    private var generation: UInt64 = 0
    private var extraNoncePrefix: [UInt8] = []
    private var extraNonce2Size = 0
    private var pendingShareIDs = Set<Int>()

    public let redactedHost: String

    public init(url value: String, user: String, password: String = "x", handler: @escaping EventHandler) throws {
        guard let url = URL(string: value), let host = url.host, let portValue = url.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else { throw StratumError.invalidURL(value) }
        switch url.scheme?.lowercased() {
        case "stratum+tcp": parameters = .tcp
        case "stratum+tls", "stratum+ssl": parameters = NWParameters(tls: .init(), tcp: .init())
        default: throw StratumError.unsupportedScheme(url.scheme ?? "")
        }
        endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        redactedHost = "\(host):\(portValue)"
        self.user = user
        self.password = password
        self.handler = handler
    }

    public func connect() {
        queue.async {
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            let connection = NWConnection(to: self.endpoint, using: self.parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            connection.start(queue: self.queue)
            self.receive()
        }
    }

    public func disconnect() {
        queue.async {
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    @discardableResult
    public func submit(job: ErgoStratumJob, nonce: UInt64) throws -> Int {
        guard job.generation == generation else { throw StratumError.notReady }
        let nonceBytes = stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: nonce >> UInt64($0)) }
        guard nonceBytes.starts(with: job.extraNoncePrefix) else { throw StratumError.notReady }
        return queue.sync {
            let id = nextID; nextID += 1; pendingShareIDs.insert(id)
            send(id: id, method: "mining.submit", params: [user, job.id,
                Array(nonceBytes.dropFirst(job.extraNoncePrefix.count)).hex, "undefined", nonceBytes.hex])
            return id
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            handler(.connected)
            send(id: 1, method: "mining.subscribe", params: ["ergometal/0.1.0"])
        case .failed(let error): handler(.disconnected(error.localizedDescription))
        case .cancelled: handler(.disconnected("cancelled"))
        default: break
        }
    }

    private func send(id: Int, method: String, params: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else { return }
        var line = data; line.append(0x0a)
        connection?.send(content: line, completion: .contentProcessed { [weak self] error in
            if let error { self?.handler(.disconnected(error.localizedDescription)) }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drainLines() }
            if let error { self.handler(.disconnected(error.localizedDescription)); return }
            if complete { self.handler(.disconnected("remote closed connection")); return }
            self.receive()
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let object = try JSONSerialization.jsonObject(with: line)
                guard let message = object as? [String: Any] else { throw StratumError.invalidJob("message is not an object") }
                try process(message)
            } catch { handler(.protocolError(error.localizedDescription)) }
        }
    }

    private func process(_ message: [String: Any]) throws {
        if let method = message["method"] as? String {
            let params = message["params"] as? [Any] ?? []
            switch method {
            case "mining.set_difficulty":
                if let value = params.first as? NSNumber { handler(.difficulty(value.doubleValue)) }
            case "mining.notify": try processJob(params)
            default: break
            }
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue else { return }
        if id == 1 {
            let parsed = try Self.decodeSubscription(message["result"])
            extraNoncePrefix = parsed.prefix; extraNonce2Size = parsed.extraNonce2Size
            send(id: 2, method: "mining.authorize", params: [user, password])
        } else if id == 2 {
            let accepted = (message["result"] as? Bool) ?? false
            if accepted { handler(.authorized) }
            else { handler(.protocolError("pool authorization rejected")) }
        } else if pendingShareIDs.remove(id) != nil {
            let accepted = (message["result"] as? Bool) ?? false
            let errorArray = message["error"] as? [Any]
            handler(.shareResult(id: id, accepted: accepted, message: errorArray?.dropFirst().first as? String))
        }
    }

    private func processJob(_ params: [Any]) throws {
        generation &+= 1
        let job = try Self.decodeJob(params, generation: generation,
            extraNoncePrefix: extraNoncePrefix, extraNonce2Size: extraNonce2Size)
        handler(.job(job))
    }

    static func decodeSubscription(_ raw: Any?) throws -> (prefix: [UInt8], extraNonce2Size: Int) {
        guard let result = raw as? [Any], result.count >= 3,
              let prefix = result[result.count - 2] as? String,
              let bytes = [UInt8](hex: prefix), let size = (result.last as? NSNumber)?.intValue,
              bytes.count + size == 8
        else { throw StratumError.invalidJob("subscribe response lacks an 8-byte extranonce layout") }
        return (bytes, size)
    }

    static func decodeJob(_ params: [Any], generation: UInt64,
                          extraNoncePrefix: [UInt8], extraNonce2Size: Int) throws -> ErgoStratumJob {
        guard params.count >= 9, let id = params[0] as? String,
              let height = (params[1] as? NSNumber)?.intValue,
              let messageHex = params[2] as? String, let work = [UInt8](hex: messageHex), work.count == 32,
              let version = (params[5] as? NSNumber)?.intValue,
              let targetString = params[6] as? String, let target = UInt256(encoded: targetString)
        else { throw StratumError.invalidJob("notify parameter layout is unsupported") }
        return ErgoStratumJob(generation: generation, id: id, height: height, message: work,
            version: version, target: target, cleanJobs: (params[8] as? Bool) ?? false,
            extraNoncePrefix: extraNoncePrefix, extraNonce2Size: extraNonce2Size, receivedAt: Date())
    }
}
