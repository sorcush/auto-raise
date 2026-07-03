import Foundation

/// Pure conversions between a user-facing delay (ms) and the engine's -delay units.
enum DelayConversion {
    static let pollMillis = 5
    static let maxDelayMs = 2000

    /// Clamp to [0, maxDelayMs] and snap to a pollMillis multiple.
    static func clampMs(_ ms: Int) -> Int {
        let clamped = min(max(ms, 0), maxDelayMs)
        return (clamped / pollMillis) * pollMillis
    }

    /// Engine units: 1 = fire on settle; each extra unit adds one pollMillis.
    static func delayUnits(fromMs ms: Int) -> Int {
        let clamped = clampMs(ms)
        return max(1, Int((Double(clamped) / Double(pollMillis)).rounded()) + 1)
    }
}
