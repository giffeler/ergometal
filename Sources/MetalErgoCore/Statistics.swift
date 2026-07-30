import Foundation
import IOKit.hidsystem
import Darwin

private struct SoCTemperatureSample {
    let averageCelsius: Double
    let maximumCelsius: Double
    let sensorCount: Int
}

/// Best-effort Apple Silicon temperature telemetry. macOS has no public API
/// for numeric SoC temperatures, so the private HID event functions are
/// resolved dynamically. Missing symbols or sensors simply disable the
/// numeric fields while ProcessInfo.thermalState remains available.
private final class SoCTemperatureReader {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (UnsafeRawPointer, CFDictionary) -> Void
    private typealias CopyEvent = @convention(c) (
        UnsafeRawPointer, Int64, Int32, Int64
    ) -> Unmanaged<AnyObject>?
    private typealias GetFloatValue = @convention(c) (UnsafeRawPointer, Int64) -> Double

    private struct Functions {
        let createClient: CreateClient
        let setMatching: SetMatching
        let copyEvent: CopyEvent
        let getFloatValue: GetFloatValue
    }

    private let framework: UnsafeMutableRawPointer?
    private let functions: Functions?

    init() {
        guard let framework = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            RTLD_LAZY | RTLD_LOCAL)
        else {
            self.framework = nil
            functions = nil
            return
        }
        guard let createClient = dlsym(framework, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(framework, "IOHIDEventSystemClientSetMatching"),
              let copyEvent = dlsym(framework, "IOHIDServiceClientCopyEvent"),
              let getFloatValue = dlsym(framework, "IOHIDEventGetFloatValue")
        else {
            dlclose(framework)
            self.framework = nil
            functions = nil
            return
        }
        self.framework = framework
        functions = Functions(
            createClient: unsafeBitCast(createClient, to: CreateClient.self),
            setMatching: unsafeBitCast(setMatching, to: SetMatching.self),
            copyEvent: unsafeBitCast(copyEvent, to: CopyEvent.self),
            getFloatValue: unsafeBitCast(getFloatValue, to: GetFloatValue.self))
    }

    deinit {
        if let framework { dlclose(framework) }
    }

    func sample() -> SoCTemperatureSample? {
        guard let functions,
              let unmanagedClient = functions.createClient(nil)
        else { return nil }

        let clientObject = unmanagedClient.takeRetainedValue()
        let clientPointer = Unmanaged.passUnretained(clientObject).toOpaque()
        let matching = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 0x0005
        ] as CFDictionary
        functions.setMatching(clientPointer, matching)

        let client = unsafeBitCast(clientObject, to: IOHIDEventSystemClient.self)
        guard let services = IOHIDEventSystemClientCopyServices(client) else { return nil }

        var readingsByName: [String: [Double]] = [:]
        for index in 0..<CFArrayGetCount(services) {
            let service = unsafeBitCast(
                CFArrayGetValueAtIndex(services, index),
                to: IOHIDServiceClient.self)
            guard let rawName = IOHIDServiceClientCopyProperty(service, "Product" as CFString)
            else { continue }
            let name = String(describing: rawName)
            let lowercasedName = name.lowercased()
            guard lowercasedName.contains("tdie")
                    || lowercasedName.contains("mtr temp sensor")
            else { continue }

            let servicePointer = Unmanaged.passUnretained(service).toOpaque()
            guard let unmanagedEvent = functions.copyEvent(
                servicePointer, 15, 0, 0)
            else { continue }
            let event = unmanagedEvent.takeRetainedValue()
            let value = functions.getFloatValue(
                Unmanaged.passUnretained(event).toOpaque(),
                15 << 16)
            guard value.isFinite, value > 0, value <= 150 else { continue }
            readingsByName[name, default: []].append(value)
        }

        let readings = readingsByName.values.map {
            $0.reduce(0, +) / Double($0.count)
        }
        guard let maximum = readings.max(), !readings.isEmpty else { return nil }
        return SoCTemperatureSample(
            averageCelsius: readings.reduce(0, +) / Double(readings.count),
            maximumCelsius: maximum,
            sensorCount: readings.count)
    }
}

public enum MinerMode: String, Codable, Sendable { case idle, benchmark, replay, mining }
public enum MinerState: String, Codable, Sendable {
    case starting, buildingDataset = "building_dataset", searching, reconnecting, stopped, failed
}

public struct JobStatistics: Codable, Sendable {
    public var id: String?
    public var height: Int?
    public var receivedAt: Date?
    public var difficulty: Double?
    public var targetHex: String?

    public init(
        id: String? = nil,
        height: Int? = nil,
        receivedAt: Date? = nil,
        difficulty: Double? = nil,
        targetHex: String? = nil
    ) {
        self.id = id
        self.height = height
        self.receivedAt = receivedAt
        self.difficulty = difficulty
        self.targetHex = targetHex
    }
}

public struct ShareStatistics: Codable, Sendable {
    public var expected = 0.0
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
    public var effectiveHashrate: Double
    public var datasetBytes: UInt64
    public var datasetBuildSeconds: Double
    public var datasetActivationSeconds: Double
    public var datasetSource: DatasetBuildSource?
    public var prefetchHeight: Int?
    public var prefetchProgress: Double
    public var prefetchBuildSeconds: Double?
    public var prefetchError: String?
    public var gpuSeconds: Double
    public var searchSeconds: Double
    public var reconnects: Int
    public var protocolErrors: Int
    public var thermalState: String
    public var socTemperatureAverageCelsius: Double?
    public var socTemperatureMaximumCelsius: Double?
    public var socTemperatureSensorCount: Int
    public var temperatureSource: String
    public var shares: ShareStatistics
    public var lastError: String?
}

public extension MinerSnapshot {
    /// A credential-free, flat representation for append-only event logs.
    var eventFields: [String: String] {
        var fields = [
            "elapsed_seconds": String(max(0, sampledAt.timeIntervalSince(startedAt))),
            "state": state.rawValue,
            "profile": profile,
            "nonces": String(nonces),
            "hashrate": String(hashrate),
            "average_hashrate": String(averageHashrate),
            "effective_hashrate": String(effectiveHashrate),
            "gpu_seconds": String(gpuSeconds),
            "search_seconds": String(searchSeconds),
            "dataset_bytes": String(datasetBytes),
            "dataset_build_seconds": String(datasetBuildSeconds),
            "dataset_activation_seconds": String(datasetActivationSeconds),
            "prefetch_progress": String(prefetchProgress),
            "pool_connected": String(poolConnected),
            "reconnects": String(reconnects),
            "protocol_errors": String(protocolErrors),
            "thermal_state": thermalState,
            "soc_temperature_sensor_count": String(socTemperatureSensorCount),
            "temperature_source": temperatureSource,
            "shares_expected": String(shares.expected),
            "shares_found": String(shares.found),
            "shares_submitted": String(shares.submitted),
            "shares_accepted": String(shares.accepted),
            "shares_rejected": String(shares.rejected),
            "shares_stale": String(shares.stale)
        ]
        if let id = job.id { fields["job_id"] = id }
        if let height = job.height { fields["height"] = String(height) }
        if let difficulty = job.difficulty { fields["difficulty"] = String(difficulty) }
        if let targetHex = job.targetHex { fields["job_target_hex"] = targetHex }
        if let source = datasetSource { fields["dataset_source"] = source.rawValue }
        if let height = prefetchHeight { fields["prefetch_height"] = String(height) }
        if let seconds = prefetchBuildSeconds { fields["prefetch_build_seconds"] = String(seconds) }
        if let error = prefetchError { fields["prefetch_error"] = error }
        if let temperature = socTemperatureAverageCelsius {
            fields["soc_temperature_average_celsius"] = String(temperature)
        }
        if let temperature = socTemperatureMaximumCelsius {
            fields["soc_temperature_maximum_celsius"] = String(temperature)
        }
        return fields
    }
}

public final class StatisticsStore: @unchecked Sendable {
    private let lock = NSLock()
    private let temperatureReader: SoCTemperatureReader
    private var value: MinerSnapshot

    public init(mode: MinerMode = .idle, profile: String = "efficiency", device: MetalDeviceInfo? = nil) {
        let now = Date()
        let temperatureReader = SoCTemperatureReader()
        let temperature = temperatureReader.sample()
        self.temperatureReader = temperatureReader
        value = MinerSnapshot(schemaVersion: 1, sessionID: UUID(), startedAt: now, sampledAt: now,
            mode: mode, state: .starting, device: device, profile: profile, poolHost: nil,
            poolConnected: false, job: JobStatistics(), nonces: 0, hashrate: 0,
            averageHashrate: 0, effectiveHashrate: 0, datasetBytes: 0,
            datasetBuildSeconds: 0, datasetActivationSeconds: 0, datasetSource: nil,
            prefetchHeight: nil, prefetchProgress: 0, prefetchBuildSeconds: nil,
            prefetchError: nil,
            gpuSeconds: 0, searchSeconds: 0,
            reconnects: 0, protocolErrors: 0, thermalState: Self.thermalName,
            socTemperatureAverageCelsius: temperature?.averageCelsius,
            socTemperatureMaximumCelsius: temperature?.maximumCelsius,
            socTemperatureSensorCount: temperature?.sensorCount ?? 0,
            temperatureSource: temperature == nil ? "unavailable" : "iohid_soc_die",
            shares: ShareStatistics(), lastError: nil)
    }

    public func update(_ body: (inout MinerSnapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
        value.sampledAt = Date()
        value.thermalState = Self.thermalName
    }

    public func recordBatch(
        nonces: Int,
        gpuSeconds: Double,
        wallSeconds: Double,
        shareTarget: UInt256? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        value.nonces += UInt64(nonces)
        value.gpuSeconds += gpuSeconds
        value.searchSeconds += wallSeconds
        if let shareTarget {
            value.shares.expected += Double(nonces) * Self.shareProbability(for: shareTarget)
        }
        let now = Date()
        value.hashrate = wallSeconds > 0 ? Double(nonces) / wallSeconds : 0
        value.averageHashrate = value.searchSeconds > 0 ? Double(value.nonces) / value.searchSeconds : 0
        let elapsed = now.timeIntervalSince(value.startedAt)
        value.effectiveHashrate = elapsed > 0 ? Double(value.nonces) / elapsed : 0
        value.sampledAt = now
        value.thermalState = Self.thermalName
    }

    /// Refreshes wall-clock dependent values even while no search batch is
    /// completing, for example during a long dataset build.
    @discardableResult
    public func refresh() -> MinerSnapshot {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let elapsed = now.timeIntervalSince(value.startedAt)
        value.effectiveHashrate = elapsed > 0 ? Double(value.nonces) / elapsed : 0
        let temperature = temperatureReader.sample()
        value.socTemperatureAverageCelsius = temperature?.averageCelsius
        value.socTemperatureMaximumCelsius = temperature?.maximumCelsius
        value.socTemperatureSensorCount = temperature?.sensorCount ?? 0
        value.temperatureSource = temperature == nil ? "unavailable" : "iohid_soc_die"
        value.sampledAt = now
        value.thermalState = Self.thermalName
        return value
    }

    public func snapshot() -> MinerSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func prometheus() -> String {
        let s = snapshot()
        let labels = "session=\"\(s.sessionID.uuidString)\",mode=\"\(s.mode.rawValue)\""
        var output = """
        # HELP ergometal_hashrate Nonces searched per second.
        # TYPE ergometal_hashrate gauge
        ergometal_hashrate{\(labels)} \(s.hashrate)
        # TYPE ergometal_nonces_total counter
        ergometal_nonces_total{\(labels)} \(s.nonces)
        # HELP ergometal_effective_hashrate Nonces searched per wall-clock second, including dataset work.
        # TYPE ergometal_effective_hashrate gauge
        ergometal_effective_hashrate{\(labels)} \(s.effectiveHashrate)
        # TYPE ergometal_gpu_seconds_total counter
        ergometal_gpu_seconds_total{\(labels)} \(s.gpuSeconds)
        # TYPE ergometal_search_seconds_total counter
        ergometal_search_seconds_total{\(labels)} \(s.searchSeconds)
        # TYPE ergometal_dataset_build_seconds gauge
        ergometal_dataset_build_seconds{\(labels)} \(s.datasetBuildSeconds)
        # TYPE ergometal_dataset_activation_seconds gauge
        ergometal_dataset_activation_seconds{\(labels)} \(s.datasetActivationSeconds)
        # TYPE ergometal_dataset_bytes gauge
        ergometal_dataset_bytes{\(labels)} \(s.datasetBytes)
        # TYPE ergometal_dataset_prefetch_progress gauge
        ergometal_dataset_prefetch_progress{\(labels)} \(s.prefetchProgress)
        # TYPE ergometal_pool_connected gauge
        ergometal_pool_connected{\(labels)} \(s.poolConnected ? 1 : 0)
        # TYPE ergometal_shares_found_total counter
        ergometal_shares_found_total{\(labels)} \(s.shares.found)
        # HELP ergometal_shares_expected_total Expected candidate shares for all searched nonces and their job targets.
        # TYPE ergometal_shares_expected_total counter
        ergometal_shares_expected_total{\(labels)} \(s.shares.expected)
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
        """
        if let temperature = s.socTemperatureAverageCelsius {
            output += """

            # HELP ergometal_soc_temperature_average_celsius Average available SoC die temperature in degrees Celsius.
            # TYPE ergometal_soc_temperature_average_celsius gauge
            ergometal_soc_temperature_average_celsius{\(labels)} \(temperature)
            """
        }
        if let temperature = s.socTemperatureMaximumCelsius {
            output += """

            # HELP ergometal_soc_temperature_maximum_celsius Maximum available SoC die temperature in degrees Celsius.
            # TYPE ergometal_soc_temperature_maximum_celsius gauge
            ergometal_soc_temperature_maximum_celsius{\(labels)} \(temperature)
            """
        }
        return output + "\n"
    }

    /// A uniformly distributed 256-bit hit is below `target` with probability
    /// target / 2^256. Limbs are stored most-significant first.
    private static func shareProbability(for target: UInt256) -> Double {
        let radix = 4_294_967_296.0
        return target.limbs.reversed().reduce(0.0) {
            ($0 + Double($1)) / radix
        }
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
        } catch {
            failure = error
            fputs("ergometal event log: \(error.localizedDescription)\n", stderr)
        }
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
            fputs("ergometal event log: \(error.localizedDescription)\n", stderr)
        }
    }

    deinit { try? handle?.close() }
}
