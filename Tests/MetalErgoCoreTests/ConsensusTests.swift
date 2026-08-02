import XCTest
@testable import MetalErgoCore

final class ConsensusTests: XCTestCase {
    func testBlake2b256Vectors() {
        XCTAssertEqual(Blake2b256.hash([]).hex,
            "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
        XCTAssertEqual(Blake2b256.hash(Array("abc".utf8)).hex,
            "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
    }

    func testCalcNConsensusBoundaries() {
        XCTAssertEqual(AutolykosV2.calcN(height: 614_399), 67_108_864)
        XCTAssertEqual(AutolykosV2.calcN(height: 614_400), 70_464_240)
        XCTAssertEqual(AutolykosV2.calcN(height: 665_599), 70_464_240)
        XCTAssertEqual(AutolykosV2.calcN(height: 665_600), 73_987_410)
        XCTAssertEqual(AutolykosV2.calcN(version: 1, height: 9_000_000), 67_108_864)
        XCTAssertEqual(AutolykosV2.calcN(height: 4_198_400), AutolykosV2.calcN(height: 9_000_000))
    }

    func testIndependentAutolykosFixture() throws {
        let message = try XCTUnwrap([UInt8](hex: "fb4ea208049836e0b879b90da0ab9b2173cd84f5889b85668378081f95e0bbf6"))
        let nonce = try XCTUnwrap([UInt8](hex: "000000000000002a"))
        let hit = try AutolykosV2.hit(message: message, nonce: nonce, height: 614_400, tableSize: 1_024)
        XCTAssertEqual(hit.hex, "2d9b2daa19cba01c595881ed4cc12eb24f3417d4b2e76f062ae1f355464deede")
    }

    func testCPUConsensusRejectsOutOfRangeHeightAndDatasetIndex() {
        XCTAssertThrowsError(try AutolykosV2.datasetElement(index: -1, height: 614_400))
        XCTAssertThrowsError(try AutolykosV2.datasetElement(index: 0, height: -1))
        XCTAssertThrowsError(try AutolykosV2.hit(
            message: [UInt8](repeating: 0, count: 32),
            nonce: [UInt8](repeating: 0, count: 8),
            height: -1))
    }

    func testOfficialMainnetAutolykosVector() throws {
        let message = try XCTUnwrap([UInt8](
            hex: "548c3e602a8f36f8f2738f5f643b02425038044d98543a51cabaa9785e7e864f"))
        let nonce = try XCTUnwrap([UInt8](hex: "0000000000003105"))
        let hit = try AutolykosV2.hit(message: message, nonce: nonce, height: 614_400)
        XCTAssertEqual(
            hit.hex,
            "0002fcb113fe65e5754959872dfdbffea0489bf830beb4961ddc0e9e66a1412a")
    }

    func testDecimalUInt256ParsingAndAddition() throws {
        let decimal = try XCTUnwrap(UInt256(encoded: "115792089237316195423570985008687907853269984665640564039457584007913129639935"))
        XCTAssertEqual(decimal, .max)
        var value = UInt256(bigEndian: [0xff])
        value.add(UInt256(bigEndian: [1]))
        XCTAssertEqual(value.hex.suffix(4), "0100")
    }

    func testErgoAddressValidationForNetworkAndType() {
        let testPayoutAddress = "9emWVfBsLPbV6dvpugpjsjwKwETT7yBBfCyMefXbZDory7kDUVg"
        XCTAssertTrue(ErgoAddress.isPlausible(testPayoutAddress, network: .mainnet))
        XCTAssertFalse(ErgoAddress.isPlausible(testPayoutAddress, network: .testnet))
        XCTAssertFalse(ErgoAddress.isPlausible(testPayoutAddress, network: "devnet"))

        XCTAssertTrue(ErgoAddress.isPlausible(
            "8UApt8czfFVuTgQmMwtsRBZ4nfWquNiSwCWUjMg", network: .mainnet))
        XCTAssertTrue(ErgoAddress.isPlausible(
            "4MQyML64GnzMxZgm", network: .mainnet))
        XCTAssertTrue(ErgoAddress.isPlausible(
            "3WvsT2Gm4EpsM9Pg18PdY6XyhNNMqXDsvJTbbf6ihLvAmSb7u5RN", network: .testnet))

        let corrupted = String(testPayoutAddress.dropLast()) + "h"
        XCTAssertFalse(ErgoAddress.isPlausible(corrupted, network: .mainnet))
    }

    func testNonceSpaceHandlesUInt64BoundaryWithoutOverflow() throws {
        XCTAssertEqual(NonceSpace.maximumOffset(variableBytes: 0), 0)
        XCTAssertEqual(NonceSpace.maximumOffset(variableBytes: 6), 0x0000_ffff_ffff_ffff)
        XCTAssertEqual(NonceSpace.maximumOffset(variableBytes: 8), .max)
        XCTAssertNil(NonceSpace.maximumOffset(variableBytes: 9))

        XCTAssertEqual(NonceSpace.batchSize(offset: 0, maximumOffset: .max, requested: 65_536), 65_536)
        XCTAssertEqual(NonceSpace.batchSize(offset: .max - 9, maximumOffset: .max, requested: 65_536), 10)
        XCTAssertNil(NonceSpace.advance(offset: .max - 9, count: 10, maximumOffset: .max))
        XCTAssertEqual(NonceSpace.advance(offset: 0, count: 65_536, maximumOffset: .max), 65_536)
    }

    func testMetalMatchesCPUForFixture() throws {
        let solver = try MetalAutolykosSolver()
        _ = try solver.buildDataset(height: 614_400, tableSize: 1_024)
        let message = try XCTUnwrap([UInt8](hex: "fb4ea208049836e0b879b90da0ab9b2173cd84f5889b85668378081f95e0bbf6"))
        let cpuHit = try AutolykosV2.hit(message: message, nonce: [0,0,0,0,0,0,0,42], height: 614_400, tableSize: 1_024)
        let rejected = try solver.search(message: message, target: cpuHit, baseNonce: 42, nonceCount: 1)
        XCTAssertEqual(rejected.candidates, [], "Metal hit must use strict less-than target semantics")
        var nextLimbs = cpuHit.limbs
        nextLimbs[7] += 1
        let accepted = try solver.search(message: message, target: UInt256(limbs: nextLimbs), baseNonce: 42, nonceCount: 1)
        XCTAssertEqual(accepted.candidates, [42], "Metal and CPU must calculate the same 256-bit hit")
    }

    func testDatasetKernelsMatchCPUElementsExactly() throws {
        let height = 614_401
        let tableSize = 257
        let indices = [0, 1, 2, 7, 31, 63, 127, 128, 255, 256]

        for kernel in DatasetKernel.allCases {
            let solver = try MetalAutolykosSolver(datasetKernel: kernel)
            _ = try solver.buildDataset(height: height, tableSize: tableSize)
            let actual = try solver.datasetElements(at: indices)
            let expected = try indices.map {
                try AutolykosV2.datasetElement(index: $0, height: height)
            }
            XCTAssertEqual(actual, expected, "Dataset kernel \(kernel.rawValue) diverged")
        }
    }

    func testGatherOnlySearchKernelExecutesOnlyWhenSelected() throws {
        let defaultSolver = try MetalAutolykosSolver()
        XCTAssertEqual(defaultSolver.searchKernel, .search)

        let gatherSolver = try MetalAutolykosSolver(searchKernel: .gatherOnly)
        XCTAssertEqual(gatherSolver.searchKernel, .gatherOnly)
        _ = try gatherSolver.buildDataset(height: 614_400, tableSize: 1_024)
        let batch = try gatherSolver.search(
            message: [UInt8](repeating: 0x5a, count: 32),
            target: .zero,
            baseNonce: 0,
            nonceCount: 1_024)
        XCTAssertEqual(batch.candidates, [])
    }

    func testDatasetElementReadbackRejectsInvalidIndices() throws {
        let solver = try MetalAutolykosSolver()
        _ = try solver.buildDataset(height: 614_400, tableSize: 32)
        XCTAssertEqual(try solver.datasetElements(at: []), [])
        XCTAssertThrowsError(try solver.datasetElements(at: [-1]))
        XCTAssertThrowsError(try solver.datasetElements(at: [32]))
    }

    func testMetalMatchesCPUForNontrivialNonceBytePatterns() throws {
        let solver = try MetalAutolykosSolver()
        let height = 614_401
        // A non-power-of-two table exercises both reciprocal-modulo paths.
        let tableSize = 257
        _ = try solver.buildDataset(height: height, tableSize: tableSize)
        let message = try XCTUnwrap([UInt8](
            hex: "00112233445566778899aabbccddeeffffeeddccbbaa99887766554433221100"))

        for nonce in [UInt64(0), 0x0102_0304_0506_0708, UInt64.max] {
            let nonceBytes = stride(from: 56, through: 0, by: -8).map {
                UInt8(truncatingIfNeeded: nonce >> UInt64($0))
            }
            let cpuHit = try AutolykosV2.hit(
                message: message, nonce: nonceBytes, height: height, tableSize: tableSize)
            var next = cpuHit.limbs
            for index in stride(from: 7, through: 0, by: -1) {
                if next[index] == .max {
                    next[index] = 0
                } else {
                    next[index] += 1
                    break
                }
            }

            XCTAssertEqual(try solver.search(
                message: message, target: cpuHit, baseNonce: nonce, nonceCount: 1
            ).candidates, [])
            XCTAssertEqual(try solver.search(
                message: message, target: UInt256(limbs: next),
                baseNonce: nonce, nonceCount: 1
            ).candidates, [nonce])
        }
    }

    func testMetalQueuesTwoSearchesWithIndependentResults() throws {
        let solver = try MetalAutolykosSolver()
        _ = try solver.buildDataset(height: 614_400, tableSize: 2_048)
        let message = [UInt8](repeating: 0xa5, count: 32)

        let first = try solver.enqueueSearch(
            message: message, target: .max, baseNonce: 1_000, nonceCount: 64)
        let second = try solver.enqueueSearch(
            message: message, target: .max, baseNonce: 2_000, nonceCount: 64)

        XCTAssertEqual(first.baseNonce, 1_000)
        XCTAssertEqual(second.baseNonce, 2_000)
        let firstBatch = try first.wait()
        let secondBatch = try second.wait()
        XCTAssertEqual(firstBatch.candidates, Array(1_000..<1_064).map(UInt64.init))
        XCTAssertEqual(secondBatch.candidates, Array(2_000..<2_064).map(UInt64.init))
        XCTAssertEqual(firstBatch.nonceCount, 64)
        XCTAssertEqual(secondBatch.nonceCount, 64)
        XCTAssertGreaterThanOrEqual(firstBatch.gpuSeconds, 0)
        XCTAssertGreaterThanOrEqual(secondBatch.wallSeconds, 0)
        let metrics = solver.datasetWorkMetrics()
        XCTAssertGreaterThanOrEqual(metrics.buildCommandsCompleted, 1)
        XCTAssertEqual(metrics.searchCommandsCompleted, 2)
        XCTAssertGreaterThanOrEqual(
            metrics.buildCommandWallSeconds, metrics.buildCommandGPUSeconds)
        XCTAssertGreaterThanOrEqual(
            metrics.searchCommandWallSeconds, metrics.searchCommandGPUSeconds)
    }

    func testQueuedSearchKeepsUnretainedCommandResourcesAlive() throws {
        var solver: MetalAutolykosSolver? = try MetalAutolykosSolver()
        _ = try solver?.buildDataset(height: 614_400, tableSize: 2_048)
        let submission = try XCTUnwrap(solver).enqueueSearch(
            message: [UInt8](repeating: 0x5a, count: 32),
            target: .zero,
            baseNonce: 7_000,
            nonceCount: 262_144)

        solver = nil
        let batch = try submission.wait()
        XCTAssertEqual(batch.baseNonce, 7_000)
        XCTAssertEqual(batch.nonceCount, 262_144)
        XCTAssertEqual(batch.candidates, [])
        XCTAssertGreaterThanOrEqual(batch.gpuSeconds, 0)
    }

    func testMetalRejectsUnsafeInputsAndCandidateOverflow() throws {
        let solver = try MetalAutolykosSolver()
        XCTAssertThrowsError(try solver.buildDataset(height: -1, tableSize: 1_024))
        let initialBuild = try solver.buildDataset(height: 614_400, tableSize: 1_024)
        let reusedBuild = try solver.buildDataset(height: 614_400, tableSize: 1_024)
        XCTAssertEqual(reusedBuild.seconds, initialBuild.seconds)
        XCTAssertEqual(reusedBuild.source, .cached)
        XCTAssertEqual(solver.datasetWorkMetrics().coldBuildsCompleted, 1)
        XCTAssertThrowsError(try MetalAutolykosSolver(synchronousBuildChunkElements: 0))
        XCTAssertThrowsError(try MetalAutolykosSolver(prefetchBuildChunkElements: 0))
        XCTAssertThrowsError(try MetalAutolykosSolver(datasetThreadgroupSize: 0))
        let message = [UInt8](repeating: 0, count: 32)
        XCTAssertThrowsError(try solver.search(
            message: message, target: .max, baseNonce: 0, nonceCount: 0))
        XCTAssertThrowsError(try solver.search(
            message: message, target: .max, baseNonce: 0, nonceCount: 1, threadgroupSize: 0))
        XCTAssertThrowsError(try solver.search(
            message: message, target: .max, baseNonce: .max, nonceCount: 2))
        XCTAssertThrowsError(try solver.search(
            message: message, target: .max, baseNonce: 0, nonceCount: 257))
    }

    func testDatasetBuildPipelinesChunksAndPreservesMetrics() throws {
        let solver = try MetalAutolykosSolver(
            synchronousBuildChunkElements: 64,
            prefetchBuildChunkElements: 64)
        let tableSize = 257
        let cold = try solver.buildDataset(height: 614_400, tableSize: tableSize)
        let coldMetrics = solver.datasetWorkMetrics()

        XCTAssertEqual(coldMetrics.buildCommandsCompleted, 5)
        XCTAssertEqual(
            coldMetrics.coldBuildGPUSeconds,
            cold.gpuSeconds,
            accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(
            coldMetrics.buildCommandWallSeconds,
            coldMetrics.buildCommandGPUSeconds)
        XCTAssertLessThanOrEqual(coldMetrics.buildCommandWallSeconds, cold.seconds)
        let indices = [0, 63, 64, 127, 128, 255, 256]
        XCTAssertEqual(
            try solver.datasetElements(at: indices),
            try indices.map { try AutolykosV2.datasetElement(index: $0, height: 614_400) })

        XCTAssertTrue(try solver.prefetchDataset(height: 614_401, tableSize: tableSize))
        let prefetched = try solver.buildDataset(height: 614_401, tableSize: tableSize)
        let metrics = solver.datasetWorkMetrics()
        XCTAssertEqual(prefetched.source, .prefetched)
        XCTAssertEqual(metrics.buildCommandsCompleted, 10)
        XCTAssertEqual(metrics.coldBuildsCompleted, 1)
        XCTAssertEqual(metrics.prefetchBuildsCompleted, 1)
        XCTAssertEqual(metrics.prefetchBuildGPUSeconds, prefetched.gpuSeconds, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(
            metrics.buildCommandWallSeconds,
            cold.seconds + prefetched.seconds)
    }

    func testPipelinedBuildCancellationDrainsSubmittedCommands() throws {
        let solver = try MetalAutolykosSolver(synchronousBuildChunkElements: 32_768)
        var continuationChecks = 0

        XCTAssertThrowsError(try solver.buildDataset(
            height: 614_400,
            tableSize: 262_144,
            shouldContinue: {
                continuationChecks += 1
                return continuationChecks <= 2
            }
        )) { error in
            guard case MetalSolverError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }

        let metrics = solver.datasetWorkMetrics()
        XCTAssertEqual(continuationChecks, 3)
        XCTAssertEqual(metrics.buildCommandsCompleted, 2)
        XCTAssertEqual(metrics.coldBuildsCancelled, 1)
        XCTAssertEqual(
            metrics.coldBuildGPUSeconds,
            metrics.buildCommandGPUSeconds,
            accuracy: 1e-9)
    }

    func testPipelinedPrefetchCancellationDrainsSubmittedCommands() throws {
        let solver = try MetalAutolykosSolver(prefetchBuildChunkElements: 32_768)
        XCTAssertTrue(try solver.prefetchDataset(height: 614_400, tableSize: 2_097_152))

        let deadline = Date(timeIntervalSinceNow: 2)
        while solver.prefetchStatus()?.completedElements == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertGreaterThan(solver.prefetchStatus()?.completedElements ?? 0, 0)
        solver.cancelPrefetch(waitUntilFinished: true)

        let metrics = solver.datasetWorkMetrics()
        XCTAssertEqual(metrics.prefetchBuildsCancelled, 1)
        XCTAssertEqual(metrics.prefetchBuildsCompleted, 0)
        XCTAssertGreaterThan(metrics.buildCommandsCompleted, 0)
        XCTAssertEqual(
            metrics.prefetchWastedGPUSeconds,
            metrics.buildCommandGPUSeconds,
            accuracy: 1e-9)
    }

    func testMetalPrefetchPromotesNextHeightAndCanCancelBuild() throws {
        let solver = try MetalAutolykosSolver()
        _ = try solver.buildDataset(height: 614_400, tableSize: 1_024)
        XCTAssertTrue(try solver.prefetchDataset(height: 614_401, tableSize: 1_024))
        let prefetched = try solver.buildDataset(height: 614_401, tableSize: 1_024)
        XCTAssertEqual(prefetched.source, .prefetched)
        XCTAssertEqual(prefetched.height, 614_401)
        XCTAssertGreaterThanOrEqual(prefetched.gpuSeconds, 0)
        XCTAssertNil(solver.prefetchStatus())
        let metrics = solver.datasetWorkMetrics()
        XCTAssertEqual(metrics.coldBuildsCompleted, 1)
        XCTAssertEqual(metrics.prefetchBuildsStarted, 1)
        XCTAssertEqual(metrics.prefetchBuildsCompleted, 1)
        XCTAssertEqual(metrics.prefetchBuildsDiscarded, 0)

        let message = try XCTUnwrap([UInt8](
            hex: "fb4ea208049836e0b879b90da0ab9b2173cd84f5889b85668378081f95e0bbf6"))
        let nonce = [UInt8](repeating: 0, count: 7) + [42]
        let cpuHit = try AutolykosV2.hit(
            message: message, nonce: nonce, height: 614_401, tableSize: 1_024)
        var targetLimbs = cpuHit.limbs
        targetLimbs[7] += 1
        let search = try solver.search(
            message: message, target: UInt256(limbs: targetLimbs),
            baseNonce: 42, nonceCount: 1)
        XCTAssertEqual(search.candidates, [42])

        XCTAssertThrowsError(try solver.buildDataset(
            height: 614_402, tableSize: 1_024, shouldContinue: { false })) { error in
            guard case MetalSolverError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
    }

    func testMetalPrefetchAndSearchBothMakeProgress() throws {
        let solver = try MetalAutolykosSolver(datasetScheduling: .serialized)
        let tableSize = 262_144
        _ = try solver.buildDataset(height: 614_400, tableSize: tableSize)
        XCTAssertTrue(try solver.prefetchDataset(height: 614_401, tableSize: tableSize))

        let deadline = Date(timeIntervalSinceNow: 5)
        var searches = 0
        while solver.prefetchStatus()?.finished == false, Date() < deadline {
            _ = try solver.search(
                message: [UInt8](repeating: 0, count: 32),
                target: .zero,
                baseNonce: UInt64(searches),
                nonceCount: 1)
            searches += 1
        }

        let status = try XCTUnwrap(solver.prefetchStatus())
        XCTAssertTrue(status.finished)
        XCTAssertNil(status.errorDescription)
        XCTAssertGreaterThan(searches, 0)
        XCTAssertEqual(
            try solver.buildDataset(height: 614_401, tableSize: tableSize).source,
            .prefetched)
    }

    func testOverlappedDatasetSchedulingPreservesConsensusAndProgress() throws {
        let solver = try MetalAutolykosSolver(
            prefetchBuildChunkElements: 16_384,
            datasetKernel: .u32Pair,
            datasetScheduling: .overlap)
        let tableSize = 131_072
        _ = try solver.buildDataset(height: 614_400, tableSize: tableSize)
        XCTAssertTrue(try solver.prefetchDataset(height: 614_401, tableSize: tableSize))

        let message = [UInt8](repeating: 0x5a, count: 32)
        var nonces = 0
        let deadline = Date(timeIntervalSinceNow: 5)
        while solver.prefetchStatus()?.finished == false, Date() < deadline {
            _ = try solver.search(
                message: message, target: .zero,
                baseNonce: UInt64(nonces), nonceCount: 64)
            nonces += 64
        }

        XCTAssertGreaterThan(nonces, 0)
        XCTAssertTrue(try XCTUnwrap(solver.prefetchStatus()).finished)
        XCTAssertEqual(
            try solver.buildDataset(height: 614_401, tableSize: tableSize).source,
            .prefetched)
        let indices = [0, 1, 65_535, 131_071]
        XCTAssertEqual(
            try solver.datasetElements(at: indices),
            try indices.map { try AutolykosV2.datasetElement(index: $0, height: 614_401) })
    }
}
