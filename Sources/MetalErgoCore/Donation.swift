import Foundation

public enum MiningRecipient: String, Codable, Sendable {
    case user
    case donation
}

public enum DonationScheduleError: Error, LocalizedError {
    case invalidPercent(Int)
    case invalidCycleDuration(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .invalidPercent(let value):
            return "Donation percent must be in 0...100, not \(value)"
        case .invalidCycleDuration(let value):
            return "Donation cycle duration must be finite and positive, not \(value)"
        }
    }
}

/// A wall-clock schedule. Each cycle starts with the user's share and ends
/// with the optional donation share; no hash or share counter affects it.
public struct DonationSchedule: Sendable {
    public static let defaultCycleSeconds: TimeInterval = 100 * 60

    public let percent: Int
    public let cycleSeconds: TimeInterval

    public init(
        percent: Int,
        cycleSeconds: TimeInterval = DonationSchedule.defaultCycleSeconds
    ) throws {
        guard (0...100).contains(percent) else {
            throw DonationScheduleError.invalidPercent(percent)
        }
        guard cycleSeconds.isFinite, cycleSeconds > 0 else {
            throw DonationScheduleError.invalidCycleDuration(cycleSeconds)
        }
        self.percent = percent
        self.cycleSeconds = cycleSeconds
    }

    public var isEnabled: Bool { percent > 0 }

    public func recipient(at elapsedSeconds: TimeInterval) -> MiningRecipient {
        guard percent > 0 else { return .user }
        guard percent < 100 else { return .donation }
        let position = normalizedPosition(elapsedSeconds)
        return position < userSecondsPerCycle ? .user : .donation
    }

    public func cycleIndex(at elapsedSeconds: TimeInterval) -> Int {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return 0 }
        return Int(elapsedSeconds / cycleSeconds)
    }

    /// Returns the next phase or cycle boundary measured from schedule start.
    /// A 100% schedule still returns each cycle boundary so a failed donation
    /// connection can be retried without adding a separate retry policy.
    public func nextBoundary(after elapsedSeconds: TimeInterval) -> TimeInterval? {
        guard isEnabled else { return nil }
        let elapsed = max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0)
        let cycle = floor(elapsed / cycleSeconds)
        let cycleStart = cycle * cycleSeconds
        let position = elapsed - cycleStart
        if percent < 100, position < userSecondsPerCycle {
            return cycleStart + userSecondsPerCycle
        }
        return cycleStart + cycleSeconds
    }

    private var userSecondsPerCycle: TimeInterval {
        cycleSeconds * Double(100 - percent) / 100
    }

    private func normalizedPosition(_ elapsedSeconds: TimeInterval) -> TimeInterval {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return 0 }
        return elapsedSeconds.truncatingRemainder(dividingBy: cycleSeconds)
    }
}

public struct DonationStatistics: Codable, Sendable {
    public var percent: Int
    public var scheduledRecipient: MiningRecipient
    public var activeRecipient: MiningRecipient
    public var windowSeconds: Double
    public var searchSeconds: Double
    public var nonces: UInt64
    public var shares: ShareStatistics
    public var switches: Int
    public var failures: Int

    public init(
        percent: Int = 0,
        scheduledRecipient: MiningRecipient = .user,
        activeRecipient: MiningRecipient = .user,
        windowSeconds: Double = 0,
        searchSeconds: Double = 0,
        nonces: UInt64 = 0,
        shares: ShareStatistics = ShareStatistics(),
        switches: Int = 0,
        failures: Int = 0
    ) {
        self.percent = percent
        self.scheduledRecipient = scheduledRecipient
        self.activeRecipient = activeRecipient
        self.windowSeconds = windowSeconds
        self.searchSeconds = searchSeconds
        self.nonces = nonces
        self.shares = shares
        self.switches = switches
        self.failures = failures
    }
}
