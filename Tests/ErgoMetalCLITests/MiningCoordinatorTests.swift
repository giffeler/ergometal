import Foundation
import Testing
@testable import MetalErgoCore

struct MiningCoordinatorTests {
    @Test func testJobChangeDrainsEveryPendingNonceBeforeResettingSearchWindow() throws {
        for depth in 1...4 {
            let stats = StatisticsStore(mode: .mining)
            let coordinator = MiningCoordinator(
                stats: stats, writer: JSONLEventWriter(path: nil),
                donationSchedule: try DonationSchedule(percent: 0),
                automaticallySchedules: false)
            coordinator.configure(userClient: FakeStratumClient(), donationClient: nil)
            coordinator.start()
            defer { coordinator.stop() }
            coordinator.handle(.job(makeJob(generation: 1)))
            let oldJob = try #require(coordinator.nextJob())
            stats.update { $0.state = .searching }
            var accumulator = SearchStatisticsAccumulator()
            func batch(_ index: Int) -> SearchBatch {
                SearchBatch(
                    baseNonce: UInt64(index * 1_048_576), nonceCount: 1_048_576, candidates: [],
                    wallStartTime: Double(index), wallEndTime: Double(index + depth),
                    gpuSeconds: 0.5, wallSeconds: Double(depth))
            }
            for index in 0..<16 {
                accumulator.append(batch(index))?.record(
                    in: stats, shareTarget: oldJob.target, recipient: oldJob.recipient)
            }
            let pending = (16..<(16 + depth)).map(batch)
            coordinator.handle(.job(makeJob(generation: 2)))
            #expect(!coordinator.isCurrent(oldJob))
            // The CLI's normal/deferred drain uses the old target and recipient
            // even though the coordinator already knows about the new job.
            for completed in pending {
                accumulator.append(completed)?.record(
                    in: stats, shareTarget: oldJob.target, recipient: oldJob.recipient)
            }
            let oldSample = accumulator.flush()
            try #require(oldSample).record(
                in: stats, shareTarget: oldJob.target, recipient: oldJob.recipient)
            #expect(accumulator.flush() == nil)
            let completedCount = 16 + depth
            #expect(stats.snapshot().nonces == UInt64(completedCount * 1_048_576))
            #expect(stats.snapshot().searchSeconds == Double(15 + 2 * depth))
            #expect(stats.snapshot().shares.expected == Double(completedCount * 65_536))

            let newJob = try #require(coordinator.nextJob())
            #expect(coordinator.isCurrent(newJob))
            #expect(newJob.height == oldJob.height)
            stats.update { $0.state = .buildingDataset }
            #expect(stats.refresh().hashrate == 0)
            stats.update { $0.state = .searching }
            #expect(stats.snapshot().hashrate == 0)
            var nextAccumulator = SearchStatisticsAccumulator()
            let newBatch = batch(40)
            let newSample = nextAccumulator.append(newBatch, flush: true)
            try #require(newSample).record(
                in: stats, shareTarget: newJob.target, recipient: newJob.recipient)
            #expect(stats.snapshot().nonces == UInt64((completedCount + 1) * 1_048_576))
            #expect(stats.snapshot().searchSeconds == Double(15 + 3 * depth))
            #expect(stats.snapshot().hashrate == 1_048_576 / Double(depth))
            #expect(stats.snapshot().shares.expected == Double((completedCount + 1) * 65_536))
        }
    }

    @Test func testStopFinalizesOnlyAfterCompletedSearchIsAccountedFor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = StatisticsStore(mode: .mining)
        let coordinator = MiningCoordinator(
            stats: stats, writer: JSONLEventWriter(path: url.path),
            donationSchedule: try DonationSchedule(percent: 0),
            automaticallySchedules: false)
        coordinator.configure(userClient: FakeStratumClient(), donationClient: nil)
        coordinator.start()

        coordinator.requestStop()
        #expect(coordinator.isStopped)
        #expect(coordinator.nextJob() == nil)
        #expect(try Data(contentsOf: url).count == 0)
        stats.recordBatch(nonces: 2_048, gpuSeconds: 0.1, wallSeconds: 0.2)
        coordinator.stop()
        coordinator.stop()
        coordinator.recordStatisticsSample()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(MinerEvent.self, from: Data(try #require(lines.first).utf8))
        #expect(event.type == "session_ended")
        #expect(event.fields["nonces"] == "2048")
        #expect(event.fields["search_seconds"] == "0.2")
    }

    @Test func testReconnectAtSameHeightResumesBuildButInvalidatesOldJob() throws {
        let coordinator = makeCoordinator(percent: 0)
        coordinator.configure(userClient: FakeStratumClient(), donationClient: nil)
        coordinator.start()
        defer { coordinator.stop() }
        coordinator.handle(.job(makeJob(generation: 1)), recipient: .user)
        let original = try #require(coordinator.nextJob())
        let solver = try MetalAutolykosSolver(synchronousBuildChunkElements: 64)
        var checks = 0
        #expect {
            try solver.buildDataset(
                height: original.height, tableSize: 257, preserveOnCancellation: true,
                shouldContinue: {
                    checks += 1
                    if checks == 3 {
                        coordinator.handle(.disconnected("local test"), recipient: .user)
                    }
                    return coordinator.isHeightCurrent(original.height)
                })
        } throws: { error in
            if case MetalSolverError.cancelled = error { true } else { false }
        }
        #expect(!coordinator.isCurrent(original))
        #expect(!coordinator.isHeightCurrent(original.height))
        #expect(throws: (any Error).self) { try solver.datasetElements(at: [0]) }

        coordinator.handle(.authorized, recipient: .user)
        coordinator.handle(.job(makeJob(generation: 2)), recipient: .user)
        let resumed = try #require(coordinator.nextJob())
        _ = try solver.buildDataset(
            height: resumed.height, tableSize: 257, preserveOnCancellation: true,
            shouldContinue: { coordinator.isHeightCurrent(resumed.height) })
        #expect(!coordinator.isCurrent(original))
        #expect(coordinator.isCurrent(resumed))
        #expect(solver.datasetWorkMetrics().buildCommandsCompleted == 5)
        #expect(solver.datasetWorkMetrics().coldBuildsResumed == 1)
        #expect(solver.datasetWorkMetrics().coldBuildResumedElements == 128)
        let indices = [0, 127, 128, 256]
        #expect(try solver.datasetElements(at: indices) == (try indices.map {
            try AutolykosV2.datasetElement(index: $0, height: resumed.height)
        }))
    }

    @Test func testRecipientRoundTripInvalidatesPendingReconnect() {
        let user = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 1, cycleSeconds: 100)
        coordinator.configure(userClient: user, donationClient: FakeStratumClient())
        coordinator.start()
        coordinator.handle(.disconnected("local test"), recipient: .user)
        coordinator.advanceSchedule(to: 99)
        coordinator.advanceSchedule(to: 100)
        #expect(user.connectCount == 2)
        Thread.sleep(forTimeInterval: 1.7)
        #expect(user.connectCount == 2)
        coordinator.stop()
    }

    @Test func testAuthorizationInvalidatesPendingReconnect() {
        let user = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 0)
        coordinator.configure(userClient: user, donationClient: nil)
        coordinator.start()
        coordinator.handle(.disconnected("local test"), recipient: .user)
        coordinator.handle(.authorized, recipient: .user)
        Thread.sleep(forTimeInterval: 1.7)
        #expect(user.connectCount == 1)
        coordinator.stop()
    }

    @Test func testPoolMessagesRedactCredentialsWithoutRedactingCounters() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = MiningCoordinator(
            stats: StatisticsStore(mode: .mining), writer: JSONLEventWriter(path: url.path),
            donationSchedule: try DonationSchedule(percent: 0),
            automaticallySchedules: false,
            sensitiveValues: ["WALLET_SENTINEL", "secret/password", "1"])
        coordinator.configure(userClient: FakeStratumClient(), donationClient: nil)
        coordinator.start()
        coordinator.handle(.shareResult(id: 10, accepted: false,
            message: "WALLET_SENTINEL secret/password secret%2Fpassword"), recipient: .user)
        coordinator.handle(.protocolError("invalid WALLET_SENTINEL secret/password"), recipient: .user)
        #expect(!coordinator.stats.snapshot().lastError!.contains("secret/password"))
        coordinator.stop()
        let text = try String(contentsOf: url, encoding: .utf8)
        for secret in ["WALLET_SENTINEL", "secret/password", "secret%2Fpassword"] {
            #expect(!text.contains(secret))
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let events = try text.split(separator: "\n").map {
            try decoder.decode(MinerEvent.self, from: Data($0.utf8))
        }
        #expect(events.last?.fields["shares_rejected"] == "1")
        #expect(events.last?.fields["protocol_errors"] == "1")
    }

    @Test func testDisabledDonationNeverConnectsDonationClient() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 0)
        coordinator.configure(userClient: user, donationClient: donation)

        coordinator.start()

        #expect(user.connectCount == 1)
        #expect(donation.connectCount == 0)
        #expect(coordinator.stats.snapshot().donation.percent == 0)
        #expect(coordinator.stats.snapshot().donation.activeRecipient == .user)
        coordinator.stop()
    }

    @Test func testScheduledSwitchInvalidatesOldWorkAndDonationFailureFallsBack() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 1, cycleSeconds: 100)
        coordinator.configure(userClient: user, donationClient: donation)
        coordinator.start()
        coordinator.handle(.job(makeJob(generation: 1)), recipient: .user)
        let oldWork = try #require(coordinator.nextJob())

        coordinator.advanceSchedule(to: 99)

        #expect(user.disconnectCount == 1)
        #expect(donation.connectCount == 1)
        #expect(!coordinator.isCurrent(oldWork))
        #expect(coordinator.stats.snapshot().donation.activeRecipient == .donation)

        coordinator.handle(.disconnected("test failure"), recipient: .donation)

        let failed = coordinator.stats.snapshot().donation
        #expect(failed.failures == 1)
        #expect(failed.activeRecipient == .user)
        #expect(user.connectCount == 2)
        #expect(donation.connectCount == 1)

        coordinator.advanceSchedule(to: 100)
        #expect(donation.connectCount == 1, "failed time must not be retried in the user window")
        coordinator.advanceSchedule(to: 199)
        #expect(donation.connectCount == 2, "donation retries only in the next donation window")
        coordinator.stop()
    }

    @Test func testDonationSharesAndSearchAreAttributedWithoutChangingScheduling() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 100, cycleSeconds: 100)
        coordinator.configure(userClient: user, donationClient: donation)
        coordinator.start()
        let job = makeJob(generation: 1)
        coordinator.handle(.authorized, recipient: .donation)
        coordinator.handle(.job(job), recipient: .donation)
        let work = try #require(coordinator.nextJob())

        coordinator.stats.recordBatch(
            nonces: 1_000,
            gpuSeconds: 0.1,
            wallSeconds: 0.2,
            shareTarget: job.target,
            recipient: work.recipient)
        coordinator.stats.recordShareFound(recipient: work.recipient)
        _ = try coordinator.submit(work, nonce: 42)
        coordinator.stats.recordShareSubmitted(recipient: work.recipient)
        coordinator.handle(
            .shareResult(id: 10, accepted: true, message: nil),
            recipient: .donation)

        let snapshot = coordinator.stats.snapshot()
        #expect(snapshot.nonces == 1_000)
        #expect(snapshot.donation.nonces == 1_000)
        #expect(snapshot.donation.searchSeconds == 0.2)
        #expect(snapshot.donation.shares.found == 1)
        #expect(snapshot.donation.shares.submitted == 1)
        #expect(snapshot.donation.shares.accepted == 1)
        #expect(donation.submittedNonces == [42])
        coordinator.stop()
    }

    @Test func testDonationJobWithoutAuthorizationStillTimesOut() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(
            percent: 100,
            cycleSeconds: 100,
            donationTimeoutSeconds: 0.02)
        coordinator.configure(userClient: user, donationClient: donation)
        coordinator.start()
        coordinator.handle(.job(makeJob(generation: 1)), recipient: .donation)

        let deadline = Date(timeIntervalSinceNow: 1)
        while coordinator.stats.snapshot().donation.failures == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        #expect(coordinator.stats.snapshot().donation.failures == 1)
        #expect(coordinator.stats.snapshot().donation.activeRecipient == .user)
        #expect(user.connectCount == 1)
        coordinator.stop()
    }

    @Test func testAuthorizedDonationJobCancelsTimeout() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(
            percent: 100,
            cycleSeconds: 100,
            donationTimeoutSeconds: 0.02)
        coordinator.configure(userClient: user, donationClient: donation)
        coordinator.start()
        coordinator.handle(.authorized, recipient: .donation)
        coordinator.handle(.job(makeJob(generation: 1)), recipient: .donation)

        Thread.sleep(forTimeInterval: 0.05)

        #expect(coordinator.stats.snapshot().donation.failures == 0)
        #expect(coordinator.stats.snapshot().donation.activeRecipient == .donation)
        #expect(user.connectCount == 0)
        coordinator.stop()
    }

    @Test func testDonationTimeoutReturnsToUser() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(
            percent: 100,
            cycleSeconds: 100,
            donationTimeoutSeconds: 0.02)
        coordinator.configure(userClient: user, donationClient: donation)
        coordinator.start()

        let deadline = Date(timeIntervalSinceNow: 1)
        while coordinator.stats.snapshot().donation.failures == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        #expect(coordinator.stats.snapshot().donation.failures == 1)
        #expect(coordinator.stats.snapshot().donation.activeRecipient == .user)
        #expect(user.connectCount == 1)
        coordinator.stop()
    }

    @Test func testConcurrentDonationFailuresTriggerOneFailback() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 100, cycleSeconds: 100)
        coordinator.configure(userClient: user, donationClient: donation)
        coordinator.start()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            coordinator.handle(.disconnected("simultaneous failure"), recipient: .donation)
        }

        #expect(coordinator.stats.snapshot().donation.failures == 1)
        #expect(coordinator.stats.snapshot().donation.activeRecipient == .user)
        #expect(user.connectCount == 1)
        coordinator.stop()
    }

    private func makeCoordinator(
        percent: Int,
        cycleSeconds: TimeInterval = 6_000,
        donationTimeoutSeconds: TimeInterval = 15
    ) -> MiningCoordinator {
        let stats = StatisticsStore(mode: .mining)
        let writer = JSONLEventWriter(path: nil)
        return MiningCoordinator(
            stats: stats,
            writer: writer,
            donationSchedule: try! DonationSchedule(
                percent: percent,
                cycleSeconds: cycleSeconds),
            donationTimeoutSeconds: donationTimeoutSeconds,
            uptime: { 0 },
            automaticallySchedules: false)
    }

    private func makeJob(generation: UInt64) -> ErgoStratumJob {
        ErgoStratumJob(
            generation: generation,
            id: "job-\(generation)",
            height: 1_840_000,
            message: [UInt8](repeating: 0x11, count: 32),
            version: 2,
            target: UInt256(limbs: [0x1000_0000] + [UInt32](repeating: 0, count: 7)),
            cleanJobs: true,
            extraNoncePrefix: [],
            extraNonce2Size: 8,
            receivedAt: Date())
    }
}

private final class FakeStratumClient: MiningStratumClient, @unchecked Sendable {
    private let lock = NSLock()
    private var connects = 0
    private var disconnects = 0
    private var nonces: [UInt64] = []

    var connectCount: Int { lock.withLock { connects } }
    var disconnectCount: Int { lock.withLock { disconnects } }
    var submittedNonces: [UInt64] { lock.withLock { nonces } }

    func connect() {
        lock.withLock { connects += 1 }
    }

    func disconnect() {
        lock.withLock { disconnects += 1 }
    }

    func submit(job: ErgoStratumJob, nonce: UInt64) throws -> Int {
        lock.withLock { nonces.append(nonce) }
        return 10
    }
}
