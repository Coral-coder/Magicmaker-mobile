import Foundation

/// Transmit timing from esp32_magicband. Port of Android `core/TransmitTiming.kt`.
///
/// sendWithWakeup: wakeup ping on air, then command burst.
/// Prelude bumped +100ms over the esp32 default — the band needs a touch longer to wake.
enum TransmitTiming {
    // Band commands interleave wake/command 1:1: `commandBurstMs` is the TOTAL interleave
    // window; the wake prelude is the per-slice duration of each wake and each command burst.
    static let commandBurstMs = 4000
    static let minCommandBurstMs = 500
    static let maxCommandBurstMs = 12000
    static let pingBurstMs = 2000
    static let defaultWakeupPreludeMs = 520
    static let minWakeupPreludeMs = 100
    static let maxWakeupPreludeMs = 3000
    /// Older name for `defaultWakeupPreludeMs`; prefer that or the stored runtime value.
    static let wakeupPreludeMs = defaultWakeupPreludeMs
    static let wakeupGapMs: Int64 = 520
    static let starlightBurstMs = 500
    static let minStarlightBurstMs = 250
    static let maxStarlightBurstMs = 5000
    /// Gap after the advertiser stops before scanning or advertising again.
    static let radioSettleMs: Int64 = 150
    /// Extra delay before restarting the scan after a transmit.
    static let scanResumeDelayMs: Int64 = 200
}
