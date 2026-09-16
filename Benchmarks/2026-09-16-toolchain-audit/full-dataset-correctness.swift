import Foundation
import MetalErgoCore

/// Standalone correctness check; run separately from throughput measurements.
@main enum FullDatasetCorrectness {
    static func main() throws {
        let height = 1_873_775
        let solver = try MetalAutolykosSolver(
            synchronousBuildChunkElements: 2_097_152,
            prefetchBuildChunkElements: 1_048_576,
            searchThreadgroupSize: 64, datasetThreadgroupSize: 256,
            searchPipelineDepth: 2, buildPipelineDepth: 2)
        let build = try solver.buildDataset(height: height)
        let message = Blake2b256.hash(Array("ergometal-full-dataset-correctness".utf8))
        let hits = try (0..<129).map { value in
            try AutolykosV2.hit(message: message,
                nonce: [UInt8](repeating: 0, count: 7) + [UInt8(value)], height: height)
        }
        let target = hits[64]
        var cases = 0
        for group in [32, 33, 64] {
            for count in [1, 31, 32, 33, 63, 64, 65, 127, 128, 129] {
                let expected = (0..<count).filter { hits[$0] < target }.map(UInt64.init)
                let batch = try solver.search(message: message, target: target,
                    baseNonce: 0, nonceCount: count, threadgroupSize: group)
                precondition(batch.candidates == expected, "group=\(group), count=\(count)")
                cases += 1
            }
        }
        let indices = [0, 1, 1_023, build.tableSize / 2, build.tableSize - 1]
        let expected = try indices.map { try AutolykosV2.datasetElement(index: $0, height: height) }
        let actual = try solver.datasetElements(at: indices)
        precondition(actual == expected)
        print("height=\(height) table=\(build.tableSize) bytes=\(build.tableSize * 32) search_cases=\(cases) dataset_cells=\(indices.count) PASS")
    }
}
