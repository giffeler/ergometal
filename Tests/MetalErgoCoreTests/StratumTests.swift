import Foundation
import Testing
import Network
@testable import MetalErgoCore

struct StratumTests {
    @Test func testShareRejectionReportsCodeWithoutEchoingPoolProse() {
        #expect(ErgoStratumClient.shareRejectionDiagnostic(
            [23, "wallet=WALLET password=SECRET", NSNull()]) == "pool rejected share (code 23)")
        for raw: Any in [NSNull(), ["SECRET", "wallet=WALLET"], [true, "SECRET"], [23.5, "SECRET"]] {
            #expect(ErgoStratumClient.shareRejectionDiagnostic(raw) == "pool rejected share")
        }
    }

    @Test func testTCPAndTLSConnectionsEnableKeepalive() throws {
        for useTLS in [false, true] {
            let parameters = ErgoStratumClient.connectionParameters(useTLS: useTLS)
            let tcp = try #require(
                parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)

            #expect(tcp.enableKeepalive)
            #expect(tcp.keepaliveIdle == ErgoStratumClient.keepaliveIdleSeconds)
            #expect(tcp.keepaliveInterval == ErgoStratumClient.keepaliveIntervalSeconds)
            #expect(tcp.keepaliveCount == ErgoStratumClient.keepaliveProbeCount)
        }
    }

    @Test func testMiningcoreSubscriptionAndJobLayout() throws {
        let subscription: [Any] = [[["mining.set_difficulty", "id"], ["mining.notify", "id"]], "a1b2", 6]
        let extra = try ErgoStratumClient.decodeSubscription(subscription)
        #expect(extra.prefix == [0xa1, 0xb2])
        #expect(extra.extraNonce2Size == 6)

        let message = String(repeating: "11", count: 32)
        let target = "1000000000000000000000000000000000000000000000000000000000000000"
        let params: [Any] = ["job-7", 1_500_000, message, "", "", 2, target, "", true]
        let job = try ErgoStratumClient.decodeJob(params, generation: 7,
            extraNoncePrefix: extra.prefix, extraNonce2Size: extra.extraNonce2Size)
        #expect(job.id == "job-7")
        #expect(job.height == 1_500_000)
        #expect(job.message == [UInt8](repeating: 0x11, count: 32))
        #expect(job.target == UInt256(encoded: target))
        #expect(job.cleanJobs)

        let livePoolParams: [Any] = [
            "3eb", 1_839_512, message, "", "", "00000002",
            "6634674375215649981044791689095340972727658017446627184440307089471", "", false
        ]
        let livePoolJob = try ErgoStratumClient.decodeJob(
            livePoolParams, generation: 8, extraNoncePrefix: extra.prefix,
            extraNonce2Size: extra.extraNonce2Size)
        #expect(livePoolJob.version == 2)
        #expect(livePoolJob.height == 1_839_512)
    }

    @Test func testRejectsMalformedExtranonceAndJob() {
        #expect(throws: (any Error).self) { try ErgoStratumClient.decodeSubscription([[], "abcd", 5]) }
        #expect(throws: (any Error).self) {
            try ErgoStratumClient.decodeSubscription(
                [[], String(repeating: "aa", count: 9), -1])
        }
        #expect(throws: (any Error).self) {
            try ErgoStratumClient.decodeJob([], generation: 1,
                extraNoncePrefix: [], extraNonce2Size: 8)
        }

        let message = String(repeating: "11", count: 32)
        #expect(throws: (any Error).self) {
            try ErgoStratumClient.decodeJob(
                ["job", -1, message, "", "", 2, "1", "", true],
                generation: 1, extraNoncePrefix: [], extraNonce2Size: 8)
        }
        #expect(throws: (any Error).self) {
            try ErgoStratumClient.decodeJob(
                ["job", 1_500_000, message, "", "", 2, "0", "", true],
                generation: 1, extraNoncePrefix: [], extraNonce2Size: 8)
        }
        #expect(throws: (any Error).self) {
            try ErgoStratumClient.decodeJob(
                ["job", 1_500_000, message, "", "", 2, "1", "", true],
                generation: 1, extraNoncePrefix: [0xaa], extraNonce2Size: 8)
        }
        #expect(throws: (any Error).self) {
            try ErgoStratumClient.decodeJob(
                ["job", 1_500_000, message, "", "", 1, "1", "", true],
                generation: 1, extraNoncePrefix: [], extraNonce2Size: 8)
        }
    }
}
