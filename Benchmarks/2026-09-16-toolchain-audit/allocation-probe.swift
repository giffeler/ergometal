import Foundation

@main enum AllocationProbe {
    static func main() throws {
        let handle = dlopen(ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"]!, RTLD_NOW)!
        let reset = unsafeBitCast(dlsym(handle, "audit_reset"), to: (@convention(c) () -> Void).self)
        let objects = unsafeBitCast(dlsym(handle, "audit_objects"), to: (@convention(c) () -> UInt64).self)
        let bytes = unsafeBitCast(dlsym(handle, "audit_bytes"), to: (@convention(c) () -> UInt64).self)
        let message = [UInt8](repeating: 0x5a, count: 32)
        let nonce = [UInt8](repeating: 0, count: 8)
        let input = [UInt8](repeating: 42, count: 8_200)
        _ = try AutolykosV2.hit(message: message, nonce: nonce, height: 614400, tableSize: 1024)
        _ = Blake2b256.hash(input)
        reset()
        let digest = Blake2b256.hash(input)
        let hashObjects = objects(), hashBytes = bytes()
        print("hash-8200,\(hashObjects),\(hashBytes),\(digest.hex)")
        reset()
        let hit = try AutolykosV2.hit(message: message, nonce: nonce, height: 614400, tableSize: 1024)
        let hitObjects = objects(), hitBytes = bytes()
        print("hit,\(hitObjects),\(hitBytes),\(hit.hex)")
        // The public array boundary is intentionally exercised separately.
        let value = UInt256(bigEndian: message)
        reset()
        let exposed = value.limbs
        let limbObjects = objects(), limbBytes = bytes()
        print("public-limbs,\(limbObjects),\(limbBytes),\(exposed)")
    }
}
