import Foundation

@main enum CorrectnessProbe {
    static func main() {
        for count in Array(0...300) + [8_191, 8_192, 8_199, 8_200, 8_201, 16_384] {
            let input = (0..<count).map { UInt8(truncatingIfNeeded: $0 * 17 + count) }
            let expected = Blake2b256.hash(input)
            print("\(count),\(expected.hex)")
            #if SEGMENTED
            for split in Set([0, count / 2, count] + [1, 7, 8, 120, 127, 128, 129, 256].filter { $0 <= count }) {
                let actual = Blake2b256.hash(prefix: input.span.extracting(0..<split),
                                            suffix: input.span.extracting(split..<count))
                precondition(actual == expected)
                let prefix = Array(input.prefix(split)), suffix = Array(input.dropFirst(split))
                precondition(Blake2b256.hash(prefix: prefix.span, suffix: suffix.span) == expected)
            }
            #endif
        }
        print("layout,\(MemoryLayout<InlineArray<8, UInt32>>.size),\(MemoryLayout<InlineArray<8, UInt32>>.stride),\(MemoryLayout<InlineArray<8, UInt32>>.alignment)")
    }
}
