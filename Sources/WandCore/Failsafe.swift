// `[failsafe]` parsed values. The block is mandatory — see
// CLAUDE.md "Safety invariants" for the WHY of the inverted
// clamp-to-default policy and the bundled `config.toml`'s
// `[failsafe]` header for user-facing notes. `WandConfig.parse`
// signals a missing block via `failsafeBlockPresent`.

import Foundation

public struct FailsafeConfig: Sendable, Equatable {
    /// The ONE source for `[failsafe]`'s bounds + defaults. The schema
    /// descriptor (`Config+Spec.swift`) and the lenient runtime clamp
    /// (`WandConfig.parse`) both cite these constants, so what completion
    /// SHOWS can never drift from what the loader ENFORCES. Regression-guarded
    /// by `FailsafeDriftTests`. (A3 DRY — projects t-5qxd.)
    public static let mouseHoldTimeoutRange: ClosedRange<Int> = 5...300
    public static let mouseHoldTimeoutDefault = 30
    public static let emergencyReleaseKeyDefault = "esc"

    /// Clamped to `mouseHoldTimeoutRange`.
    public let mouseHoldTimeoutSec: Int

    /// Currently only `"esc"` is implemented.
    public let emergencyReleaseKey: String

    public init(mouseHoldTimeoutSec: Int = FailsafeConfig.mouseHoldTimeoutDefault,
                emergencyReleaseKey: String = FailsafeConfig.emergencyReleaseKeyDefault) {
        self.mouseHoldTimeoutSec = mouseHoldTimeoutSec
        self.emergencyReleaseKey = emergencyReleaseKey
    }

    public static let `default` = FailsafeConfig()
}
