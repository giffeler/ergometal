import Foundation
import MetalErgoCore

@main
enum ErgoMetalCLI {
    private static let maximumBatchNonces = 16_777_216
    private static let defaultPrebuildBatchNonces = 65_536
    private static let searchPipelineDepth = 2
    private static let searchStatisticsBatchCount = 16
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
                print("\(d.name)  unified=\(d.unifiedMemory)  working-set=\(formatBytes(d.recommendedWorkingSetBytes))  max-buffer=\(formatBytes(d.maxBufferBytes))")
            }
        }
    }

    private static func benchmark(_ args: Arguments) throws {
        try args.validate(
            valueOptions: ["duration", "height", "profile", "table-size", "batch-nonces",
                           "prebuild", "prebuild-batch-nonces", "threadgroup-size",
                           "build-chunk-elements", "prefetch-chunk-elements",
                           "api-bind", "stats-file",
                           "gpu-trace", "gpu-trace-phase"],
            flagOptions: ["json"])
        let duration = try args.int("duration", default: 60, in: 1...Int.max)
        let height = try args.int("height", default: 614_399, in: 0...Int(UInt32.max))
        let tableOverride = try args.optionalInt("table-size", in: 1...Int(UInt32.max))
        let profile = args.string("profile", default: "efficiency")!
        guard ["efficiency", "peak"].contains(profile) else { throw CLIError.invalidArgument(profile) }
        let prebuildValue = args.string("prebuild", default: "off")!
        guard prebuildValue == "on" || prebuildValue == "off" else {
            throw CLIError.invalidArgument("--prebuild \(prebuildValue)")
        }
        let batchSize = try args.int(
            "batch-nonces", default: profile == "peak" ? 1_048_576 : 262_144,
            in: 1...maximumBatchNonces)
        let prebuildBatchSize = try args.int(
            "prebuild-batch-nonces", default: defaultPrebuildBatchNonces,
            in: 1...maximumBatchNonces)
        let group = try args.int("threadgroup-size", default: 128, in: 1...1_024)
        let buildChunkElements = try args.int(
            "build-chunk-elements",
            default: MetalAutolykosSolver.defaultSynchronousBuildChunkElements,
            in: 1...maximumBatchNonces)
        let prefetchChunkElements = try args.int(
            "prefetch-chunk-elements",
            default: MetalAutolykosSolver.defaultPrefetchBuildChunkElements,
            in: 1...maximumBatchNonces)
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
            prefetchBuildChunkElements: prefetchChunkElements)
        defer { solver.stopGPUCapture() }
        let stats = StatisticsStore(mode: .benchmark, profile: profile, device: solver.info)
        let writer = JSONLEventWriter(path: args.string("stats-file"))
        let server = StatisticsHTTPServer(store: stats)
        try server.start(bind: args.string("api-bind", default: "127.0.0.1:4078")!)
        defer { server.stop() }
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "session_started"))

        stats.update { $0.state = .buildingDataset }
        if tracePhase == .build, let tracePath {
            try solver.startGPUCapture(path: tracePath)
        }
        let build = try solver.buildDataset(height: height, tableSize: tableOverride)
        if tracePhase == .build, tracePath != nil {
            solver.stopGPUCapture()
        }
        stats.recordDatasetActivation(build)
        stats.updateDatasetWork(solver.datasetWorkMetrics())
        stats.update { $0.state = .searching }
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "dataset_completed",
            fields: datasetEventFields(build, height: height)))
        if prebuildValue == "on" {
            _ = try solver.prefetchDataset(height: height + 1, tableSize: tableOverride)
            writer.write(MinerEvent(
                sessionID: stats.snapshot().sessionID,
                type: "dataset_prefetch_started",
                fields: ["height": String(height + 1)]))
        }

        let message = Blake2b256.hash(Array("ergometal-autolykos-v2-benchmark".utf8))
        let target = UInt256(limbs: [0x0000ffff] + [UInt32](repeating: .max, count: 7))
        var nonce: UInt64 = 0
        let end = Date(timeIntervalSinceNow: Double(duration))
        var nextStatusAt = Date.distantPast
        var verified = 0
        var searchTracePending = tracePhase == .search && tracePath != nil
        var statisticsAccumulator = SearchStatisticsAccumulator()

        func record(_ batch: SearchBatch, flush: Bool = false) throws {
            let sample = statisticsAccumulator.append(batch, flush: flush)
            for candidate in batch.candidates {
                let bytes = nonceBytes(candidate)
                if try AutolykosV2.hit(
                    message: message, nonce: bytes, height: height,
                    tableSize: build.tableSize) < target
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
                if !args.has("json") {
                    printStatus(stats.snapshot(), suffix: "verified=\(verified)")
                }
                nextStatusAt = now.addingTimeInterval(1)
            }
        }

        // A trace remains intentionally limited to one command buffer. Normal
        // operation below then keeps two independent search submissions queued.
        if searchTracePending, let tracePath, Date() < end {
            thermalPauseIfNeeded(profile: profile)
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
            while pending.count < searchPipelineDepth, Date() < end {
                thermalPauseIfNeeded(profile: profile)
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
            guard !pending.isEmpty else { break }

            let batch = try pending.removeFirst().wait()

            // Refill before CPU verification so the GPU and CPU stages overlap.
            while pending.count < searchPipelineDepth, Date() < end {
                thermalPauseIfNeeded(profile: profile)
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
                                         "api-bind", "stats-file", "stats-interval"])
        let pool = try args.require("pool")
        let wallet = try args.require("wallet")
        let worker = args.string("worker", default: "metal")!
        guard !worker.isEmpty else { throw CLIError.invalidArgument("--worker must not be empty") }
        let networkValue = args.string("network", default: "mainnet")!
        guard let network = ErgoNetwork(rawValue: networkValue) else {
            throw CLIError.invalidArgument("--network \(networkValue)")
        }
        guard ErgoAddress.isPlausible(wallet, network: network) else { throw CLIError.invalidAddress }
        let profile = args.string("profile", default: "efficiency")!
        guard ["efficiency", "peak"].contains(profile) else { throw CLIError.invalidArgument("--profile \(profile)") }
        let prebuildValue = args.string("prebuild", default: "auto")!
        guard let requestedPrebuild = PrebuildMode(rawValue: prebuildValue) else {
            throw CLIError.invalidArgument("--prebuild \(prebuildValue)")
        }
        var prebuildEnabled = requestedPrebuild != .off
        let batchSize = try args.int(
            "batch-nonces", default: profile == "peak" ? 1_048_576 : 262_144,
            in: 1...maximumBatchNonces)
        let prebuildBatchSize = try args.int(
            "prebuild-batch-nonces", default: defaultPrebuildBatchNonces,
            in: 1...maximumBatchNonces)
        let group = try args.int("threadgroup-size", default: 128, in: 1...1_024)
        let buildChunkElements = try args.int(
            "build-chunk-elements",
            default: MetalAutolykosSolver.defaultSynchronousBuildChunkElements,
            in: 1...maximumBatchNonces)
        let prefetchChunkElements = try args.int(
            "prefetch-chunk-elements",
            default: MetalAutolykosSolver.defaultPrefetchBuildChunkElements,
            in: 1...maximumBatchNonces)
        let statsInterval = try args.int("stats-interval", default: 60, in: 1...3_600)
        let solver = try MetalAutolykosSolver(
            synchronousBuildChunkElements: buildChunkElements,
            prefetchBuildChunkElements: prefetchChunkElements)
        let stats = StatisticsStore(mode: .mining, profile: profile, device: solver.info)
        let writer = JSONLEventWriter(path: args.string("stats-file"))
        let server = StatisticsHTTPServer(store: stats)
        try server.start(bind: args.string("api-bind", default: "127.0.0.1:4078")!)
        defer { server.stop() }
        let coordinator = MiningCoordinator(stats: stats, writer: writer)
        coordinator.beforeStop = {
            solver.cancelPrefetch(waitUntilFinished: true)
            stats.updateDatasetWork(solver.datasetWorkMetrics())
        }
        let password = ProcessInfo.processInfo.environment["ERGOMETAL_POOL_PASSWORD"] ?? "x"
        let client = try ErgoStratumClient(url: pool, user: "\(wallet).\(worker)", password: password) { event in coordinator.handle(event) }
        coordinator.client = client
        stats.update { $0.poolHost = client.redactedHost }
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "session_started"))

        let statsTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.ergometal.statistics"))
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
            coordinator.stop()
        }

        let signalQueue = DispatchQueue(label: "dev.ergometal.signals")
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        sigint.setEventHandler { coordinator.stop() }
        sigterm.setEventHandler { coordinator.stop() }
        sigint.resume(); sigterm.resume(); client.connect()

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
                    if !coordinator.isHeightCurrent(job.height) {
                        coldBuildCancellations += 1
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

                func enqueueNextBatch() throws -> Bool {
                    guard !nonceSpaceExhausted,
                          coordinator.isCurrent(job),
                          !coordinator.isStopped
                    else { return false }
                    thermalPauseIfNeeded(profile: profile)
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

                while pending.count < searchPipelineDepth, try enqueueNextBatch() {}
                while !pending.isEmpty {
                    let batch = try pending.removeFirst().wait()

                    // Keep the next GPU command ready before CPU verification
                    // and any synchronous Stratum submission work.
                    while pending.count < searchPipelineDepth, try enqueueNextBatch() {}
                    let statisticsSample = statisticsAccumulator.append(batch)
                    if let statisticsSample {
                        stats.recordBatch(
                            nonces: statisticsSample.nonces,
                            gpuSeconds: statisticsSample.gpuSeconds,
                            wallSeconds: statisticsSample.activeSearchSeconds,
                            shareTarget: job.target)
                    }
                    for nonce in batch.candidates {
                        guard coordinator.isCurrent(job) else { stats.update { $0.shares.stale += 1 }; break }
                        let hit = try AutolykosV2.hit(message: job.message, nonce: nonceBytes(nonce), height: job.height)
                        guard hit < job.target else { continue }
                        stats.update { $0.shares.found += 1 }
                        do {
                            _ = try client.submit(job: job, nonce: nonce)
                            stats.update { $0.shares.submitted += 1 }
                        } catch StratumError.notReady {
                            stats.update { $0.shares.stale += 1 }
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
                if let statisticsSample = statisticsAccumulator.flush() {
                    stats.recordBatch(
                        nonces: statisticsSample.nonces,
                        gpuSeconds: statisticsSample.gpuSeconds,
                        wallSeconds: statisticsSample.activeSearchSeconds,
                        shareTarget: job.target)
                }
                if nonceSpaceExhausted,
                   coordinator.isCurrent(job),
                   !coordinator.isStopped
                {
                    coordinator.handle(.protocolError("nonce space exhausted for job \(job.id)"))
                }
            } catch MetalSolverError.cancelled {
                coldBuildCancellations += 1
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
        let prefetch = s.prefetchHeight == nil
            ? "prefetch=off"
            : String(format: "prefetch=%5.1f%%", min(1, max(0, s.prefetchProgress)) * 100)
        let temperature = s.socTemperatureMaximumCelsius.map {
            String(format: "temp=%4.1f/%4.1fC", $0, s.socTemperatureSessionPeakCelsius ?? $0)
        } ?? "temp=n/a"
        let luck = s.shareLuckRatio.map {
            String(format: "luck=%5.1f%%", $0 * 100)
        } ?? "luck=n/a"
        let text = String(
            format: "\rcurrent=%6.2f  avg=%6.2f  effective=%6.2f MH/s  duty=%5.1f%%  %@  %@  expected=%.2f  %@  nonces=%llu  %@    ",
            s.hashrate / 1_000_000,
            s.averageHashrate / 1_000_000,
            s.effectiveHashrate / 1_000_000,
            s.searchDutyCycle * 100,
            prefetch,
            temperature,
            s.shares.expected,
            luck,
            s.nonces,
            suffix)
        FileHandle.standardOutput.write(Data(text.utf8))
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

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
