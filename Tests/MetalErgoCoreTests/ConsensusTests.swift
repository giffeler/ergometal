import XCTest
@testable import MetalErgoCore

final class ConsensusTests: XCTestCase {
    func testBlake2b256Vectors() {
        XCTAssertEqual(Blake2b256.hash([]).hex,
            "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
        XCTAssertEqual(Blake2b256.hash(Array("abc".utf8)).hex,
            "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
    }

    func testCalcNConsensusBoundaries() {
        XCTAssertEqual(AutolykosV2.calcN(height: 614_399), 67_108_864)
        XCTAssertEqual(AutolykosV2.calcN(height: 614_400), 70_464_240)
        XCTAssertEqual(AutolykosV2.calcN(height: 665_599), 70_464_240)
        XCTAssertEqual(AutolykosV2.calcN(height: 665_600), 73_987_410)
        XCTAssertEqual(AutolykosV2.calcN(version: 1, height: 9_000_000), 67_108_864)
        XCTAssertEqual(AutolykosV2.calcN(height: 4_198_400), AutolykosV2.calcN(height: 9_000_000))
    }

    func testIndependentAutolykosFixture() throws {
        let message = try XCTUnwrap([UInt8](hex: "fb4ea208049836e0b879b90da0ab9b2173cd84f5889b85668378081f95e0bbf6"))
        let nonce = try XCTUnwrap([UInt8](hex: "000000000000002a"))
        let hit = try AutolykosV2.hit(message: message, nonce: nonce, height: 614_400, tableSize: 1_024)
        XCTAssertEqual(hit.hex, "2d9b2daa19cba01c595881ed4cc12eb24f3417d4b2e76f062ae1f355464deede")
    }

    func testDecimalUInt256ParsingAndAddition() throws {
        let decimal = try XCTUnwrap(UInt256(encoded: "115792089237316195423570985008687907853269984665640564039457584007913129639935"))
        XCTAssertEqual(decimal, .max)
        var value = UInt256(bigEndian: [0xff])
        value.add(UInt256(bigEndian: [1]))
        XCTAssertEqual(value.hex.suffix(4), "0100")
    }

    func testMetalMatchesCPUForFixture() throws {
        let solver = try MetalAutolykosSolver()
        _ = try solver.buildDataset(height: 614_400, tableSize: 1_024)
        let message = try XCTUnwrap([UInt8](hex: "fb4ea208049836e0b879b90da0ab9b2173cd84f5889b85668378081f95e0bbf6"))
        let cpuHit = try AutolykosV2.hit(message: message, nonce: [0,0,0,0,0,0,0,42], height: 614_400, tableSize: 1_024)
        let rejected = try solver.search(message: message, target: cpuHit, baseNonce: 42, nonceCount: 1)
        XCTAssertEqual(rejected.candidates, [], "Metal hit must use strict less-than target semantics")
        var nextLimbs = cpuHit.limbs
        nextLimbs[7] += 1
        let accepted = try solver.search(message: message, target: UInt256(limbs: nextLimbs), baseNonce: 42, nonceCount: 1)
        XCTAssertEqual(accepted.candidates, [42], "Metal and CPU must calculate the same 256-bit hit")
    }
}
