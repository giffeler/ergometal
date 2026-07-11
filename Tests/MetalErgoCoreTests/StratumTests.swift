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
    }

    func testRejectsMalformedExtranonceAndJob() {
        XCTAssertThrowsError(try ErgoStratumClient.decodeSubscription([[], "abcd", 5]))
        XCTAssertThrowsError(try ErgoStratumClient.decodeJob([], generation: 1,
            extraNoncePrefix: [], extraNonce2Size: 8))
    }
}
