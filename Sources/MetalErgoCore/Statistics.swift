import Foundation
import IOKit.hidsystem
import Darwin
import Synchronization

public struct SoCTemperatureSample: Codable, Sendable {
    public let averageCelsius: Double
    public let maximumCelsius: Double
    public let sensorCount: Int

    fileprivate init(averageCelsius: Double, maximumCelsius: Double, sensorCount: Int) {
        self.averageCelsius = averageCelsius
        self.maximumCelsius = maximumCelsius
        self.sensorCount = sensorCount
    }
}

public enum SoCTemperatureTelemetry {
    public static func sample() -> SoCTemperatureSample? {
        SoCTemperatureReader().sample()
    }
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

        let client = unsafeDowncast(clientObject, to: IOHIDEventSystemClient.self)
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
    public var datasetBuildGPUSeconds: Double
    public var datasetActivationSeconds: Double
    public var datasetSource: DatasetBuildSource?
    public var datasetActivations: Int
    public var datasetBuiltActivations: Int
    public var datasetPrefetchedActivations: Int
    public var datasetCachedActivations: Int
    public var datasetActivationSecondsTotal: Double
    public var datasetPrefetchWaits: Int
    public var datasetPrefetchWaitSecondsTotal: Double
    public var datasetWork: DatasetWorkMetrics
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
    public var socTemperatureSessionPeakCelsius: Double?
    public var socTemperatureSensorCount: Int
    public var temperatureSource: String
    public var shares: ShareStatistics
    public var lastError: String?
}

public extension MinerSnapshot {
    var searchDutyCycle: Double {
        let elapsed = max(0, sampledAt.timeIntervalSince(startedAt))
        return elapsed > 0 ? min(1, max(0, searchSeconds / elapsed)) : 0
    }

    var shareLuckRatio: Double? {
        shares.expected > 0 ? Double(shares.accepted) / shares.expected : nil
    }

    /// A credential-free, flat representation for append-only event logs.
    var eventFields: [String: String] {
        var fields: [String: String] = [
            "elapsed_seconds": String(max(0, sampledAt.timeIntervalSince(startedAt))),
            "state": state.rawValue,
            "profile": profile,
            "nonces": String(nonces),
            "hashrate": String(hashrate),
            "average_hashrate": String(averageHashrate),
            "effective_hashrate": String(effectiveHashrate),
            "gpu_seconds": String(gpuSeconds),
            "search_seconds": String(searchSeconds),
            "search_duty_cycle": String(searchDutyCycle),
            "dataset_bytes": String(datasetBytes),
            "dataset_build_seconds": String(datasetBuildSeconds),
            "dataset_build_gpu_seconds": String(datasetBuildGPUSeconds),
            "dataset_activation_seconds": String(datasetActivationSeconds),
            "dataset_activations_total": String(datasetActivations),
            "dataset_built_activations_total": String(datasetBuiltActivations),
            "dataset_prefetched_activations_total": String(datasetPrefetchedActivations),
            "dataset_cached_activations_total": String(datasetCachedActivations),
            "dataset_activation_seconds_total": String(datasetActivationSecondsTotal),
            "dataset_prefetch_waits_total": String(datasetPrefetchWaits),
            "dataset_prefetch_wait_seconds_total": String(datasetPrefetchWaitSecondsTotal),
            "prefetch_progress": String(prefetchProgress)
        ]
        let workFields: [String: String] = [
            "dataset_cold_builds_completed_total": String(datasetWork.coldBuildsCompleted),
            "dataset_cold_builds_cancelled_total": String(datasetWork.coldBuildsCancelled),
            "dataset_cold_builds_failed_total": String(datasetWork.coldBuildsFailed),
            "dataset_cold_build_wall_seconds_total": String(datasetWork.coldBuildWallSeconds),
            "dataset_cold_build_gpu_seconds_total": String(datasetWork.coldBuildGPUSeconds),
            "dataset_prefetch_builds_started_total": String(datasetWork.prefetchBuildsStarted),
            "dataset_prefetch_builds_completed_total": String(datasetWork.prefetchBuildsCompleted),
            "dataset_prefetch_builds_cancelled_total": String(datasetWork.prefetchBuildsCancelled),
            "dataset_prefetch_builds_failed_total": String(datasetWork.prefetchBuildsFailed),
            "dataset_prefetch_builds_discarded_total": String(datasetWork.prefetchBuildsDiscarded),
            "dataset_prefetch_build_wall_seconds_total": String(datasetWork.prefetchBuildWallSeconds),
            "dataset_prefetch_build_gpu_seconds_total": String(datasetWork.prefetchBuildGPUSeconds),
            "dataset_prefetch_wasted_wall_seconds_total": String(datasetWork.prefetchWastedWallSeconds),
            "dataset_prefetch_wasted_gpu_seconds_total": String(datasetWork.prefetchWastedGPUSeconds),
            "gpu_build_commands_completed_total": String(datasetWork.buildCommandsCompleted),
            "gpu_build_command_wall_seconds_total": String(datasetWork.buildCommandWallSeconds),
            "gpu_build_command_gpu_seconds_total": String(datasetWork.buildCommandGPUSeconds),
            "gpu_build_command_non_gpu_seconds_total": String(max(
                0, datasetWork.buildCommandWallSeconds - datasetWork.buildCommandGPUSeconds)),
            "gpu_search_commands_completed_total": String(datasetWork.searchCommandsCompleted),
            "gpu_search_command_wall_seconds_total": String(datasetWork.searchCommandWallSeconds),
            "gpu_search_command_gpu_seconds_total": String(datasetWork.searchCommandGPUSeconds),
            "gpu_search_command_non_gpu_seconds_total": String(max(
                0, datasetWork.searchCommandWallSeconds - datasetWork.searchCommandGPUSeconds)),
            "gpu_search_command_wall_busy_seconds_total": String(
                datasetWork.searchCommandWallBusySeconds),
            "gpu_search_command_gpu_busy_seconds_total": String(
                datasetWork.searchCommandGPUBusySeconds),
            "gpu_search_command_non_gpu_busy_seconds_total": String(max(
                0,
                datasetWork.searchCommandWallBusySeconds
                    - datasetWork.searchCommandGPUBusySeconds))
        ]
        fields.merge(workFields) { _, new in new }
        let runtimeFields: [String: String] = [
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
        fields.merge(runtimeFields) { _, new in new }
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
        if let temperature = socTemperatureSessionPeakCelsius {
            fields["soc_temperature_session_peak_celsius"] = String(temperature)
        }
        if let luck = shareLuckRatio {
            fields["share_luck_ratio"] = String(luck)
        }
        if let value = device?.searchPipelineMaxThreads {
            fields["search_pipeline_max_threads"] = String(value)
        }
        if let value = device?.buildPipelineMaxThreads {
            fields["build_pipeline_max_threads"] = String(value)
        }
        return fields
    }
}

public final class StatisticsStore: Sendable {
    private struct State {
        let temperatureReader: SoCTemperatureReader
        var value: MinerSnapshot
    }

    private let state: Mutex<State>

    public init(mode: MinerMode = .idle, profile: String = "efficiency", device: MetalDeviceInfo? = nil) {
        let now = Date()
        let temperatureReader = SoCTemperatureReader()
        let temperature = temperatureReader.sample()
        let value = MinerSnapshot(schemaVersion: 1, sessionID: UUID(), startedAt: now, sampledAt: now,
            mode: mode, state: .starting, device: device, profile: profile, poolHost: nil,
            poolConnected: false, job: JobStatistics(), nonces: 0, hashrate: 0,
            averageHashrate: 0, effectiveHashrate: 0, datasetBytes: 0,
            datasetBuildSeconds: 0, datasetBuildGPUSeconds: 0,
            datasetActivationSeconds: 0, datasetSource: nil,
            datasetActivations: 0, datasetBuiltActivations: 0,
            datasetPrefetchedActivations: 0, datasetCachedActivations: 0,
            datasetActivationSecondsTotal: 0, datasetPrefetchWaits: 0,
            datasetPrefetchWaitSecondsTotal: 0, datasetWork: DatasetWorkMetrics(),
            prefetchHeight: nil, prefetchProgress: 0, prefetchBuildSeconds: nil,
            prefetchError: nil,
            gpuSeconds: 0, searchSeconds: 0,
            reconnects: 0, protocolErrors: 0, thermalState: Self.thermalName,
            socTemperatureAverageCelsius: temperature?.averageCelsius,
            socTemperatureMaximumCelsius: temperature?.maximumCelsius,
            socTemperatureSessionPeakCelsius: temperature?.maximumCelsius,
            socTemperatureSensorCount: temperature?.sensorCount ?? 0,
            temperatureSource: temperature == nil ? "unavailable" : "iohid_soc_die",
            shares: ShareStatistics(), lastError: nil)
        state = Mutex(State(temperatureReader: temperatureReader, value: value))
    }

    public func update(_ body: @Sendable (inout MinerSnapshot) -> Void) {
        state.withLock { state in
            body(&state.value)
            if let temperature = state.value.socTemperatureMaximumCelsius {
                state.value.socTemperatureSessionPeakCelsius = max(
                    state.value.socTemperatureSessionPeakCelsius ?? temperature,
                    temperature)
            }
            state.value.sampledAt = Date()
            state.value.thermalState = Self.thermalName
        }
    }

    public func recordDatasetActivation(_ build: DatasetBuild) {
        state.withLock { state in
            state.value.datasetBytes = build.bytes
            state.value.datasetBuildSeconds = build.seconds
            state.value.datasetBuildGPUSeconds = build.gpuSeconds
            state.value.datasetActivationSeconds = build.activationSeconds
            state.value.datasetSource = build.source
            state.value.datasetActivations += 1
            state.value.datasetActivationSecondsTotal += build.activationSeconds
            switch build.source {
            case .built: state.value.datasetBuiltActivations += 1
            case .prefetched: state.value.datasetPrefetchedActivations += 1
            case .cached: state.value.datasetCachedActivations += 1
            }
            if build.waitedForPrefetch {
                state.value.datasetPrefetchWaits += 1
                state.value.datasetPrefetchWaitSecondsTotal += build.prefetchWaitSeconds
            }
            state.value.sampledAt = Date()
        }
    }

    public func updateDatasetWork(_ metrics: DatasetWorkMetrics) {
        state.withLock { state in
            state.value.datasetWork = metrics
            state.value.sampledAt = Date()
        }
    }

    public func recordBatch(
        nonces: Int,
        gpuSeconds: Double,
        wallSeconds: Double,
        shareTarget: UInt256? = nil
    ) {
        state.withLock { state in
            state.value.nonces += UInt64(nonces)
            state.value.gpuSeconds += gpuSeconds
            state.value.searchSeconds += wallSeconds
            if let shareTarget {
                state.value.shares.expected += Double(nonces) * Self.shareProbability(
                    for: shareTarget)
            }
            let now = Date()
            state.value.hashrate = wallSeconds > 0 ? Double(nonces) / wallSeconds : 0
            state.value.averageHashrate = state.value.searchSeconds > 0
                ? Double(state.value.nonces) / state.value.searchSeconds
                : 0
            let elapsed = now.timeIntervalSince(state.value.startedAt)
            state.value.effectiveHashrate = elapsed > 0
                ? Double(state.value.nonces) / elapsed
                : 0
            state.value.sampledAt = now
            state.value.thermalState = Self.thermalName
        }
    }

    /// Refreshes wall-clock dependent values even while no search batch is
    /// completing, for example during a long dataset build.
    @discardableResult
    public func refresh() -> MinerSnapshot {
        state.withLock { state in
            let now = Date()
            let elapsed = now.timeIntervalSince(state.value.startedAt)
            state.value.effectiveHashrate = elapsed > 0
                ? Double(state.value.nonces) / elapsed
                : 0
            let temperature = state.temperatureReader.sample()
            state.value.socTemperatureAverageCelsius = temperature?.averageCelsius
            state.value.socTemperatureMaximumCelsius = temperature?.maximumCelsius
            if let maximum = temperature?.maximumCelsius {
                state.value.socTemperatureSessionPeakCelsius = max(
                    state.value.socTemperatureSessionPeakCelsius ?? maximum,
                    maximum)
            }
            state.value.socTemperatureSensorCount = temperature?.sensorCount ?? 0
            state.value.temperatureSource = temperature == nil ? "unavailable" : "iohid_soc_die"
            state.value.sampledAt = now
            state.value.thermalState = Self.thermalName
            return state.value
        }
    }

    public func snapshot() -> MinerSnapshot {
        state.withLock { $0.value }
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
        # HELP ergometal_search_duty_cycle Fraction of session wall time spent actively searching.
        # TYPE ergometal_search_duty_cycle gauge
        ergometal_search_duty_cycle{\(labels)} \(s.searchDutyCycle)
        # TYPE ergometal_dataset_build_seconds gauge
        ergometal_dataset_build_seconds{\(labels)} \(s.datasetBuildSeconds)
        # TYPE ergometal_dataset_build_gpu_seconds gauge
        ergometal_dataset_build_gpu_seconds{\(labels)} \(s.datasetBuildGPUSeconds)
        # TYPE ergometal_dataset_activation_seconds gauge
        ergometal_dataset_activation_seconds{\(labels)} \(s.datasetActivationSeconds)
        # TYPE ergometal_dataset_activations_total counter
        ergometal_dataset_activations_total{\(labels)} \(s.datasetActivations)
        # TYPE ergometal_dataset_built_activations_total counter
        ergometal_dataset_built_activations_total{\(labels)} \(s.datasetBuiltActivations)
        # TYPE ergometal_dataset_prefetched_activations_total counter
        ergometal_dataset_prefetched_activations_total{\(labels)} \(s.datasetPrefetchedActivations)
        # TYPE ergometal_dataset_cached_activations_total counter
        ergometal_dataset_cached_activations_total{\(labels)} \(s.datasetCachedActivations)
        # TYPE ergometal_dataset_activation_seconds_total counter
        ergometal_dataset_activation_seconds_total{\(labels)} \(s.datasetActivationSecondsTotal)
        # TYPE ergometal_dataset_prefetch_waits_total counter
        ergometal_dataset_prefetch_waits_total{\(labels)} \(s.datasetPrefetchWaits)
        # TYPE ergometal_dataset_prefetch_wait_seconds_total counter
        ergometal_dataset_prefetch_wait_seconds_total{\(labels)} \(s.datasetPrefetchWaitSecondsTotal)
        # TYPE ergometal_dataset_cold_builds_completed_total counter
        ergometal_dataset_cold_builds_completed_total{\(labels)} \(s.datasetWork.coldBuildsCompleted)
        # TYPE ergometal_dataset_cold_builds_cancelled_total counter
        ergometal_dataset_cold_builds_cancelled_total{\(labels)} \(s.datasetWork.coldBuildsCancelled)
        # TYPE ergometal_dataset_cold_builds_failed_total counter
        ergometal_dataset_cold_builds_failed_total{\(labels)} \(s.datasetWork.coldBuildsFailed)
        # TYPE ergometal_dataset_cold_build_wall_seconds_total counter
        ergometal_dataset_cold_build_wall_seconds_total{\(labels)} \(s.datasetWork.coldBuildWallSeconds)
        # TYPE ergometal_dataset_cold_build_gpu_seconds_total counter
        ergometal_dataset_cold_build_gpu_seconds_total{\(labels)} \(s.datasetWork.coldBuildGPUSeconds)
        # TYPE ergometal_dataset_prefetch_builds_started_total counter
        ergometal_dataset_prefetch_builds_started_total{\(labels)} \(s.datasetWork.prefetchBuildsStarted)
        # TYPE ergometal_dataset_prefetch_builds_completed_total counter
        ergometal_dataset_prefetch_builds_completed_total{\(labels)} \(s.datasetWork.prefetchBuildsCompleted)
        # TYPE ergometal_dataset_prefetch_builds_cancelled_total counter
        ergometal_dataset_prefetch_builds_cancelled_total{\(labels)} \(s.datasetWork.prefetchBuildsCancelled)
        # TYPE ergometal_dataset_prefetch_builds_failed_total counter
        ergometal_dataset_prefetch_builds_failed_total{\(labels)} \(s.datasetWork.prefetchBuildsFailed)
        # TYPE ergometal_dataset_prefetch_builds_discarded_total counter
        ergometal_dataset_prefetch_builds_discarded_total{\(labels)} \(s.datasetWork.prefetchBuildsDiscarded)
        # TYPE ergometal_dataset_prefetch_build_wall_seconds_total counter
        ergometal_dataset_prefetch_build_wall_seconds_total{\(labels)} \(s.datasetWork.prefetchBuildWallSeconds)
        # TYPE ergometal_dataset_prefetch_build_gpu_seconds_total counter
        ergometal_dataset_prefetch_build_gpu_seconds_total{\(labels)} \(s.datasetWork.prefetchBuildGPUSeconds)
        # TYPE ergometal_dataset_prefetch_wasted_wall_seconds_total counter
        ergometal_dataset_prefetch_wasted_wall_seconds_total{\(labels)} \(s.datasetWork.prefetchWastedWallSeconds)
        # TYPE ergometal_dataset_prefetch_wasted_gpu_seconds_total counter
        ergometal_dataset_prefetch_wasted_gpu_seconds_total{\(labels)} \(s.datasetWork.prefetchWastedGPUSeconds)
        # TYPE ergometal_gpu_build_commands_completed_total counter
        ergometal_gpu_build_commands_completed_total{\(labels)} \(s.datasetWork.buildCommandsCompleted)
        # TYPE ergometal_gpu_build_command_wall_seconds_total counter
        ergometal_gpu_build_command_wall_seconds_total{\(labels)} \(s.datasetWork.buildCommandWallSeconds)
        # TYPE ergometal_gpu_build_command_gpu_seconds_total counter
        ergometal_gpu_build_command_gpu_seconds_total{\(labels)} \(s.datasetWork.buildCommandGPUSeconds)
        # TYPE ergometal_gpu_search_commands_completed_total counter
        ergometal_gpu_search_commands_completed_total{\(labels)} \(s.datasetWork.searchCommandsCompleted)
        # TYPE ergometal_gpu_search_command_wall_seconds_total counter
        ergometal_gpu_search_command_wall_seconds_total{\(labels)} \(s.datasetWork.searchCommandWallSeconds)
        # TYPE ergometal_gpu_search_command_gpu_seconds_total counter
        ergometal_gpu_search_command_gpu_seconds_total{\(labels)} \(s.datasetWork.searchCommandGPUSeconds)
        # HELP ergometal_gpu_search_command_wall_busy_seconds_total Union of overlapping search command wall intervals.
        # TYPE ergometal_gpu_search_command_wall_busy_seconds_total counter
        ergometal_gpu_search_command_wall_busy_seconds_total{\(labels)} \(s.datasetWork.searchCommandWallBusySeconds)
        # HELP ergometal_gpu_search_command_gpu_busy_seconds_total Union of overlapping search command GPU intervals.
        # TYPE ergometal_gpu_search_command_gpu_busy_seconds_total counter
        ergometal_gpu_search_command_gpu_busy_seconds_total{\(labels)} \(s.datasetWork.searchCommandGPUBusySeconds)
        # HELP ergometal_gpu_search_command_non_gpu_busy_seconds_total Busy search wall time outside GPU execution.
        # TYPE ergometal_gpu_search_command_non_gpu_busy_seconds_total counter
        ergometal_gpu_search_command_non_gpu_busy_seconds_total{\(labels)} \(max(
            0,
            s.datasetWork.searchCommandWallBusySeconds
                - s.datasetWork.searchCommandGPUBusySeconds))
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
        if let temperature = s.socTemperatureSessionPeakCelsius {
            output += """

            # HELP ergometal_soc_temperature_session_peak_celsius Highest observed SoC die temperature in this session.
            # TYPE ergometal_soc_temperature_session_peak_celsius gauge
            ergometal_soc_temperature_session_peak_celsius{\(labels)} \(temperature)
            """
        }
        if let luck = s.shareLuckRatio {
            output += """

            # HELP ergometal_share_luck_ratio Accepted shares divided by statistically expected shares.
            # TYPE ergometal_share_luck_ratio gauge
            ergometal_share_luck_ratio{\(labels)} \(luck)
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

public final class JSONLEventWriter: Sendable {
    private struct State {
        var handle: FileHandle?
        let encoder: JSONEncoder
        var failure: Error?
    }

    private let state: Mutex<State>

    public var failure: Error? {
        state.withLock { $0.failure }
    }

    public init(path: String?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var handle: FileHandle?
        var failure: Error?
        if let path {
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            do {
                handle = try FileHandle(forWritingTo: url)
                try handle?.seekToEnd()
            } catch {
                failure = error
                fputs("ergometal event log: \(error.localizedDescription)\n", stderr)
            }
        }
        state = Mutex(State(handle: handle, encoder: encoder, failure: failure))
    }

    public func write(_ event: MinerEvent) {
        state.withLock { state in
            guard state.failure == nil, let handle = state.handle else { return }
            do {
                var data = try state.encoder.encode(event)
                data.append(0x0a)
                try handle.write(contentsOf: data)
            } catch {
                state.failure = error
                try? handle.close()
                state.handle = nil
                fputs("ergometal event log: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    deinit {
        state.withLock { try? $0.handle?.close() }
    }
}
