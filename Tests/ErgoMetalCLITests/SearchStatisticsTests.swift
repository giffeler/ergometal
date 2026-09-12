import XCTest
@testable import MetalErgoCore

final class SearchStatisticsTests: XCTestCase {
    private let batchNonces = 1_048_576

    private func batch(start: Double, end: Double, nonces: Int = 1_048_576) -> SearchBatch {
        SearchBatch(
            baseNonce: 0, nonceCount: nonces, candidates: [],
            wallStartTime: start, wallEndTime: end,
            gpuSeconds: 0.05, wallSeconds: max(0, end - start))
    }

    private func record(_ sample: SearchStatisticsSample, in stats: StatisticsStore) {
        sample.record(in: stats)
    }

    func testOverlappingPartialWindowUsesItsCompleteCommandInterval() throws {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        let secondsPerBatch = Double(batchNonces) / 15_400_000
        // FIFO submissions at depth four. Completion callbacks for the final
        // pending command can arrive just after the 16-command window closes.
        for index in 0..<16 {
            let sample = accumulator.append(batch(
                start: Double(max(0, index - 3)) * secondsPerBatch,
                end: Double(index + 1) * secondsPerBatch))
            if index < 15 { XCTAssertNil(sample) }
            if let sample { record(sample, in: stats) }
        }
        let frontier = 16 * secondsPerBatch
        let tailStart = 13 * secondsPerBatch
        let tailEnd = frontier + 0.000_018_458_333
        XCTAssertNil(accumulator.append(batch(start: tailStart, end: tailEnd)))
        record(try XCTUnwrap(accumulator.flush()), in: stats)

        XCTAssertEqual(
            stats.snapshot().hashrate,
            Double(batchNonces) / (tailEnd - tailStart), accuracy: 1e-6)
        XCTAssertEqual(stats.snapshot().nonces, UInt64(17 * batchNonces))
        XCTAssertEqual(stats.snapshot().searchSeconds, tailEnd, accuracy: 1e-12)
        XCTAssertNil(accumulator.flush())
    }

    func testDatasetBuildDoesNotRetainPreviousSearchRate() {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        stats.recordBatch(nonces: batchNonces, gpuSeconds: 0.05, wallSeconds: 0.1)
        XCTAssertGreaterThan(stats.snapshot().hashrate, 0)

        stats.update { $0.state = .buildingDataset }
        XCTAssertEqual(stats.snapshot().hashrate, 0)
        XCTAssertEqual(stats.refresh().hashrate, 0)
        stats.update { $0.state = .searching }
        XCTAssertEqual(stats.snapshot().hashrate, 0)
        XCTAssertEqual(stats.snapshot().nonces, UInt64(batchNonces))
    }

    func testWindowBoundariesAndEveryTailLengthAtPipelineDepthsOneThroughFour() throws {
        for depth in 1...4 {
            for tailCount in 1...15 {
                let stats = StatisticsStore(mode: .mining)
                stats.update { $0.state = .searching }
                var accumulator = SearchStatisticsAccumulator()
                let count = 32 + tailCount
                var samples: [SearchStatisticsSample] = []
                // Analytic union for m consecutive commands: (m - 1 + depth) / 8.
                for index in 0..<count {
                    if let sample = accumulator.append(batch(
                        start: Double(index) / 8,
                        end: Double(index + depth) / 8)) {
                        samples.append(sample)
                    }
                }
                samples.append(try XCTUnwrap(accumulator.flush()))
                XCTAssertNil(accumulator.flush())
                XCTAssertEqual(samples.count, 3)
                for (index, sample) in samples.enumerated() {
                    let windowCount = index < 2 ? 16 : tailCount
                    let windowSeconds = Double(windowCount - 1 + depth) / 8
                    XCTAssertEqual(sample.nonces, windowCount * batchNonces)
                    XCTAssertEqual(sample.hashrateWindowSeconds, windowSeconds)
                    XCTAssertEqual(
                        sample.activeSearchSeconds,
                        index == 0 ? windowSeconds : Double(windowCount) / 8)
                    sample.record(in: stats)
                    let snapshot = stats.snapshot()
                    XCTAssertEqual(
                        snapshot.hashrate, Double(windowCount * batchNonces) / windowSeconds,
                        accuracy: 1e-6, "depth=\(depth), tail=\(tailCount), window=\(index)")
                }
                let snapshot = stats.snapshot()
                let totalSeconds = Double(count - 1 + depth) / 8
                XCTAssertEqual(snapshot.nonces, UInt64(count * batchNonces))
                XCTAssertEqual(snapshot.searchSeconds, totalSeconds)
                XCTAssertEqual(snapshot.gpuSeconds, Double(count) * 0.05, accuracy: 1e-12)
                XCTAssertEqual(
                    snapshot.averageHashrate, Double(count * batchNonces) / totalSeconds,
                    accuracy: 1e-6)
                XCTAssertEqual(
                    snapshot.effectiveHashrate,
                    Double(snapshot.nonces) / snapshot.sampledAt.timeIntervalSince(snapshot.startedAt),
                    accuracy: 1e-6)
            }
        }
    }

    func testFlushRetainsFrontierForFullyCoveredAndOutOfOrderCompletions() throws {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        XCTAssertNil(accumulator.flush())
        try XCTUnwrap(accumulator.append(batch(start: 0, end: 10), flush: true)).record(in: stats)
        // Starts are FIFO, but a delayed callback can end after later commands.
        XCTAssertNil(accumulator.append(batch(start: 1, end: 7)))
        XCTAssertNil(accumulator.append(batch(start: 2, end: 6)))
        let covered = try XCTUnwrap(accumulator.flush())
        XCTAssertEqual(covered.activeSearchSeconds, 0)
        XCTAssertEqual(covered.hashrateWindowSeconds, 6)
        covered.record(in: stats)
        XCTAssertEqual(stats.snapshot().hashrate, Double(2 * batchNonces) / 6)
        XCTAssertEqual(stats.snapshot().searchSeconds, 10)
        XCTAssertNil(accumulator.flush())

        let next = try XCTUnwrap(accumulator.append(batch(start: 7, end: 11), flush: true))
        XCTAssertEqual(next.activeSearchSeconds, 1)
        XCTAssertEqual(next.hashrateWindowSeconds, 4)
        next.record(in: stats)
        XCTAssertEqual(stats.snapshot().nonces, UInt64(4 * batchNonces))
        XCTAssertEqual(stats.snapshot().searchSeconds, 11)
    }

    func testTimeGapsDoNotBecomeActiveTimeInsideOrBetweenWindows() throws {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        XCTAssertNil(accumulator.append(batch(start: 10, end: 11)))
        XCTAssertNil(accumulator.append(batch(start: 13, end: 15)))
        let first = try XCTUnwrap(accumulator.flush())
        XCTAssertEqual(first.hashrateWindowSeconds, 3)
        XCTAssertEqual(first.activeSearchSeconds, 3)
        first.record(in: stats)

        XCTAssertNil(accumulator.append(batch(start: 14, end: 16)))
        XCTAssertNil(accumulator.append(batch(start: 20, end: 21)))
        let second = try XCTUnwrap(accumulator.flush())
        XCTAssertEqual(second.hashrateWindowSeconds, 3)
        XCTAssertEqual(second.activeSearchSeconds, 2)
        second.record(in: stats)
        XCTAssertEqual(stats.snapshot().hashrate, Double(2 * batchNonces) / 3)
        XCTAssertEqual(stats.snapshot().searchSeconds, 5)
        XCTAssertEqual(stats.snapshot().averageHashrate, Double(4 * batchNonces) / 5)

        // Evaluate the synthetic session's duty cycle without sleeping or
        // involving the real system clock: 5 active seconds in 21 elapsed.
        var snapshot = stats.snapshot()
        snapshot.sampledAt = snapshot.startedAt.addingTimeInterval(21)
        XCTAssertEqual(snapshot.searchDutyCycle, 5.0 / 21, accuracy: 1e-12)
    }

    func testZeroTimeAndInvalidDurationCountNoncesWithoutInventingTime() throws {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        for _ in 0..<16 {
            accumulator.append(batch(start: 0, end: 0))?.record(in: stats)
        }
        XCTAssertEqual(stats.snapshot().nonces, UInt64(16 * batchNonces))
        XCTAssertEqual(stats.snapshot().searchSeconds, 0)
        XCTAssertEqual(stats.snapshot().hashrate, 0)
        XCTAssertEqual(stats.snapshot().averageHashrate, 0)
        XCTAssertNil(accumulator.flush())

        let valid = try XCTUnwrap(accumulator.append(batch(start: 2, end: 3), flush: true))
        valid.record(in: stats)
        XCTAssertEqual(stats.snapshot().searchSeconds, 1)
        XCTAssertEqual(stats.snapshot().hashrate, Double(batchNonces))
        XCTAssertNil(accumulator.append(batch(start: 3, end: 3)))
        XCTAssertNil(accumulator.append(batch(start: 4, end: 3)))
        let zero = try XCTUnwrap(accumulator.flush())
        XCTAssertEqual(zero.hashrateWindowSeconds, 0)
        XCTAssertEqual(zero.activeSearchSeconds, 0)
        zero.record(in: stats)
        XCTAssertEqual(stats.snapshot().nonces, UInt64(19 * batchNonces))
        XCTAssertEqual(stats.snapshot().searchSeconds, 1)
        XCTAssertEqual(stats.snapshot().hashrate, 0)
        XCTAssertEqual(stats.snapshot().averageHashrate, Double(19 * batchNonces))
    }

    func testVariableBatchSizesAndShortMeasuredIntervalsAreNotCapped() throws {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        XCTAssertNil(accumulator.append(batch(start: 0, end: 2, nonces: 100)))
        XCTAssertNil(accumulator.append(batch(start: 1, end: 3, nonces: 200)))
        try XCTUnwrap(accumulator.flush()).record(in: stats)
        XCTAssertEqual(stats.snapshot().nonces, 300)
        XCTAssertEqual(stats.snapshot().hashrate, 100)

        let end = 4.000_001
        try XCTUnwrap(accumulator.append(batch(start: 4, end: end), flush: true)).record(in: stats)
        XCTAssertEqual(stats.snapshot().hashrate, Double(batchNonces) / (end - 4))
        XCTAssertGreaterThan(stats.snapshot().hashrate, 1_000_000_000_000)
        XCTAssertEqual(stats.snapshot().nonces, UInt64(300 + batchNonces))
    }

    func testDatasetBoundaryFlushKeepsSeparateWindowsAndExcludesBuildGap() throws {
        let stats = StatisticsStore(mode: .benchmark)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        XCTAssertNil(accumulator.append(batch(start: 0, end: 1)))
        XCTAssertNil(accumulator.append(batch(start: 0.5, end: 1.5)))
        try XCTUnwrap(accumulator.flush()).record(in: stats)
        let beforeBuild = stats.snapshot()
        stats.update { $0.state = .buildingDataset }
        XCTAssertEqual(stats.refresh().hashrate, 0)
        XCTAssertEqual(stats.snapshot().nonces, beforeBuild.nonces)
        XCTAssertEqual(stats.snapshot().averageHashrate, beforeBuild.averageHashrate)

        stats.update { $0.state = .searching }
        XCTAssertEqual(stats.snapshot().hashrate, 0)
        let afterBuild = try XCTUnwrap(accumulator.append(batch(start: 10, end: 11), flush: true))
        XCTAssertEqual(afterBuild.nonces, batchNonces)
        XCTAssertEqual(afterBuild.activeSearchSeconds, 1)
        XCTAssertEqual(afterBuild.hashrateWindowSeconds, 1)
        afterBuild.record(in: stats)
        XCTAssertEqual(stats.snapshot().nonces, UInt64(3 * batchNonces))
        XCTAssertEqual(stats.snapshot().searchSeconds, 2.5)
        XCTAssertEqual(stats.snapshot().hashrate, Double(batchNonces))
        XCTAssertEqual(stats.snapshot().averageHashrate, Double(3 * batchNonces) / 2.5)
    }
}
