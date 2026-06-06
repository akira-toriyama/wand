// `[failsafe]` parsed values. The block is mandatory — see
// CLAUDE.md "Safety invariants" for the WHY of the inverted
// clamp-to-default policy and the bundled `config.toml`'s
// `[failsafe]` header for user-facing notes. `WandConfig.parse`
// signals a missing block via `failsafeBlockPresent`.

import Foundation

public struct FailsafeConfig: Sendable, Equatable {
    /// Clamped 5..300.
    public let mouseHoldTimeoutSec: Int

    /// Currently only `"esc"` is implemented.
    public let emergencyReleaseKey: String

    public init(mouseHoldTimeoutSec: Int = 30,
                emergencyReleaseKey: String = "esc") {
        self.mouseHoldTimeoutSec = mouseHoldTimeoutSec
        self.emergencyReleaseKey = emergencyReleaseKey
    }

    public static let `default` = FailsafeConfig()
}
