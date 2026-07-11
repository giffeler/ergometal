import Foundation

public enum MinerMode: String, Codable, Sendable { case idle, benchmark, replay, mining }
public enum MinerState: String, Codable, Sendable {
    case starting, buildingDataset = "building_dataset", searching, reconnecting, stopped, failed
}

public struct JobStatistics: Codable, Sendable {
    public var id: String?
    public var height: Int?
    public var receivedAt: Date?
    public var difficulty: Double?

    public init(id: String? = nil, height: Int? = nil, receivedAt: Date? = nil, difficulty: Double? = nil) {
        self.id = id; self.height = height; self.receivedAt = receivedAt; self.difficulty = difficulty
    }
}

public struct ShareStatistics: Codable, Sendable {
    public var found = 0
    public var submitted = 0
    public var accepted = 0
    public var rejected = 0
    public var stale = 0
}

public struct MinerSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let startedAt: Date
    public var sampledAt: Date
    public var mode: MinerMode
    public var state: MinerState
    public var device: MetalDeviceInfo?
    public var profile: String
    public var poolHost: String?
    public var poolConnected: Bool
    public var job: JobStatistics
    public var nonces: UInt64
    public var hashrate: Double
    public var averageHashrate: Double
    public var datasetBytes: UInt64
    public var datasetBuildSeconds: Double
    public var gpuSeconds: Double
    public var searchSeconds: Double
    public var reconnects: Int
    public var protocolErrors: Int
    public var thermalState: String
    public var shares: ShareStatistics
    public var lastError: String?
}

public final class StatisticsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MinerSnapshot

    public init(mode: MinerMode = .idle, profile: String = "efficiency", device: MetalDeviceInfo? = nil) {
        let now = Date()
        value = MinerSnapshot(schemaVersion: 1, sessionID: UUID(), startedAt: now, sampledAt: now,
            mode: mode, state: .starting, device: device, profile: profile, poolHost: nil,
            poolConnected: false, job: JobStatistics(), nonces: 0, hashrate: 0,
            averageHashrate: 0, datasetBytes: 0, datasetBuildSeconds: 0, gpuSeconds: 0, searchSeconds: 0,
            reconnects: 0, protocolErrors: 0, thermalState: Self.thermalName,
            shares: ShareStatistics(), lastError: nil)
    }

    public func update(_ body: (inout MinerSnapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
        value.sampledAt = Date()
        value.thermalState = Self.thermalName
    }

    public func recordBatch(nonces: Int, gpuSeconds: Double, wallSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        value.nonces += UInt64(nonces)
        value.gpuSeconds += gpuSeconds
        value.searchSeconds += wallSeconds
        let now = Date()
        value.hashrate = wallSeconds > 0 ? Double(nonces) / wallSeconds : 0
        value.averageHashrate = value.searchSeconds > 0 ? Double(value.nonces) / value.searchSeconds : 0
        value.sampledAt = now
    }

    public func snapshot() -> MinerSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func prometheus() -> String {
        let s = snapshot()
        let labels = "session=\"\(s.sessionID.uuidString)\",mode=\"\(s.mode.rawValue)\""
        return """
        # HELP ergometal_hashrate Nonces searched per second.
        # TYPE ergometal_hashrate gauge
        ergometal_hashrate{\(labels)} \(s.hashrate)
        # TYPE ergometal_nonces_total counter
        ergometal_nonces_total{\(labels)} \(s.nonces)
        # TYPE ergometal_gpu_seconds_total counter
        ergometal_gpu_seconds_total{\(labels)} \(s.gpuSeconds)
        # TYPE ergometal_search_seconds_total counter
        ergometal_search_seconds_total{\(labels)} \(s.searchSeconds)
        # TYPE ergometal_dataset_build_seconds gauge
        ergometal_dataset_build_seconds{\(labels)} \(s.datasetBuildSeconds)
        # TYPE ergometal_dataset_bytes gauge
        ergometal_dataset_bytes{\(labels)} \(s.datasetBytes)
        # TYPE ergometal_pool_connected gauge
        ergometal_pool_connected{\(labels)} \(s.poolConnected ? 1 : 0)
        # TYPE ergometal_shares_found_total counter
        ergometal_shares_found_total{\(labels)} \(s.shares.found)
        # TYPE ergometal_shares_submitted_total counter
        ergometal_shares_submitted_total{\(labels)} \(s.shares.submitted)
        # TYPE ergometal_shares_accepted_total counter
        ergometal_shares_accepted_total{\(labels)} \(s.shares.accepted)
        # TYPE ergometal_shares_rejected_total counter
        ergometal_shares_rejected_total{\(labels)} \(s.shares.rejected)
        # TYPE ergometal_shares_stale_total counter
        ergometal_shares_stale_total{\(labels)} \(s.shares.stale)
        # TYPE ergometal_reconnects_total counter
        ergometal_reconnects_total{\(labels)} \(s.reconnects)
        # TYPE ergometal_protocol_errors_total counter
        ergometal_protocol_errors_total{\(labels)} \(s.protocolErrors)
        """ + "\n"
    }

    private static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

public struct MinerEvent: Codable, Sendable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let sessionID: UUID
    public let type: String
    public let fields: [String: String]

    public init(sessionID: UUID, type: String, fields: [String: String] = [:]) {
        self.schemaVersion = 1
        self.timestamp = Date()
        self.sessionID = sessionID
        self.type = type
        self.fields = fields
    }
}

public final class JSONLEventWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private let encoder: JSONEncoder
    public private(set) var failure: Error?

    public init(path: String?) {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
        } catch { failure = error }
    }

    public func write(_ event: MinerEvent) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, let handle else { return }
        do {
            var data = try encoder.encode(event)
            data.append(0x0a)
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            try? handle.close()
            self.handle = nil
        }
    }

    deinit { try? handle?.close() }
}
