import Foundation
import XCTest
import MetalErgoCore

final class TuningTests: XCTestCase {
    func testBudgetCancelsBuildWithOneElementChunks() throws {
        let probe = try MetalAutolykosSolver()
        let info = probe.info
        let fingerprint = GPUArchitectureFingerprint(
            deviceName: info.name, architectureName: info.architectureName,
            highestKnownAppleFamily: info.highestKnownAppleFamily,
            searchThreadExecutionWidth: info.searchThreadExecutionWidth!,
            searchMaxThreadsPerThreadgroup: info.searchPipelineMaxThreads!,
            buildThreadExecutionWidth: info.buildThreadExecutionWidth!,
            buildMaxThreadsPerThreadgroup: info.buildPipelineMaxThreads!,
            operatingSystemBuild: GPUArchitectureFingerprint.operatingSystemBuild())
        let fixed = MetalExecutionOverrides(synchronousBuildChunkElements: 1)
        let tuner = LiveMetalAutotuner(profile: .peak,
            initial: fixed.applying(to: .safeFallback(profile: .peak)), fixed: fixed,
            datasetKernel: .u32PairInlineM, datasetScheduling: .overlap,
            searchKernel: .search, budget: AutotuningBudget(seconds: 0.2),
            fingerprint: fingerprint)
        let outcome = try tuner.run()
        XCTAssertEqual(outcome.measurements["budget_expired"], 1)
        XCTAssertEqual(outcome.measurements["autotune.complete"], 0)
        XCTAssertLessThan(try XCTUnwrap(outcome.measurements["autotune.elapsed_seconds"]), 5)
        XCTAssertEqual(outcome.configuration, fixed.applying(to: .safeFallback(profile: .peak)))
    }
}
