// Pac-Man trail renderer. Stateless — `TrailView` packages every
// piece of state the renderer needs into `State` and calls into
// the static `draw(state:color:outline:)` entry point. Pulling
// the pacman/ghost code into its own file keeps GestureOverlay.swift
// focused on the shared trail / HUD plumbing instead of one style's
// ~450-line implementation.
//
// File structure mirrors the rendering pipeline used by `draw`:
//   1. snappedPoints       — shared centerline sequence (origin →
//                             corners → axis-snapped cursor) consumed
//                             by every layer below so corridor /
//                             pellets / face anchor stay locked.
//   2. corridor + walls    — `buildCenterline` + CG outline stroking
//                             paints the black road and both neon
//                             walls in one geometry pass.
//   3. face anchor + pellets — `walkPolyline` walks the same
//                                snapped sequence at fixed
//                                intervals.
//   4. face / ghost sprite  — pixel-grid rasterisation; ghost on
//                              no-match swaps the wedge for the
//                              chunky 14×14 arcade-ghost silhouette.

import AppKit
import WandCore

/// Stateless renderer for `style = "pacman"`. Every pacman/ghost-
/// specific constant + helper lives in this namespace so the
/// generic `TrailView` doesn't have to carry them.
@MainActor
enum PacmanRenderer {

    /// Input bundle the renderer needs from `TrailView`. Constructed
    /// at the dispatch site (where TrailView's `fileprivate` state
    /// is readable); everything below this line treats it as plain
    /// values.
    struct State {
        let origin: CGPoint
        let cursor: CGPoint?
        let corners: [CGPoint]
        let rawTrail: [CGPoint]
        let lastDir: Direction?
        let straightenOnTurn: Bool
        /// Scale multiplier (= `TrailView.strokeWidth`). Every
        /// pacman dimension below scales off this.
        let strokeWidth: CGFloat
        /// Match state. `false` swaps the pacman face for the
        /// chased red ghost sprite.
        let valid: Bool
    }

    // MARK: - Tuning constants

    /// Pellet dot diameter (pt at scale=1).
    private static let pelletDiameter: CGFloat = 4
    /// Spacing between pellets along the path (pt at scale=1).
    private static let pelletInterval: CGFloat = 14
    /// Face silhouette radius (pt at scale=1). Tuned so 13-ish
    /// cells across the diameter still leave room for the eyes /
    /// mouth detail without crowding.
    private static let faceRadius: CGFloat = 16
    /// Cell size of the face's pixel grid, as a fraction of the
    /// face radius. ~0.155 gives ~13 cells across the diameter,
    /// matching the canonical arcade Pac-Man sprite's 12×13 cell
    /// silhouette. Smaller values smooth the edge back toward an
    /// arc; larger values turn the wedge into a coarse polygon.
    private static let pixelCellRatio: CGFloat = 0.155
    /// Mouth half-angle bounds (degrees). The face animates
    /// between these via discrete frames. `min` is just above zero
    /// so the mouth doesn't fully close (a sealed circle reads as
    /// "not Pac-Man anymore").
    private static let mouthHalfAngleMinDeg: CGFloat = 5
    private static let mouthHalfAngleMaxDeg: CGFloat = 60
    /// Chomp frequency (Hz). One stepped 4-frame cycle per period
    /// (closed → half → open → half → …); ~5 Hz lands ~50 ms per
    /// frame, matching the original arcade's snappy sprite cadence.
    private static let chompHz: Double = 5
    /// Discrete mouth phases the chomp cycles through, one per
    /// stepped frame. Triangle pattern (closed → mid → open → mid)
    /// so the open/close motion is symmetric without doubling the
    /// frame count.
    private static let chompFrames: [CGFloat] = [0, 0.5, 1, 0.5]
    /// How far back along the path the face sits behind the live
    /// cursor (pt at scale=1). 60pt ≈ 2 face widths of gap, which
    /// reads as "actively chasing" without hiding the sprite off
    /// the live cursor end.
    private static let faceLag: CGFloat = 60
    /// Toggle rate of the ghost-skirt 2-frame leg animation (Hz).
    /// 2.5 Hz gives ~200 ms per leg pose — slow enough to pulse in
    /// the background rather than draw attention.
    private static let ghostSkirtHz: Double = 2.5
    /// Half-width of the corridor between the two maze walls
    /// (pt at scale=1). 16pt centre-to-wall gives a ~32pt wide
    /// corridor — enough air around the 4pt arcade pellets that
    /// the walls don't crowd them.
    private static let wallOffset: CGFloat = 16
    /// Stroke width of each wall (pt at scale=1). Thin so the read
    /// is "neon line", not "filled bar".
    private static let wallStroke: CGFloat = 2.5

    // MARK: - Entry point

    /// Pac-Man trail: pellets along a snapped polyline; if
    /// `outline` is set, two neon walls flanking a black corridor;
    /// and a chasing face sprite (or ghost on no-match) lagging
    /// behind the live cursor. `strokeWidth` is a scale multiplier
    /// — `width = 1` gives the default pellet / face size and
    /// spacing, higher values scale everything proportionally. The
    /// arcade aesthetic is always a single line of pellets, so
    /// thickness rows would fight the visual.
    static func draw(state: State,
                      color: NSColor,
                      outline: NSColor?) {
        let scale = max(1, state.strokeWidth)
        let dot = pelletDiameter * scale
        let interval = pelletInterval * scale
        let lag = faceLag * scale
        let radius = faceRadius * scale
        let pelletFill = color.withAlphaComponent(0.9)

        // Single shared point sequence — corridor, pellets, and the
        // face-anchor walk all consume the same axis-snapped
        // polyline. Computing it once here keeps the three layers
        // locked together: when the live cursor is mid-diagonal
        // between two committed corners, the snap keeps every
        // visual on the same line instead of splitting dots off
        // the walls.
        let snappedPts = snappedPoints(state: state)

        // 1) Black corridor + neon walls — one geometry pass on a
        // pacman-specific centerline. `buildCenterline` bezier-
        // smooths every interior corner so single-corner gestures
        // (e.g. "DR") still soften, and the offsets from
        // `copy(strokingWithWidth:)` then paint road (fill) +
        // walls (stroke) in one path each.
        if let outline,
           let ctx = NSGraphicsContext.current?.cgContext {
            let corridorWidth = wallOffset * 2 * scale
            let strokeWidth = max(1, scale * wallStroke)
            let cornerRadius = wallOffset * scale
            let center = buildCenterline(
                points: snappedPts, cornerRadius: cornerRadius)
            let boundary = toCGPath(center).copy(
                strokingWithWidth: corridorWidth,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10)
            // Road (fill).
            ctx.addPath(boundary)
            ctx.setFillColor(
                NSColor.black.withAlphaComponent(0.95).cgColor)
            ctx.fillPath()
            // Walls (stroke).
            ctx.addPath(boundary)
            ctx.setStrokeColor(
                outline.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(strokeWidth)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }

        // 2) Locate where Pac-Man's face sits this frame: walk the
        // snapped polyline with the lag as `trimTail` — the final
        // step the walker emits is exactly the cutoff point. Skip
        // drawing in this pass; we only need the coordinate +
        // tangent.
        var faceAnchor: (point: CGPoint, tangent: CGPoint)?
        walkPolyline(points: snappedPts,
                     interval: interval,
                     trimTail: lag) { p, tangent in
            faceAnchor = (p, tangent)
        }

        // 3) Pellets across the full snapped polyline. The arcade
        // dot is unhaloed — the walls drawn above carry the
        // outline-for-legibility treatment; doubling that with a
        // per-pellet halo would muddy the corridor read.
        let plot: (CGPoint, CGPoint) -> Void = { p, _ in
            pelletFill.setFill()
            let rect = NSRect(x: p.x - dot / 2, y: p.y - dot / 2,
                              width: dot, height: dot)
            NSBezierPath(ovalIn: rect).fill()
        }
        walkPolyline(points: snappedPts, interval: interval,
                     step: plot)

        // 4) Draw the sprite only once the trail is long enough for
        // a real lag — it then emerges naturally `faceLag` pt
        // behind the cursor instead of popping in glued to the
        // cursor at button-down. Sprite swaps to a ghost when the
        // in-progress gesture has fallen off every rule, matching
        // the arcade pairing (yellow Pac-Man = on-track, red ghost
        // = chased / failure).
        if let anchor = faceAnchor {
            if state.valid {
                drawFace(at: anchor.point, tangent: anchor.tangent,
                          radius: radius, color: color)
            } else {
                drawGhost(at: anchor.point, tangent: anchor.tangent,
                           radius: radius, color: color)
            }
        }
    }

    // MARK: - Centerline helpers

    /// Shared point sequence for every pacman-style geometry pass:
    /// corridor centerline, wall offsets, pellet steps, and the
    /// face-anchor walk all use this exact list so the visuals stay
    /// locked together. With `straightenOnTurn = true` it's
    /// `origin → corners → axis-snapped cursor`; with `false` it
    /// falls back to raw freehand. The cursor snap projects the
    /// live mouse position onto `lastDir` so mid-diagonal hand
    /// motion doesn't split the dots from the walls.
    private static func snappedPoints(state: State) -> [CGPoint] {
        if !state.straightenOnTurn {
            return state.rawTrail
        }
        var pts: [CGPoint] = [state.origin] + state.corners
        if let liveCursor = state.cursor {
            let snappedTail: CGPoint
            if let dir = state.lastDir, let from = pts.last {
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

    /// Pacman-specific smoothed centerline. Bezier-smooths every
    /// interior corner of the supplied `pts` sequence with a
    /// `cornerRadius`-sized arc — so single-corner gestures (e.g.
    /// "DR") get a rounded turn that the wall offsets can follow
    /// without notches.
    private static func buildCenterline(points pts: [CGPoint],
                                          cornerRadius: CGFloat)
        -> NSBezierPath {
        let path = NSBezierPath()
        guard pts.count >= 2 else { return path }
        path.move(to: pts[0])
        if pts.count == 2 {
            path.line(to: pts[1])
            return path
        }
        for i in 1..<pts.count - 1 {
            let A = pts[i - 1]
            let B = pts[i]
            let C = pts[i + 1]
            let inLen = hypot(B.x - A.x, B.y - A.y)
            let outLen = hypot(C.x - B.x, C.y - B.y)
            // Radius capped to half each adjacent segment so the
            // curve never overshoots into the neighbouring corner.
            let r = min(cornerRadius, inLen / 2, outLen / 2)
            let inU = CGPoint(x: (B.x - A.x) / max(inLen, 1),
                              y: (B.y - A.y) / max(inLen, 1))
            let outU = CGPoint(x: (C.x - B.x) / max(outLen, 1),
                               y: (C.y - B.y) / max(outLen, 1))
            let P = CGPoint(x: B.x - inU.x * r, y: B.y - inU.y * r)
            let Q = CGPoint(x: B.x + outU.x * r, y: B.y + outU.y * r)
            path.line(to: P)
            // Cubic with both control points at B: a smooth arc
            // from P through ~B to Q (matches buildHybridPath's
            // corner-smoothing geometry).
            path.curve(to: Q, controlPoint1: B, controlPoint2: B)
        }
        path.line(to: pts.last!)
        return path
    }

    /// Walk a polyline at fixed intervals, invoking `step` once per
    /// `interval`-pt advance with the point + tangent. `trimTail`
    /// trims that much distance off the end of the path before
    /// emitting — used to leave a visible gap between the trailing
    /// pellets and Pac-Man's face. Mirrors `TrailView.walkPath`
    /// but takes the polyline explicitly so corridor / pellets /
    /// face anchor all sample the exact same snapped sequence.
    private static func walkPolyline(points pts: [CGPoint],
                                       interval: CGFloat,
                                       trimTail: CGFloat = 0,
                                       step: (CGPoint, CGPoint) -> Void) {
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
        step(pts[0], lastTangent)
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
                         lastTangent)
                    return
                }
                step(CGPoint(x: a.x + ux * t, y: a.y + uy * t),
                     lastTangent)
                t += interval
            }
            traveled += segLen
            carry = segLen - (t - interval)
        }
        if cutoff == nil, let last = pts.last {
            step(last, lastTangent)
        }
    }

    // MARK: - Sprite rendering

    /// Draw the pacman face as a chunky pixel-grid sprite — a
    /// circle minus a mouth wedge rasterised onto a square grid.
    /// Cells live in face-local coordinates (mouth opens along
    /// local +x); the graphics context is rotated so the whole
    /// pixel sprite turns as one rigid block along `tangent`,
    /// matching the arcade aesthetic where the body's pixels stay
    /// aligned to the sprite frame as it changes direction. The
    /// chomp **snaps** between the discrete `chompFrames` at
    /// `chompHz` instead of being smoothly interpolated, so the
    /// open/close cadence reads as arcade sprite-swapping rather
    /// than analog easing.
    private static func drawFace(at p: CGPoint, tangent: CGPoint,
                                   radius: CGFloat, color: NSColor) {
        let frames = chompFrames
        let cyclePos = (CACurrentMediaTime() * chompHz)
            .truncatingRemainder(dividingBy: 1)
        let frameIdx = min(frames.count - 1,
                            Int(cyclePos * Double(frames.count)))
        let phase = frames[frameIdx]
        let mouthHalfRad = (mouthHalfAngleMinDeg
            + (mouthHalfAngleMaxDeg - mouthHalfAngleMinDeg) * phase)
            * .pi / 180

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let xform = NSAffineTransform()
        xform.translateX(by: p.x, yBy: p.y)
        xform.rotate(byRadians: atan2(tangent.y, tangent.x))
        xform.concat()

        let cell = max(2, radius * pixelCellRatio)
        let r2 = radius * radius
        let extent = Int(ceil(radius / cell))
        color.withAlphaComponent(0.95).setFill()
        for iy in -extent...extent {
            for ix in -extent...extent {
                // Cell-centre in local space; cells live on the
                // half-integer grid so the silhouette is symmetric.
                let cx = (CGFloat(ix) + 0.5) * cell
                let cy = (CGFloat(iy) + 0.5) * cell
                if cx * cx + cy * cy > r2 { continue }
                // Mouth opens along local +x — drop cells whose
                // angle from the centre falls inside ±mouthHalf.
                if abs(atan2(cy, cx)) < mouthHalfRad { continue }
                let rect = NSRect(
                    x: CGFloat(ix) * cell,
                    y: CGFloat(iy) * cell,
                    width: cell, height: cell)
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    /// Draw the no-match ghost sprite — arcade-style "Blinky" shape
    /// rasterised onto the same pixel grid as the pacman face: a
    /// dome on top, square body below, and a wavy skirt of 4 humps
    /// along the bottom edge that **alternates between two leg
    /// poses** at `ghostSkirtHz` (humps on the outside vs humps on
    /// the inside) so the sprite reads as walking. Body sits
    /// upright (arcade ghosts don't rotate); only the eyes look
    /// along `tangent`. Body colour flows from `color`
    /// (= `trailColorNoMatch`, typically red).
    private static func drawGhost(at p: CGPoint, tangent: CGPoint,
                                    radius: CGFloat, color: NSColor) {
        let cell = max(2, radius * pixelCellRatio)
        // Body below the dome is shorter than the dome's radius —
        // the arcade ghost is a chunky/squat silhouette, not a
        // tall one.
        let bodyHeight = radius * 0.82
        let skirtAmp = radius * 0.34
        let totalBottom = -bodyHeight - skirtAmp
        let r2 = radius * radius
        // Skirt frame: 0 = humps centred at hump-A positions, 1 =
        // humps shifted by half a hump-width (A-frame's valleys
        // become humps and vice versa). Synced off wall time so
        // every ghost on screen pulses together.
        let legFrame = Int(CACurrentMediaTime() * ghostSkirtHz) & 1

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let xform = NSAffineTransform()
        xform.translateX(by: p.x, yBy: p.y)
        xform.concat()

        color.withAlphaComponent(0.95).setFill()
        let extentX = Int(ceil(radius / cell))
        let extentYTop = Int(ceil(radius / cell))
        let extentYBot = Int(ceil(-totalBottom / cell))
        for iy in -extentYBot...extentYTop {
            for ix in -extentX...extentX {
                let cx = (CGFloat(ix) + 0.5) * cell
                let cy = (CGFloat(iy) + 0.5) * cell
                if !ghostBodyFilled(cx: cx, cy: cy,
                                     radius: radius, r2: r2,
                                     bodyHeight: bodyHeight,
                                     skirtAmp: skirtAmp,
                                     legFrame: legFrame) { continue }
                let rect = NSRect(
                    x: CGFloat(ix) * cell,
                    y: CGFloat(iy) * cell,
                    width: cell, height: cell)
                NSBezierPath(rect: rect).fill()
            }
        }

        // Eyes — two 4×4 white blocks set into the upper body, each
        // with a 2×2 blue pupil whose offset within the eye tracks
        // the tangent direction. Eye / pupil sizing matches the
        // arcade ghost sprite where the eyes dominate the visual
        // mass. Pupil shift is symmetric in both axes so diagonal
        // travel reads as a true diagonal gaze.
        let eyeOffsetX = radius * 0.42
        let eyeY = radius * 0.10
        let eyeHalfW = cell * 2.0
        let eyeHalfH = cell * 2.0
        let pupilSize = cell * 2
        let len = max(hypot(tangent.x, tangent.y), 0.0001)
        // Pupil rides flush against the eye edge at full tangent.
        let pupilShift = cell
        let pupilDx = (tangent.x / len) * pupilShift
        let pupilDy = (tangent.y / len) * pupilShift
        let pupilColor = NSColor(srgbRed: 0.13, green: 0.13,
                                  blue: 1.0, alpha: 1.0)

        for side: CGFloat in [-1, 1] {
            let ex = side * eyeOffsetX
            let eyeRect = NSRect(x: ex - eyeHalfW,
                                 y: eyeY - eyeHalfH,
                                 width: eyeHalfW * 2,
                                 height: eyeHalfH * 2)
            NSColor.white.setFill()
            NSBezierPath(rect: eyeRect).fill()
            let pupilRect = NSRect(
                x: ex - pupilSize / 2 + pupilDx,
                y: eyeY - pupilSize / 2 + pupilDy,
                width: pupilSize, height: pupilSize)
            pupilColor.setFill()
            NSBezierPath(rect: pupilRect).fill()
        }
    }

    /// Predicate: is the cell at local (cx, cy) inside the ghost
    /// silhouette? Top half is a circle (dome); middle is a
    /// rectangle (body); bottom is a 4-hump skirt — each hump is
    /// a triangle wedge extending below the body baseline.
    /// `legFrame` (0 or 1) shifts the hump pattern by half a
    /// hump-width so alternating frames give the classic arcade
    /// "leg shuffle".
    private static func ghostBodyFilled(cx: CGFloat, cy: CGFloat,
                                          radius: CGFloat, r2: CGFloat,
                                          bodyHeight: CGFloat,
                                          skirtAmp: CGFloat,
                                          legFrame: Int) -> Bool {
        if abs(cx) > radius { return false }
        // Dome: cy >= 0, inside circle.
        if cy >= 0 { return cx * cx + cy * cy <= r2 }
        // Body rectangle: -bodyHeight <= cy <= 0.
        if cy >= -bodyHeight { return true }
        // Skirt humps. 4 humps across — matches the canonical
        // 14-wide arcade ghost sprite's 4-toothed bottom.
        let humpCount: CGFloat = 4
        let humpWidth = (2 * radius) / humpCount
        let humpHalf = humpWidth / 2
        let phaseShift: CGFloat = (legFrame == 0) ? 0 : humpHalf
        // Wrap into the [-radius, radius) band so a shifted hump
        // that pokes off one side is folded back onto the other.
        let shifted = cx + phaseShift
        let wrapped = shifted - 2 * radius
            * floor((shifted + radius) / (2 * radius))
        let segIdx = min(Int(humpCount) - 1, max(0,
            Int(floor((wrapped + radius) / humpWidth))))
        let humpCentre = -radius + (CGFloat(segIdx) + 0.5) * humpWidth
        let distFromCentre = abs(wrapped - humpCentre) / humpHalf
        let depthAllowed = (1 - distFromCentre) * skirtAmp
        return cy >= -bodyHeight - depthAllowed
    }

    // MARK: - Utility

    /// Snap `p` onto the axis defined by `dir` and the point
    /// `from`. Horizontal directions preserve `from.y`; vertical
    /// preserve `from.x`. Duplicates `TrailView.snap` so the
    /// renderer stays self-contained — the function is 5 lines of
    /// math, not worth widening TrailView's encapsulation to share.
    private static func snap(_ p: CGPoint, to dir: Direction,
                              from: CGPoint) -> CGPoint {
        switch dir {
        case .left, .right: return CGPoint(x: p.x, y: from.y)
        case .up, .down:    return CGPoint(x: from.x, y: p.y)
        }
    }

    /// Convert an `NSBezierPath` of move/line/curve segments into a
    /// `CGPath`. We target macOS 13+, but the framework-supplied
    /// `NSBezierPath.cgPath` accessor only landed in 14.
    private static func toCGPath(_ ns: NSBezierPath) -> CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<ns.elementCount {
            switch ns.element(at: i, associatedPoints: &points) {
            case .moveTo:    path.move(to: points[0])
            case .lineTo:    path.addLine(to: points[0])
            case .curveTo:   path.addCurve(to: points[2],
                                            control1: points[0],
                                            control2: points[1])
            case .closePath: path.closeSubpath()
            default:
                // macOS 14 added `.cubicCurveTo` / `.quadraticCurveTo`
                // as distinct cases. `buildCenterline` only ever
                // emits the four cases above, so the catch-all is
                // safe; if a new emitter starts producing the
                // newer elements, this needs explicit handling.
                break
            }
        }
        return path
    }
}
