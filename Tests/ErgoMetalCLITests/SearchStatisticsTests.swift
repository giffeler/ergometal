import Testing
@testable import MetalErgoCore

struct SearchStatisticsTests {
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

    @Test func testOverlappingPartialWindowUsesItsCompleteCommandInterval() throws {
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
            if index < 15 { #expect(sample == nil) }
            if let sample { record(sample, in: stats) }
        }
        let frontier = 16 * secondsPerBatch
        let tailStart = 13 * secondsPerBatch
        let tailEnd = frontier + 0.000_018_458_333
        #expect(accumulator.append(batch(start: tailStart, end: tailEnd)) == nil)
        let tailSample = accumulator.flush()
        record(try #require(tailSample), in: stats)

        #expect(abs(stats.snapshot().hashrate - (Double(batchNonces) / (tailEnd - tailStart))) <= 1e-6)
        #expect(stats.snapshot().nonces == UInt64(17 * batchNonces))
        #expect(abs(stats.snapshot().searchSeconds - tailEnd) <= 1e-12)
        #expect(accumulator.flush() == nil)
    }

    @Test func testDatasetBuildDoesNotRetainPreviousSearchRate() {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        stats.recordBatch(nonces: batchNonces, gpuSeconds: 0.05, wallSeconds: 0.1)
        #expect(stats.snapshot().hashrate > 0)

        stats.update { $0.state = .buildingDataset }
        #expect(stats.snapshot().hashrate == 0)
        #expect(stats.refresh().hashrate == 0)
        stats.update { $0.state = .searching }
        #expect(stats.snapshot().hashrate == 0)
        #expect(stats.snapshot().nonces == UInt64(batchNonces))
    }

    @Test func testWindowBoundariesAndEveryTailLengthAtPipelineDepthsOneThroughFour() throws {
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
                let tailSample = accumulator.flush()
                samples.append(try #require(tailSample))
                #expect(accumulator.flush() == nil)
                #expect(samples.count == 3)
                for (index, sample) in samples.enumerated() {
                    let windowCount = index < 2 ? 16 : tailCount
                    let windowSeconds = Double(windowCount - 1 + depth) / 8
                    #expect(sample.nonces == windowCount * batchNonces)
                    #expect(sample.hashrateWindowSeconds == windowSeconds)
                    #expect(sample.activeSearchSeconds == (index == 0 ? windowSeconds : Double(windowCount) / 8))
                    sample.record(in: stats)
                    let snapshot = stats.snapshot()
                    #expect(abs(snapshot.hashrate - (Double(windowCount * batchNonces) / windowSeconds)) <= 1e-6, "depth=\(depth), tail=\(tailCount), window=\(index)")
                }
                let snapshot = stats.snapshot()
                let totalSeconds = Double(count - 1 + depth) / 8
                #expect(snapshot.nonces == UInt64(count * batchNonces))
                #expect(snapshot.searchSeconds == totalSeconds)
                #expect(abs(snapshot.gpuSeconds - (Double(count) * 0.05)) <= 1e-12)
                #expect(abs(snapshot.averageHashrate - (Double(count * batchNonces) / totalSeconds)) <= 1e-6)
                #expect(abs(snapshot.effectiveHashrate - (Double(snapshot.nonces) / snapshot.sampledAt.timeIntervalSince(snapshot.startedAt))) <= 1e-6)
            }
        }
    }

    @Test func testFlushRetainsFrontierForFullyCoveredAndOutOfOrderCompletions() throws {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        #expect(accumulator.flush() == nil)
        let initialSample = accumulator.append(batch(start: 0, end: 10), flush: true)
        try #require(initialSample).record(in: stats)
        // Starts are FIFO, but a delayed callback can end after later commands.
        #expect(accumulator.append(batch(start: 1, end: 7)) == nil)
        #expect(accumulator.append(batch(start: 2, end: 6)) == nil)
        let coveredSample = accumulator.flush()
        let covered = try #require(coveredSample)
        #expect(covered.activeSearchSeconds == 0)
        #expect(covered.hashrateWindowSeconds == 6)
        covered.record(in: stats)
        #expect(stats.snapshot().hashrate == Double(2 * batchNonces) / 6)
        #expect(stats.snapshot().searchSeconds == 10)
        #expect(accumulator.flush() == nil)

        let nextSample = accumulator.append(batch(start: 7, end: 11), flush: true)
        let next = try #require(nextSample)
        #expect(next.activeSearchSeconds == 1)
        #expect(next.hashrateWindowSeconds == 4)
        next.record(in: stats)
        #expect(stats.snapshot().nonces == UInt64(4 * batchNonces))
        #expect(stats.snapshot().searchSeconds == 11)
    }

    @Test func testTimeGapsDoNotBecomeActiveTimeInsideOrBetweenWindows() throws {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        #expect(accumulator.append(batch(start: 10, end: 11)) == nil)
        #expect(accumulator.append(batch(start: 13, end: 15)) == nil)
        let firstSample = accumulator.flush()
        let first = try #require(firstSample)
        #expect(first.hashrateWindowSeconds == 3)
        #expect(first.activeSearchSeconds == 3)
        first.record(in: stats)

        #expect(accumulator.append(batch(start: 14, end: 16)) == nil)
        #expect(accumulator.append(batch(start: 20, end: 21)) == nil)
        let secondSample = accumulator.flush()
        let second = try #require(secondSample)
        #expect(second.hashrateWindowSeconds == 3)
        #expect(second.activeSearchSeconds == 2)
        second.record(in: stats)
        #expect(stats.snapshot().hashrate == Double(2 * batchNonces) / 3)
        #expect(stats.snapshot().searchSeconds == 5)
        #expect(stats.snapshot().averageHashrate == Double(4 * batchNonces) / 5)

        // Evaluate the synthetic session's duty cycle without sleeping or
        // involving the real system clock: 5 active seconds in 21 elapsed.
        var snapshot = stats.snapshot()
        snapshot.sampledAt = snapshot.startedAt.addingTimeInterval(21)
        #expect(abs(snapshot.searchDutyCycle - (5.0 / 21)) <= 1e-12)
    }

    @Test func testZeroTimeAndInvalidDurationCountNoncesWithoutInventingTime() throws {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        for _ in 0..<16 {
            accumulator.append(batch(start: 0, end: 0))?.record(in: stats)
        }
        #expect(stats.snapshot().nonces == UInt64(16 * batchNonces))
        #expect(stats.snapshot().searchSeconds == 0)
        #expect(stats.snapshot().hashrate == 0)
        #expect(stats.snapshot().averageHashrate == 0)
        #expect(accumulator.flush() == nil)

        let validSample = accumulator.append(batch(start: 2, end: 3), flush: true)
        let valid = try #require(validSample)
        valid.record(in: stats)
        #expect(stats.snapshot().searchSeconds == 1)
        #expect(stats.snapshot().hashrate == Double(batchNonces))
        #expect(accumulator.append(batch(start: 3, end: 3)) == nil)
        #expect(accumulator.append(batch(start: 4, end: 3)) == nil)
        let zeroSample = accumulator.flush()
        let zero = try #require(zeroSample)
        #expect(zero.hashrateWindowSeconds == 0)
        #expect(zero.activeSearchSeconds == 0)
        zero.record(in: stats)
        #expect(stats.snapshot().nonces == UInt64(19 * batchNonces))
        #expect(stats.snapshot().searchSeconds == 1)
        #expect(stats.snapshot().hashrate == 0)
        #expect(stats.snapshot().averageHashrate == Double(19 * batchNonces))
    }

    @Test func testVariableBatchSizesAndShortMeasuredIntervalsAreNotCapped() throws {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        #expect(accumulator.append(batch(start: 0, end: 2, nonces: 100)) == nil)
        #expect(accumulator.append(batch(start: 1, end: 3, nonces: 200)) == nil)
        let windowSample = accumulator.flush()
        try #require(windowSample).record(in: stats)
        #expect(stats.snapshot().nonces == 300)
        #expect(stats.snapshot().hashrate == 100)

        let end = 4.000_001
        let shortSample = accumulator.append(batch(start: 4, end: end), flush: true)
        try #require(shortSample).record(in: stats)
        #expect(stats.snapshot().hashrate == Double(batchNonces) / (end - 4))
        #expect(stats.snapshot().hashrate > 1_000_000_000_000)
        #expect(stats.snapshot().nonces == UInt64(300 + batchNonces))
    }

    @Test func testDatasetBoundaryFlushKeepsSeparateWindowsAndExcludesBuildGap() throws {
        let stats = StatisticsStore(mode: .benchmark)
        stats.update { $0.state = .searching }
        var accumulator = SearchStatisticsAccumulator()
        #expect(accumulator.append(batch(start: 0, end: 1)) == nil)
        #expect(accumulator.append(batch(start: 0.5, end: 1.5)) == nil)
        let prebuildSample = accumulator.flush()
        try #require(prebuildSample).record(in: stats)
        let beforeBuild = stats.snapshot()
        stats.update { $0.state = .buildingDataset }
        #expect(stats.refresh().hashrate == 0)
        #expect(stats.snapshot().nonces == beforeBuild.nonces)
        #expect(stats.snapshot().averageHashrate == beforeBuild.averageHashrate)

        stats.update { $0.state = .searching }
        #expect(stats.snapshot().hashrate == 0)
        let postbuildSample = accumulator.append(batch(start: 10, end: 11), flush: true)
        let afterBuild = try #require(postbuildSample)
        #expect(afterBuild.nonces == batchNonces)
        #expect(afterBuild.activeSearchSeconds == 1)
        #expect(afterBuild.hashrateWindowSeconds == 1)
        afterBuild.record(in: stats)
        #expect(stats.snapshot().nonces == UInt64(3 * batchNonces))
        #expect(stats.snapshot().searchSeconds == 2.5)
        #expect(stats.snapshot().hashrate == Double(batchNonces))
        #expect(stats.snapshot().averageHashrate == Double(3 * batchNonces) / 2.5)
    }
}
