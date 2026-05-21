// Stroke recognition: samples → direction sequence.
//
// Pure logic, no AppKit / no CG event types. Algorithm (M2):
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
                // NSScreen Y grows upward. CGEvent Y also grows
                // upward in the macOS coordinate space stroke uses
                // (we sample via NSEvent.mouseLocation in the
                // adapter). So dy > 0 means cursor moved up.
                dir = dy >= 0 ? .up : .down
            }
            if out.last != dir { out.append(dir) }
            anchor = s.p
        }
        return out
    }
}
