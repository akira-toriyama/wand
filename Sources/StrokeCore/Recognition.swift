// Dominant-axis quantisation:
//   walk samples; when |dx| or |dy| since the last anchor exceeds
//   minStrokePx, emit a Direction on the dominant axis and reset the
//   anchor. Coalesce consecutive duplicates so a long single stroke
//   is one direction, not many. Keeps the mental model "draw a path
//   of arrow keys" instead of something fancier.

import CoreGraphics

public enum Recognition {

    public static func recognize(samples: [Sample], minStrokePx: Int) -> [Direction] {
        guard samples.count >= 2, minStrokePx > 0 else { return [] }
        var out: [Direction] = []
        var anchor = samples[0].p
        for s in samples.dropFirst() {
            let dx = s.p.x - anchor.x
            let dy = s.p.y - anchor.y
            let absX = abs(dx), absY = abs(dy)
            let threshold = CGFloat(minStrokePx)
            guard max(absX, absY) >= threshold else { continue }
            let dir: Direction
            if absX >= absY {
                dir = dx >= 0 ? .right : .left
            } else {
                // Y grows UP in the sample stream: the adapter
                // samples CGEvent.location (Y-down) and sign-flips Y
                // at creation (EventTap.flipY), so a larger y means
                // the cursor moved up. dy >= 0 ⇒ .up.
                dir = dy >= 0 ? .up : .down
            }
            if out.last != dir { out.append(dir) }
            anchor = s.p
        }
        return out
    }

    /// Number of 180° direction reversals (`L↔R`, `U↔D`) in a coalesced
    /// pattern string. Pure: counts pairs of adjacent characters in
    /// `LURD` whose axes match and signs oppose. Drives the
    /// scribble-to-cancel detector in the adapter; lives in Core so it
    /// can be unit-tested without an AX stack.
    public static func reversals(_ pattern: String) -> Int {
        let c = Array(pattern)
        guard c.count > 1 else { return 0 }
        var n = 0
        for i in 1..<c.count where isOpposite(c[i - 1], c[i]) { n += 1 }
        return n
    }

    /// Whether two `LURD` characters denote opposite directions.
    /// Public to support the same testability story as `reversals`.
    public static func isOpposite(_ a: Character, _ b: Character) -> Bool {
        (a == "L" && b == "R") || (a == "R" && b == "L")
            || (a == "U" && b == "D") || (a == "D" && b == "U")
    }

    /// Returns a human-readable issue string if `pattern` is something
    /// the recogniser can never produce — otherwise nil. Two failure
    /// modes today: a character outside the `L U R D` alphabet, and
    /// consecutive duplicate directions (the recogniser coalesces same-
    /// direction segments, so `DRR` would always read as `DR` and the
    /// rule could never fire). Called from `StrokeConfig.parse` to drop
    /// the bad rule loudly instead of letting it load and silently
    /// no-op at runtime.
    public static func patternIssue(_ pattern: String) -> String? {
        let chars = Array(pattern)
        guard !chars.isEmpty else { return "empty pattern" }
        let valid: Set<Character> = ["L", "U", "R", "D"]
        for (i, c) in chars.enumerated() {
            if !valid.contains(c) {
                return "invalid character '\(c)' — alphabet is L U R D"
            }
            if i > 0 && chars[i] == chars[i - 1] {
                return "consecutive duplicate direction '\(c)\(c)' — "
                     + "the recogniser coalesces same-direction segments, "
                     + "so this pattern can never be drawn"
            }
        }
        return nil
    }
}
