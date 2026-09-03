import Foundation
import XCTest
@testable import MetalErgoCore

final class PerformanceTuningTests: XCTestCase {
    func testSafeFallbackIsM1CompatibleAndProfileSpecific() {
        let efficiency = MetalExecutionConfiguration.safeFallback(profile: .efficiency)
        XCTAssertEqual(efficiency.searchThreadgroupSize, 128)
        XCTAssertEqual(efficiency.datasetThreadgroupSize, 256)
        XCTAssertEqual(efficiency.batchNonces, 262_144)
        XCTAssertEqual(efficiency.prebuildBatchNonces, 65_536)
        XCTAssertEqual(efficiency.synchronousBuildChunkElements, 2_097_152)
        XCTAssertEqual(efficiency.prefetchBuildChunkElements, 1_048_576)
        XCTAssertEqual(efficiency.searchPipelineDepth, 2)
        XCTAssertEqual(efficiency.buildPipelineDepth, 2)
        XCTAssertEqual(
            MetalExecutionConfiguration.safeFallback(profile: .peak).batchNonces,
            1_048_576)
    }

    func testKnownFamilyClassificationStopsAtInstalledSDKBoundary() {
        XCTAssertNil(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: []))
        XCTAssertEqual(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7]), 7)
        XCTAssertEqual(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7, 8]), 8)
        XCTAssertEqual(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7, 8, 9]), 9)
        XCTAssertEqual(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7, 8, 9, 10]), 10)
        XCTAssertEqual(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7, 11]), 7)
    }

    func testGenerationClassificationIncludesM6WithoutInventingMetalFamily() {
        XCTAssertEqual(GPUArchitectureFingerprint.generation(for: "Apple M1 Max"), .m1)
        XCTAssertEqual(GPUArchitectureFingerprint.generation(for: "Apple M2 Pro"), .m2)
        XCTAssertEqual(GPUArchitectureFingerprint.generation(for: "Apple M3 Ultra"), .m3)
        XCTAssertEqual(GPUArchitectureFingerprint.generation(for: "Apple M4"), .m4)
        XCTAssertEqual(GPUArchitectureFingerprint.generation(for: "Apple M5 Ultra"), .m5)
        XCTAssertEqual(GPUArchitectureFingerprint.generation(for: "Apple M6 Pro"), .m6)
        XCTAssertEqual(GPUArchitectureFingerprint.generation(for: "Future Apple GPU"), .unknown)
        let future = fingerprint(name: "Apple M6", architecture: "applegpu_future", family: nil)
        XCTAssertEqual(future.generation, .m6)
        XCTAssertEqual(future.familyName, "unknown")
    }

    func testResolverPrecedenceIsExplicitThenCacheThenTuningThenFallback() {
        var tuned = MetalExecutionConfiguration.safeFallback(profile: .efficiency)
        tuned.batchNonces = 131_072
        tuned.searchPipelineDepth = 3
        var cached = tuned
        cached.batchNonces = 524_288
        cached.searchPipelineDepth = 4
        let overrides = MetalExecutionOverrides(batchNonces: 777_216)
        let resolved = MetalTuningResolver.resolve(
            profile: .efficiency, cached: cached, tuned: tuned,
            overrides: overrides, cacheKey: "test")
        XCTAssertEqual(resolved.configuration.batchNonces, 777_216)
        XCTAssertEqual(resolved.configuration.searchPipelineDepth, 4)
        XCTAssertEqual(resolved.provenance["batch_nonces"], .explicit)
        XCTAssertEqual(resolved.provenance["search_pipeline_depth"], .cache)
        XCTAssertEqual(resolved.cacheKey, "test")
    }

    func testCandidateSetsRespectSIMDWidthAndImprovementGate() {
        XCTAssertEqual(
            AutotuningPolicy.threadgroupCandidates(width: 32, limit: 256),
            [64, 128, 256])
        XCTAssertEqual(
            AutotuningPolicy.threadgroupCandidates(width: 64, limit: 128),
            [64, 128])
        XCTAssertFalse(AutotuningPolicy.isMeaningfulImprovement(
            baseline: [100, 100], candidate: [101.99, 101.99]))
        XCTAssertTrue(AutotuningPolicy.isMeaningfulImprovement(
            baseline: [100, 100], candidate: [102, 102]))
        XCTAssertEqual(AutotuningPolicy.pipelineDepthCandidates, [1, 2, 3, 4])
    }

    func testBudgetAndThermalSafetyGates() {
        let start = Date(timeIntervalSince1970: 1_000)
        let budget = AutotuningBudget(seconds: 120, now: start)
        XCTAssertTrue(budget.hasTimeRemaining(at: start.addingTimeInterval(119.999)))
        XCTAssertFalse(budget.hasTimeRemaining(at: start.addingTimeInterval(120)))
        XCTAssertFalse(AutotuningSafety.shouldAbort(thermalState: .nominal))
        XCTAssertFalse(AutotuningSafety.shouldAbort(thermalState: .fair))
        XCTAssertTrue(AutotuningSafety.shouldAbort(thermalState: .serious))
        XCTAssertTrue(AutotuningSafety.shouldAbort(thermalState: .critical))
    }

    func testCacheIsKeyedByArchitectureBinaryAndProfileAndRecoversFromCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ergometal-tuning-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.json")
        let store = AutotuneCacheStore(url: url)
        let identity = cacheIdentity(binary: "aaa", architecture: "g16", profile: .efficiency)
        let record = AutotuneRecord(
            identity: identity,
            configuration: .safeFallback(profile: .efficiency),
            measurements: ["search.ratio": 1.03],
            tunedAt: Date(timeIntervalSince1970: 123))
        XCTAssertTrue(store.save(record))
        XCTAssertEqual(store.load(identity: identity), record)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertNil(store.load(identity: cacheIdentity(
            binary: "bbb", architecture: "g16", profile: .efficiency)))
        XCTAssertNil(store.load(identity: cacheIdentity(
            binary: "aaa", architecture: "g17", profile: .efficiency)))
        XCTAssertNil(store.load(identity: cacheIdentity(
            binary: "aaa", architecture: "g16", profile: .peak)))

        try Data("not-json".utf8).write(to: url)
        XCTAssertNil(store.load(identity: identity))
        XCTAssertTrue(store.save(record))
        XCTAssertEqual(store.load(identity: identity), record)
    }

    func testConcurrentCacheWritesRemainDecodableAndPreserveRecords() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ergometal-tuning-concurrency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutotuneCacheStore(url: directory.appendingPathComponent("cache.json"))
        let identities = (0..<16).map {
            cacheIdentity(binary: "binary-\($0)", architecture: "g16", profile: .peak)
        }
        DispatchQueue.concurrentPerform(iterations: identities.count) { index in
            _ = store.save(AutotuneRecord(
                identity: identities[index],
                configuration: .safeFallback(profile: .peak),
                measurements: [:]))
        }
        for identity in identities {
            XCTAssertNotNil(store.load(identity: identity))
        }
    }

    func testPipelineDepthsOneThroughFourPreserveSearchConsensus() throws {
        let message = Blake2b256.hash(Array("pipeline-depth-test".utf8))
        for depth in 1...4 {
            let solver = try MetalAutolykosSolver(
                searchPipelineDepth: depth, buildPipelineDepth: depth)
            XCTAssertEqual(solver.searchPipelineDepth, depth)
            XCTAssertEqual(solver.buildPipelineDepth, depth)
            _ = try solver.buildDataset(height: 614_400, tableSize: 1_024)
            let hit = try AutolykosV2.hit(
                message: message,
                nonce: [0, 0, 0, 0, 0, 0, 0, 42],
                height: 614_400,
                tableSize: 1_024)
            var target = hit.limbs
            target[7] += 1
            let submissions = try (0..<depth).map { _ in
                try solver.enqueueSearch(
                    message: message, target: UInt256(limbs: target),
                    baseNonce: 42, nonceCount: 1)
            }
            for submission in submissions {
                XCTAssertEqual(try submission.wait().candidates, [42])
            }
        }
        XCTAssertThrowsError(try MetalAutolykosSolver(searchPipelineDepth: 0))
        XCTAssertThrowsError(try MetalAutolykosSolver(buildPipelineDepth: 5))
    }

    func testBuildPipelineDepthsOneThroughFourDrainSubmittedWorkOnCancellation() throws {
        for depth in 1...4 {
            let solver = try MetalAutolykosSolver(
                synchronousBuildChunkElements: 64,
                searchPipelineDepth: 1,
                buildPipelineDepth: depth)
            var checks = 0
            XCTAssertThrowsError(try solver.buildDataset(
                height: 614_400,
                tableSize: 1_024,
                shouldContinue: {
                    checks += 1
                    return checks <= depth
                })) { error in
                    guard case MetalSolverError.cancelled = error else {
                        return XCTFail("Expected cancellation at depth \(depth), got \(error)")
                    }
                }
            let metrics = solver.datasetWorkMetrics()
            XCTAssertEqual(metrics.buildCommandsCompleted, depth)
            XCTAssertEqual(metrics.coldBuildsCancelled, 1)
            XCTAssertEqual(
                metrics.coldBuildGPUSeconds,
                metrics.buildCommandGPUSeconds,
                accuracy: 1e-9)
        }
    }

    private func fingerprint(
        name: String = "Apple M4",
        architecture: String = "applegpu_g16g",
        family: Int? = 9
    ) -> GPUArchitectureFingerprint {
        GPUArchitectureFingerprint(
            deviceName: name,
            architectureName: architecture,
            highestKnownAppleFamily: family,
            searchThreadExecutionWidth: 32,
            searchMaxThreadsPerThreadgroup: 1_024,
            buildThreadExecutionWidth: 32,
            buildMaxThreadsPerThreadgroup: 1_024,
            operatingSystemBuild: "25G91")
    }

    private func cacheIdentity(
        binary: String,
        architecture: String,
        profile: PerformanceProfile
    ) -> AutotuneCacheIdentity {
        AutotuneCacheIdentity(
            binarySHA256: binary,
            fingerprint: fingerprint(architecture: architecture),
            profile: profile,
            normalizedOverrides: MetalExecutionOverrides().normalized,
            workloadSignature: "u32pair-inline-m/overlap/search")
    }
}
