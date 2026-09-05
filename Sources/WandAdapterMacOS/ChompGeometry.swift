// Pure geometry behind the chomp trail: the axis-snapped polyline,
// its corridor centerline, the inner-corner fillet points, the
// fixed-interval walker, and the position hash that picks bonus
// pellets. CoreGraphics + WandCore only — no AppKit, no graphics
// context, no wall clock — so every function is a deterministic
// value → value map and XCTest can pin it without a window
// (`Tests/WandAdapterMacOSTests/ChompGeometryTests.swift`).
// Sprites, strokes, and colours belong in `ChompRenderer`.

import CoreGraphics
import Foundation
import WandCore

enum ChompGeometry {
    /// Shared point sequence for every chomp-style geometry pass:
    /// corridor centerline, wall offsets, pellet steps, and the
    /// face-anchor walk all use this exact list so the visuals stay
    /// locked together. With `straightenOnTurn = true` it's
    /// `origin → corners → axis-snapped cursor`; with `false` it
    /// falls back to raw freehand. The cursor snap projects the
    /// live mouse position onto `lastDir` so mid-diagonal hand
    /// motion doesn't split the dots from the walls.
    static func snappedPoints(origin: CGPoint,
                              corners: [CGPoint],
                              cursor: CGPoint?,
                              lastDir: Direction?,
                              straightenOnTurn: Bool,
                              rawTrail: [CGPoint]) -> [CGPoint] {
        if !straightenOnTurn {
            return rawTrail
        }
        var pts: [CGPoint] = [origin] + corners
        if let liveCursor = cursor {
            let snappedTail: CGPoint
            if let dir = lastDir, let from = pts.last {
                snappedTail = snap(liveCursor, to: dir, from: from)
            } else {
                snappedTail = liveCursor
            }
            if snappedTail != pts.last {
                pts.append(snappedTail)
            }
        }
        return pts
    }

    /// Chomp centerline = straight polyline through `pts`. No
    /// per-corner smoothing: `ChompRenderer.draw`'s two `.round`
    /// lineCap / lineJoin stroke passes turn each 90° vertex into a
    /// rounded outer arc + sharp inner point, which is exactly the
    /// arcade-maze elbow we want — the sharp inner point is then
    /// eroded by the `innerCornerPoints` fillets.
    static func centerline(points pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        return path
    }

    /// Compute the road's inside-of-L corner point at each interior
    /// turn vertex of the snapped polyline. For a 90° turn at `B`,
    /// the two inner road edges (each at perpendicular distance
    /// `wallOffset` from the centerline, on the concave side) meet
    /// at exactly one point — that's the sharp tip that the
    /// inner-corner fillet erodes.
    ///
    /// Returns an empty array when there are no interior vertices
    /// (single segment) or when every interior vertex sits on a
    /// straight run (the snapped polyline already collapsed
    /// adjacent collinear points elsewhere, so this is rare but
    /// still guarded against).
    static func innerCornerPoints(
        snappedPts: [CGPoint],
        wallOffset: CGFloat
    ) -> [CGPoint] {
        guard snappedPts.count >= 3 else { return [] }
        var result: [CGPoint] = []
        for i in 1..<(snappedPts.count - 1) {
            let A = snappedPts[i - 1]
            let B = snappedPts[i]
            let C = snappedPts[i + 1]
            let inDx = B.x - A.x, inDy = B.y - A.y
            let outDx = C.x - B.x, outDy = C.y - B.y
            let inLen = hypot(inDx, inDy)
            let outLen = hypot(outDx, outDy)
            guard inLen > 0.001, outLen > 0.001 else { continue }
            let inUx = inDx / inLen, inUy = inDy / inLen
            let outUx = outDx / outLen, outUy = outDy / outLen
            // Skip straight runs (cross ≈ 0). For wand's snapped
            // polylines this only triggers when `straightenOnTurn`
            // failed to collapse a duplicate, but the guard keeps
            // pathological inputs from emitting a useless fillet.
            let cross = inUx * outUy - inUy * outUx
            guard abs(cross) > 0.01 else { continue }
            // Inside-of-L bisector. The "left-perpendicular" of a
            // direction vector `(dx, dy)` is `(-dy, dx)`. Summing
            // the left-perpendiculars of `inU` and `outU` gives a
            // bisector that points to the LEFT of the path
            // direction (i.e., the inside of a left turn). If the
            // turn is actually a RIGHT turn (`cross < 0`), the
            // inside-of-L is the opposite side and we negate.
            let perpSumX = -inUy + -outUy
            let perpSumY = inUx + outUx
            let perpLen = hypot(perpSumX, perpSumY)
            guard perpLen > 0.001 else { continue }
            let sign: CGFloat = cross > 0 ? 1 : -1
            let bisX = sign * perpSumX / perpLen
            let bisY = sign * perpSumY / perpLen
            // For 90° turns the two perpendicular inner edges meet
            // at distance `wallOffset × √2` from `B` along the
            // bisector. wand forces 90° turns under chomp
            // (`straightenOnTurn = true` is mandatory), so the √2
            // is exact; supporting other angles would need
            // `wallOffset / sin(θ/2)`, but there's no path to a
            // non-90° turn here today.
            let cornerDistance = wallOffset * CGFloat(sqrt(2.0))
            result.append(CGPoint(
                x: B.x + bisX * cornerDistance,
                y: B.y + bisY * cornerDistance))
        }
        return result
    }

    /// Walk a polyline at fixed intervals, invoking `step` once per
    /// `interval`-pt advance with the point + tangent + the arc-
    /// length from the polyline origin to that point. `trimTail`
    /// trims that much distance off the end of the path before
    /// emitting — used to leave a visible gap between the trailing
    /// pellets and Chomp's face. The arc-length is what lets the
    /// cherry-eaten detection compare each pellet's position against
    /// the face's lag-adjusted arc-length.
    static func walkPolyline(points pts: [CGPoint],
                                       interval: CGFloat,
                                       trimTail: CGFloat = 0,
                                       step: (CGPoint, CGPoint, CGFloat) -> Void) {
        guard !pts.isEmpty, interval > 0 else { return }
        let cutoff: CGFloat?
        if trimTail > 0 {
            var totalLen: CGFloat = 0
            for i in 1..<pts.count {
                totalLen += hypot(pts[i].x - pts[i - 1].x,
                                  pts[i].y - pts[i - 1].y)
            }
            if totalLen <= trimTail { return }
            cutoff = totalLen - trimTail
        } else {
            cutoff = nil
        }
        var lastTangent = CGPoint(x: 1, y: 0)
        if pts.count > 1 {
            for i in 1..<pts.count {
                let dx = pts[i].x - pts[i - 1].x
                let dy = pts[i].y - pts[i - 1].y
                let len = hypot(dx, dy)
                if len > 0 {
                    lastTangent = CGPoint(x: dx / len, y: dy / len)
                    break
                }
            }
        }
        step(pts[0], lastTangent, 0)
        var carry: CGFloat = 0
        var traveled: CGFloat = 0
        for i in 1..<pts.count {
            let a = pts[i - 1]
            let b = pts[i]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let segLen = hypot(dx, dy)
            if segLen <= 0 { continue }
            let ux = dx / segLen
            let uy = dy / segLen
            lastTangent = CGPoint(x: ux, y: uy)
            var t = interval - carry
            while t <= segLen {
                if let cutoff, traveled + t > cutoff {
                    let last = traveled + t - cutoff
                    let tEnd = t - last
                    step(CGPoint(x: a.x + ux * tEnd,
                                  y: a.y + uy * tEnd),
                         lastTangent,
                         traveled + tEnd)
                    return
                }
                step(CGPoint(x: a.x + ux * t, y: a.y + uy * t),
                     lastTangent,
                     traveled + t)
                t += interval
            }
            traveled += segLen
            carry = segLen - (t - interval)
        }
        if cutoff == nil, let last = pts.last {
            step(last, lastTangent, traveled)
        }
    }

    /// Snap `p` onto the axis defined by `dir` and the point
    /// `from`. Horizontal directions preserve `from.y`; vertical
    /// preserve `from.x`. Same math as `TrailView.snap`; kept here
    /// so this namespace never depends on a view.
    static func snap(_ p: CGPoint, to dir: Direction,
                              from: CGPoint) -> CGPoint {
        switch dir {
        case .left, .right: return CGPoint(x: p.x, y: from.y)
        case .up, .down:    return CGPoint(x: from.x, y: p.y)
        }
    }

    /// Stable 0..1 hash of a screen position. Used to pick which
    /// pellets become cherries — the same coordinate always hashes
    /// the same way, so a cherry that appears on one frame stays a
    /// cherry on every subsequent redraw of the same stroke (instead
    /// of flickering between cherry / pellet on each repaint).
    /// Pellet positions only change when the user moves past a new
    /// sample, so the cherry set stays stable through the redraws
    /// the cursor triggers per-frame.
    static func positionHash01(_ p: CGPoint) -> Double {
        let xi = Int(p.x.rounded())
        let yi = Int(p.y.rounded())
        // 64-bit Cantor-pairing-ish hash with two large primes; the
        // `&` arithmetic wraps cleanly so negative coords work too.
        let h = (UInt64(bitPattern: Int64(xi)) &* 2654435761)
            ^ (UInt64(bitPattern: Int64(yi)) &* 40503)
        return Double(h % 10000) / 10000.0
    }
}
