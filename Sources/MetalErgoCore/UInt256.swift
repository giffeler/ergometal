import Foundation

/// Unsigned 256-bit integer represented as eight big-endian 32-bit limbs.
public struct UInt256: Equatable, Comparable, Codable, Sendable {
    public var limbs: [UInt32]

    public init(limbs: [UInt32]) {
        precondition(limbs.count == 8)
        self.limbs = limbs
    }

    public init(bigEndian bytes: [UInt8]) {
        precondition(bytes.count <= 32)
        let padded = [UInt8](repeating: 0, count: 32 - bytes.count) + bytes
        var words: [UInt32] = []
        words.reserveCapacity(8)
        for i in stride(from: 0, to: 32, by: 4) {
            let a = UInt32(padded[i]) << 24
            let b = UInt32(padded[i + 1]) << 16
            let c = UInt32(padded[i + 2]) << 8
            let d = UInt32(padded[i + 3])
            words.append(a | b | c | d)
        }
        limbs = words
    }

    public static let zero = UInt256(limbs: [UInt32](repeating: 0, count: 8))
    public static let max = UInt256(limbs: [UInt32](repeating: .max, count: 8))

    public init?(encoded value: String) {
        let containsHexLetters = value.contains { ("a"..."f").contains(String($0).lowercased()) }
        if value.hasPrefix("0x") || containsHexLetters {
            let clean = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
            guard let bytes = [UInt8](hex: clean), bytes.count <= 32 else { return nil }
            self.init(bigEndian: bytes)
            return
        }
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        var result = UInt256.zero
        for character in value {
            guard let digit = character.wholeNumberValue else { return nil }
            var carry = UInt64(digit)
            for i in stride(from: 7, through: 0, by: -1) {
                let product = UInt64(result.limbs[i]) * 10 + carry
                result.limbs[i] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            guard carry == 0 else { return nil }
        }
        self = result
    }

    public static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        for i in 0..<8 where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }

    public mutating func add(_ other: UInt256) {
        var carry: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            let sum = UInt64(limbs[i]) + UInt64(other.limbs[i]) + carry
            limbs[i] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
    }

    public var bigEndianBytes: [UInt8] {
        limbs.flatMap { word in
            [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16),
             UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
        }
    }

    public var hex: String { bigEndianBytes.hex }
}
