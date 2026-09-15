import Foundation

/// Unsigned 256-bit integer represented as eight big-endian 32-bit limbs.
public struct UInt256: Equatable, Comparable, Codable, Sendable {
    // Fixed storage avoids heap allocation and copy-on-write checks in arithmetic.
    var words: InlineArray<8, UInt32>

    /// Array compatibility at the serialization and public API boundary.
    public var limbs: [UInt32] {
        get { (0..<8).map { words[$0] } }
        set {
            precondition(newValue.count == 8)
            words = .init { newValue[$0] }
        }
    }

    public init(limbs: [UInt32]) {
        precondition(limbs.count == 8)
        words = .init { limbs[$0] }
    }

    public init(bigEndian bytes: [UInt8]) {
        precondition(bytes.count <= 32)
        if bytes.count == 32 {
            words = .init {
                UInt32(bigEndian: bytes.span.bytes.load(fromByteOffset: $0 * 4, as: UInt32.self))
            }
        } else {
            words = .init(repeating: 0)
            let padding = 32 - bytes.count
            for i in bytes.indices {
                let offset = padding + i
                words[offset / 4] |= UInt32(bytes[i]) << ((3 - offset % 4) * 8)
            }
        }
    }

    private init(repeating word: UInt32) { words = .init(repeating: word) }

    public static let zero = UInt256(repeating: 0)
    public static let max = UInt256(repeating: .max)

    private enum CodingKeys: String, CodingKey { case limbs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let limbs = try container.decode([UInt32].self, forKey: .limbs)
        guard limbs.count == 8 else {
            throw DecodingError.dataCorruptedError(
                forKey: .limbs, in: container, debugDescription: "UInt256 requires exactly eight limbs")
        }
        self.init(limbs: limbs)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(limbs, forKey: .limbs)
    }

    public static func == (lhs: UInt256, rhs: UInt256) -> Bool {
        (0..<8).allSatisfy { lhs.words[$0] == rhs.words[$0] }
    }

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
                let product = UInt64(result.words[i]) * 10 + carry
                result.words[i] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            guard carry == 0 else { return nil }
        }
        self = result
    }

    public static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        for i in 0..<8 where lhs.words[i] != rhs.words[i] {
            return lhs.words[i] < rhs.words[i]
        }
        return false
    }

    public mutating func add(_ other: UInt256) {
        var carry: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            let sum = UInt64(words[i]) + UInt64(other.words[i]) + carry
            words[i] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
    }

    public var bigEndianBytes: [UInt8] {
        (0..<32).map { UInt8(truncatingIfNeeded: words[$0 / 4] >> ((3 - $0 % 4) * 8)) }
    }

    public var hex: String { bigEndianBytes.hex }
}
