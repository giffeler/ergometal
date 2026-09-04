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
    case tooManyPendingShares(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "Invalid Stratum URL: \(value)"
        case .unsupportedScheme(let value): return "Unsupported Stratum URL scheme: \(value)"
        case .invalidJob(let value): return "Invalid Ergo Stratum job: \(value)"
        case .notReady: return "Stratum client has not received subscription data and a job"
        case .tooManyPendingShares(let count):
            return "Stratum client already has \(count) pending share submissions"
        }
    }
}

/// Miningcore-compatible Ergo Stratum v1 client. It deliberately exposes events
/// rather than owning the solver so stale-work policy stays in the orchestrator.
public final class ErgoStratumClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (StratumEvent) -> Void

    static let keepaliveIdleSeconds = 30
    static let keepaliveIntervalSeconds = 10
    static let keepaliveProbeCount = 3

    private let queue = DispatchQueue(label: "dev.ergometal.stratum")
    private let queueKey = DispatchSpecificKey<Void>()
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
    private var ready = false
    private var authorized = false
    private let maximumBufferedBytes = 1_048_576

    public let redactedHost: String

    public init(url value: String, user: String, password: String = "x", handler: @escaping EventHandler) throws {
        guard let url = URL(string: value), let host = url.host, let portValue = url.port,
              let rawPort = UInt16(exactly: portValue), let port = NWEndpoint.Port(rawValue: rawPort)
        else { throw StratumError.invalidURL(value) }
        switch url.scheme?.lowercased() {
        case "stratum+tcp": parameters = Self.connectionParameters(useTLS: false)
        case "stratum+tls", "stratum+ssl": parameters = Self.connectionParameters(useTLS: true)
        default: throw StratumError.unsupportedScheme(url.scheme ?? "")
        }
        endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        redactedHost = "\(host):\(portValue)"
        self.user = user
        self.password = password
        self.handler = handler
        queue.setSpecific(key: queueKey, value: ())
    }

    static func connectionParameters(useTLS: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepaliveIdleSeconds
        tcp.keepaliveInterval = keepaliveIntervalSeconds
        tcp.keepaliveCount = keepaliveProbeCount
        return NWParameters(tls: useTLS ? NWProtocolTLS.Options() : nil, tcp: tcp)
    }

    public func connect() {
        queue.async {
            self.cancelCurrentConnection()
            self.buffer.removeAll(keepingCapacity: true)
            self.extraNoncePrefix = []
            self.extraNonce2Size = 0
            self.authorized = false
            self.pendingShareIDs.removeAll(keepingCapacity: true)
            self.generation &+= 1
            let connection = NWConnection(to: self.endpoint, using: self.parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let connection else { return }
                self?.stateChanged(state, connection: connection)
            }
            connection.start(queue: self.queue)
            self.receive(from: connection)
        }
    }

    public func disconnect() {
        queue.async {
            self.cancelCurrentConnection()
            self.buffer.removeAll(keepingCapacity: true)
            self.authorized = false
            self.pendingShareIDs.removeAll(keepingCapacity: true)
            self.generation &+= 1
        }
    }

    @discardableResult
    public func submit(job: ErgoStratumJob, nonce: UInt64) throws -> Int {
        let nonceBytes = stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: nonce >> UInt64($0)) }
        return try onQueue {
            guard ready, authorized, connection != nil, job.generation == generation,
                  nonceBytes.starts(with: job.extraNoncePrefix)
            else { throw StratumError.notReady }
            guard pendingShareIDs.count < 1_024 else {
                throw StratumError.tooManyPendingShares(pendingShareIDs.count)
            }
            let id = nextID; nextID += 1; pendingShareIDs.insert(id)
            send(id: id, method: "mining.submit", params: [user, job.id,
                Array(nonceBytes.dropFirst(job.extraNoncePrefix.count)).hex, "undefined", nonceBytes.hex])
            return id
        }
    }

    private func stateChanged(_ state: NWConnection.State, connection candidate: NWConnection) {
        guard connection === candidate else { return }
        switch state {
        case .ready:
            ready = true
            handler(.connected)
            send(id: 1, method: "mining.subscribe", params: ["ergometal/0.1.0"])
        case .failed(let error): reportDisconnect(error.localizedDescription, connection: candidate)
        case .cancelled: reportDisconnect("cancelled", connection: candidate)
        default: break
        }
    }

    private func send(id: Int, method: String, params: [Any]) {
        guard ready, let connection else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else { return }
        var line = data; line.append(0x0a)
        connection.send(content: line, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, let error else { return }
            self.queue.async {
                self.reportDisconnect(error.localizedDescription, connection: connection)
            }
        })
    }

    private func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, complete, error in
            guard let connection else { return }
            guard let self else { return }
            guard self.connection === connection else { return }
            if let data {
                self.buffer.append(data)
                guard self.drainLines(connection: connection) else { return }
            }
            if self.buffer.count > self.maximumBufferedBytes {
                let message = "Stratum message exceeds \(self.maximumBufferedBytes) buffered bytes"
                self.handler(.protocolError(message))
                self.reportDisconnect(message, connection: connection)
                return
            }
            if let error {
                self.reportDisconnect(error.localizedDescription, connection: connection)
                return
            }
            if complete {
                self.reportDisconnect("remote closed connection", connection: connection)
                return
            }
            self.receive(from: connection)
        }
    }

    private func drainLines(connection: NWConnection) -> Bool {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= maximumBufferedBytes else {
                let message = "Stratum message exceeds \(maximumBufferedBytes) bytes"
                handler(.protocolError(message))
                reportDisconnect(message, connection: connection)
                return false
            }
            let message: [String: Any]
            do {
                let object = try JSONSerialization.jsonObject(with: line)
                guard let parsed = object as? [String: Any] else {
                    throw StratumError.invalidJob("message is not an object")
                }
                message = parsed
            } catch {
                handler(.protocolError(error.localizedDescription))
                continue
            }
            do {
                try process(message)
            } catch {
                handler(.protocolError(error.localizedDescription))
                let id = message["id"] as? NSNumber
                if id?.intValue == 1 || id?.intValue == 2 {
                    reportDisconnect(error.localizedDescription, connection: connection)
                    return false
                }
            }
        }
        return true
    }

    private func process(_ message: [String: Any]) throws {
        if let method = message["method"] as? String {
            let params = message["params"] as? [Any] ?? []
            switch method {
            case "mining.set_difficulty":
                guard let value = params.first as? NSNumber,
                      value.doubleValue.isFinite, value.doubleValue > 0
                else { throw StratumError.invalidJob("difficulty must be finite and positive") }
                handler(.difficulty(value.doubleValue))
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
            if accepted { authorized = true; handler(.authorized) }
            else { throw StratumError.invalidJob("pool authorization rejected") }
        } else if pendingShareIDs.remove(id) != nil {
            let accepted = (message["result"] as? Bool) ?? false
            let errorArray = message["error"] as? [Any]
            handler(.shareResult(id: id, accepted: accepted, message: errorArray?.dropFirst().first as? String))
        }
    }

    private func processJob(_ params: [Any]) throws {
        let nextGeneration = generation &+ 1
        let job = try Self.decodeJob(params, generation: nextGeneration,
            extraNoncePrefix: extraNoncePrefix, extraNonce2Size: extraNonce2Size)
        generation = nextGeneration
        handler(.job(job))
    }

    static func decodeSubscription(_ raw: Any?) throws -> (prefix: [UInt8], extraNonce2Size: Int) {
        guard let result = raw as? [Any], result.count >= 3,
              let prefix = result[result.count - 2] as? String,
              let bytes = [UInt8](hex: prefix), let size = (result.last as? NSNumber)?.intValue,
              (0...8).contains(size), bytes.count <= 8,
              bytes.count + size == 8
        else { throw StratumError.invalidJob("subscribe response lacks an 8-byte extranonce layout") }
        return (bytes, size)
    }

    static func decodeJob(_ params: [Any], generation: UInt64,
                          extraNoncePrefix: [UInt8], extraNonce2Size: Int) throws -> ErgoStratumJob {
        guard params.count >= 9, let id = params[0] as? String, !id.isEmpty,
              let height = (params[1] as? NSNumber)?.intValue,
              UInt32(exactly: height) != nil,
              let messageHex = params[2] as? String, let work = [UInt8](hex: messageHex), work.count == 32,
              let version = decodeVersion(params[5]),
              version == 2,
              let targetString = params[6] as? String, let target = UInt256(encoded: targetString),
              target != .zero,
              (0...8).contains(extraNonce2Size), extraNoncePrefix.count + extraNonce2Size == 8
        else { throw StratumError.invalidJob("notify parameter layout is unsupported") }
        return ErgoStratumJob(generation: generation, id: id, height: height, message: work,
            version: version, target: target, cleanJobs: (params[8] as? Bool) ?? false,
            extraNoncePrefix: extraNoncePrefix, extraNonce2Size: extraNonce2Size, receivedAt: Date())
    }

    private static func decodeVersion(_ raw: Any) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        guard let string = raw as? String else { return nil }
        if string.count == 8, string.allSatisfy(\.isHexDigit) {
            return Int(string, radix: 16)
        }
        return Int(string)
    }

    private func cancelCurrentConnection() {
        ready = false
        authorized = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func reportDisconnect(_ message: String, connection candidate: NWConnection) {
        guard connection === candidate else { return }
        cancelCurrentConnection()
        buffer.removeAll(keepingCapacity: true)
        pendingShareIDs.removeAll(keepingCapacity: true)
        generation &+= 1
        handler(.disconnected(message))
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }
}
