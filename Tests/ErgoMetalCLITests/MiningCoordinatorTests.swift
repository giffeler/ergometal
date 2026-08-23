import Foundation
import XCTest
@testable import MetalErgoCore

final class MiningCoordinatorTests: XCTestCase {
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
