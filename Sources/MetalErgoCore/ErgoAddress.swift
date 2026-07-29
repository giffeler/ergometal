import Foundation

public enum ErgoNetwork: String, Sendable {
    case mainnet
    case testnet

    fileprivate var addressPrefix: UInt8 {
        switch self {
        case .mainnet: return 0x00
        case .testnet: return 0x10
        }
    }
}

public enum ErgoAddress {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    public static func isPlausible(_ address: String, network: String = "mainnet") -> Bool {
        guard let network = ErgoNetwork(rawValue: network) else { return false }
        return isPlausible(address, network: network)
    }

    public static func isPlausible(_ address: String, network: ErgoNetwork) -> Bool {
        guard let decoded = base58Decode(address), decoded.count >= 6 else { return false }
        let payload = Array(decoded.dropLast(4))
        let checksum = Array(decoded.suffix(4))
        guard Array(Blake2b256.hash(payload).prefix(4)) == checksum else { return false }

        let header = payload[0]
        guard header & 0xf0 == network.addressPrefix else { return false }
        let content = payload.dropFirst()
        switch header & 0x0f {
        case 0x01:
            return content.count == 33 && (content.first == 0x02 || content.first == 0x03)
        case 0x02:
            return content.count == 24
        case 0x03:
            return !content.isEmpty
        default:
            return false
        }
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
