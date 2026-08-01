import XCTest
@testable import MetalErgoCore

final class StatisticsTests: XCTestCase {
    func testPrometheusIsStableAndContainsNoPoolCredentials() {
        let stats = StatisticsStore(mode: .mining)
        stats.update { snapshot in
            snapshot.poolHost = "pool.example:1234"
            snapshot.state = .searching
            snapshot.shares.expected = 2.5
            snapshot.shares.accepted = 2
            snapshot.socTemperatureAverageCelsius = 61.25
            snapshot.socTemperatureMaximumCelsius = 67.5
        }
        stats.recordBatch(nonces: 65_536, gpuSeconds: 0.1, wallSeconds: 0.2)
        let output = stats.prometheus()
        XCTAssertTrue(output.contains("ergometal_nonces_total"))
        XCTAssertTrue(output.contains("ergometal_effective_hashrate"))
        XCTAssertTrue(output.contains("ergometal_search_duty_cycle"))
        XCTAssertTrue(output.contains("ergometal_dataset_prefetch_progress"))
        XCTAssertTrue(output.contains("ergometal_dataset_activations_total"))
        XCTAssertTrue(output.contains("ergometal_dataset_prefetch_builds_completed_total"))
        XCTAssertTrue(output.contains("ergometal_gpu_build_commands_completed_total"))
        XCTAssertTrue(output.contains("ergometal_gpu_search_commands_completed_total"))
        XCTAssertTrue(output.contains("ergometal_shares_accepted_total"))
        XCTAssertTrue(output.contains("ergometal_shares_expected_total"))
        XCTAssertTrue(output.contains("ergometal_share_luck_ratio"))
        XCTAssertTrue(output.contains("ergometal_soc_temperature_average_celsius"))
        XCTAssertTrue(output.contains("ergometal_soc_temperature_maximum_celsius"))
        XCTAssertTrue(output.contains("ergometal_soc_temperature_session_peak_celsius"))
        XCTAssertFalse(output.contains("pool.example"))
    }

    func testRefreshAndEventFieldsCaptureLongTermStatisticsWithoutPoolHost() {
        let stats = StatisticsStore(mode: .mining, profile: "peak")
        stats.update { snapshot in
            snapshot.poolHost = "private.pool.example:1234"
            snapshot.job = JobStatistics(
                id: "job-1",
                height: 1_839_730,
                difficulty: 42,
                targetHex: String(repeating: "ab", count: 32))
            snapshot.datasetSource = .prefetched
            snapshot.shares.expected = 4.25
            snapshot.shares.accepted = 3
        }
        stats.recordBatch(nonces: 65_536, gpuSeconds: 0.1, wallSeconds: 0.2)

        let snapshot = stats.refresh()
        let fields = snapshot.eventFields

        XCTAssertEqual(fields["nonces"], "65536")
        XCTAssertEqual(fields["height"], "1839730")
        XCTAssertEqual(fields["job_target_hex"], String(repeating: "ab", count: 32))
        XCTAssertEqual(fields["dataset_source"], "prefetched")
        XCTAssertEqual(fields["shares_expected"], "4.25")
        XCTAssertEqual(fields["shares_accepted"], "3")
        XCTAssertGreaterThan(Double(fields["elapsed_seconds"] ?? "") ?? -1, 0)
        XCTAssertGreaterThan(Double(fields["effective_hashrate"] ?? "") ?? 0, 0)
        XCTAssertFalse(fields.values.contains { $0.contains("private.pool.example") })
        XCTAssertNil(fields["pool_host"])
    }

    func testEventFieldsIncludeSoCTemperatureTelemetry() {
        var snapshot = StatisticsStore().snapshot()
        snapshot.socTemperatureAverageCelsius = 61.25
        snapshot.socTemperatureMaximumCelsius = 67.5
        snapshot.socTemperatureSessionPeakCelsius = 72.25
        snapshot.socTemperatureSensorCount = 12
        snapshot.temperatureSource = "iohid_soc_die"

        let fields = snapshot.eventFields

        XCTAssertEqual(fields["soc_temperature_average_celsius"], "61.25")
        XCTAssertEqual(fields["soc_temperature_maximum_celsius"], "67.5")
        XCTAssertEqual(fields["soc_temperature_session_peak_celsius"], "72.25")
        XCTAssertEqual(fields["soc_temperature_sensor_count"], "12")
        XCTAssertEqual(fields["temperature_source"], "iohid_soc_die")
    }

    func testExpectedSharesUseFull256BitTarget() {
        let stats = StatisticsStore()
        let halfRangeTarget = UInt256(
            limbs: [0x8000_0000] + [UInt32](repeating: 0, count: 7))

        stats.recordBatch(
            nonces: 1_000,
            gpuSeconds: 0.1,
            wallSeconds: 0.2,
            shareTarget: halfRangeTarget)

        XCTAssertEqual(stats.snapshot().shares.expected, 500, accuracy: 1e-12)
    }

    func testDatasetAndPrefetchMetricsRemainCumulative() {
        let stats = StatisticsStore(mode: .mining)
        let build = DatasetBuild(
            height: 1_840_500,
            tableSize: 1_024,
            bytes: 32_768,
            seconds: 1.5,
            gpuSeconds: 1.25,
            activationSeconds: 0.4,
            prefetchWaitSeconds: 0.35,
            source: .prefetched)
        stats.recordDatasetActivation(build)
        var work = DatasetWorkMetrics()
        work.coldBuildsCompleted = 2
        work.coldBuildGPUSeconds = 2.5
        work.prefetchBuildsStarted = 3
        work.prefetchBuildsCompleted = 2
        work.prefetchBuildsCancelled = 1
        work.prefetchBuildsDiscarded = 1
        work.prefetchBuildGPUSeconds = 4.5
        work.prefetchWastedGPUSeconds = 0.75
        work.buildCommandsCompleted = 12
        work.buildCommandWallSeconds = 5.25
        work.buildCommandGPUSeconds = 5
        work.searchCommandsCompleted = 24
        work.searchCommandWallSeconds = 3.5
        work.searchCommandGPUSeconds = 3.25
        stats.updateDatasetWork(work)
        stats.update {
            $0.shares.expected = 4
            $0.shares.accepted = 3
        }

        let snapshot = stats.refresh()
        let fields = snapshot.eventFields

        XCTAssertEqual(snapshot.datasetActivations, 1)
        XCTAssertEqual(snapshot.datasetPrefetchedActivations, 1)
        XCTAssertEqual(snapshot.datasetPrefetchWaits, 1)
        XCTAssertEqual(snapshot.datasetActivationSecondsTotal, 0.4, accuracy: 1e-12)
        XCTAssertEqual(snapshot.datasetPrefetchWaitSecondsTotal, 0.35, accuracy: 1e-12)
        XCTAssertEqual(fields["dataset_build_gpu_seconds"], "1.25")
        XCTAssertEqual(fields["dataset_prefetch_builds_completed_total"], "2")
        XCTAssertEqual(fields["dataset_prefetch_builds_cancelled_total"], "1")
        XCTAssertEqual(fields["dataset_prefetch_wasted_gpu_seconds_total"], "0.75")
        XCTAssertEqual(fields["gpu_build_commands_completed_total"], "12")
        XCTAssertEqual(fields["gpu_build_command_non_gpu_seconds_total"], "0.25")
        XCTAssertEqual(fields["gpu_search_commands_completed_total"], "24")
        XCTAssertEqual(fields["gpu_search_command_non_gpu_seconds_total"], "0.25")
        XCTAssertEqual(Double(fields["share_luck_ratio"] ?? ""), 0.75)
        XCTAssertGreaterThanOrEqual(Double(fields["search_duty_cycle"] ?? "") ?? -1, 0)
    }

    func testEventWriterAppendsValidJSONLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stats = StatisticsStore()
        do {
            let writer = JSONLEventWriter(path: url.path)
            writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "test"))
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "test")
    }

    func testMinerStatusLineSelectsARepresentationThatFitsTheTerminal() {
        var snapshot = StatisticsStore(mode: .mining).snapshot()
        snapshot.hashrate = 15_660_000
        snapshot.averageHashrate = 15_680_000
        snapshot.effectiveHashrate = 10_810_000
        snapshot.searchSeconds = 68.9
        snapshot.sampledAt = snapshot.startedAt.addingTimeInterval(100)
        snapshot.prefetchHeight = 1_841_493
        snapshot.prefetchProgress = 1
        snapshot.socTemperatureMaximumCelsius = 72.1
        snapshot.socTemperatureSessionPeakCelsius = 83.7
        snapshot.nonces = 198_739_886_080
        snapshot.shares.expected = 11.39
        snapshot.shares.accepted = 15

        for width in [200, 120, 80, 50, 20, 8, 1] {
            let line = MinerStatusLineFormatter.format(
                snapshot, suffix: "shares=15/0", maximumColumns: width)
            XCTAssertLessThanOrEqual(line.count, width, "line for width \(width): \(line)")
            XCTAssertFalse(line.contains("\n"))
            XCTAssertFalse(line.contains("\r"))
        }
        XCTAssertTrue(MinerStatusLineFormatter.format(
            snapshot, suffix: "shares=15/0", maximumColumns: 20).contains("sh=15/0"))
    }

    func testMinerStatusLinePreservesFullTelemetryWhenSpaceAllows() {
        var snapshot = StatisticsStore(mode: .mining).snapshot()
        snapshot.hashrate = 15_660_000
        snapshot.averageHashrate = 15_680_000
        snapshot.effectiveHashrate = 10_810_000
        snapshot.searchSeconds = 68.9
        snapshot.sampledAt = snapshot.startedAt.addingTimeInterval(100)
        snapshot.prefetchHeight = 1_841_493
        snapshot.prefetchProgress = 1
        snapshot.socTemperatureMaximumCelsius = 72.1
        snapshot.socTemperatureSessionPeakCelsius = 83.7
        snapshot.nonces = 198_739_886_080
        snapshot.shares.expected = 11.39
        snapshot.shares.accepted = 15

        let line = MinerStatusLineFormatter.format(
            snapshot, suffix: "shares=15/0", maximumColumns: 200)

        XCTAssertTrue(line.contains("current="))
        XCTAssertTrue(line.contains("avg="))
        XCTAssertTrue(line.contains("effective="))
        XCTAssertTrue(line.contains("duty="))
        XCTAssertTrue(line.contains("prefetch="))
        XCTAssertTrue(line.contains("temp="))
        XCTAssertTrue(line.contains("expected="))
        XCTAssertTrue(line.contains("luck="))
        XCTAssertTrue(line.contains("nonces="))
        XCTAssertTrue(line.contains("shares=15/0"))
    }
}
