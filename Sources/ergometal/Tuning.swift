import Foundation
import CryptoKit
import Metal
import MetalErgoCore

struct CLITuningResolution {
    let resolved: ResolvedTuning
    let fingerprint: GPUArchitectureFingerprint
    let mode: AutotuneMode
    let cacheURL: URL
    let cacheWritten: Bool
    let measurements: [String: Double]
}

private enum LiveAutotuneError: Error, LocalizedError {
    case budgetExpired
    case thermalState(ProcessInfo.ThermalState)
    case consensusMismatch
    case invalidMeasurement(String)

    var errorDescription: String? {
        switch self {
        case .budgetExpired: return "autotuning budget expired"
        case .thermalState(let state): return "autotuning stopped at thermal state \(state.rawValue)"
        case .consensusMismatch: return "an autotuning candidate failed the Metal/CPU consensus check"
        case .invalidMeasurement(let message): return "autotuning measurement invalid: \(message)"
        }
    }
}

enum CLITuning {
    static let valueOptions: Set<String> = [
        "autotune", "autotune-budget", "autotune-cache",
        "batch-nonces", "prebuild-batch-nonces", "threadgroup-size",
        "dataset-threadgroup-size", "build-chunk-elements",
        "prefetch-chunk-elements", "search-pipeline-depth", "build-pipeline-depth"
    ]

    static func profile(from args: Arguments) throws -> PerformanceProfile {
        let raw = args.string("profile", default: PerformanceProfile.efficiency.rawValue)!
        guard let profile = PerformanceProfile(rawValue: raw) else {
            throw CLIError.invalidArgument("--profile must be efficiency|peak")
        }
        return profile
    }

    static func mode(from args: Arguments) throws -> AutotuneMode {
        let raw = args.string("autotune", default: AutotuneMode.auto.rawValue)!
        guard let mode = AutotuneMode(rawValue: raw) else {
            throw CLIError.invalidArgument("--autotune must be auto|refresh|off")
        }
        return mode
    }

    static func cacheURL(from args: Arguments) -> URL {
        guard let raw = args.string("autotune-cache") else {
            return AutotuneCacheStore.defaultURL
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func overrides(from args: Arguments) throws -> MetalExecutionOverrides {
        MetalExecutionOverrides(
            searchThreadgroupSize: try args.optionalInt("threadgroup-size", in: 1...1_024),
            datasetThreadgroupSize: try args.optionalInt(
                "dataset-threadgroup-size", in: 1...1_024),
            batchNonces: try args.optionalInt("batch-nonces", in: 1...16_777_216),
            prebuildBatchNonces: try args.optionalInt(
                "prebuild-batch-nonces", in: 1...16_777_216),
            synchronousBuildChunkElements: try args.optionalInt(
                "build-chunk-elements", in: 1...16_777_216),
            prefetchBuildChunkElements: try args.optionalInt(
                "prefetch-chunk-elements", in: 1...16_777_216),
            searchPipelineDepth: try args.optionalInt("search-pipeline-depth", in: 1...4),
            buildPipelineDepth: try args.optionalInt("build-pipeline-depth", in: 1...4))
    }

    static func resolve(
        args: Arguments,
        profile: PerformanceProfile,
        datasetKernel: DatasetKernel,
        datasetScheduling: DatasetScheduling,
        searchKernel: SearchKernel,
        forceRefresh: Bool = false
    ) throws -> CLITuningResolution {
        let requestedMode = try mode(from: args)
        let mode: AutotuneMode = forceRefresh ? .refresh : requestedMode
        let budget = try args.int("autotune-budget", default: 120, in: 30...600)
        let overrides = try overrides(from: args)
        let fallback = MetalExecutionConfiguration.safeFallback(profile: profile)
        let probe = try MetalAutolykosSolver(
            searchThreadgroupSize: 1_024,
            datasetThreadgroupSize: 1_024,
            searchPipelineDepth: 1,
            buildPipelineDepth: 1,
            datasetKernel: datasetKernel,
            datasetScheduling: datasetScheduling,
            searchKernel: searchKernel)
        let fingerprint = fingerprint(for: probe.info)
        try validate(overrides: overrides, fingerprint: fingerprint)
        let cacheURL = cacheURL(from: args)
        let identity = AutotuneCacheIdentity(
            binarySHA256: executableSHA256() ?? "unavailable",
            fingerprint: fingerprint,
            profile: profile,
            normalizedOverrides: overrides.normalized,
            workloadSignature: [datasetKernel.rawValue, datasetScheduling.rawValue,
                                searchKernel.rawValue].joined(separator: "/"))

        if mode == .off {
            return CLITuningResolution(
                resolved: MetalTuningResolver.resolve(
                    profile: profile, overrides: overrides, cacheKey: nil),
                fingerprint: fingerprint, mode: mode,
                cacheURL: cacheURL, cacheWritten: false, measurements: [:])
        }

        let cache = AutotuneCacheStore(url: cacheURL)
        if mode == .auto, let record = cache.load(identity: identity) {
            return CLITuningResolution(
                resolved: MetalTuningResolver.resolve(
                    profile: profile, cached: record.configuration,
                    overrides: overrides, cacheKey: identity.key),
                fingerprint: fingerprint, mode: mode,
                cacheURL: cacheURL, cacheWritten: false,
                measurements: record.measurements)
        }

        if overrides.isComplete {
            return CLITuningResolution(
                resolved: MetalTuningResolver.resolve(
                    profile: profile, overrides: overrides, cacheKey: identity.key),
                fingerprint: fingerprint, mode: mode,
                cacheURL: cacheURL, cacheWritten: false, measurements: [:])
        }

        writeProgress("Autotuning \(fingerprint.deviceName) [\(fingerprint.architectureName), \(fingerprint.familyName)] for \(profile.rawValue), budget \(budget)s")
        do {
            let tuner = LiveMetalAutotuner(
                profile: profile,
                initial: overrides.applying(to: fallback),
                fixed: overrides,
                datasetKernel: datasetKernel,
                datasetScheduling: datasetScheduling,
                searchKernel: searchKernel,
                budget: AutotuningBudget(seconds: Double(budget)),
                fingerprint: fingerprint)
            let outcome = try tuner.run()
            let record = AutotuneRecord(
                identity: identity,
                configuration: outcome.configuration,
                measurements: outcome.measurements)
            let written = cache.save(record)
            if !written { writeProgress("warning: autotuning cache could not be written") }
            return CLITuningResolution(
                resolved: MetalTuningResolver.resolve(
                    profile: profile, tuned: outcome.configuration,
                    overrides: overrides, cacheKey: identity.key),
                fingerprint: fingerprint, mode: mode,
                cacheURL: cacheURL, cacheWritten: written,
                measurements: outcome.measurements)
        } catch {
            if mode == .refresh { throw error }
            writeProgress("warning: \(error.localizedDescription); using the safe fallback")
            return CLITuningResolution(
                resolved: MetalTuningResolver.resolve(
                    profile: profile, overrides: overrides, cacheKey: identity.key),
                fingerprint: fingerprint, mode: mode,
                cacheURL: cacheURL, cacheWritten: false, measurements: [:])
        }
    }

    private static func validate(
        overrides: MetalExecutionOverrides,
        fingerprint: GPUArchitectureFingerprint
    ) throws {
        if let value = overrides.searchThreadgroupSize,
           value > fingerprint.searchMaxThreadsPerThreadgroup ||
            !value.isMultiple(of: fingerprint.searchThreadExecutionWidth) {
            throw CLIError.invalidArgument(
                "--threadgroup-size must be a multiple of \(fingerprint.searchThreadExecutionWidth) and no greater than \(fingerprint.searchMaxThreadsPerThreadgroup)")
        }
        if let value = overrides.datasetThreadgroupSize,
           value > fingerprint.buildMaxThreadsPerThreadgroup ||
            !value.isMultiple(of: fingerprint.buildThreadExecutionWidth) {
            throw CLIError.invalidArgument(
                "--dataset-threadgroup-size must be a multiple of \(fingerprint.buildThreadExecutionWidth) and no greater than \(fingerprint.buildMaxThreadsPerThreadgroup)")
        }
    }

    private static func fingerprint(for info: MetalDeviceInfo) -> GPUArchitectureFingerprint {
        GPUArchitectureFingerprint(
            deviceName: info.name,
            architectureName: info.architectureName,
            highestKnownAppleFamily: info.highestKnownAppleFamily,
            searchThreadExecutionWidth: info.searchThreadExecutionWidth ?? 32,
            searchMaxThreadsPerThreadgroup: info.searchPipelineMaxThreads ?? 1_024,
            buildThreadExecutionWidth: info.buildThreadExecutionWidth ?? 32,
            buildMaxThreadsPerThreadgroup: info.buildPipelineMaxThreads ?? 1_024,
            operatingSystemBuild: GPUArchitectureFingerprint.operatingSystemBuild())
    }

    private static func executableSHA256() -> String? {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return SHA256Digest.hex(data)
    }

    private static func writeProgress(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        // CryptoKit stays in the executable target; the core uses the same
        // digest construction for cache identities.
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class LiveMetalAutotuner {
    struct Outcome {
        let configuration: MetalExecutionConfiguration
        let measurements: [String: Double]
    }

    private let profile: PerformanceProfile
    private let fixed: MetalExecutionOverrides
    private let datasetKernel: DatasetKernel
    private let datasetScheduling: DatasetScheduling
    private let searchKernel: SearchKernel
    private let budget: AutotuningBudget
    private let fingerprint: GPUArchitectureFingerprint
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var configuration: MetalExecutionConfiguration
    private var measurements: [String: Double] = [:]
    private var nonce: UInt64 = 0

    init(
        profile: PerformanceProfile,
        initial: MetalExecutionConfiguration,
        fixed: MetalExecutionOverrides,
        datasetKernel: DatasetKernel,
        datasetScheduling: DatasetScheduling,
        searchKernel: SearchKernel,
        budget: AutotuningBudget,
        fingerprint: GPUArchitectureFingerprint
    ) {
        self.profile = profile
        self.configuration = initial
        self.fixed = fixed
        self.datasetKernel = datasetKernel
        self.datasetScheduling = datasetScheduling
        self.searchKernel = searchKernel
        self.budget = budget
        self.fingerprint = fingerprint
    }

    func run() throws -> Outcome {
        var completed = true
        do {
            try checkEnvironment()
            if fixed.datasetThreadgroupSize == nil {
                try select(
                    label: "dataset_threadgroup_size",
                    candidates: AutotuningPolicy.threadgroupCandidates(
                        width: fingerprint.buildThreadExecutionWidth,
                        limit: min(256, fingerprint.buildMaxThreadsPerThreadgroup)),
                    set: { $0.datasetThreadgroupSize = $1 }, measure: measureBuild)
            }
            if fixed.synchronousBuildChunkElements == nil {
                try select(label: "build_chunk_elements",
                    candidates: AutotuningPolicy.synchronousChunkCandidates,
                    set: { $0.synchronousBuildChunkElements = $1 }, measure: measureBuild)
            }
            if fixed.buildPipelineDepth == nil {
                try select(label: "build_pipeline_depth",
                    candidates: AutotuningPolicy.pipelineDepthCandidates,
                    set: { $0.buildPipelineDepth = $1 }, measure: measureBuild)
            }
            if fixed.searchThreadgroupSize == nil {
                try select(
                    label: "search_threadgroup_size",
                    candidates: AutotuningPolicy.threadgroupCandidates(
                        width: fingerprint.searchThreadExecutionWidth,
                        limit: min(256, fingerprint.searchMaxThreadsPerThreadgroup)),
                    set: { $0.searchThreadgroupSize = $1 }, measure: measureSearch)
            }
            if fixed.batchNonces == nil {
                try select(label: "batch_nonces",
                    candidates: AutotuningPolicy.batchCandidates(profile: profile),
                    set: { $0.batchNonces = $1 }, measure: measureSearch)
            }
            if fixed.searchPipelineDepth == nil {
                try select(label: "search_pipeline_depth",
                    candidates: AutotuningPolicy.pipelineDepthCandidates,
                    set: { $0.searchPipelineDepth = $1 }, measure: measureSearch)
            }
            if fixed.prefetchBuildChunkElements == nil {
                try select(label: "prefetch_chunk_elements",
                    candidates: AutotuningPolicy.prefetchChunkCandidates,
                    set: { $0.prefetchBuildChunkElements = $1 }, measure: measurePrefetch)
            }
            if fixed.prebuildBatchNonces == nil {
                try select(label: "prebuild_batch_nonces",
                    candidates: AutotuningPolicy.prebuildBatchCandidates,
                    set: { $0.prebuildBatchNonces = $1 }, measure: measureOverlap)
            }
        } catch LiveAutotuneError.budgetExpired {
            measurements["budget_expired"] = 1
            completed = false
        }
        measurements["autotune.complete"] = completed ? 1 : 0
        measurements["autotune.elapsed_seconds"] =
            ProcessInfo.processInfo.systemUptime - startedAt
        return Outcome(configuration: configuration, measurements: measurements)
    }

    private func select(
        label: String,
        candidates: [Int],
        set: (inout MetalExecutionConfiguration, Int) -> Void,
        measure: (MetalExecutionConfiguration) throws -> Double
    ) throws {
        for value in candidates {
            try checkEnvironment()
            var candidate = configuration
            set(&candidate, value)
            guard candidate != configuration else { continue }
            let a1 = try measure(configuration)
            let b1 = try measure(candidate)
            let b2 = try measure(candidate)
            let a2 = try measure(configuration)
            let baseline = [a1, a2]
            let contender = [b1, b2]
            let baselineMedian = AutotuningPolicy.median(baseline)
            let candidateMedian = AutotuningPolicy.median(contender)
            let ratio = candidateMedian / max(baselineMedian, .leastNonzeroMagnitude)
            measurements["\(label).\(value).baseline"] = baselineMedian
            measurements["\(label).\(value).candidate"] = candidateMedian
            measurements["\(label).\(value).ratio"] = ratio
            if AutotuningPolicy.isMeaningfulImprovement(
                baseline: baseline, candidate: contender) {
                configuration = candidate
            }
        }
    }

    private func makeSolver(_ value: MetalExecutionConfiguration) throws -> MetalAutolykosSolver {
        try MetalAutolykosSolver(
            synchronousBuildChunkElements: value.synchronousBuildChunkElements,
            prefetchBuildChunkElements: value.prefetchBuildChunkElements,
            searchThreadgroupSize: value.searchThreadgroupSize,
            datasetThreadgroupSize: value.datasetThreadgroupSize,
            searchPipelineDepth: value.searchPipelineDepth,
            buildPipelineDepth: value.buildPipelineDepth,
            datasetKernel: datasetKernel,
            datasetScheduling: datasetScheduling,
            searchKernel: searchKernel)
    }

    private func measureBuild(_ value: MetalExecutionConfiguration) throws -> Double {
        try checkEnvironment()
        let tableSize = 4_194_304
        let solver = try makeSolver(value)
        let build = try buildDataset(solver, height: 614_400, tableSize: tableSize)
        try verifyConsensus(solver: solver, height: 614_400, tableSize: tableSize)
        try checkEnvironment()
        return Double(tableSize) / max(build.seconds, .leastNonzeroMagnitude)
    }

    private func measureSearch(_ value: MetalExecutionConfiguration) throws -> Double {
        try checkEnvironment()
        let tableSize = 4_194_304
        let solver = try makeSolver(value)
        _ = try buildDataset(solver, height: 614_400, tableSize: tableSize)
        try verifyConsensus(solver: solver, height: 614_400, tableSize: tableSize)
        let message = Blake2b256.hash(Array("ergometal-autotune-search".utf8))
        let target = UInt256.zero
        _ = try solver.search(
            message: message, target: target, baseNonce: nonce,
            nonceCount: min(value.batchNonces, 262_144),
            threadgroupSize: value.searchThreadgroupSize)
        let commandCount = max(4, value.searchPipelineDepth * 2)
        var pending: [SearchSubmission] = []
        defer { for submission in pending { _ = try? submission.wait() } }
        var submitted = 0
        var completedNonces = 0
        let started = ProcessInfo.processInfo.systemUptime
        while submitted < commandCount || !pending.isEmpty {
            try checkEnvironment()
            while submitted < commandCount && pending.count < value.searchPipelineDepth {
                pending.append(try solver.enqueueSearch(
                    message: message, target: target, baseNonce: nonce,
                    nonceCount: value.batchNonces,
                    threadgroupSize: value.searchThreadgroupSize))
                nonce &+= UInt64(value.batchNonces)
                submitted += 1
            }
            if !pending.isEmpty { completedNonces += try pending.removeFirst().wait().nonceCount }
        }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        try checkEnvironment()
        return Double(completedNonces) / max(seconds, .leastNonzeroMagnitude)
    }

    private func measurePrefetch(_ value: MetalExecutionConfiguration) throws -> Double {
        try checkEnvironment()
        let activeTableSize = 1_048_576
        let prefetchTableSize = 4_194_304
        let solver = try makeSolver(value)
        _ = try buildDataset(solver, height: 614_400, tableSize: activeTableSize)
        guard try solver.prefetchDataset(height: 614_401, tableSize: prefetchTableSize) else {
            throw LiveAutotuneError.invalidMeasurement("prefetch did not start")
        }
        defer { solver.cancelPrefetch(waitUntilFinished: true) }
        while solver.prefetchStatus()?.finished == false {
            try checkEnvironment()
            Thread.sleep(forTimeInterval: 0.005)
        }
        let status = solver.prefetchStatus()
        guard let status else {
            throw LiveAutotuneError.invalidMeasurement("prefetch status disappeared")
        }
        guard let seconds = status.seconds, status.errorDescription == nil else {
            let reason = status.errorDescription ?? "missing timing"
            throw LiveAutotuneError.invalidMeasurement(
                "prefetch failed: \(reason)")
        }
        _ = try buildDataset(solver, height: 614_401, tableSize: prefetchTableSize)
        return Double(prefetchTableSize) / max(seconds, .leastNonzeroMagnitude)
    }

    private func measureOverlap(_ value: MetalExecutionConfiguration) throws -> Double {
        try checkEnvironment()
        let solver = try makeSolver(value)
        let activeTableSize = 4_194_304
        let prefetchTableSize = 16_777_216
        _ = try buildDataset(solver, height: 614_400, tableSize: activeTableSize)
        try verifyConsensus(solver: solver, height: 614_400, tableSize: activeTableSize)
        guard try solver.prefetchDataset(height: 614_401, tableSize: prefetchTableSize) else {
            throw LiveAutotuneError.invalidMeasurement("overlap prefetch did not start")
        }
        defer { solver.cancelPrefetch(waitUntilFinished: true) }
        let message = Blake2b256.hash(Array("ergometal-autotune-overlap".utf8))
        let requestedNonces = 2_097_152
        var submitted = 0
        var completed = 0
        var pending: [SearchSubmission] = []
        defer { for submission in pending { _ = try? submission.wait() } }
        let started = ProcessInfo.processInfo.systemUptime
        while submitted < requestedNonces || !pending.isEmpty {
            while submitted < requestedNonces && pending.count < value.searchPipelineDepth {
                let count = min(value.prebuildBatchNonces, requestedNonces - submitted)
                pending.append(try solver.enqueueSearch(
                    message: message, target: .zero, baseNonce: nonce,
                    nonceCount: count,
                    threadgroupSize: value.searchThreadgroupSize))
                nonce &+= UInt64(count)
                submitted += count
            }
            if !pending.isEmpty { completed += try pending.removeFirst().wait().nonceCount }
            try checkEnvironment()
        }
        guard let status = solver.prefetchStatus() else {
            throw LiveAutotuneError.invalidMeasurement("overlap prefetch status disappeared")
        }
        guard status.errorDescription == nil else {
            throw LiveAutotuneError.invalidMeasurement(
                "overlap prefetch failed: \(status.errorDescription!)")
        }
        guard !status.finished else {
            throw LiveAutotuneError.invalidMeasurement(
                "overlap prefetch finished before the search window")
        }
        guard status.completedElements > 0 else {
            throw LiveAutotuneError.invalidMeasurement(
                "overlap prefetch made no progress during the search window")
        }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let searchRate = Double(completed) / max(seconds, .leastNonzeroMagnitude)
        let buildRate = Double(status.completedElements) /
            max(seconds, .leastNonzeroMagnitude)
        let searchWeight = profile == .peak ? 0.7 : 0.5
        return exp(searchWeight * log(searchRate) + (1 - searchWeight) * log(buildRate))
    }

    /// The solver drains already submitted chunks when cancellation is
    /// requested. Preserve the budget/thermal reason for the tuning policy.
    private func buildDataset(
        _ solver: MetalAutolykosSolver, height: Int, tableSize: Int
    ) throws -> DatasetBuild {
        try checkEnvironment()
        var interruption: Error?
        do {
            return try solver.buildDataset(height: height, tableSize: tableSize,
                shouldContinue: {
                    do { try self.checkEnvironment(); return true }
                    catch { interruption = error; return false }
                })
        } catch MetalSolverError.cancelled {
            throw interruption ?? MetalSolverError.cancelled
        }
    }

    private func verifyConsensus(
        solver: MetalAutolykosSolver,
        height: Int,
        tableSize: Int
    ) throws {
        if searchKernel == .gatherOnly {
            let indices = [0, min(1, tableSize - 1), tableSize - 1]
            let actual = try solver.datasetElements(at: indices)
            let expected = try indices.map {
                try AutolykosV2.datasetElement(index: $0, height: height)
            }
            guard actual == expected else {
                throw LiveAutotuneError.consensusMismatch
            }
            return
        }
        let message = Blake2b256.hash(Array("ergometal-autotune-consensus".utf8))
        let nonceValue: UInt64 = 42
        let nonceBytes = stride(from: 56, through: 0, by: -8).map {
            UInt8(truncatingIfNeeded: nonceValue >> UInt64($0))
        }
        let hit = try AutolykosV2.hit(
            message: message, nonce: nonceBytes, height: height, tableSize: tableSize)
        var limbs = hit.limbs
        guard limbs[7] < UInt32.max else { throw LiveAutotuneError.consensusMismatch }
        limbs[7] += 1
        let result = try solver.search(
            message: message, target: UInt256(limbs: limbs),
            baseNonce: nonceValue, nonceCount: 1,
            threadgroupSize: configuration.searchThreadgroupSize)
        guard result.candidates == [nonceValue] else {
            throw LiveAutotuneError.consensusMismatch
        }
    }

    private func checkEnvironment() throws {
        guard budget.hasTimeRemaining() else { throw LiveAutotuneError.budgetExpired }
        let state = ProcessInfo.processInfo.thermalState
        if AutotuningSafety.shouldAbort(thermalState: state) {
            throw LiveAutotuneError.thermalState(state)
        }
    }
}
