// `[failsafe]` — the one mandatory block. Decoded bespoke (block-
// present check + the empty→`esc` sentinel) rather than through
// `configSpec`, which only DESCRIBES it. Why the block is mandatory
// is written once, in config.toml's `[failsafe]` comment.

import ConfigSchema
import Foundation
import Toml

extension WandConfig {
    static func parseFailsafe(_ doc: TOMLDocument)
        -> (config: FailsafeConfig, blockPresent: Bool) {
        // [failsafe] — mandatory; absence signalled via
        // `failsafeBlockPresent`. See CLAUDE.md "Safety invariants".
        let fs = doc.tables["failsafe"] ?? [:]
        let mouseHoldTimeoutSec = clampInt(
            fs, key: "mouse-hold-timeout-seconds",
            default: FailsafeConfig.mouseHoldTimeoutDefault,
            lo: FailsafeConfig.mouseHoldTimeoutRange.lowerBound,
            hi: FailsafeConfig.mouseHoldTimeoutRange.upperBound)
        let emergencyReleaseKey: String = {
            let raw = fs.string("emergency-release-key").lowercased()
            return raw.isEmpty ? FailsafeConfig.emergencyReleaseKeyDefault : raw
        }()
        let failsafe = FailsafeConfig(
            mouseHoldTimeoutSec: mouseHoldTimeoutSec,
            emergencyReleaseKey: emergencyReleaseKey)
        let failsafeBlockPresent = doc.tables["failsafe"] != nil
        return (failsafe, failsafeBlockPresent)
    }

    /// Clamp a `[lo, hi]` integer, logging when the parsed value
    /// differs from what the user wrote. The uniform `[block]` clamps
    /// run through `configSpec` now (`Config+Spec.swift`); this stays
    /// for the bespoke `[failsafe]` knob (decoded outside the spec
    /// because of the block-present semantics).
    private static func clampInt(_ table: [String: TOMLValue],
                                  key: String, default def: Int,
                                  lo: Int, hi: Int) -> Int {
        let raw = table.int(key, def)
        let clamped = max(lo, min(hi, raw))
        if raw != clamped {
            Log.line("config: \(key) = \(raw) clamped to \(clamped) "
                     + "(allowed \(lo)..\(hi))")
        }
        return clamped
    }

    /// `[failsafe]` — described only; decoded bespoke by `parseFailsafe`.
    static var failsafeSpecSections: [ConfigSchema.Section<Decoded>] {
        [
            .init("failsafe",
                  doc: "Mandatory safety net for low-level mouse "
                     + "interception. wand refuses to start if this block "
                     + "is absent.",
                  fields: [
                // mouse-hold-timeout-seconds / emergency-release-key are
                // decoded bespoke (the block-present check + the empty→esc
                // sentinel), but DESCRIBED here for completion.
                .descInt("mouse-hold-timeout-seconds",
                         min: Double(FailsafeConfig.mouseHoldTimeoutRange.lowerBound),
                         max: Double(FailsafeConfig.mouseHoldTimeoutRange.upperBound),
                         default: FailsafeConfig.mouseHoldTimeoutDefault,
                         doc: "Auto-release a held button after this many "
                            + "seconds (runaway-drag guard). Clamped "
                            + "\(FailsafeConfig.mouseHoldTimeoutRange.lowerBound).."
                            + "\(FailsafeConfig.mouseHoldTimeoutRange.upperBound)."),
                .descOnly("emergency-release-key",
                          default: .string(FailsafeConfig.emergencyReleaseKeyDefault),
                          doc: "Key that force-releases a stuck button "
                             + "mid-stroke. Empty = `esc`."),
            ]),
        ]
    }
}
