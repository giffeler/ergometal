import Foundation

public enum AutolykosError: Error, LocalizedError {
    case invalidMessageLength(Int)
    case invalidNonceLength(Int)
    case invalidHeight(Int)
    case invalidDatasetIndex(Int)
    case invalidTableSize(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidMessageLength(let n): return "Autolykos message must contain 32 bytes, got \(n)"
        case .invalidNonceLength(let n): return "Autolykos nonce must contain 8 bytes, got \(n)"
        case .invalidHeight(let n): return "Autolykos height must fit an unsigned 32-bit value, got \(n)"
        case .invalidDatasetIndex(let n):
            return "Autolykos dataset index must fit an unsigned 32-bit value, got \(n)"
        case .invalidTableSize(let n): return "Autolykos table size must be positive, got \(n)"
        }
    }
}

public enum AutolykosV2 {
    public static let k = 32
    public static let nBase = 1 << 26
    public static let increaseStart = 600 * 1024
    public static let increasePeriod = 50 * 1024
    public static let increaseStop = 4_198_400

    public static func calcN(version: UInt8 = 2, height: Int) -> Int {
        if version == 1 { return nBase }
        let capped = min(increaseStop, height)
        guard capped >= increaseStart else { return nBase }
        let iterations = (capped - increaseStart) / increasePeriod + 1
        return (0..<iterations).reduce(nBase) { value, _ in value / 100 * 105 }
    }

    public static func datasetBytes(height: Int, version: UInt8 = 2) -> UInt64 {
        UInt64(calcN(version: version, height: height)) * 32
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private static func be64(_ value: UInt64) -> [UInt8] {
        stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> UInt64($0)) }
    }

    /// Constant M = 1024 consecutive big-endian UInt64 values.
    public static let constantM: [UInt8] = (0..<1024).flatMap { be64(UInt64($0)) }

    public static func datasetElement(
        index: Int,
        height: Int
    ) throws(AutolykosError) -> UInt256 {
        guard let encodedIndex = UInt32(exactly: index) else {
            throw AutolykosError.invalidDatasetIndex(index)
        }
        guard let encodedHeight = UInt32(exactly: height) else {
            throw AutolykosError.invalidHeight(height)
        }
        var digest = Blake2b256.hash(be32(encodedIndex) + be32(encodedHeight) + constantM)
        digest[0] = 0 // consensus uses drop(1), represented as a zero-prefixed UInt256
        return UInt256(bigEndian: digest)
    }

    public static func indexes(
        seed: [UInt8],
        tableSize: Int
    ) throws(AutolykosError) -> [Int] {
        guard tableSize > 0 else { throw AutolykosError.invalidTableSize(tableSize) }
        let digest = Blake2b256.hash(seed)
        let extended = digest + digest.prefix(3)
        return (0..<k).map { i in
            let value = (UInt32(extended[i]) << 24) | (UInt32(extended[i + 1]) << 16) |
                (UInt32(extended[i + 2]) << 8) | UInt32(extended[i + 3])
            return Int(UInt64(value) % UInt64(tableSize))
        }
    }

    public static func hit(
        message: [UInt8],
        nonce: [UInt8],
        height: Int,
        tableSize: Int? = nil
    ) throws(AutolykosError) -> UInt256 {
        guard message.count == 32 else { throw AutolykosError.invalidMessageLength(message.count) }
        guard nonce.count == 8 else { throw AutolykosError.invalidNonceLength(nonce.count) }
        guard UInt32(exactly: height) != nil else { throw AutolykosError.invalidHeight(height) }
        let n = tableSize ?? calcN(height: height)
        guard n > 0 else { throw AutolykosError.invalidTableSize(n) }

        let messageNonceHash = Blake2b256.hash(message + nonce)
        let tail = messageNonceHash.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let i = Int(tail % UInt64(n))
        let f = try datasetElement(index: i, height: height).bigEndianBytes.dropFirst()
        let js = try indexes(seed: Array(f) + message + nonce, tableSize: n)

        var sum = UInt256.zero
        for j in js { sum.add(try datasetElement(index: j, height: height)) }
        return UInt256(bigEndian: Blake2b256.hash(sum.bigEndianBytes))
    }
}

/// Helpers for traversing the variable part of an eight-byte Stratum nonce
/// without overflowing at the end of the UInt64 range.
public enum NonceSpace {
    public static func maximumOffset(variableBytes: Int) -> UInt64? {
        guard (0...8).contains(variableBytes) else { return nil }
        return variableBytes == 8 ? .max : (UInt64(1) << UInt64(variableBytes * 8)) - 1
    }

    public static func batchSize(offset: UInt64, maximumOffset: UInt64, requested: Int) -> Int {
        guard requested > 0, offset <= maximumOffset else { return 0 }
        let remainingAfterFirst = maximumOffset - offset
        let requestedAfterFirst = UInt64(requested - 1)
        return remainingAfterFirst >= requestedAfterFirst ? requested : Int(remainingAfterFirst) + 1
    }

    /// Returns the next offset, or nil after the inclusive maximum was consumed.
    public static func advance(offset: UInt64, count: Int, maximumOffset: UInt64) -> UInt64? {
        guard count > 0 else { return nil }
        let (next, overflow) = offset.addingReportingOverflow(UInt64(count))
        guard !overflow, next <= maximumOffset else { return nil }
        return next
    }
}
