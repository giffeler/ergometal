import Foundation
import Testing
@testable import MetalErgoCore

struct StatisticsTests {
    @Test func testIndependentHashrateWindowPreservesCumulativeAndDonationAccounting() {
        let stats = StatisticsStore(mode: .mining)
        stats.update { $0.state = .searching }
        let target = UInt256(limbs: [0x8000_0000] + [UInt32](repeating: 0, count: 7))
        stats.recordBatch(
            nonces: 100, gpuSeconds: 0.3, wallSeconds: 2,
            hashrateWindowSeconds: 2, shareTarget: target, recipient: .donation)
        stats.recordBatch(
            nonces: 100, gpuSeconds: 0.4, wallSeconds: 0,
            hashrateWindowSeconds: 1, shareTarget: target, recipient: .donation)
        let searching = stats.snapshot()
        #expect(searching.hashrate == 100)
        #expect(searching.averageHashrate == 100)
        #expect(searching.nonces == 200)
        #expect(searching.searchSeconds == 2)
        #expect(abs(searching.gpuSeconds - 0.7) <= 1e-12)
        #expect(searching.shares.expected == 100)
        #expect(searching.donation.nonces == 200)
        #expect(searching.donation.searchSeconds == 2)
        #expect(searching.donation.shares.expected == 100)

        // No new completions during dataset work or idle time. The active
        // average stays fixed; effective rate and duty include the whole gap.
        stats.update { $0.state = .buildingDataset }
        let building = stats.refresh(at: searching.startedAt.addingTimeInterval(10))
        #expect(building.hashrate == 0)
        #expect(building.averageHashrate == 100)
        #expect(building.effectiveHashrate == 20)
        #expect(building.searchDutyCycle == 0.2)
        stats.update { $0.state = .reconnecting }
        let idle = stats.refresh(at: searching.startedAt.addingTimeInterval(20))
        #expect(idle.hashrate == 0)
        #expect(idle.nonces == 200)
        #expect(idle.searchSeconds == 2)
        #expect(idle.averageHashrate == 100)
        #expect(idle.effectiveHashrate == 10)
        #expect(idle.searchDutyCycle == 0.1)
        #expect(idle.averageHashrate * idle.searchDutyCycle == idle.effectiveHashrate)
        #expect(idle.eventFields["hashrate"] == "0.0")
        #expect(idle.eventFields["effective_hashrate"] == "10.0")
        #expect(idle.eventFields["search_duty_cycle"] == "0.1")
    }

    @Test func testNonSearchStatesClearRateAndLateCompletionsCannotRestoreIt() throws {
        for nextState: MinerState in [.starting, .buildingDataset, .reconnecting, .stopped, .failed] {
            let stats = StatisticsStore(mode: .mining)
            stats.update { $0.state = .searching }
            stats.recordBatch(nonces: 100, gpuSeconds: 0.1, wallSeconds: 1)
            #expect(stats.snapshot().hashrate == 100)
            stats.update { $0.state = nextState }
            #expect(stats.snapshot().hashrate == 0)
            // A reconnect or recipient switch can precede the old work's drain.
            stats.recordBatch(
                nonces: 100, gpuSeconds: 0.1, wallSeconds: 1, hashrateWindowSeconds: 2)
            let snapshot = stats.refresh()
            #expect(snapshot.hashrate == 0)
            #expect(snapshot.nonces == 200)
            #expect(snapshot.searchSeconds == 2)
            #expect(snapshot.averageHashrate == 100)
            #expect(snapshot.eventFields["hashrate"] == "0.0")
            let json = try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(snapshot)) as? [String: Any])
            #expect(json["hashrate"] as? Double == 0)
            #expect(stats.prometheus().split(separator: "\n").contains {
                $0.hasPrefix("ergometal_hashrate{") && $0.hasSuffix(" 0.0")
            })
            stats.update { $0.state = .searching }
            #expect(stats.snapshot().hashrate == 0)
            stats.recordBatch(nonces: 300, gpuSeconds: 0.1, wallSeconds: 1)
            #expect(stats.snapshot().hashrate == 300)
        }
    }

    @Test func testStatusAndEventFieldsExposeResolvedTuning() {
        let configuration = MetalExecutionConfiguration.safeFallback(profile: .peak)
        let tuning = MetalTuningResolver.resolve(
            profile: .peak,
            cached: configuration,
            cacheKey: "cache-key")
        let device = MetalDeviceInfo(
            name: "Apple M6",
            registryID: 1,
            recommendedWorkingSetBytes: 2,
            maxBufferBytes: 3,
            unifiedMemory: true,
            searchPipelineMaxThreads: 128,
            buildPipelineMaxThreads: 256,
            architectureName: "applegpu_future",
            highestKnownAppleFamily: nil,
            searchThreadExecutionWidth: 32,
            buildThreadExecutionWidth: 32)
        let snapshot = StatisticsStore(
            mode: .benchmark,
            profile: "peak",
            device: device,
            autotuneMode: .auto,
            tuning: tuning).snapshot()
        #expect(snapshot.autotuneMode == .auto)
        #expect(snapshot.tuning?.configuration == configuration)
        #expect(snapshot.device?.generation == .m6)
        #expect(snapshot.eventFields["gpu_architecture"] == "applegpu_future")
        #expect(snapshot.eventFields["gpu_family"] == "unknown")
        #expect(snapshot.eventFields["autotune_cache_key"] == "cache-key")
        #expect(snapshot.eventFields["search_pipeline_depth"] == "2")
        #expect(snapshot.eventFields["tuning_source_batch_nonces"] == "cache")
    }

    @Test func testPrometheusIsStableAndContainsNoPoolCredentials() {
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
        #expect(output.contains("ergometal_nonces_total"))
        #expect(output.contains("ergometal_effective_hashrate"))
        #expect(output.contains("ergometal_search_duty_cycle"))
        #expect(output.contains("ergometal_dataset_prefetch_progress"))
        #expect(output.contains("ergometal_dataset_activations_total"))
        #expect(output.contains("ergometal_dataset_prefetch_builds_completed_total"))
        #expect(output.contains("ergometal_gpu_build_commands_completed_total"))
        #expect(output.contains("ergometal_gpu_search_commands_completed_total"))
        #expect(output.contains("ergometal_gpu_search_command_wall_busy_seconds_total"))
        #expect(output.contains("ergometal_gpu_search_command_gpu_busy_seconds_total"))
        #expect(output.contains("ergometal_gpu_search_command_non_gpu_busy_seconds_total"))
        #expect(output.contains("ergometal_shares_accepted_total"))
        #expect(output.contains("ergometal_shares_expected_total"))
        #expect(output.contains("ergometal_share_luck_ratio"))
        #expect(output.contains("ergometal_soc_temperature_average_celsius"))
        #expect(output.contains("ergometal_soc_temperature_maximum_celsius"))
        #expect(output.contains("ergometal_soc_temperature_session_peak_celsius"))
        #expect(!output.contains("pool.example"))
    }

    @Test func testRefreshAndEventFieldsCaptureLongTermStatisticsWithoutPoolHost() {
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

        #expect(fields["nonces"] == "65536")
        #expect(fields["height"] == "1839730")
        #expect(fields["job_target_hex"] == String(repeating: "ab", count: 32))
        #expect(fields["dataset_source"] == "prefetched")
        #expect(fields["shares_expected"] == "4.25")
        #expect(fields["shares_accepted"] == "3")
        #expect(Double(fields["elapsed_seconds"] ?? "") ?? -1 > 0)
        #expect(Double(fields["effective_hashrate"] ?? "") ?? 0 > 0)
        #expect(!fields.values.contains { $0.contains("private.pool.example") })
        #expect(fields["pool_host"] == nil)
    }

    @Test func testEventFieldsIncludeSoCTemperatureTelemetry() {
        var snapshot = StatisticsStore().snapshot()
        snapshot.socTemperatureAverageCelsius = 61.25
        snapshot.socTemperatureMaximumCelsius = 67.5
        snapshot.socTemperatureSessionPeakCelsius = 72.25
        snapshot.socTemperatureSensorCount = 12
        snapshot.temperatureSource = "iohid_soc_die"

        let fields = snapshot.eventFields

        #expect(fields["soc_temperature_average_celsius"] == "61.25")
        #expect(fields["soc_temperature_maximum_celsius"] == "67.5")
        #expect(fields["soc_temperature_session_peak_celsius"] == "72.25")
        #expect(fields["soc_temperature_sensor_count"] == "12")
        #expect(fields["temperature_source"] == "iohid_soc_die")
    }

    @Test func testEventFieldsIncludePipelineOccupancyTelemetry() {
        let device = MetalDeviceInfo(
            name: "Test GPU",
            registryID: 1,
            recommendedWorkingSetBytes: 2,
            maxBufferBytes: 3,
            unifiedMemory: true,
            searchPipelineMaxThreads: 256,
            buildPipelineMaxThreads: 512)

        let fields = StatisticsStore(device: device).snapshot().eventFields

        #expect(fields["search_pipeline_max_threads"] == "256")
        #expect(fields["build_pipeline_max_threads"] == "512")
    }

    @Test func testExpectedSharesUseFull256BitTarget() {
        let stats = StatisticsStore()
        let halfRangeTarget = UInt256(
            limbs: [0x8000_0000] + [UInt32](repeating: 0, count: 7))

        stats.recordBatch(
            nonces: 1_000,
            gpuSeconds: 0.1,
            wallSeconds: 0.2,
            shareTarget: halfRangeTarget)

        #expect(abs(stats.snapshot().shares.expected - 500) <= 1e-12)
    }

    @Test func testDonationTelemetryIsAttributedAndCredentialFree() {
        let stats = StatisticsStore(mode: .mining)
        let halfRangeTarget = UInt256(
            limbs: [0x8000_0000] + [UInt32](repeating: 0, count: 7))
        stats.configureDonation(percent: 1, initialRecipient: .user)
        stats.setDonationScheduledRecipient(.donation)
        stats.setActiveMiningRecipient(.donation, switched: true)
        stats.recordBatch(
            nonces: 1_000,
            gpuSeconds: 0.1,
            wallSeconds: 0.2,
            shareTarget: halfRangeTarget,
            recipient: .donation)
        stats.recordShareFound(recipient: .donation)
        stats.recordShareSubmitted(recipient: .donation)
        stats.recordShareResult(recipient: .donation, accepted: true)
        stats.recordDonationFailure()

        let snapshot = stats.snapshot()
        let fields = snapshot.eventFields
        let prometheus = stats.prometheus()

        #expect(snapshot.donation.percent == 1)
        #expect(snapshot.donation.scheduledRecipient == .donation)
        #expect(snapshot.donation.activeRecipient == .donation)
        #expect(snapshot.donation.nonces == 1_000)
        #expect(snapshot.donation.searchSeconds == 0.2)
        #expect(abs(snapshot.donation.shares.expected - 500) <= 1e-12)
        #expect(snapshot.donation.shares.accepted == 1)
        #expect(snapshot.donation.switches == 1)
        #expect(snapshot.donation.failures == 1)
        #expect(fields["donation_percent"] == "1")
        #expect(fields["donation_active_recipient"] == "donation")
        #expect(prometheus.contains("ergometal_donation_percent"))
        #expect(prometheus.contains("ergometal_donation_nonces_total"))
        #expect(!fields.values.contains { $0.contains("2miners") })
        #expect(!prometheus.contains("2miners"))
    }

    @Test func testStatisticsStoreSerializesConcurrentUpdates() {
        let stats = StatisticsStore()

        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            stats.update { $0.shares.accepted += 1 }
        }

        #expect(stats.snapshot().shares.accepted == 128)
    }

    @Test func testDatasetAndPrefetchMetricsRemainCumulative() {
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
        work.coldBuildsResumed = 1
        work.coldBuildResumedElements = 128
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
        work.searchCommandWallBusySeconds = 2.9
        work.searchCommandGPUBusySeconds = 2.4
        stats.updateDatasetWork(work)
        stats.update {
            $0.shares.expected = 4
            $0.shares.accepted = 3
        }

        let snapshot = stats.refresh()
        let fields = snapshot.eventFields

        #expect(fields["dataset_cold_builds_resumed_total"] == "1")
        #expect(fields["dataset_cold_build_resumed_elements_total"] == "128")

        #expect(snapshot.datasetActivations == 1)
        #expect(snapshot.datasetPrefetchedActivations == 1)
        #expect(snapshot.datasetPrefetchWaits == 1)
        #expect(abs(snapshot.datasetActivationSecondsTotal - 0.4) <= 1e-12)
        #expect(abs(snapshot.datasetPrefetchWaitSecondsTotal - 0.35) <= 1e-12)
        #expect(fields["dataset_build_gpu_seconds"] == "1.25")
        #expect(fields["dataset_prefetch_builds_completed_total"] == "2")
        #expect(fields["dataset_prefetch_builds_cancelled_total"] == "1")
        #expect(fields["dataset_prefetch_wasted_gpu_seconds_total"] == "0.75")
        #expect(fields["gpu_build_commands_completed_total"] == "12")
        #expect(fields["gpu_build_command_non_gpu_seconds_total"] == "0.25")
        #expect(fields["gpu_search_commands_completed_total"] == "24")
        #expect(fields["gpu_search_command_non_gpu_seconds_total"] == "0.25")
        #expect(fields["gpu_search_command_wall_busy_seconds_total"] == "2.9")
        #expect(fields["gpu_search_command_gpu_busy_seconds_total"] == "2.4")
        #expect(fields["gpu_search_command_non_gpu_busy_seconds_total"] == "0.5")
        let prometheus = stats.prometheus()
        #expect(prometheus.split(separator: "\n").contains {
            $0.hasPrefix("ergometal_gpu_search_command_wall_busy_seconds_total{")
                && $0.hasSuffix(" 2.9")
        })
        #expect(prometheus.split(separator: "\n").contains {
            $0.hasPrefix("ergometal_gpu_search_command_gpu_busy_seconds_total{")
                && $0.hasSuffix(" 2.4")
        })
        #expect(prometheus.split(separator: "\n").contains {
            $0.hasPrefix("ergometal_gpu_search_command_non_gpu_busy_seconds_total{")
                && $0.hasSuffix(" 0.5")
        })
        #expect(Double(fields["share_luck_ratio"] ?? "") == 0.75)
        #expect(Double(fields["search_duty_cycle"] ?? "") ?? -1 >= 0)
    }

    @Test func testEventWriterAppendsValidJSONLinesAcrossRestarts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = StatisticsStore()
        do {
            let writer = JSONLEventWriter(path: url.path)
            writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "first"))
        }
        do {
            let writer = JSONLEventWriter(path: url.path)
            writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "second"))
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let objects = try lines.map {
            try #require(JSONSerialization.jsonObject(
                with: Data($0.utf8)) as? [String: Any])
        }
        #expect(objects.compactMap { $0["type"] as? String } == ["first", "second"])
    }

    @Test func testEventWriterSerializesConcurrentWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = JSONLEventWriter(path: url.path)
        let sessionID = UUID()

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            writer.write(MinerEvent(
                sessionID: sessionID,
                type: "concurrent_test",
                fields: ["index": String(index)]))
        }

        #expect(writer.failure == nil)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 64)
        let indices = try Set(lines.map { line in
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require((object["fields"] as? [String: String])?["index"])
        })
        #expect(indices.count == 64)
    }

    @Test func testIndependentEventWritersAppendCompleteRecordsToTheSameFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let writers = (0..<8).map { _ in JSONLEventWriter(path: url.path) }
        let sessionID = UUID()
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            writers[index % writers.count].write(MinerEvent(
                sessionID: sessionID, type: "shared_file",
                fields: ["index": String(index), "payload": String(repeating: "x", count: 32_768)]))
        }
        for writer in writers { #expect(writer.failure == nil) }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 128)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let events = try lines.map { try decoder.decode(MinerEvent.self, from: Data($0.utf8)) }
        #expect(Set(events.compactMap { $0.fields["index"] }).count == 128)
        #expect(events.allSatisfy { $0.fields["payload"]?.count == 32_768 })
    }

    @Test func testMinerStatusLineSelectsARepresentationThatFitsTheTerminal() {
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
        snapshot.donation.percent = 1
        snapshot.donation.activeRecipient = .donation

        for width in [200, 120, 80, 50, 20, 8, 1] {
            let line = MinerStatusLineFormatter.format(
                snapshot, suffix: "shares=15/0", maximumColumns: width)
            #expect(line.count <= width, "line for width \(width): \(line)")
            #expect(!line.contains("\n"))
            #expect(!line.contains("\r"))
        }
        #expect(MinerStatusLineFormatter.format(
            snapshot, suffix: "shares=15/0", maximumColumns: 20).contains("sh=15/0"))
    }

    @Test func testMinerStatusLinePreservesFullTelemetryWhenSpaceAllows() {
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
        snapshot.donation.percent = 1
        snapshot.donation.activeRecipient = .donation

        let line = MinerStatusLineFormatter.format(
            snapshot, suffix: "shares=15/0", maximumColumns: 200)

        #expect(line.contains("current="))
        #expect(line.contains("avg="))
        #expect(line.contains("effective="))
        #expect(line.contains("duty="))
        #expect(line.contains("prefetch="))
        #expect(line.contains("temp="))
        #expect(line.contains("expected="))
        #expect(line.contains("luck="))
        #expect(line.contains("nonces="))
        #expect(line.contains("donation=1% role=donation"))
        #expect(line.contains("shares=15/0"))
    }
}
