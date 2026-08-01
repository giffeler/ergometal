import Foundation

/// Produces a single-line mining status that fits the visible terminal width.
/// Fields are progressively condensed so the most useful live values remain
/// visible instead of letting the terminal soft-wrap the status line.
public enum MinerStatusLineFormatter {
    public static func format(
        _ snapshot: MinerSnapshot,
        suffix: String,
        maximumColumns: Int? = nil
    ) -> String {
        let prefetch = snapshot.prefetchHeight == nil
            ? "prefetch=off"
            : String(
                format: "prefetch=%5.1f%%",
                min(1, max(0, snapshot.prefetchProgress)) * 100)
        let compactPrefetch = snapshot.prefetchHeight == nil
            ? "pre=off"
            : String(
                format: "pre=%.0f%%",
                min(1, max(0, snapshot.prefetchProgress)) * 100)
        let temperature = snapshot.socTemperatureMaximumCelsius.map {
            String(
                format: "temp=%4.1f/%4.1fC",
                $0,
                snapshot.socTemperatureSessionPeakCelsius ?? $0)
        } ?? "temp=n/a"
        let compactTemperature = snapshot.socTemperatureMaximumCelsius.map {
            String(
                format: "temp=%.0f/%.0fC",
                $0,
                snapshot.socTemperatureSessionPeakCelsius ?? $0)
        } ?? "temp=n/a"
        let luck = snapshot.shareLuckRatio.map {
            String(format: "luck=%5.1f%%", $0 * 100)
        } ?? "luck=n/a"
        let tinySuffix = suffix
            .replacingOccurrences(of: "shares=", with: "sh=")
            .replacingOccurrences(of: "verified=", with: "v=")

        let candidates = [
            String(
                format: "current=%6.2f  avg=%6.2f  effective=%6.2f MH/s  duty=%5.1f%%  %@  %@  expected=%.2f  %@  nonces=%llu  %@",
                snapshot.hashrate / 1_000_000,
                snapshot.averageHashrate / 1_000_000,
                snapshot.effectiveHashrate / 1_000_000,
                snapshot.searchDutyCycle * 100,
                prefetch,
                temperature,
                snapshot.shares.expected,
                luck,
                snapshot.nonces,
                suffix),
            String(
                format: "cur=%.2f avg=%.2f eff=%.2f MH/s duty=%.1f%% %@ %@ exp=%.2f %@ %@",
                snapshot.hashrate / 1_000_000,
                snapshot.averageHashrate / 1_000_000,
                snapshot.effectiveHashrate / 1_000_000,
                snapshot.searchDutyCycle * 100,
                compactPrefetch,
                compactTemperature,
                snapshot.shares.expected,
                luck,
                suffix),
            String(
                format: "cur=%.2f eff=%.2f MH/s %@ %@ %@",
                snapshot.hashrate / 1_000_000,
                snapshot.effectiveHashrate / 1_000_000,
                compactPrefetch,
                compactTemperature,
                suffix),
            String(
                format: "%.2f/%.2f MH/s %@ %@",
                snapshot.hashrate / 1_000_000,
                snapshot.effectiveHashrate / 1_000_000,
                compactPrefetch,
                suffix),
            String(
                format: "e=%.2fM %@",
                snapshot.effectiveHashrate / 1_000_000,
                tinySuffix)
        ]

        guard let maximumColumns else { return candidates[0] }
        let limit = max(1, maximumColumns)
        if let fitting = candidates.first(where: { $0.count <= limit }) {
            return fitting
        }
        return String(candidates.last!.prefix(limit))
    }
}
