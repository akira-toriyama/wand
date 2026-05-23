// Stroke recognition: samples → direction sequence.
//
// Pure logic, no AppKit / no CG event types. Algorithm:
//
//   1. Walk samples accumulating displacement.
//   2. When |dx| or |dy| since the last anchor exceeds
//      ``minStrokePx``, emit a Direction whose axis is the dominant
//      one, then reset the anchor to that sample.
//   3. Coalesce consecutive duplicate directions (continuing in the
//      same direction is one stroke, not many).
//
// Dominant-axis quantisation is a stable, easy-to-explain shape
// recogniser for short directional flicks — keeps the mental model
// "draw a path of arrow keys" rather than anything fancier.

import CoreGraphics

public enum Recognition {

    /// Convert a captured sample stream into a direction sequence.
    /// `minStrokePx` from `StrokeConfig.minStrokePx`.
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
}
