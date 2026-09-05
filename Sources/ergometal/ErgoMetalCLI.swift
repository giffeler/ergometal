import Foundation
import CryptoKit
import Darwin
import MetalErgoCore

@main
enum ErgoMetalCLI {
    private static let searchStatisticsBatchCount = 16
    private static let donationPool = "stratum+tls://erg.2miners.com:18888"
    private static let donationWallet = "9emWVfBsLPbV6dvpugpjsjwKwETT7yBBfCyMefXbZDory7kDUVg"
    private static let donationWorker = "ergometal"
    private enum PrebuildMode: String {
        case auto
        case on
        case off
    }
    private enum GPUTracePhase: String {
        case build
        case search
    }

    private struct SearchStatisticsSample {
        let nonces: Int
        let gpuSeconds: Double
        let activeSearchSeconds: Double
    }

    /// Search command buffers can overlap on Apple GPUs. Aggregate a short
    /// rolling command window and merge submit-to-completion intervals so
    /// active time is neither counted twice nor exposed as callback jitter.
    private struct SearchStatisticsAccumulator {
        private var nonces = 0
        private var batchCount = 0
        private var wallIntervals: [(start: TimeInterval, end: TimeInterval)] = []
        private var gpuSeconds = 0.0
        private var accountedWallEnd: TimeInterval?

        mutating func append(
            _ batch: SearchBatch,
            flush: Bool = false
        ) -> SearchStatisticsSample? {
            nonces += batch.nonceCount
            batchCount += 1
            gpuSeconds += max(0, batch.gpuSeconds)
            if batch.wallEndTime > batch.wallStartTime {
                wallIntervals.append((batch.wallStartTime, batch.wallEndTime))
            }
            return batchCount >= ErgoMetalCLI.searchStatisticsBatchCount || flush ? take() : nil
        }

        mutating func flush() -> SearchStatisticsSample? {
            batchCount == 0 ? nil : take()
        }

        private mutating func take() -> SearchStatisticsSample {
            let ordered = wallIntervals.sorted { $0.start < $1.start }
            var activeSearchSeconds = 0.0
            var cursor = accountedWallEnd
            for interval in ordered {
                if let cursor, interval.end <= cursor { continue }
                let start = cursor.map { max($0, interval.start) } ?? interval.start
                if interval.end > start {
                    activeSearchSeconds += interval.end - start
                }
                cursor = max(cursor ?? interval.end, interval.end)
            }
            accountedWallEnd = cursor
            let sample = SearchStatisticsSample(
                nonces: nonces,
                gpuSeconds: gpuSeconds,
                activeSearchSeconds: max(0, activeSearchSeconds))
            nonces = 0
            batchCount = 0
            wallIntervals.removeAll(keepingCapacity: true)
            gpuSeconds = 0
            return sample
        }
    }

    static func main() {
        do {
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            switch args.command {
            case "devices": try devices(args)
            case "temperature": try temperature(args)
            case "tune": try tune(args)
            case "benchmark": try benchmark(args)
            case "replay": try replay(args)
            case "mine": try mine(args)
            case "help", "--help", "-h": print(usage)
            default: throw CLIError.invalidArgument(args.command)
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n\n\(usage)\n", stderr)
            Foundation.exit(2)
        }
    }

    private static func devices(_ args: Arguments) throws {
        try args.validate(flagOptions: ["json"])
        let devices = MetalAutolykosSolver.devices()
        if args.has("json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(devices)); print()
        } else if devices.isEmpty {
            print("No Metal devices found")
        } else {
            for d in devices {
                let family = d.highestKnownAppleFamily.map { "apple\($0)" } ?? "unknown"
                print("\(d.name)  architecture=\(d.architectureName)  generation=\(d.generation.rawValue)  family=\(family)  unified=\(d.unifiedMemory)  working-set=\(formatBytes(d.recommendedWorkingSetBytes))  max-buffer=\(formatBytes(d.maxBufferBytes))")
            }
        }
    }

    private static func temperature(_ args: Arguments) throws {
        try args.validate(flagOptions: ["json"])
        let sample = SoCTemperatureTelemetry.sample()
        if args.has("json") {
            if let sample {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(sample)); print()
            } else {
                print("null")
            }
        } else if let sample {
            print(String(format: "%.1f C", sample.maximumCelsius))
        } else {
            print("SoC temperature unavailable")
        }
    }

    private struct TuneReport: Codable {
        let profile: PerformanceProfile
        let fingerprint: GPUArchitectureFingerprint
        let resolved: ResolvedTuning
        let cachePath: String
        let cacheWritten: Bool
        let measurements: [String: Double]
    }

    private static func tune(_ args: Arguments) throws {
        try args.validate(
            valueOptions: CLITuning.valueOptions.union([
                "profile", "dataset-kernel", "dataset-scheduling", "search-kernel"
            ]),
            flagOptions: ["json"])
        let rawProfile = args.string("profile", default: "all")!
        let profiles: [PerformanceProfile]
        if rawProfile == "all" {
            profiles = PerformanceProfile.allCases
        } else if let profile = PerformanceProfile(rawValue: rawProfile) {
            profiles = [profile]
        } else {
            throw CLIError.invalidArgument("--profile must be efficiency|peak|all")
        }
        let datasetKernel = try datasetKernel(from: args)
        let datasetScheduling = try datasetScheduling(from: args)
        let searchKernel = try searchKernel(from: args)
        var reports: [TuneReport] = []
        for profile in profiles {
            let result = try CLITuning.resolve(
                args: args, profile: profile,
                datasetKernel: datasetKernel,
                datasetScheduling: datasetScheduling,
                searchKernel: searchKernel,
                forceRefresh: true)
            reports.append(TuneReport(
                profile: profile,
                fingerprint: result.fingerprint,
                resolved: result.resolved,
                cachePath: result.cacheURL.path,
                cacheWritten: result.cacheWritten,
                measurements: result.measurements))
        }
        if args.has("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(reports))
            print()
        } else {
            for report in reports {
                let value = report.resolved.configuration
                print("\(report.profile.rawValue): \(report.fingerprint.deviceName) \(report.fingerprint.architectureName) \(report.fingerprint.familyName)")
                print("  search: tg=\(value.searchThreadgroupSize) batch=\(value.batchNonces) depth=\(value.searchPipelineDepth)")
                print("  dataset: tg=\(value.datasetThreadgroupSize) cold-chunk=\(value.synchronousBuildChunkElements) prefetch-chunk=\(value.prefetchBuildChunkElements) prebuild-batch=\(value.prebuildBatchNonces) depth=\(value.buildPipelineDepth)")
                print("  measurements: \(report.measurements.count)")
                print("  cache: \(report.cachePath) written=\(report.cacheWritten)")
            }
        }
    }

    private static func benchmark(_ args: Arguments) throws {
        try args.validate(
            valueOptions: ["duration", "height", "profile", "table-size", "batch-nonces",
                           "height-interval",
                           "prebuild", "prebuild-batch-nonces", "threadgroup-size",
                           "build-chunk-elements", "prefetch-chunk-elements",
                           "search-pipeline-depth", "build-pipeline-depth",
                           "autotune", "autotune-budget", "autotune-cache",
                           "dataset-threadgroup-size",
                           "dataset-kernel", "dataset-scheduling", "search-kernel",
                           "api-bind", "stats-file",
                           "gpu-trace", "gpu-trace-phase"],
            flagOptions: ["json"])
        let duration = try args.int("duration", default: 60, in: 1...Int.max)
        let height = try args.int("height", default: 614_399, in: 0...Int(UInt32.max))
        let heightInterval = try args.int(
            "height-interval", default: 0, in: 0...Int.max)
        let tableOverride = try args.optionalInt("table-size", in: 1...Int(UInt32.max))
        let profile = try CLITuning.profile(from: args)
        let profileName = profile.rawValue
        let prebuildValue = args.string("prebuild", default: "off")!
        guard prebuildValue == "on" || prebuildValue == "off" else {
            throw CLIError.invalidArgument("--prebuild \(prebuildValue)")
        }
        if heightInterval > 0, prebuildValue != "on" {
            throw CLIError.invalidArgument("--height-interval requires --prebuild on")
        }
        if prebuildValue == "on" {
            let heightTransitions = heightInterval > 0
                ? (duration - 1) / heightInterval
                : 0
            let lastPrefetchHeight = UInt64(height) + UInt64(heightTransitions) + 1
            if lastPrefetchHeight > UInt64(UInt32.max) {
                throw CLIError.invalidArgument(
                    "benchmark height range including prefetch must fit UInt32")
            }
        }
        let datasetKernel = try datasetKernel(from: args)
        let datasetScheduling = try datasetScheduling(from: args)
        let searchKernel = try searchKernel(from: args)
        let tuning = try CLITuning.resolve(
            args: args, profile: profile,
            datasetKernel: datasetKernel,
            datasetScheduling: datasetScheduling,
            searchKernel: searchKernel)
        let execution = tuning.resolved.configuration
        let batchSize = execution.batchNonces
        let prebuildBatchSize = execution.prebuildBatchNonces
        let group = execution.searchThreadgroupSize
        let buildChunkElements = execution.synchronousBuildChunkElements
        let prefetchChunkElements = execution.prefetchBuildChunkElements
        let datasetThreadgroupSize = execution.datasetThreadgroupSize
        let tracePath = args.string("gpu-trace")
        let tracePhaseValue = args.string("gpu-trace-phase", default: "search")!
        guard let tracePhase = GPUTracePhase(rawValue: tracePhaseValue) else {
            throw CLIError.invalidArgument("--gpu-trace-phase \(tracePhaseValue)")
        }
        if tracePath == nil, args.string("gpu-trace-phase") != nil {
            throw CLIError.invalidArgument("--gpu-trace-phase requires --gpu-trace")
        }
        let solver = try MetalAutolykosSolver(
            synchronousBuildChunkElements: buildChunkElements,
            prefetchBuildChunkElements: prefetchChunkElements,
            searchThreadgroupSize: group,
            datasetThreadgroupSize: datasetThreadgroupSize,
            searchPipelineDepth: execution.searchPipelineDepth,
            buildPipelineDepth: execution.buildPipelineDepth,
            datasetKernel: datasetKernel,
            datasetScheduling: datasetScheduling,
            searchKernel: searchKernel)
        defer { solver.stopGPUCapture() }
        let stats = StatisticsStore(
            mode: .benchmark, profile: profileName, device: solver.info,
            autotuneMode: tuning.mode, tuning: tuning.resolved)
        let writer = JSONLEventWriter(path: args.string("stats-file"))
        let server = StatisticsHTTPServer(store: stats)
        try server.start(bind: args.string("api-bind", default: "127.0.0.1:4078")!)
        defer { server.stop() }
        writer.write(MinerEvent(
            sessionID: stats.snapshot().sessionID,
            type: "session_started",
            fields: runMetadataFields(
                profile: profileName,
                prebuild: prebuildValue,
                batchSize: batchSize,
                prebuildBatchSize: prebuildBatchSize,
                threadgroupSize: group,
                buildChunkElements: buildChunkElements,
                prefetchChunkElements: prefetchChunkElements,
                datasetThreadgroupSize: datasetThreadgroupSize,
                datasetKernel: datasetKernel,
                datasetScheduling: datasetScheduling,
                tuning: tuning,
                extra: [
                    "mode": "benchmark",
                    "duration_seconds": String(duration),
                    "height": String(height),
                    "height_interval_seconds": String(heightInterval),
                    "table_size": tableOverride.map(String.init) ?? "consensus",
                    "search_kernel": searchKernel.rawValue
                ])))

        stats.update { $0.state = .buildingDataset }
        if tracePhase == .build, let tracePath {
            try solver.startGPUCapture(path: tracePath)
        }
        var activeHeight = height
        var activeBuild = try solver.buildDataset(
            height: activeHeight, tableSize: tableOverride)
        if tracePhase == .build, tracePath != nil {
            solver.stopGPUCapture()
        }
        stats.recordDatasetActivation(activeBuild)
        stats.updateDatasetWork(solver.datasetWorkMetrics())
        stats.update { $0.state = .searching }
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "dataset_completed",
            fields: datasetEventFields(activeBuild, height: activeHeight)))
        if prebuildValue == "on" {
            _ = try solver.prefetchDataset(height: activeHeight + 1, tableSize: tableOverride)
            writer.write(MinerEvent(
                sessionID: stats.snapshot().sessionID,
                type: "dataset_prefetch_started",
                fields: ["height": String(activeHeight + 1)]))
        }

        let message = Blake2b256.hash(Array("ergometal-autolykos-v2-benchmark".utf8))
        let target = UInt256(limbs: [0x0000ffff] + [UInt32](repeating: .max, count: 7))
        var nonce: UInt64 = 0
        let end = Date(timeIntervalSinceNow: Double(duration))
        var nextHeightAt = heightInterval > 0
            ? Date(timeIntervalSinceNow: Double(heightInterval))
            : Date.distantFuture
        var nextStatusAt = Date.distantPast
        var verified = 0
        var searchTracePending = tracePhase == .search && tracePath != nil
        var statisticsAccumulator = SearchStatisticsAccumulator()

        func record(_ batch: SearchBatch, flush: Bool = false) throws {
            let sample = statisticsAccumulator.append(batch, flush: flush)
            for candidate in batch.candidates {
                let bytes = nonceBytes(candidate)
                if try AutolykosV2.hit(
                    message: message, nonce: bytes, height: activeHeight,
                    tableSize: activeBuild.tableSize) < target
                {
                    verified += 1
                }
            }
            guard let sample else { return }
            stats.recordBatch(
                nonces: sample.nonces,
                gpuSeconds: sample.gpuSeconds,
                wallSeconds: sample.activeSearchSeconds)
            let now = Date()
            if now >= nextStatusAt {
                _ = synchronizeDatasetStatistics(solver: solver, stats: stats)
                let snapshot = stats.refresh()
                writer.write(MinerEvent(
                    sessionID: snapshot.sessionID,
                    type: "statistics_sample",
                    fields: snapshot.eventFields))
                if !args.has("json") {
                    printStatus(snapshot, suffix: "verified=\(verified)")
                }
                nextStatusAt = now.addingTimeInterval(1)
            }
        }

        // A trace remains intentionally limited to one command buffer. Normal
        // operation below then keeps two independent search submissions queued.
        if searchTracePending, let tracePath, Date() < end {
            thermalPauseIfNeeded(profile: profileName)
            let activeBatchSize = solver.prefetchStatus()?.finished == false
                ? min(batchSize, prebuildBatchSize)
                : batchSize
            try solver.startGPUCapture(path: tracePath)
            let batch = try solver.search(
                message: message, target: target, baseNonce: nonce,
                nonceCount: activeBatchSize, threadgroupSize: group)
            solver.stopGPUCapture()
            searchTracePending = false
            try record(batch, flush: true)
            nonce &+= UInt64(activeBatchSize)
        }

        var pending: [SearchSubmission] = []
        while Date() < end || !pending.isEmpty {
            let searchDeadline = min(end, nextHeightAt)
            while pending.count < execution.searchPipelineDepth, Date() < searchDeadline {
                thermalPauseIfNeeded(profile: profileName)
                let activeBatchSize = solver.prefetchStatus()?.finished == false
                    ? min(batchSize, prebuildBatchSize)
                    : batchSize
                pending.append(try solver.enqueueSearch(
                    message: message,
                    target: target,
                    baseNonce: nonce,
                    nonceCount: activeBatchSize,
                    threadgroupSize: group))
                nonce &+= UInt64(activeBatchSize)
            }
            if pending.isEmpty {
                guard heightInterval > 0, Date() >= nextHeightAt, Date() < end else {
                    break
                }
                stats.update { $0.state = .buildingDataset }
                activeHeight += 1
                activeBuild = try solver.buildDataset(
                    height: activeHeight, tableSize: tableOverride)
                stats.recordDatasetActivation(activeBuild)
                stats.updateDatasetWork(solver.datasetWorkMetrics())
                stats.update { $0.state = .searching }
                writer.write(MinerEvent(
                    sessionID: stats.snapshot().sessionID,
                    type: "dataset_completed",
                    fields: datasetEventFields(activeBuild, height: activeHeight)))
                if activeHeight < Int(UInt32.max) {
                    _ = try solver.prefetchDataset(
                        height: activeHeight + 1, tableSize: tableOverride)
                    writer.write(MinerEvent(
                        sessionID: stats.snapshot().sessionID,
                        type: "dataset_prefetch_started",
                        fields: ["height": String(activeHeight + 1)]))
                }
                nextHeightAt = nextHeightAt.addingTimeInterval(Double(heightInterval))
                continue
            }

            let batch = try pending.removeFirst().wait()

            // Refill before CPU verification so the GPU and CPU stages overlap.
            while pending.count < execution.searchPipelineDepth, Date() < searchDeadline {
                thermalPauseIfNeeded(profile: profileName)
                let activeBatchSize = solver.prefetchStatus()?.finished == false
                    ? min(batchSize, prebuildBatchSize)
                    : batchSize
                pending.append(try solver.enqueueSearch(
                    message: message,
                    target: target,
                    baseNonce: nonce,
                    nonceCount: activeBatchSize,
                    threadgroupSize: group))
                nonce &+= UInt64(activeBatchSize)
            }
            try record(batch)
        }
        if let sample = statisticsAccumulator.flush() {
            stats.recordBatch(
                nonces: sample.nonces,
                gpuSeconds: sample.gpuSeconds,
                wallSeconds: sample.activeSearchSeconds)
        }
        solver.cancelPrefetch(waitUntilFinished: true)
        stats.updateDatasetWork(solver.datasetWorkMetrics())
        stats.update { $0.state = .stopped }
        let finalSnapshot = stats.refresh()
        var finalFields = finalSnapshot.eventFields
        finalFields["verified_candidates"] = String(verified)
        writer.write(MinerEvent(sessionID: finalSnapshot.sessionID, type: "session_ended",
            fields: finalFields))
        if args.has("json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try encoder.encode(stats.snapshot())); print()
        } else { print("\nBenchmark complete: \(String(format: "%.2f", stats.snapshot().averageHashrate / 1_000_000)) MH/s, \(verified) CPU-verified candidates") }
    }

    private struct ReplayFixture: Codable {
        let messageHex: String
        let nonceHex: String
        let height: Int
        let tableSize: Int?
        let expectedHitHex: String
    }

    private static func replay(_ args: Arguments) throws {
        try args.validate(valueOptions: ["fixture"])
        let path = try args.require("fixture")
        let fixture = try JSONDecoder().decode(ReplayFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let message = [UInt8](hex: fixture.messageHex), let nonce = [UInt8](hex: fixture.nonceHex),
              let expected = UInt256(encoded: fixture.expectedHitHex) else { throw CLIError.fixture("invalid hex") }
        let actual = try AutolykosV2.hit(message: message, nonce: nonce, height: fixture.height, tableSize: fixture.tableSize)
        guard actual == expected else { throw CLIError.fixture("expected \(expected.hex), got \(actual.hex)") }
        print("Replay valid: height=\(fixture.height) nonce=\(fixture.nonceHex) hit=\(actual.hex)")
    }

    private static func mine(_ args: Arguments) throws {
        try args.validate(valueOptions: ["pool", "wallet", "worker", "network", "profile",
                                         "prebuild", "prebuild-batch-nonces",
                                         "batch-nonces", "threadgroup-size",
                                         "build-chunk-elements", "prefetch-chunk-elements",
                                         "search-pipeline-depth", "build-pipeline-depth",
                                         "autotune", "autotune-budget", "autotune-cache",
                                         "dataset-threadgroup-size",
                                         "dataset-kernel", "dataset-scheduling",
                                         "api-bind", "stats-file", "stats-interval",
                                         "donation"])
        let pool = try args.require("pool")
        let wallet = try args.require("wallet")
        let worker = args.string("worker", default: "metal")!
        guard !worker.isEmpty else { throw CLIError.invalidArgument("--worker must not be empty") }
        let networkValue = args.string("network", default: "mainnet")!
        guard let network = ErgoNetwork(rawValue: networkValue) else {
            throw CLIError.invalidArgument("--network \(networkValue)")
        }
        let donationPercent = try args.donationPercent(network: network)
        let donationSchedule = try DonationSchedule(percent: donationPercent)
        guard ErgoAddress.isPlausible(wallet, network: network) else { throw CLIError.invalidAddress }
        let profile = try CLITuning.profile(from: args)
        let profileName = profile.rawValue
        let prebuildValue = args.string("prebuild", default: "auto")!
        guard let requestedPrebuild = PrebuildMode(rawValue: prebuildValue) else {
            throw CLIError.invalidArgument("--prebuild \(prebuildValue)")
        }
        var prebuildEnabled = requestedPrebuild != .off
        let datasetKernel = try datasetKernel(from: args)
        let datasetScheduling = try datasetScheduling(from: args)
        let tuning = try CLITuning.resolve(
            args: args, profile: profile,
            datasetKernel: datasetKernel,
            datasetScheduling: datasetScheduling,
            searchKernel: .search)
        let execution = tuning.resolved.configuration
        let batchSize = execution.batchNonces
        let prebuildBatchSize = execution.prebuildBatchNonces
        let group = execution.searchThreadgroupSize
        let buildChunkElements = execution.synchronousBuildChunkElements
        let prefetchChunkElements = execution.prefetchBuildChunkElements
        let datasetThreadgroupSize = execution.datasetThreadgroupSize
        let statsInterval = try args.int("stats-interval", default: 60, in: 1...3_600)
        let solver = try MetalAutolykosSolver(
            synchronousBuildChunkElements: buildChunkElements,
            prefetchBuildChunkElements: prefetchChunkElements,
            searchThreadgroupSize: group,
            datasetThreadgroupSize: datasetThreadgroupSize,
            searchPipelineDepth: execution.searchPipelineDepth,
            buildPipelineDepth: execution.buildPipelineDepth,
            datasetKernel: datasetKernel,
            datasetScheduling: datasetScheduling)
        let stats = StatisticsStore(
            mode: .mining, profile: profileName, device: solver.info,
            autotuneMode: tuning.mode, tuning: tuning.resolved)
        let writer = JSONLEventWriter(path: args.string("stats-file"))
        let server = StatisticsHTTPServer(store: stats)
        try server.start(bind: args.string("api-bind", default: "127.0.0.1:4078")!)
        defer { server.stop() }
        let password = ProcessInfo.processInfo.environment["ERGOMETAL_POOL_PASSWORD"] ?? "x"
        let coordinator = MiningCoordinator(
            stats: stats,
            writer: writer,
            donationSchedule: donationSchedule,
            sensitiveValues: [pool, wallet, donationPool, donationWallet,
                              password == "x" ? "" : password])
        coordinator.beforeStop = {
            solver.cancelPrefetch(waitUntilFinished: true)
            stats.updateDatasetWork(solver.datasetWorkMetrics())
        }
        let userClient = try ErgoStratumClient(
            url: pool,
            user: "\(wallet).\(worker)",
            password: password
        ) { [weak coordinator] event in
            coordinator?.handle(event, recipient: .user)
        }
        let donationClient: ErgoStratumClient?
        if donationSchedule.isEnabled {
            guard ErgoAddress.isPlausible(donationWallet, network: .mainnet) else {
                throw CLIError.invalidArgument("embedded donation wallet is invalid")
            }
            donationClient = try ErgoStratumClient(
                url: donationPool,
                user: "\(donationWallet).\(donationWorker)",
                password: "x"
            ) { [weak coordinator] event in
                coordinator?.handle(event, recipient: .donation)
            }
        } else {
            donationClient = nil
        }
        coordinator.configure(userClient: userClient, donationClient: donationClient)
        stats.update { $0.poolHost = userClient.redactedHost }
        writer.write(MinerEvent(
            sessionID: stats.snapshot().sessionID,
            type: "session_started",
            fields: runMetadataFields(
                profile: profileName,
                prebuild: prebuildValue,
                batchSize: batchSize,
                prebuildBatchSize: prebuildBatchSize,
                threadgroupSize: group,
                buildChunkElements: buildChunkElements,
                prefetchChunkElements: prefetchChunkElements,
                datasetThreadgroupSize: datasetThreadgroupSize,
                datasetKernel: datasetKernel,
                datasetScheduling: datasetScheduling,
                tuning: tuning,
                extra: [
                    "mode": "mining",
                    "network": network.rawValue,
                    "donation_percent": String(donationPercent),
                    "donation_cycle_seconds": String(Int(donationSchedule.cycleSeconds))
                ])))

        let statsQueue = DispatchQueue(label: "dev.ergometal.statistics")
        let statsTimer = DispatchSource.makeTimerSource(queue: statsQueue)
        statsTimer.schedule(
            deadline: .now() + .seconds(statsInterval),
            repeating: .seconds(statsInterval),
            leeway: .milliseconds(min(1_000, statsInterval * 50)))
        statsTimer.setEventHandler {
            guard !coordinator.isStopped else { return }
            _ = synchronizeDatasetStatistics(solver: solver, stats: stats)
            coordinator.recordStatisticsSample()
        }
        statsTimer.resume()
        defer {
            statsTimer.cancel()
            statsQueue.sync {}
            coordinator.stop()
        }

        let signalQueue = DispatchQueue(label: "dev.ergometal.signals")
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        sigint.setEventHandler { coordinator.requestStop() }
        sigterm.setEventHandler { coordinator.requestStop() }
        sigint.resume(); sigterm.resume(); coordinator.start()

        var nextStatusAt = Date.distantPast
        var reportedPrefetchHeight: Int?
        var coldBuildCancellations = 0
        var coldLookaheadHeight: Int?
        while !coordinator.isStopped, let job = coordinator.nextJob() {
            guard job.extraNoncePrefix.count + job.extraNonce2Size == 8 else {
                coordinator.handle(.protocolError("pool extranonce layout is not 8 bytes")); continue
            }

            if let preparedHeight = coldLookaheadHeight {
                if job.height == preparedHeight {
                    coldLookaheadHeight = nil
                    coldBuildCancellations = 0
                } else if preparedHeight > 0, job.height == preparedHeight - 1 {
                    // The lookahead is ready; wait for its height instead of
                    // replacing it for a same-height template refresh.
                    continue
                } else {
                    coldLookaheadHeight = nil
                }
            }

            if prebuildEnabled, coldBuildCancellations >= 2, job.height < Int(UInt32.max) {
                let lookaheadHeight = job.height + 1
                stats.update { $0.state = .buildingDataset }
                writer.write(MinerEvent(
                    sessionID: stats.snapshot().sessionID,
                    type: "dataset_lookahead_started",
                    fields: ["current_height": String(job.height),
                             "height": String(lookaheadHeight),
                             "cold_cancellations": String(coldBuildCancellations)]))
                do {
                    let lookahead = try solver.buildDataset(
                        height: lookaheadHeight,
                        shouldContinue: {
                            coordinator.isEitherHeightCurrent(job.height, lookaheadHeight)
                        })
                    coldLookaheadHeight = lookaheadHeight
                    stats.recordDatasetActivation(lookahead)
                    stats.updateDatasetWork(solver.datasetWorkMetrics())
                    writer.write(MinerEvent(
                        sessionID: stats.snapshot().sessionID,
                        type: "dataset_lookahead_completed",
                        fields: datasetEventFields(lookahead, height: lookaheadHeight)))
                } catch MetalSolverError.cancelled {
                    continue
                }
                continue
            }

            stats.update { $0.state = .buildingDataset }
            do {
                let build = try solver.buildDataset(
                    height: job.height,
                    shouldContinue: { coordinator.isHeightCurrent(job.height) })
                guard coordinator.isCurrent(job) else {
                    if coordinator.isRecipientCurrent(job.recipient),
                       !coordinator.isHeightCurrent(job.height)
                    {
                        coldBuildCancellations += 1
                    } else {
                        coldBuildCancellations = 0
                    }
                    continue
                }
                coldBuildCancellations = 0
                stats.recordDatasetActivation(build)
                stats.updateDatasetWork(solver.datasetWorkMetrics())
                if build.source == .prefetched, reportedPrefetchHeight != job.height {
                    reportedPrefetchHeight = job.height
                    writer.write(MinerEvent(
                        sessionID: stats.snapshot().sessionID,
                        type: "dataset_prefetch_completed",
                        fields: ["height": String(job.height),
                                 "seconds": String(build.seconds),
                                 "gpu_seconds": String(build.gpuSeconds)]))
                }
                stats.update {
                    $0.prefetchHeight = nil
                    $0.prefetchProgress = 0
                    $0.prefetchBuildSeconds = nil
                    $0.prefetchError = nil
                    $0.state = .searching
                    $0.lastError = nil
                }
                writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "dataset_completed",
                    fields: datasetEventFields(build, height: job.height)))
                if prebuildEnabled, job.height < Int(UInt32.max) {
                    do {
                        if try solver.prefetchDataset(height: job.height + 1) {
                            reportedPrefetchHeight = nil
                            writer.write(MinerEvent(
                                sessionID: stats.snapshot().sessionID,
                                type: "dataset_prefetch_started",
                                fields: ["height": String(job.height + 1)]))
                        }
                    } catch {
                        if requestedPrebuild == .on { throw error }
                        prebuildEnabled = false
                        writer.write(MinerEvent(
                            sessionID: stats.snapshot().sessionID,
                            type: "dataset_prefetch_disabled",
                            fields: ["reason": error.localizedDescription]))
                    }
                }
                var base = job.extraNoncePrefix.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                base <<= UInt64(job.extraNonce2Size * 8)
                guard let variableMask = NonceSpace.maximumOffset(variableBytes: job.extraNonce2Size) else {
                    coordinator.handle(.protocolError("pool extranonce2 size is outside 0...8 bytes"))
                    continue
                }
                var offset: UInt64 = 0
                var nonceSpaceExhausted = false
                var pending: [SearchSubmission] = []
                var statisticsAccumulator = SearchStatisticsAccumulator()
                // Also drain and account for queued work if a later submission
                // or share-handling operation throws before the normal drain.
                defer {
                    for submission in pending {
                        if let batch = try? submission.wait(),
                           let sample = statisticsAccumulator.append(batch) {
                            stats.recordBatch(
                                nonces: sample.nonces, gpuSeconds: sample.gpuSeconds,
                                wallSeconds: sample.activeSearchSeconds,
                                shareTarget: job.target, recipient: job.recipient)
                        }
                    }
                    if let sample = statisticsAccumulator.flush() {
                        stats.recordBatch(
                            nonces: sample.nonces, gpuSeconds: sample.gpuSeconds,
                            wallSeconds: sample.activeSearchSeconds,
                            shareTarget: job.target, recipient: job.recipient)
                    }
                }

                func enqueueNextBatch() throws -> Bool {
                    guard !nonceSpaceExhausted,
                          coordinator.isCurrent(job),
                          !coordinator.isStopped
                    else { return false }
                    thermalPauseIfNeeded(profile: profileName)
                    let activeBatchSize = solver.prefetchStatus()?.finished == false
                        ? min(batchSize, prebuildBatchSize)
                        : batchSize
                    let count = NonceSpace.batchSize(offset: offset, maximumOffset: variableMask,
                                                     requested: activeBatchSize)
                    guard count > 0 else {
                        nonceSpaceExhausted = true
                        return false
                    }
                    pending.append(try solver.enqueueSearch(
                        message: job.message,
                        target: job.target,
                        baseNonce: base | offset,
                        nonceCount: count,
                        threadgroupSize: group))
                    if let next = NonceSpace.advance(
                        offset: offset, count: count, maximumOffset: variableMask)
                    {
                        offset = next
                    } else {
                        nonceSpaceExhausted = true
                    }
                    return true
                }

                while pending.count < execution.searchPipelineDepth, try enqueueNextBatch() {}
                while !pending.isEmpty {
                    let batch = try pending.removeFirst().wait()

                    let statisticsSample = statisticsAccumulator.append(batch)
                    if let statisticsSample {
                        stats.recordBatch(
                            nonces: statisticsSample.nonces,
                            gpuSeconds: statisticsSample.gpuSeconds,
                            wallSeconds: statisticsSample.activeSearchSeconds,
                            shareTarget: job.target,
                            recipient: job.recipient)
                    }
                    // Account for the completed batch before a refill can
                    // throw, then overlap the next GPU work with verification.
                    while pending.count < execution.searchPipelineDepth, try enqueueNextBatch() {}
                    for nonce in batch.candidates {
                        guard coordinator.isCurrent(job) else {
                            stats.recordShareStale(recipient: job.recipient)
                            break
                        }
                        let hit = try AutolykosV2.hit(message: job.message, nonce: nonceBytes(nonce), height: job.height)
                        guard hit < job.target else { continue }
                        stats.recordShareFound(recipient: job.recipient)
                        do {
                            _ = try coordinator.submit(job, nonce: nonce)
                            stats.recordShareSubmitted(recipient: job.recipient)
                        } catch StratumError.notReady {
                            stats.recordShareStale(recipient: job.recipient)
                            break
                        }
                    }
                    let now = Date()
                    if statisticsSample != nil, now >= nextStatusAt {
                        let prefetch = synchronizeDatasetStatistics(
                            solver: solver, stats: stats)
                        if let prefetch, prefetch.finished, reportedPrefetchHeight != prefetch.height {
                            reportedPrefetchHeight = prefetch.height
                            if let failure = prefetch.errorDescription {
                                if requestedPrebuild == .auto { prebuildEnabled = false }
                                writer.write(MinerEvent(
                                    sessionID: stats.snapshot().sessionID,
                                    type: "dataset_prefetch_failed",
                                    fields: ["height": String(prefetch.height),
                                             "message": failure]))
                            } else {
                                writer.write(MinerEvent(
                                    sessionID: stats.snapshot().sessionID,
                                    type: "dataset_prefetch_completed",
                                    fields: ["height": String(prefetch.height),
                                             "seconds": String(prefetch.seconds ?? 0),
                                             "gpu_seconds": String(prefetch.gpuSeconds ?? 0)]))
                            }
                        }
                        let snapshot = stats.snapshot()
                        printStatus(snapshot,
                            suffix: "shares=\(snapshot.shares.accepted)/\(snapshot.shares.rejected)")
                        nextStatusAt = now.addingTimeInterval(1)
                    }
                }
                if nonceSpaceExhausted,
                   coordinator.isCurrent(job),
                   !coordinator.isStopped
                {
                    coordinator.handle(.protocolError("nonce space exhausted for job \(job.id)"))
                }
            } catch MetalSolverError.cancelled {
                if coordinator.isRecipientCurrent(job.recipient) {
                    coldBuildCancellations += 1
                } else {
                    coldBuildCancellations = 0
                }
                continue
            } catch {
                stats.update { $0.lastError = error.localizedDescription; $0.state = .failed }
                writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "error", fields: ["message": error.localizedDescription]))
            }
        }
        print("\nStopped")
    }

    private static func nonceBytes(_ value: UInt64) -> [UInt8] {
        stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> UInt64($0)) }
    }

    private static func thermalPauseIfNeeded(profile: String) {
        guard profile == "efficiency" else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .critical: Thread.sleep(forTimeInterval: 2)
        case .serious: Thread.sleep(forTimeInterval: 0.25)
        default: break
        }
    }

    private static func printStatus(_ s: MinerSnapshot, suffix: String) {
        let terminal = isatty(STDOUT_FILENO) == 1
        let maximumColumns = terminal
            ? max(1, (terminalColumnCount() ?? 80) - 1)
            : nil
        let line = MinerStatusLineFormatter.format(
            s, suffix: suffix, maximumColumns: maximumColumns)
        let control = terminal ? "\r\u{001B}[2K" : "\r"
        FileHandle.standardOutput.write(Data((control + line).utf8))
    }

    private static func terminalColumnCount() -> Int? {
        guard isatty(STDOUT_FILENO) == 1 else { return nil }
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            return nil
        }
        return Int(size.ws_col)
    }

    @discardableResult
    private static func synchronizeDatasetStatistics(
        solver: MetalAutolykosSolver,
        stats: StatisticsStore
    ) -> DatasetPrefetchStatus? {
        let prefetch = solver.prefetchStatus()
        stats.updateDatasetWork(solver.datasetWorkMetrics())
        stats.update {
            $0.prefetchHeight = prefetch?.height
            $0.prefetchProgress = prefetch?.progress ?? 0
            $0.prefetchBuildSeconds = prefetch?.seconds
            $0.prefetchError = prefetch?.errorDescription
        }
        return prefetch
    }

    private static func datasetEventFields(
        _ build: DatasetBuild,
        height: Int
    ) -> [String: String] {
        [
            "height": String(height),
            "table_size": String(build.tableSize),
            "seconds": String(build.seconds),
            "gpu_seconds": String(build.gpuSeconds),
            "activation_seconds": String(build.activationSeconds),
            "prefetch_wait_seconds": String(build.prefetchWaitSeconds),
            "waited_for_prefetch": String(build.waitedForPrefetch),
            "source": build.source.rawValue
        ]
    }

    private static func datasetKernel(from args: Arguments) throws -> DatasetKernel {
        let raw = args.string(
            "dataset-kernel", default: DatasetKernel.u32PairInlineM.rawValue)!
        guard let value = DatasetKernel(rawValue: raw) else {
            throw CLIError.invalidArgument(
                "--dataset-kernel must be \(DatasetKernel.allCases.map(\.rawValue).joined(separator: "|"))")
        }
        return value
    }

    private static func searchKernel(from args: Arguments) throws -> SearchKernel {
        let raw = args.string("search-kernel", default: SearchKernel.search.rawValue)!
        guard let value = SearchKernel(rawValue: raw) else {
            throw CLIError.invalidArgument(
                "--search-kernel must be \(SearchKernel.allCases.map(\.rawValue).joined(separator: "|"))")
        }
        return value
    }

    private static func datasetScheduling(from args: Arguments) throws -> DatasetScheduling {
        let raw = args.string(
            "dataset-scheduling", default: DatasetScheduling.overlap.rawValue)!
        guard let value = DatasetScheduling(rawValue: raw) else {
            throw CLIError.invalidArgument(
                "--dataset-scheduling must be \(DatasetScheduling.allCases.map(\.rawValue).joined(separator: "|"))")
        }
        return value
    }

    private static func runMetadataFields(
        profile: String,
        prebuild: String,
        batchSize: Int,
        prebuildBatchSize: Int,
        threadgroupSize: Int,
        buildChunkElements: Int,
        prefetchChunkElements: Int,
        datasetThreadgroupSize: Int,
        datasetKernel: DatasetKernel,
        datasetScheduling: DatasetScheduling,
        tuning: CLITuningResolution,
        extra: [String: String]
    ) -> [String: String] {
        var fields = extra
        fields.merge([
            "profile": profile,
            "prebuild": prebuild,
            "batch_nonces": String(batchSize),
            "prebuild_batch_nonces": String(prebuildBatchSize),
            "threadgroup_size": String(threadgroupSize),
            "build_chunk_elements": String(buildChunkElements),
            "prefetch_chunk_elements": String(prefetchChunkElements),
            "dataset_threadgroup_size": String(datasetThreadgroupSize),
            "dataset_kernel": datasetKernel.rawValue,
            "dataset_scheduling": datasetScheduling.rawValue,
            "search_pipeline_depth": String(tuning.resolved.configuration.searchPipelineDepth),
            "build_pipeline_depth": String(tuning.resolved.configuration.buildPipelineDepth),
            "gpu_architecture": tuning.fingerprint.architectureName,
            "gpu_generation": tuning.fingerprint.generation.rawValue,
            "gpu_family": tuning.fingerprint.familyName,
            "os_build": tuning.fingerprint.operatingSystemBuild,
            "autotune_mode": tuning.mode.rawValue,
            "tuning_provenance": tuning.resolved.summaryProvenance.rawValue,
            "architecture": "arm64",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ]) { _, new in new }
        if let cacheKey = tuning.resolved.cacheKey {
            fields["autotune_cache_key"] = cacheKey
        }
        for (field, source) in tuning.resolved.provenance {
            fields["tuning_source_\(field)"] = source.rawValue
        }
        if let digest = executableSHA256() {
            fields["executable_sha256"] = digest
        }
        if let revision = gitOutput(["rev-parse", "HEAD"]) {
            fields["worktree_revision"] = revision
            fields["worktree_dirty"] = String(!(gitOutput([
                "status", "--porcelain", "--untracked-files=no"
            ]) ?? "").isEmpty)
        }
        return fields
    }

    private static func executableSHA256() -> String? {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func gitOutput(_ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
