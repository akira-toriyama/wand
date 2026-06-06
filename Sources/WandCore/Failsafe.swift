// `[failsafe]` — the safety-net block that catches the worst-case
// failure mode of any low-level mouse-grabbing daemon: a stuck
// click / drag that leaves the user's PC unusable.
//
// Unlike every other config block, `[failsafe]` is **mandatory**.
// A missing block makes `WandConfig.parse` set
// `failsafeBlockPresent = false`; the App layer (`load`,
// `--validate`) treats that as fatal and refuses to bring the
// daemon up. The deliberate deviation from wand's
// clamp-to-default rule is documented in CLAUDE.md's "Safety
// invariants" section: a silently-defaulted safety net is worse
// than a loud "your config is missing this required block".

import Foundation

/// `[failsafe]` parsed values. Always populated to defaults so
/// the runtime never has to handle `nil`; presence of the block
/// in the user's config is tracked separately via
/// `WandConfig.failsafeBlockPresent`.
public struct FailsafeConfig: Sendable, Equatable {
    /// Maximum time (seconds) any mouse button may stay reported as
    /// `down` before wand force-releases it. Clamped 5..300. `0` = off
    /// (not recommended; the bundled template never ships this).
    public let mouseHoldTimeoutSec: Int

    /// Global key that triggers the idempotent emergency-release
    /// sequence. Observed via `NSEvent.addGlobalMonitorForEvents`
    /// (passive — the underlying app still receives the key), so
    /// normal Esc / cancel behaviour is preserved.
    /// Currently only `"esc"` is implemented; future keys can be
    /// added without a schema change.
    public let emergencyReleaseKey: String

    public init(mouseHoldTimeoutSec: Int = 30,
                emergencyReleaseKey: String = "esc") {
        self.mouseHoldTimeoutSec = mouseHoldTimeoutSec
        self.emergencyReleaseKey = emergencyReleaseKey
    }

    public static let `default` = FailsafeConfig()
}
