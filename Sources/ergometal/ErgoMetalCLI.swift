import Foundation
import MetalErgoCore

@main
enum ErgoMetalCLI {
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
        let duration = try args.int("duration", default: 60)
        let height = try args.int("height", default: 614_399)
        let tableOverride = args.string("table-size").flatMap(Int.init)
        let profile = args.string("profile", default: "efficiency")!
        guard ["efficiency", "peak"].contains(profile) else { throw CLIError.invalidArgument(profile) }
        let solver = try MetalAutolykosSolver()
        let stats = StatisticsStore(mode: .benchmark, profile: profile, device: solver.info)
        let writer = JSONLEventWriter(path: args.string("stats-file"))
        let server = StatisticsHTTPServer(store: stats)
        try server.start(bind: args.string("api-bind", default: "127.0.0.1:4078")!)
        defer { server.stop() }
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "session_started"))

        stats.update { $0.state = .buildingDataset }
        let build = try solver.buildDataset(height: height, tableSize: tableOverride)
        stats.update { $0.datasetBytes = build.bytes; $0.datasetBuildSeconds = build.seconds; $0.state = .searching }
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "dataset_completed",
            fields: ["height": String(height), "table_size": String(build.tableSize), "seconds": String(build.seconds)]))

        let message = Blake2b256.hash(Array("ergometal-autolykos-v2-benchmark".utf8))
        let target = UInt256(limbs: [0x0000ffff] + [UInt32](repeating: .max, count: 7))
        let batchSize = try args.int("batch-nonces", default: profile == "peak" ? 262_144 : 65_536)
        let group = try args.int("threadgroup-size", default: 128)
        var nonce: UInt64 = 0
        let end = Date(timeIntervalSinceNow: Double(duration))
        var verified = 0
        while Date() < end {
            thermalPauseIfNeeded(profile: profile)
            let batch = try solver.search(message: message, target: target, baseNonce: nonce,
                                          nonceCount: batchSize, threadgroupSize: group)
            stats.recordBatch(nonces: batch.nonceCount, gpuSeconds: batch.gpuSeconds, wallSeconds: batch.wallSeconds)
            for candidate in batch.candidates {
                let bytes = nonceBytes(candidate)
                if try AutolykosV2.hit(message: message, nonce: bytes, height: height,
                                       tableSize: build.tableSize) < target { verified += 1 }
            }
            nonce &+= UInt64(batchSize)
            if !args.has("json") { printStatus(stats.snapshot(), suffix: "verified=\(verified)") }
        }
        stats.update { $0.state = .stopped }
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "session_ended",
            fields: ["verified_candidates": String(verified)]))
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
        let path = try args.require("fixture")
        let fixture = try JSONDecoder().decode(ReplayFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let message = [UInt8](hex: fixture.messageHex), let nonce = [UInt8](hex: fixture.nonceHex),
              let expected = UInt256(encoded: fixture.expectedHitHex) else { throw CLIError.fixture("invalid hex") }
        let actual = try AutolykosV2.hit(message: message, nonce: nonce, height: fixture.height, tableSize: fixture.tableSize)
        guard actual == expected else { throw CLIError.fixture("expected \(expected.hex), got \(actual.hex)") }
        print("Replay valid: height=\(fixture.height) nonce=\(fixture.nonceHex) hit=\(actual.hex)")
    }

    private static func mine(_ args: Arguments) throws {
        let pool = try args.require("pool")
        let wallet = try args.require("wallet")
        let worker = args.string("worker", default: "metal")!
        let network = args.string("network", default: "mainnet")!
        guard ErgoAddress.isPlausible(wallet, network: network) else { throw CLIError.invalidAddress }
        let profile = args.string("profile", default: "efficiency")!
        let solver = try MetalAutolykosSolver()
        let stats = StatisticsStore(mode: .mining, profile: profile, device: solver.info)
        let writer = JSONLEventWriter(path: args.string("stats-file"))
        let server = StatisticsHTTPServer(store: stats)
        try server.start(bind: args.string("api-bind", default: "127.0.0.1:4078")!)
        defer { server.stop() }
        let coordinator = MiningCoordinator(stats: stats, writer: writer)
        let password = ProcessInfo.processInfo.environment["ERGOMETAL_POOL_PASSWORD"] ?? "x"
        let client = try ErgoStratumClient(url: pool, user: "\(wallet).\(worker)", password: password) { event in coordinator.handle(event) }
        coordinator.client = client
        stats.update { $0.poolHost = client.redactedHost }
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "session_started"))

        let signalQueue = DispatchQueue(label: "dev.ergometal.signals")
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        sigint.setEventHandler { coordinator.stop() }; sigterm.setEventHandler { coordinator.stop() }
        sigint.resume(); sigterm.resume(); client.connect()

        let batchSize = try args.int("batch-nonces", default: profile == "peak" ? 262_144 : 65_536)
        let group = try args.int("threadgroup-size", default: 128)
        while !coordinator.isStopped, let job = coordinator.nextJob() {
            guard job.extraNoncePrefix.count + job.extraNonce2Size == 8 else {
                coordinator.handle(.protocolError("pool extranonce layout is not 8 bytes")); continue
            }
            stats.update { $0.state = .buildingDataset }
            do {
                let build = try solver.buildDataset(height: job.height)
                guard coordinator.isCurrent(job) else { continue }
                stats.update { $0.datasetBytes = build.bytes; $0.datasetBuildSeconds = build.seconds; $0.state = .searching }
                var base = job.extraNoncePrefix.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                base <<= UInt64(job.extraNonce2Size * 8)
                let variableMask: UInt64 = job.extraNonce2Size == 8 ? .max : (UInt64(1) << UInt64(job.extraNonce2Size * 8)) - 1
                var offset: UInt64 = 0
                while coordinator.isCurrent(job) && !coordinator.isStopped {
                    thermalPauseIfNeeded(profile: profile)
                    let count = min(batchSize, Int(variableMask &- offset &+ 1))
                    let batch = try solver.search(message: job.message, target: job.target,
                        baseNonce: base | offset, nonceCount: count, threadgroupSize: group)
                    stats.recordBatch(nonces: count, gpuSeconds: batch.gpuSeconds, wallSeconds: batch.wallSeconds)
                    for nonce in batch.candidates {
                        guard coordinator.isCurrent(job) else { stats.update { $0.shares.stale += 1 }; break }
                        let hit = try AutolykosV2.hit(message: job.message, nonce: nonceBytes(nonce), height: job.height)
                        guard hit < job.target else { continue }
                        stats.update { $0.shares.found += 1 }
                        _ = try client.submit(job: job, nonce: nonce)
                        stats.update { $0.shares.submitted += 1 }
                    }
                    offset = (offset + UInt64(count)) & variableMask
                    printStatus(stats.snapshot(), suffix: "shares=\(stats.snapshot().shares.accepted)/\(stats.snapshot().shares.rejected)")
                }
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
        let text = String(format: "\r%7.2f MH/s  nonces=%llu  %@", s.hashrate / 1_000_000, s.nonces, suffix)
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
