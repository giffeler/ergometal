import Foundation
import MetalErgoCore

/// Uses the production height and full table index space, computing only
/// individual verifier elements on CPU, never a CPU Dataset.
/// Link this harness against the production-built MetalErgoCore library.
/// It is never linked into the miner. See cpu_linked.py for exact flags.
@main
enum ConsensusBenchmark {
    static func main() throws {
        for size in [32, 128, 8_200] {
            var input = (0..<size).map { UInt8(truncatingIfNeeded: $0) }
            let iterations = size == 8_200 ? 8_192 : 262_144
            var checksum: UInt64 = 0
            let start = ProcessInfo.processInfo.systemUptime
            for i in 0..<iterations {
                input[0] = UInt8(truncatingIfNeeded: i)
                checksum &+= UInt64(Blake2b256.hash(input)[0])
            }
            report("blake2b-\(size)", iterations, start, checksum)
        }

        let message = [UInt8](repeating: 0x5a, count: 32)
        var checksum: UInt64 = 0
        let iterations = 256
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<iterations {
            let nonce = [UInt8](repeating: 0, count: 7) + [UInt8(truncatingIfNeeded: i)]
            let hit = try AutolykosV2.hit(
                message: message, nonce: nonce, height: 1_873_775, tableSize: 227_251_815)
            checksum &+= UInt64(hit.bigEndianBytes[0])
        }
        report("autolykos-hit", iterations, start, checksum)
    }

    private static func report(_ name: String, _ iterations: Int, _ start: Double, _ checksum: UInt64) {
        let seconds = ProcessInfo.processInfo.systemUptime - start
        print("\(name),\(iterations),\(seconds),\(checksum)")
    }
}
