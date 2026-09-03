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

    func testTuningModesProfilesAndOverridesParseExactly() throws {
        let args = try Arguments([
            "benchmark",
            "--profile", "peak",
            "--autotune", "off",
            "--threadgroup-size", "64",
            "--dataset-threadgroup-size", "128",
            "--batch-nonces", "524288",
            "--prebuild-batch-nonces", "32768",
            "--build-chunk-elements", "1048576",
            "--prefetch-chunk-elements", "524288",
            "--search-pipeline-depth", "4",
            "--build-pipeline-depth", "3"
        ])
        XCTAssertEqual(try CLITuning.profile(from: args), .peak)
        XCTAssertEqual(try CLITuning.mode(from: args), .off)
        let values = try CLITuning.overrides(from: args)
        XCTAssertEqual(values.searchThreadgroupSize, 64)
        XCTAssertEqual(values.datasetThreadgroupSize, 128)
        XCTAssertEqual(values.batchNonces, 524_288)
        XCTAssertEqual(values.prebuildBatchNonces, 32_768)
        XCTAssertEqual(values.synchronousBuildChunkElements, 1_048_576)
        XCTAssertEqual(values.prefetchBuildChunkElements, 524_288)
        XCTAssertEqual(values.searchPipelineDepth, 4)
        XCTAssertEqual(values.buildPipelineDepth, 3)
        XCTAssertTrue(values.isComplete)
    }

    func testTuningOptionRangesAndEnumsRejectInvalidValues() throws {
        XCTAssertThrowsError(try CLITuning.profile(
            from: Arguments(["mine", "--profile", "turbo"])))
        XCTAssertThrowsError(try CLITuning.mode(
            from: Arguments(["mine", "--autotune", "always"])))
        XCTAssertThrowsError(try CLITuning.overrides(
            from: Arguments(["mine", "--search-pipeline-depth", "0"])))
        XCTAssertThrowsError(try CLITuning.overrides(
            from: Arguments(["mine", "--build-pipeline-depth", "5"])))
    }
}
