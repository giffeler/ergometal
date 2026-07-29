import Foundation

struct Arguments {
    let command: String
    private let values: [String: String]
    private let flags: Set<String>

    init(_ raw: [String]) throws {
        guard let command = raw.first else { throw CLIError.usage }
        self.command = command
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 1
        while index < raw.count {
            let item = raw[index]
            guard item.hasPrefix("--") else { throw CLIError.invalidArgument(item) }
            let key = String(item.dropFirst(2))
            guard !key.isEmpty else { throw CLIError.invalidArgument(item) }
            guard values[key] == nil, !flags.contains(key) else {
                throw CLIError.invalidArgument("duplicate option --\(key)")
            }
            if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                values[key] = raw[index + 1]; index += 2
            } else {
                flags.insert(key); index += 1
            }
        }
        self.values = values; self.flags = flags
    }

    func string(_ key: String, default fallback: String? = nil) -> String? { values[key] ?? fallback }
    func require(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else { throw CLIError.missing("--\(key)") }
        return value
    }
    func int(_ key: String, default fallback: Int) throws -> Int {
        guard let raw = values[key] else { return fallback }
        guard let value = Int(raw) else { throw CLIError.invalidArgument("--\(key) \(raw)") }
        return value
    }

    func int(_ key: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
        let value = try int(key, default: fallback)
        guard range.contains(value) else {
            throw CLIError.invalidArgument("--\(key) must be in \(range.lowerBound)...\(range.upperBound)")
        }
        return value
    }

    func optionalInt(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let raw = values[key] else { return nil }
        guard let value = Int(raw), range.contains(value) else {
            throw CLIError.invalidArgument("--\(key) must be in \(range.lowerBound)...\(range.upperBound)")
        }
        return value
    }

    func has(_ key: String) -> Bool { flags.contains(key) }

    func validate(valueOptions: Set<String> = [], flagOptions: Set<String> = []) throws {
        for key in flags.sorted() {
            if valueOptions.contains(key) { throw CLIError.missing("--\(key) value") }
            guard flagOptions.contains(key) else { throw CLIError.invalidArgument("--\(key)") }
        }
        for key in values.keys.sorted() {
            if flagOptions.contains(key) {
                throw CLIError.invalidArgument("--\(key) does not take a value")
            }
            guard valueOptions.contains(key) else { throw CLIError.invalidArgument("--\(key)") }
        }
    }
}

enum CLIError: Error, LocalizedError {
    case usage
    case invalidArgument(String)
    case missing(String)
    case invalidAddress
    case fixture(String)

    var errorDescription: String? {
        switch self {
        case .usage: return "missing command"
        case .invalidArgument(let value): return "invalid argument: \(value)"
        case .missing(let value): return "missing required option \(value)"
        case .invalidAddress: return "wallet is not a valid Ergo address for the selected network"
        case .fixture(let value): return "invalid replay fixture: \(value)"
        }
    }
}

let usage = """
MetalErgoMiner research CLI

Usage:
  ergometal devices [--json]
  ergometal benchmark [--duration 60] [--height 614399] [--profile efficiency|peak]
                      [--table-size N] [--prebuild on|off]
                      [--batch-nonces N] [--threadgroup-size N]
                      [--gpu-trace path.gputrace] [--gpu-trace-phase build|search]
                      [--api-bind 127.0.0.1:4078] [--stats-file path] [--json]
  ergometal replay --fixture path
  ergometal mine --pool stratum+tcp://host:port --wallet address [--worker name]
                 [--network mainnet|testnet] [--profile efficiency|peak]
                 [--prebuild auto|on|off]
                 [--batch-nonces N] [--threadgroup-size N]
                 [--api-bind 127.0.0.1:4078] [--stats-file path]
                 [--stats-interval 60]

The pool password defaults to ERGOMETAL_POOL_PASSWORD or "x" and is never logged.
"""
