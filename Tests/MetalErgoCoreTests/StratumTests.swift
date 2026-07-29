import XCTest
@testable import MetalErgoCore

final class StratumTests: XCTestCase {
    func testMiningcoreSubscriptionAndJobLayout() throws {
        let subscription: [Any] = [[["mining.set_difficulty", "id"], ["mining.notify", "id"]], "a1b2", 6]
        let extra = try ErgoStratumClient.decodeSubscription(subscription)
        XCTAssertEqual(extra.prefix, [0xa1, 0xb2])
        XCTAssertEqual(extra.extraNonce2Size, 6)

        let message = String(repeating: "11", count: 32)
        let target = "1000000000000000000000000000000000000000000000000000000000000000"
        let params: [Any] = ["job-7", 1_500_000, message, "", "", 2, target, "", true]
        let job = try ErgoStratumClient.decodeJob(params, generation: 7,
            extraNoncePrefix: extra.prefix, extraNonce2Size: extra.extraNonce2Size)
        XCTAssertEqual(job.id, "job-7")
        XCTAssertEqual(job.height, 1_500_000)
        XCTAssertEqual(job.message, [UInt8](repeating: 0x11, count: 32))
        XCTAssertEqual(job.target, UInt256(encoded: target))
        XCTAssertTrue(job.cleanJobs)

        let livePoolParams: [Any] = [
            "3eb", 1_839_512, message, "", "", "00000002",
            "6634674375215649981044791689095340972727658017446627184440307089471", "", false
        ]
        let livePoolJob = try ErgoStratumClient.decodeJob(
            livePoolParams, generation: 8, extraNoncePrefix: extra.prefix,
            extraNonce2Size: extra.extraNonce2Size)
        XCTAssertEqual(livePoolJob.version, 2)
        XCTAssertEqual(livePoolJob.height, 1_839_512)
    }

    func testRejectsMalformedExtranonceAndJob() {
        XCTAssertThrowsError(try ErgoStratumClient.decodeSubscription([[], "abcd", 5]))
        XCTAssertThrowsError(try ErgoStratumClient.decodeSubscription(
            [[], String(repeating: "aa", count: 9), -1]))
        XCTAssertThrowsError(try ErgoStratumClient.decodeJob([], generation: 1,
            extraNoncePrefix: [], extraNonce2Size: 8))

        let message = String(repeating: "11", count: 32)
        XCTAssertThrowsError(try ErgoStratumClient.decodeJob(
            ["job", -1, message, "", "", 2, "1", "", true],
            generation: 1, extraNoncePrefix: [], extraNonce2Size: 8))
        XCTAssertThrowsError(try ErgoStratumClient.decodeJob(
            ["job", 1_500_000, message, "", "", 2, "0", "", true],
            generation: 1, extraNoncePrefix: [], extraNonce2Size: 8))
        XCTAssertThrowsError(try ErgoStratumClient.decodeJob(
            ["job", 1_500_000, message, "", "", 2, "1", "", true],
            generation: 1, extraNoncePrefix: [0xaa], extraNonce2Size: 8))
        XCTAssertThrowsError(try ErgoStratumClient.decodeJob(
            ["job", 1_500_000, message, "", "", 1, "1", "", true],
            generation: 1, extraNoncePrefix: [], extraNonce2Size: 8))
    }
}
