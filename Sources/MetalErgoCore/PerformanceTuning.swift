import CryptoKit
import Darwin
import Foundation
import Metal

public enum PerformanceProfile: String, CaseIterable, Codable, Sendable {
    case efficiency
    case peak
}

public enum AutotuneMode: String, CaseIterable, Codable, Sendable {
    case auto
    case refresh
    case off
}

public enum AppleSiliconGeneration: String, Codable, Sendable {
    case m1
    case m2
    case m3
    case m4
    case m5
    case m6
    case unknown
}

/// A stable description of the GPU capabilities that can affect Metal code
/// generation or dispatch performance. The architecture name keeps a future
/// GPU (including M6) distinct even when the installed SDK cannot name its
/// Metal GPU family yet.
public struct GPUArchitectureFingerprint: Codable, Hashable, Sendable {
    public let deviceName: String
    public let architectureName: String
    public let highestKnownAppleFamily: Int?
    public let generation: AppleSiliconGeneration
    public let searchThreadExecutionWidth: Int
    public let searchMaxThreadsPerThreadgroup: Int
    public let buildThreadExecutionWidth: Int
    public let buildMaxThreadsPerThreadgroup: Int
    public let operatingSystemBuild: String

    public init(
        deviceName: String,
        architectureName: String,
        highestKnownAppleFamily: Int?,
        generation: AppleSiliconGeneration? = nil,
        searchThreadExecutionWidth: Int,
        searchMaxThreadsPerThreadgroup: Int,
        buildThreadExecutionWidth: Int,
        buildMaxThreadsPerThreadgroup: Int,
        operatingSystemBuild: String
    ) {
        self.deviceName = deviceName
        self.architectureName = architectureName
        self.highestKnownAppleFamily = highestKnownAppleFamily
        self.generation = generation ?? Self.generation(for: deviceName)
        self.searchThreadExecutionWidth = searchThreadExecutionWidth
        self.searchMaxThreadsPerThreadgroup = searchMaxThreadsPerThreadgroup
        self.buildThreadExecutionWidth = buildThreadExecutionWidth
        self.buildMaxThreadsPerThreadgroup = buildMaxThreadsPerThreadgroup
        self.operatingSystemBuild = operatingSystemBuild
    }

    public var familyName: String {
        highestKnownAppleFamily.map { "apple\($0)" } ?? "unknown"
    }

    public static func generation(for deviceName: String) -> AppleSiliconGeneration {
        let normalized = deviceName.lowercased()
        for (token, generation) in [
            ("m6", AppleSiliconGeneration.m6),
            ("m5", .m5),
            ("m4", .m4),
            ("m3", .m3),
            ("m2", .m2),
            ("m1", .m1)
        ] where normalized.range(of: "\\b\(token)\\b", options: .regularExpression) != nil {
            return generation
        }
        return .unknown
    }

    public static func highestKnownAppleFamily(device: MTLDevice) -> Int? {
        var supported = Set<Int>()
        if device.supportsFamily(.apple10) { supported.insert(10) }
        if device.supportsFamily(.apple9) { supported.insert(9) }
        if device.supportsFamily(.apple8) { supported.insert(8) }
        if device.supportsFamily(.apple7) { supported.insert(7) }
        return highestKnownAppleFamily(supportedFamilies: supported)
    }

    public static func highestKnownAppleFamily(supportedFamilies: Set<Int>) -> Int? {
        supportedFamilies.filter { (7...10).contains($0) }.max()
    }

    public static func operatingSystemBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        return String(decoding: bytes.dropLast().map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

public struct MetalExecutionConfiguration: Codable, Equatable, Sendable {
    public var searchThreadgroupSize: Int
    public var datasetThreadgroupSize: Int
    public var batchNonces: Int
    public var prebuildBatchNonces: Int
    public var synchronousBuildChunkElements: Int
    public var prefetchBuildChunkElements: Int
    public var searchPipelineDepth: Int
    public var buildPipelineDepth: Int

    public init(
        searchThreadgroupSize: Int,
        datasetThreadgroupSize: Int,
        batchNonces: Int,
        prebuildBatchNonces: Int,
        synchronousBuildChunkElements: Int,
        prefetchBuildChunkElements: Int,
        searchPipelineDepth: Int,
        buildPipelineDepth: Int
    ) {
        self.searchThreadgroupSize = searchThreadgroupSize
        self.datasetThreadgroupSize = datasetThreadgroupSize
        self.batchNonces = batchNonces
        self.prebuildBatchNonces = prebuildBatchNonces
        self.synchronousBuildChunkElements = synchronousBuildChunkElements
        self.prefetchBuildChunkElements = prefetchBuildChunkElements
        self.searchPipelineDepth = searchPipelineDepth
        self.buildPipelineDepth = buildPipelineDepth
    }

    /// Conservative defaults known to be valid on M1. Newer and unknown GPUs
    /// start here and move only after a measured, consensus-valid win.
    public static func safeFallback(profile: PerformanceProfile) -> Self {
        Self(
            searchThreadgroupSize: 128,
            datasetThreadgroupSize: 256,
            batchNonces: profile == .peak ? 1_048_576 : 262_144,
            prebuildBatchNonces: 65_536,
            synchronousBuildChunkElements: 2_097_152,
            prefetchBuildChunkElements: 1_048_576,
            searchPipelineDepth: 2,
            buildPipelineDepth: 2)
    }

    public func isValid(for fingerprint: GPUArchitectureFingerprint) -> Bool {
        func validGroup(_ size: Int, width: Int, limit: Int) -> Bool {
            width > 0 && size > 0 && size <= min(1_024, limit)
                && size.isMultiple(of: width)
        }
        return validGroup(searchThreadgroupSize,
                   width: fingerprint.searchThreadExecutionWidth,
                   limit: fingerprint.searchMaxThreadsPerThreadgroup)
            && validGroup(datasetThreadgroupSize,
                   width: fingerprint.buildThreadExecutionWidth,
                   limit: fingerprint.buildMaxThreadsPerThreadgroup)
            && [batchNonces, prebuildBatchNonces, synchronousBuildChunkElements,
                prefetchBuildChunkElements].allSatisfy { (1...16_777_216).contains($0) }
            && (1...4).contains(searchPipelineDepth)
            && (1...4).contains(buildPipelineDepth)
    }
}

public struct MetalExecutionOverrides: Codable, Equatable, Sendable {
    public var searchThreadgroupSize: Int?
    public var datasetThreadgroupSize: Int?
    public var batchNonces: Int?
    public var prebuildBatchNonces: Int?
    public var synchronousBuildChunkElements: Int?
    public var prefetchBuildChunkElements: Int?
    public var searchPipelineDepth: Int?
    public var buildPipelineDepth: Int?

    public init(
        searchThreadgroupSize: Int? = nil,
        datasetThreadgroupSize: Int? = nil,
        batchNonces: Int? = nil,
        prebuildBatchNonces: Int? = nil,
        synchronousBuildChunkElements: Int? = nil,
        prefetchBuildChunkElements: Int? = nil,
        searchPipelineDepth: Int? = nil,
        buildPipelineDepth: Int? = nil
    ) {
        self.searchThreadgroupSize = searchThreadgroupSize
        self.datasetThreadgroupSize = datasetThreadgroupSize
        self.batchNonces = batchNonces
        self.prebuildBatchNonces = prebuildBatchNonces
        self.synchronousBuildChunkElements = synchronousBuildChunkElements
        self.prefetchBuildChunkElements = prefetchBuildChunkElements
        self.searchPipelineDepth = searchPipelineDepth
        self.buildPipelineDepth = buildPipelineDepth
    }

    public var normalized: String {
        [
            "batch=\(batchNonces.map(String.init) ?? "auto")",
            "buildChunk=\(synchronousBuildChunkElements.map(String.init) ?? "auto")",
            "buildDepth=\(buildPipelineDepth.map(String.init) ?? "auto")",
            "datasetTG=\(datasetThreadgroupSize.map(String.init) ?? "auto")",
            "prefetchChunk=\(prefetchBuildChunkElements.map(String.init) ?? "auto")",
            "prebuildBatch=\(prebuildBatchNonces.map(String.init) ?? "auto")",
            "searchDepth=\(searchPipelineDepth.map(String.init) ?? "auto")",
            "searchTG=\(searchThreadgroupSize.map(String.init) ?? "auto")"
        ].joined(separator: ";")
    }

    public var isComplete: Bool {
        searchThreadgroupSize != nil && datasetThreadgroupSize != nil &&
            batchNonces != nil && prebuildBatchNonces != nil &&
            synchronousBuildChunkElements != nil && prefetchBuildChunkElements != nil &&
            searchPipelineDepth != nil && buildPipelineDepth != nil
    }

    public func applying(to configuration: MetalExecutionConfiguration) -> MetalExecutionConfiguration {
        var result = configuration
        if let value = searchThreadgroupSize { result.searchThreadgroupSize = value }
        if let value = datasetThreadgroupSize { result.datasetThreadgroupSize = value }
        if let value = batchNonces { result.batchNonces = value }
        if let value = prebuildBatchNonces { result.prebuildBatchNonces = value }
        if let value = synchronousBuildChunkElements { result.synchronousBuildChunkElements = value }
        if let value = prefetchBuildChunkElements { result.prefetchBuildChunkElements = value }
        if let value = searchPipelineDepth { result.searchPipelineDepth = value }
        if let value = buildPipelineDepth { result.buildPipelineDepth = value }
        return result
    }
}

public enum TuningProvenance: String, Codable, Sendable {
    case fallback
    case tuned
    case cache
    case explicit
}

public struct ResolvedTuning: Codable, Equatable, Sendable {
    public let configuration: MetalExecutionConfiguration
    public let provenance: [String: TuningProvenance]
    public let cacheKey: String?

    public init(
        configuration: MetalExecutionConfiguration,
        provenance: [String: TuningProvenance],
        cacheKey: String?
    ) {
        self.configuration = configuration
        self.provenance = provenance
        self.cacheKey = cacheKey
    }

    public var summaryProvenance: TuningProvenance {
        if provenance.values.contains(.explicit) { return .explicit }
        if provenance.values.contains(.cache) { return .cache }
        if provenance.values.contains(.tuned) { return .tuned }
        return .fallback
    }
}

public enum MetalTuningResolver {
    public static func resolve(
        profile: PerformanceProfile,
        cached: MetalExecutionConfiguration? = nil,
        tuned: MetalExecutionConfiguration? = nil,
        overrides: MetalExecutionOverrides = .init(),
        cacheKey: String? = nil
    ) -> ResolvedTuning {
        let fallback = MetalExecutionConfiguration.safeFallback(profile: profile)
        var configuration = fallback
        var sources = Dictionary(
            uniqueKeysWithValues: configuration.fieldNames.map { ($0, TuningProvenance.fallback) })

        func apply(_ source: MetalExecutionConfiguration?, provenance: TuningProvenance) {
            guard let source else { return }
            configuration = source
            for key in configuration.fieldNames { sources[key] = provenance }
        }
        // The generic order is fallback < tuning < cache < explicit.
        apply(tuned, provenance: .tuned)
        apply(cached, provenance: .cache)
        configuration = overrides.applying(to: configuration)
        for key in overrides.explicitFieldNames { sources[key] = .explicit }
        return ResolvedTuning(
            configuration: configuration, provenance: sources, cacheKey: cacheKey)
    }
}

private extension MetalExecutionConfiguration {
    var fieldNames: [String] {
        ["search_threadgroup_size", "dataset_threadgroup_size", "batch_nonces",
         "prebuild_batch_nonces", "build_chunk_elements", "prefetch_chunk_elements",
         "search_pipeline_depth", "build_pipeline_depth"]
    }
}

private extension MetalExecutionOverrides {
    var explicitFieldNames: [String] {
        var result: [String] = []
        if searchThreadgroupSize != nil { result.append("search_threadgroup_size") }
        if datasetThreadgroupSize != nil { result.append("dataset_threadgroup_size") }
        if batchNonces != nil { result.append("batch_nonces") }
        if prebuildBatchNonces != nil { result.append("prebuild_batch_nonces") }
        if synchronousBuildChunkElements != nil { result.append("build_chunk_elements") }
        if prefetchBuildChunkElements != nil { result.append("prefetch_chunk_elements") }
        if searchPipelineDepth != nil { result.append("search_pipeline_depth") }
        if buildPipelineDepth != nil { result.append("build_pipeline_depth") }
        return result
    }
}

public struct AutotuneCacheIdentity: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let algorithmVersion = 1

    public let binarySHA256: String
    public let fingerprint: GPUArchitectureFingerprint
    public let profile: PerformanceProfile
    public let normalizedOverrides: String
    public let workloadSignature: String

    public init(
        binarySHA256: String,
        fingerprint: GPUArchitectureFingerprint,
        profile: PerformanceProfile,
        normalizedOverrides: String,
        workloadSignature: String
    ) {
        self.binarySHA256 = binarySHA256
        self.fingerprint = fingerprint
        self.profile = profile
        self.normalizedOverrides = normalizedOverrides
        self.workloadSignature = workloadSignature
    }

    public var key: String {
        let canonical = [
            "schema=\(Self.schemaVersion)",
            "algorithm=\(Self.algorithmVersion)",
            "binary=\(binarySHA256)",
            "os=\(fingerprint.operatingSystemBuild)",
            "architecture=\(fingerprint.architectureName)",
            "name=\(fingerprint.deviceName)",
            "family=\(fingerprint.familyName)",
            "searchWidth=\(fingerprint.searchThreadExecutionWidth)",
            "searchLimit=\(fingerprint.searchMaxThreadsPerThreadgroup)",
            "buildWidth=\(fingerprint.buildThreadExecutionWidth)",
            "buildLimit=\(fingerprint.buildMaxThreadsPerThreadgroup)",
            "profile=\(profile.rawValue)",
            "overrides=\(normalizedOverrides)",
            "workload=\(workloadSignature)"
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct AutotuneRecord: Codable, Equatable, Sendable {
    public let identity: AutotuneCacheIdentity
    public let configuration: MetalExecutionConfiguration
    public let measurements: [String: Double]
    public let tunedAt: Date

    public init(
        identity: AutotuneCacheIdentity,
        configuration: MetalExecutionConfiguration,
        measurements: [String: Double],
        tunedAt: Date = Date()
    ) {
        self.identity = identity
        self.configuration = configuration
        self.measurements = measurements
        self.tunedAt = tunedAt
    }
}

public final class AutotuneCacheStore: @unchecked Sendable {
    private struct Envelope: Codable {
        let schemaVersion: Int
        var records: [AutotuneRecord]
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dev.ergometal/autotune-v1.json")
    }

    public let url: URL

    public init(url: URL = AutotuneCacheStore.defaultURL) {
        self.url = url
    }

    public func load(identity: AutotuneCacheIdentity) -> AutotuneRecord? {
        let result: AutotuneRecord?? = withLock { () -> AutotuneRecord? in
            guard let data = try? Data(contentsOf: url),
                  let envelope = try? Self.decoder().decode(Envelope.self, from: data),
                  envelope.schemaVersion == AutotuneCacheIdentity.schemaVersion
            else { return nil }
            return envelope.records.first {
                $0.identity == identity && $0.configuration.isValid(for: identity.fingerprint)
            }
        }
        return result ?? nil
    }

    @discardableResult
    public func save(_ record: AutotuneRecord) -> Bool {
        guard record.configuration.isValid(for: record.identity.fingerprint) else { return false }
        return withLock {
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                var records: [AutotuneRecord] = []
                if let data = try? Data(contentsOf: url),
                   let existing = try? Self.decoder().decode(Envelope.self, from: data),
                   existing.schemaVersion == AutotuneCacheIdentity.schemaVersion {
                    records = existing.records
                }
                records.removeAll { $0.identity == record.identity }
                records.append(record)
                records.sort { $0.tunedAt > $1.tunedAt }
                if records.count > 128 { records.removeLast(records.count - 128) }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(Envelope(
                    schemaVersion: AutotuneCacheIdentity.schemaVersion,
                    records: records))
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
                return true
            } catch {
                return false
            }
        } ?? false
    }

    private func withLock<T>(_ body: () -> T) -> T? {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum AutotuningPolicy {
    public static let minimumImprovement = 0.02

    public static func threadgroupCandidates(width: Int, limit: Int) -> [Int] {
        let width = max(1, width)
        return [64, 128, 256].filter { $0 <= limit && $0.isMultiple(of: width) }
    }

    public static let efficiencyBatchCandidates = [131_072, 262_144, 524_288]
    public static let peakBatchCandidates = [524_288, 1_048_576, 2_097_152, 4_194_304]
    public static let prebuildBatchCandidates = [32_768, 65_536, 131_072]
    public static let synchronousChunkCandidates = [524_288, 1_048_576, 2_097_152, 4_194_304]
    public static let prefetchChunkCandidates = [262_144, 524_288, 1_048_576, 2_097_152]
    public static let pipelineDepthCandidates = [1, 2, 3, 4]

    public static func batchCandidates(profile: PerformanceProfile) -> [Int] {
        profile == .peak ? peakBatchCandidates : efficiencyBatchCandidates
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }

    public static func isMeaningfulImprovement(
        baseline: [Double], candidate: [Double],
        threshold: Double = minimumImprovement
    ) -> Bool {
        let baselineMedian = median(baseline)
        guard baselineMedian > 0 else { return false }
        return median(candidate) >= baselineMedian * (1 + threshold)
    }
}

public struct AutotuningBudget: Sendable {
    public let deadline: Date

    public init(seconds: TimeInterval, now: Date = Date()) {
        self.deadline = now.addingTimeInterval(seconds)
    }

    public func hasTimeRemaining(at date: Date = Date()) -> Bool {
        date < deadline
    }
}

public enum AutotuningSafety {
    public static func shouldAbort(thermalState: ProcessInfo.ThermalState) -> Bool {
        thermalState == .serious || thermalState == .critical
    }
}
