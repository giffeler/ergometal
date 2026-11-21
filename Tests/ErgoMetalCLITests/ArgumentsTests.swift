import Testing
@testable import MetalErgoCore

struct ArgumentsTests {
    @Test func testDonationDefaultsToZeroAndAcceptsIntegerBounds() throws {
        #expect(try Arguments(["mine"]).donationPercent(network: .mainnet) == 0)
        #expect(try Arguments(["mine", "--donation", "0"]).donationPercent(network: .mainnet) == 0)
        #expect(try Arguments(["mine", "--donation", "1"]).donationPercent(network: .mainnet) == 1)
        #expect(try Arguments(["mine", "--donation", "100"]).donationPercent(network: .mainnet) == 100)
    }

    @Test func testDonationRejectsInvalidValuesAndTestnet() throws {
        #expect(throws: (any Error).self) {
            try Arguments(["mine", "--donation", "-1"]).donationPercent(network: .mainnet)
        }
        #expect(throws: (any Error).self) {
            try Arguments(["mine", "--donation", "101"]).donationPercent(network: .mainnet)
        }
        #expect(throws: (any Error).self) {
            try Arguments(["mine", "--donation", "0.5"]).donationPercent(network: .mainnet)
        }
        #expect(throws: (any Error).self) {
            try Arguments(["mine", "--donation", "1"]).donationPercent(network: .testnet)
        }
        #expect(throws: (any Error).self) {
            try Arguments(["mine", "--donation", "0"]).donationPercent(network: .testnet)
        }
    }

    @Test func testDonationRequiresAValue() throws {
        let args = try Arguments(["mine", "--donation"])
        #expect(throws: (any Error).self) { try args.validate(valueOptions: ["donation"]) }
    }

    @Test func testTuningModesProfilesAndOverridesParseExactly() throws {
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
        #expect(try CLITuning.profile(from: args) == .peak)
        #expect(try CLITuning.mode(from: args) == .off)
        let values = try CLITuning.overrides(from: args)
        #expect(values.searchThreadgroupSize == 64)
        #expect(values.datasetThreadgroupSize == 128)
        #expect(values.batchNonces == 524_288)
        #expect(values.prebuildBatchNonces == 32_768)
        #expect(values.synchronousBuildChunkElements == 1_048_576)
        #expect(values.prefetchBuildChunkElements == 524_288)
        #expect(values.searchPipelineDepth == 4)
        #expect(values.buildPipelineDepth == 3)
        #expect(values.isComplete)
    }

    @Test func testTuningOptionRangesAndEnumsRejectInvalidValues() throws {
        #expect(throws: (any Error).self) {
            try CLITuning.profile(
                from: Arguments(["mine", "--profile", "turbo"]))
        }
        #expect(throws: (any Error).self) {
            try CLITuning.mode(
                from: Arguments(["mine", "--autotune", "always"]))
        }
        #expect(throws: (any Error).self) {
            try CLITuning.overrides(
                from: Arguments(["mine", "--search-pipeline-depth", "0"]))
        }
        #expect(throws: (any Error).self) {
            try CLITuning.overrides(
                from: Arguments(["mine", "--build-pipeline-depth", "5"]))
        }
    }
}
