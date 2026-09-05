import Foundation
import XCTest
@testable import MetalErgoCore

final class MiningCoordinatorTests: XCTestCase {
    func testStopFinalizesOnlyAfterCompletedSearchIsAccountedFor() throws {
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
        XCTAssertTrue(coordinator.isStopped)
        XCTAssertNil(coordinator.nextJob())
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        stats.recordBatch(nonces: 2_048, gpuSeconds: 0.1, wallSeconds: 0.2)
        coordinator.stop()
        coordinator.stop()
        coordinator.recordStatisticsSample()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(MinerEvent.self, from: Data(try XCTUnwrap(lines.first).utf8))
        XCTAssertEqual(event.type, "session_ended")
        XCTAssertEqual(event.fields["nonces"], "2048")
        XCTAssertEqual(event.fields["search_seconds"], "0.2")
    }

    func testRecipientRoundTripInvalidatesPendingReconnect() {
        let user = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 1, cycleSeconds: 100)
        coordinator.configure(userClient: user, donationClient: FakeStratumClient())
        coordinator.start()
        coordinator.handle(.disconnected("local test"), recipient: .user)
        coordinator.advanceSchedule(to: 99)
        coordinator.advanceSchedule(to: 100)
        XCTAssertEqual(user.connectCount, 2)
        Thread.sleep(forTimeInterval: 1.7)
        XCTAssertEqual(user.connectCount, 2)
        coordinator.stop()
    }

    func testAuthorizationInvalidatesPendingReconnect() {
        let user = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 0)
        coordinator.configure(userClient: user, donationClient: nil)
        coordinator.start()
        coordinator.handle(.disconnected("local test"), recipient: .user)
        coordinator.handle(.authorized, recipient: .user)
        Thread.sleep(forTimeInterval: 1.7)
        XCTAssertEqual(user.connectCount, 1)
        coordinator.stop()
    }

    func testPoolMessagesRedactCredentialsWithoutRedactingCounters() throws {
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
        XCTAssertFalse(coordinator.stats.snapshot().lastError!.contains("secret/password"))
        coordinator.stop()
        let text = try String(contentsOf: url, encoding: .utf8)
        for secret in ["WALLET_SENTINEL", "secret/password", "secret%2Fpassword"] {
            XCTAssertFalse(text.contains(secret))
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let events = try text.split(separator: "\n").map {
            try decoder.decode(MinerEvent.self, from: Data($0.utf8))
        }
        XCTAssertEqual(events.last?.fields["shares_rejected"], "1")
        XCTAssertEqual(events.last?.fields["protocol_errors"], "1")
    }

    func testDisabledDonationNeverConnectsDonationClient() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 0)
        coordinator.configure(userClient: user, donationClient: donation)

        coordinator.start()

        XCTAssertEqual(user.connectCount, 1)
        XCTAssertEqual(donation.connectCount, 0)
        XCTAssertEqual(coordinator.stats.snapshot().donation.percent, 0)
        XCTAssertEqual(coordinator.stats.snapshot().donation.activeRecipient, .user)
        coordinator.stop()
    }

    func testScheduledSwitchInvalidatesOldWorkAndDonationFailureFallsBack() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 1, cycleSeconds: 100)
        coordinator.configure(userClient: user, donationClient: donation)
        coordinator.start()
        coordinator.handle(.job(makeJob(generation: 1)), recipient: .user)
        let oldWork = try XCTUnwrap(coordinator.nextJob())

        coordinator.advanceSchedule(to: 99)

        XCTAssertEqual(user.disconnectCount, 1)
        XCTAssertEqual(donation.connectCount, 1)
        XCTAssertFalse(coordinator.isCurrent(oldWork))
        XCTAssertEqual(coordinator.stats.snapshot().donation.activeRecipient, .donation)

        coordinator.handle(.disconnected("test failure"), recipient: .donation)

        let failed = coordinator.stats.snapshot().donation
        XCTAssertEqual(failed.failures, 1)
        XCTAssertEqual(failed.activeRecipient, .user)
        XCTAssertEqual(user.connectCount, 2)
        XCTAssertEqual(donation.connectCount, 1)

        coordinator.advanceSchedule(to: 100)
        XCTAssertEqual(donation.connectCount, 1, "failed time must not be retried in the user window")
        coordinator.advanceSchedule(to: 199)
        XCTAssertEqual(donation.connectCount, 2, "donation retries only in the next donation window")
        coordinator.stop()
    }

    func testDonationSharesAndSearchAreAttributedWithoutChangingScheduling() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 100, cycleSeconds: 100)
        coordinator.configure(userClient: user, donationClient: donation)
        coordinator.start()
        let job = makeJob(generation: 1)
        coordinator.handle(.authorized, recipient: .donation)
        coordinator.handle(.job(job), recipient: .donation)
        let work = try XCTUnwrap(coordinator.nextJob())

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
        XCTAssertEqual(snapshot.nonces, 1_000)
        XCTAssertEqual(snapshot.donation.nonces, 1_000)
        XCTAssertEqual(snapshot.donation.searchSeconds, 0.2)
        XCTAssertEqual(snapshot.donation.shares.found, 1)
        XCTAssertEqual(snapshot.donation.shares.submitted, 1)
        XCTAssertEqual(snapshot.donation.shares.accepted, 1)
        XCTAssertEqual(donation.submittedNonces, [42])
        coordinator.stop()
    }

    func testDonationJobWithoutAuthorizationStillTimesOut() throws {
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

        XCTAssertEqual(coordinator.stats.snapshot().donation.failures, 1)
        XCTAssertEqual(coordinator.stats.snapshot().donation.activeRecipient, .user)
        XCTAssertEqual(user.connectCount, 1)
        coordinator.stop()
    }

    func testAuthorizedDonationJobCancelsTimeout() throws {
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

        XCTAssertEqual(coordinator.stats.snapshot().donation.failures, 0)
        XCTAssertEqual(coordinator.stats.snapshot().donation.activeRecipient, .donation)
        XCTAssertEqual(user.connectCount, 0)
        coordinator.stop()
    }

    func testDonationTimeoutReturnsToUser() throws {
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

        XCTAssertEqual(coordinator.stats.snapshot().donation.failures, 1)
        XCTAssertEqual(coordinator.stats.snapshot().donation.activeRecipient, .user)
        XCTAssertEqual(user.connectCount, 1)
        coordinator.stop()
    }

    func testConcurrentDonationFailuresTriggerOneFailback() throws {
        let user = FakeStratumClient()
        let donation = FakeStratumClient()
        let coordinator = makeCoordinator(percent: 100, cycleSeconds: 100)
        coordinator.configure(userClient: user, donationClient: donation)
        coordinator.start()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            coordinator.handle(.disconnected("simultaneous failure"), recipient: .donation)
        }

        XCTAssertEqual(coordinator.stats.snapshot().donation.failures, 1)
        XCTAssertEqual(coordinator.stats.snapshot().donation.activeRecipient, .user)
        XCTAssertEqual(user.connectCount, 1)
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
