import Foundation
import Testing
@testable import MetalErgoCore

struct PerformanceTuningTests {
    @Test func testSafeFallbackIsM1CompatibleAndProfileSpecific() {
        let efficiency = MetalExecutionConfiguration.safeFallback(profile: .efficiency)
        #expect(efficiency.searchThreadgroupSize == 128)
        #expect(efficiency.datasetThreadgroupSize == 256)
        #expect(efficiency.batchNonces == 262_144)
        #expect(efficiency.prebuildBatchNonces == 65_536)
        #expect(efficiency.synchronousBuildChunkElements == 2_097_152)
        #expect(efficiency.prefetchBuildChunkElements == 1_048_576)
        #expect(efficiency.searchPipelineDepth == 2)
        #expect(efficiency.buildPipelineDepth == 2)
        #expect(MetalExecutionConfiguration.safeFallback(profile: .peak).batchNonces == 1_048_576)
    }

    @Test func testKnownFamilyClassificationStopsAtInstalledSDKBoundary() {
        #expect(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: []) == nil)
        #expect(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7]) == 7)
        #expect(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7, 8]) == 8)
        #expect(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7, 8, 9]) == 9)
        #expect(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7, 8, 9, 10]) == 10)
        #expect(GPUArchitectureFingerprint.highestKnownAppleFamily(
            supportedFamilies: [7, 11]) == 7)
    }

    @Test func testGenerationClassificationIncludesM6WithoutInventingMetalFamily() {
        #expect(GPUArchitectureFingerprint.generation(for: "Apple M1 Max") == .m1)
        #expect(GPUArchitectureFingerprint.generation(for: "Apple M2 Pro") == .m2)
        #expect(GPUArchitectureFingerprint.generation(for: "Apple M3 Ultra") == .m3)
        #expect(GPUArchitectureFingerprint.generation(for: "Apple M4") == .m4)
        #expect(GPUArchitectureFingerprint.generation(for: "Apple M5 Ultra") == .m5)
        #expect(GPUArchitectureFingerprint.generation(for: "Apple M6 Pro") == .m6)
        #expect(GPUArchitectureFingerprint.generation(for: "Future Apple GPU") == .unknown)
        let future = fingerprint(name: "Apple M6", architecture: "applegpu_future", family: nil)
        #expect(future.generation == .m6)
        #expect(future.familyName == "unknown")
    }

    @Test func testResolverPrecedenceIsExplicitThenCacheThenTuningThenFallback() {
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
        #expect(resolved.configuration.batchNonces == 777_216)
        #expect(resolved.configuration.searchPipelineDepth == 4)
        #expect(resolved.provenance["batch_nonces"] == .explicit)
        #expect(resolved.provenance["search_pipeline_depth"] == .cache)
        #expect(resolved.cacheKey == "test")
    }

    @Test func testCandidateSetsRespectSIMDWidthAndImprovementGate() {
        #expect(AutotuningPolicy.buildThreadgroupCandidates(width: 32, limit: 256) == [32, 64, 128, 256])
        #expect(AutotuningPolicy.buildThreadgroupCandidates(width: 64, limit: 128) == [64, 128])
        #expect(AutotuningPolicy.buildThreadgroupCandidates(width: 32, limit: 32) == [32])
        #expect(AutotuningPolicy.buildThreadgroupCandidates(width: 64, limit: 32) == [])
        #expect(AutotuningPolicy.threadgroupCandidates(width: 32, limit: 256) == [64, 128, 256])
        #expect(AutotuningPolicy.threadgroupCandidates(width: 64, limit: 128) == [64, 128])
        #expect(!AutotuningPolicy.isMeaningfulImprovement(
            baseline: [100, 100], candidate: [101.99, 101.99]))
        #expect(AutotuningPolicy.isMeaningfulImprovement(
            baseline: [100, 100], candidate: [102, 102]))
        #expect(AutotuningPolicy.pipelineDepthCandidates == [1, 2, 3, 4])
    }

    @Test func testBudgetAndThermalSafetyGates() {
        let start = Date(timeIntervalSince1970: 1_000)
        let budget = AutotuningBudget(seconds: 120, now: start)
        #expect(budget.hasTimeRemaining(at: start.addingTimeInterval(119.999)))
        #expect(!budget.hasTimeRemaining(at: start.addingTimeInterval(120)))
        #expect(!AutotuningSafety.shouldAbort(thermalState: .nominal))
        #expect(!AutotuningSafety.shouldAbort(thermalState: .fair))
        #expect(AutotuningSafety.shouldAbort(thermalState: .serious))
        #expect(AutotuningSafety.shouldAbort(thermalState: .critical))
    }

    @Test func testCacheIsKeyedByArchitectureBinaryAndProfileAndRecoversFromCorruption() throws {
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
        #expect(store.save(record))
        #expect(store.load(identity: identity) == record)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #expect(store.load(identity: cacheIdentity(
            binary: "bbb", architecture: "g16", profile: .efficiency)) == nil)
        #expect(store.load(identity: cacheIdentity(
            binary: "aaa", architecture: "g17", profile: .efficiency)) == nil)
        #expect(store.load(identity: cacheIdentity(
            binary: "aaa", architecture: "g16", profile: .peak)) == nil)

        try Data("not-json".utf8).write(to: url)
        #expect(store.load(identity: identity) == nil)
        #expect(store.save(record))
        #expect(store.load(identity: identity) == record)
    }

    @Test func testConcurrentCacheWritesRemainDecodableAndPreserveRecords() {
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
            #expect(store.load(identity: identity) != nil)
        }
    }

    @Test func testSemanticallyInvalidCacheRecordsAreIgnoredAndReplaceable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ergometal-invalid-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.json")
        let store = AutotuneCacheStore(url: url)
        let identity = cacheIdentity(binary: "test", architecture: "g16", profile: .peak)
        let valid = AutotuneRecord(identity: identity,
            configuration: .safeFallback(profile: .peak), measurements: [:],
            tunedAt: Date(timeIntervalSince1970: 123))
        #expect(store.save(valid))
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for (field, value) in [
            ("batchNonces", 0), ("prebuildBatchNonces", -1),
            ("synchronousBuildChunkElements", 0), ("prefetchBuildChunkElements", 16_777_217),
            ("searchPipelineDepth", 0), ("buildPipelineDepth", 5),
            ("searchThreadgroupSize", 33), ("datasetThreadgroupSize", 2_048)
        ] {
            var envelope = original
            var records = try #require(envelope["records"] as? [[String: Any]])
            var configuration = try #require(records[0]["configuration"] as? [String: Any])
            configuration[field] = value
            records[0]["configuration"] = configuration
            envelope["records"] = records
            try JSONSerialization.data(withJSONObject: envelope).write(to: url)
            #expect(store.load(identity: identity) == nil, "accepted invalid \(field)=\(value)")
        }
        #expect(store.save(valid))
        #expect(store.load(identity: identity) == valid)
        var invalid = valid.configuration
        invalid.batchNonces = 0
        #expect(!store.save(AutotuneRecord(identity: identity,
            configuration: invalid, measurements: [:])))
        #expect(store.load(identity: identity) == valid)
    }

    @Test func testExecutionConfigurationRespectsDevicePipelineLimits() {
        let limited = GPUArchitectureFingerprint(deviceName: "Test", architectureName: "test",
            highestKnownAppleFamily: nil, searchThreadExecutionWidth: 32,
            searchMaxThreadsPerThreadgroup: 64, buildThreadExecutionWidth: 32,
            buildMaxThreadsPerThreadgroup: 128, operatingSystemBuild: "test")
        var configuration = MetalExecutionConfiguration.safeFallback(profile: .peak)
        #expect(!configuration.isValid(for: limited))
        configuration.searchThreadgroupSize = 64
        configuration.datasetThreadgroupSize = 128
        #expect(configuration.isValid(for: limited))
    }

    @Test func testPipelineDepthsOneThroughFourPreserveSearchConsensus() throws {
        let message = Blake2b256.hash(Array("pipeline-depth-test".utf8))
        for depth in 1...4 {
            let solver = try MetalAutolykosSolver(
                searchPipelineDepth: depth, buildPipelineDepth: depth)
            #expect(solver.searchPipelineDepth == depth)
            #expect(solver.buildPipelineDepth == depth)
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
                #expect(try submission.wait().candidates == [42])
            }
        }
        #expect(throws: (any Error).self) { try MetalAutolykosSolver(searchPipelineDepth: 0) }
        #expect(throws: (any Error).self) { try MetalAutolykosSolver(buildPipelineDepth: 5) }
    }

    @Test func testBuildPipelineDepthsOneThroughFourDrainSubmittedWorkOnCancellation() throws {
        for depth in 1...4 {
            let solver = try MetalAutolykosSolver(
                synchronousBuildChunkElements: 64,
                searchPipelineDepth: 1,
                buildPipelineDepth: depth)
            var checks = 0
            #expect {
                try solver.buildDataset(
                    height: 614_400,
                    tableSize: 1_024,
                    shouldContinue: {
                        checks += 1
                        return checks <= depth
                    })
            } throws: { error in
                if case MetalSolverError.cancelled = error { true } else { false }
            }
            let metrics = solver.datasetWorkMetrics()
            #expect(metrics.buildCommandsCompleted == depth)
            #expect(metrics.coldBuildsCancelled == 1)
            #expect(abs(metrics.coldBuildGPUSeconds - metrics.buildCommandGPUSeconds) <= 1e-9)
        }
    }

    @Test func testCancelledBuildResumesDrainedChunksWithExactConsensusAtEveryDepth() throws {
        for depth in 1...4 {
            let solver = try MetalAutolykosSolver(
                synchronousBuildChunkElements: 64, datasetThreadgroupSize: 32,
                buildPipelineDepth: depth)
            try cancelBuild(solver, height: 614_400, tableSize: 1_025, afterChecks: depth)
            #expect(throws: (any Error).self) { try solver.datasetElements(at: [0]) }
            #expect(throws: (any Error).self) {
                try solver.search(
                    message: [UInt8](repeating: 0, count: 32), target: .zero,
                    baseNonce: 0, nonceCount: 1)
            }
            #expect(solver.datasetWorkMetrics().buildCommandsCompleted == depth)

            let build = try solver.buildDataset(
                height: 614_400, tableSize: 1_025, preserveOnCancellation: true)
            let indices = [0, 1, 63, 64, depth * 64 - 1, depth * 64, 1_024]
            #expect(try solver.datasetElements(at: indices) == (try indices.map {
                try AutolykosV2.datasetElement(index: $0, height: 614_400)
            }))
            let metrics = solver.datasetWorkMetrics()
            #expect(metrics.buildCommandsCompleted == 17, "Recomputed a completed chunk")
            #expect(metrics.coldBuildsCancelled == 1)
            #expect(metrics.coldBuildsCompleted == 1)
            #expect(metrics.coldBuildsFailed == 0)
            #expect(metrics.coldBuildsResumed == 1)
            #expect(metrics.coldBuildResumedElements == UInt64(depth * 64))
            #expect(abs(build.seconds - metrics.coldBuildWallSeconds) <= 1e-9)
            #expect(abs(build.gpuSeconds - metrics.coldBuildGPUSeconds) <= 1e-9)
            #expect(abs(build.gpuSeconds - metrics.buildCommandGPUSeconds) <= 1e-9)
            #expect(try solver.buildDataset(
                height: 614_400, tableSize: 1_025).source == .cached)
            #expect(solver.datasetWorkMetrics() == metrics)
        }
    }

    @Test func testResumptionRejectsDifferentHeightSizeAndOptOut() throws {
        for (height, size, preserve) in [(614_401, 257, true), (614_400, 513, true), (614_400, 257, false)] {
            let solver = try MetalAutolykosSolver(synchronousBuildChunkElements: 64)
            try cancelBuild(solver, height: 614_400, tableSize: 257, afterChecks: 2)
            _ = try solver.buildDataset(
                height: height, tableSize: size, preserveOnCancellation: preserve)
            let metrics = solver.datasetWorkMetrics()
            #expect(metrics.coldBuildsResumed == 0)
            #expect(metrics.buildCommandsCompleted == 2 + (size + 63) / 64)
            let indices = [0, 63, 64, size - 1]
            #expect(try solver.datasetElements(at: indices) == (try indices.map {
                try AutolykosV2.datasetElement(index: $0, height: height)
            }))
        }
    }

    @Test func testRepeatedCancellationPreservesOneContiguousPrefix() throws {
        let solver = try MetalAutolykosSolver(synchronousBuildChunkElements: 64)
        try cancelBuild(solver, height: 614_400, tableSize: 513, afterChecks: 2)
        try cancelBuild(solver, height: 614_400, tableSize: 513, afterChecks: 2)
        let build = try solver.buildDataset(
            height: 614_400, tableSize: 513, preserveOnCancellation: true)
        let metrics = solver.datasetWorkMetrics()
        #expect(metrics.buildCommandsCompleted == 9)
        #expect(metrics.coldBuildsResumed == 2)
        #expect(metrics.coldBuildResumedElements == 128 + 256)
        #expect(metrics.coldBuildsCancelled == 2)
        #expect(abs(build.seconds - metrics.coldBuildWallSeconds) <= 1e-9)
        let indices = [0, 127, 128, 255, 256, 512]
        #expect(try solver.datasetElements(at: indices) == (try indices.map {
            try AutolykosV2.datasetElement(index: $0, height: 614_400)
        }))
    }

    @Test func testCancellationBeforeSubmissionDoesNotRetainAnEmptyBuild() throws {
        let solver = try MetalAutolykosSolver(synchronousBuildChunkElements: 64)
        try cancelBuild(solver, height: 614_400, tableSize: 257, afterChecks: 0)
        _ = try solver.buildDataset(height: 614_400, tableSize: 257, preserveOnCancellation: true)
        #expect(solver.datasetWorkMetrics().coldBuildsResumed == 0)
        #expect(solver.datasetWorkMetrics().buildCommandsCompleted == 5)
    }

    private func cancelBuild(
        _ solver: MetalAutolykosSolver, height: Int, tableSize: Int, afterChecks limit: Int
    ) throws {
        var checks = 0
        #expect {
            try solver.buildDataset(
                height: height, tableSize: tableSize, preserveOnCancellation: true,
                shouldContinue: {
                    checks += 1
                    return checks <= limit
                })
        } throws: { error in
            if case MetalSolverError.cancelled = error { true } else { false }
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
