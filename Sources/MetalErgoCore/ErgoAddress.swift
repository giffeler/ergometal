import Foundation

public enum ErgoAddress {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    public static func isPlausible(_ address: String, network: String = "mainnet") -> Bool {
        guard let decoded = base58Decode(address), decoded.count >= 5 else { return false }
        let payload = Array(decoded.dropLast(4))
        let checksum = Array(decoded.suffix(4))
        guard Array(Blake2b256.hash(payload).prefix(4)) == checksum else { return false }
        let networkNibble = decoded[0] >> 4
        return network == "testnet" ? networkNibble == 0x1 : networkNibble == 0x0
    }

    private static func base58Decode(_ string: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 1)
        for character in string {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            var carry = index
            for i in stride(from: bytes.count - 1, through: 0, by: -1) {
                let value = Int(bytes[i]) * 58 + carry
                bytes[i] = UInt8(value & 0xff)
                carry = value >> 8
            }
            while carry > 0 { bytes.insert(UInt8(carry & 0xff), at: 0); carry >>= 8 }
        }
        let leading = string.prefix { $0 == "1" }.count
        return [UInt8](repeating: 0, count: leading) + (bytes == [0] ? [] : bytes)
    }
}
