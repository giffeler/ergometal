import XCTest
@testable import MetalErgoCore

final class ArgumentsTests: XCTestCase {
    func testDonationDefaultsToZeroAndAcceptsIntegerBounds() throws {
        XCTAssertEqual(try Arguments(["mine"]).donationPercent(network: .mainnet), 0)
        XCTAssertEqual(
            try Arguments(["mine", "--donation", "0"]).donationPercent(network: .mainnet),
            0)
        XCTAssertEqual(
            try Arguments(["mine", "--donation", "1"]).donationPercent(network: .mainnet),
            1)
        XCTAssertEqual(
            try Arguments(["mine", "--donation", "100"]).donationPercent(network: .mainnet),
            100)
    }

    func testDonationRejectsInvalidValuesAndTestnet() throws {
        XCTAssertThrowsError(
            try Arguments(["mine", "--donation", "-1"]).donationPercent(network: .mainnet))
        XCTAssertThrowsError(
            try Arguments(["mine", "--donation", "101"]).donationPercent(network: .mainnet))
        XCTAssertThrowsError(
            try Arguments(["mine", "--donation", "0.5"]).donationPercent(network: .mainnet))
        XCTAssertThrowsError(
            try Arguments(["mine", "--donation", "1"]).donationPercent(network: .testnet))
        XCTAssertThrowsError(
            try Arguments(["mine", "--donation", "0"]).donationPercent(network: .testnet))
    }

    func testDonationRequiresAValue() throws {
        let args = try Arguments(["mine", "--donation"])
        XCTAssertThrowsError(try args.validate(valueOptions: ["donation"]))
    }
}
