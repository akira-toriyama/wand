// Pac-Man trail renderer. Stateless — `TrailView` packages every
// piece of state the renderer needs into `State` and calls into
// the static `draw(state:color:outline:)` entry point. Pulling
// the pac-man/ghost code into its own file keeps GestureOverlay.swift
// focused on the shared trail / HUD plumbing instead of one theme's
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

/// Stateless renderer for the pac-man special theme
/// (`[cast].theme = "pac-man"`). Every pac-man/ghost-specific
/// constant + helper lives in this namespace so the generic
/// `TrailView` doesn't have to carry them.
@MainActor
enum PacManRenderer {

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
        /// Forced `true` by the parser whenever this renderer runs
        /// (the pac-man theme locks straighten-on-turn) — kept on the
        /// `State` for the rendering math, but in practice always
        /// `true`.
        let straightenOnTurn: Bool
        /// Scale multiplier sourced from `[cast.pac-man].size`
        /// (`.s` = 2.0, `.m` = 3.0, `.l` = 4.5). Every pac-man
        /// dimension below scales off this.
        let strokeWidth: CGFloat
        /// Match state. `false` swaps the pac-man face for the
        /// chased red ghost sprite AND dims the trail's pellets,
        /// reading as "rule unreachable, no more bonus to eat".
        let valid: Bool
        /// `true` while the trail is in its post-fire final-hold
        /// frame (button-up has happened; the trail is held at
        /// full alpha briefly before fading out). Used to drive
        /// the wide-open chomp flourish on the face — the mouth
        /// freezes wide open instead of cycling through the
        /// normal 4-frame chomp, reading as "Pac-Man caught the
        /// rule and is mid-bite".
        let isFinalHold: Bool
        /// Face's arc-length from the origin on the previous frame.
        /// `draw` compares this with the current frame's face arc-
        /// length to detect cherries the face just passed — for
        /// those, `onCherryEaten` fires once. Reset to 0 by the
        /// caller (TrailView) at each stroke start.
        let previousFaceArcLength: CGFloat
        /// Invoked once per cherry the face crossed on this frame.
        /// Receives the cherry's position in the renderer's local
        /// coordinate space (= `TrailView`'s view-local coords).
        /// The caller (TrailView) lights up `cherryFlashStartedAt`
        /// off this — drives the brief rainbow wall flash — and
        /// also forwards the position to the App layer so the
        /// arcade-score "+N" popup floats up from where the cherry
        /// was eaten.
        let onCherryEaten: @MainActor (CGPoint) -> Void
    }

    // MARK: - Tuning constants

    /// Pellet dot diameter (pt at scale=1).
    private static let pelletDiameter: CGFloat = 4
    /// Spacing between pellets along the path (pt at scale=1).
    private static let pelletInterval: CGFloat = 14
    /// Cherry pixel-sprite cell size relative to the dot diameter.
    /// 0.5 with a 12×13 sprite lands at ~6×6.5 dot-diameters,
    /// putting the bonus token in the face's size class
    /// (≈ 24×26pt at scale=1 vs face's 32pt) so it reads as the
    /// arcade bonus tile, not a giant pellet.
    private static let cherryCellMultiplier: CGFloat = 0.5
    /// 12×13 pixel sprite, traced cell-by-cell from
    /// `/Users/tommy/Desktop/x/222.png` at 8 px / cell. Two
    /// cherries with a brown stem reaching up to the right; each
    /// cherry has a 2-cell stepped `W` highlight on its upper-
    /// left (so the light source reads as upper-left). The `.`
    /// gap in the middle is the dark wedge between the two
    /// cherries — on the click-through overlay it falls through
    /// to whatever's underneath, exactly like the source image's
    /// black background showed.
    ///
    /// Rendered without rotation — like Pac-Man's pellets and
    /// the cherry's reference sprite, the cherry orientation
    /// stays fixed regardless of the stroke direction.
    ///
    ///   `R` red body, `W` white specular highlight,
    ///   `K` black outline / overlap silhouette,
    ///   `B` brown stem, `.` transparent.
    private static let cherrySprite: [String] = [
        "..........BB",
        "........BBBB",
        "......BBKB..",
        ".....BKKKB..",
        ".RRRBKKKB...",
        "RRRBRRKB....",
        "RRRRRKRBRR..",
        "RWRR.RRBRRR.",
        "RRWR.RRRRRR.",
        ".RRR.RWRRRR.",
        ".....RRWRRR.",
        "......RRRR..",
        "......KKKK..",
    ]
    /// Cherry sprite palette. Sampled directly from
    /// `/Users/tommy/Desktop/x/222.png`: red ≈ 248,0,7;
    /// brown ≈ 217,125,64; outline pure black; highlight
    /// near-white. The brown is the same single tone used for
    /// the stem AND the stem's "shading-into-body" overlap
    /// cells (the source sprite is flat-shaded — no second
    /// brown tone).
    private static let cherryRed = NSColor(srgbRed: 0.97,
                                            green: 0.0,
                                            blue: 0.03, alpha: 1.0)
    private static let cherryOutline = NSColor.black
    private static let cherryHighlight = NSColor.white
    private static let cherryStem = NSColor(srgbRed: 0.85,
                                             green: 0.49,
                                             blue: 0.25,
                                             alpha: 1.0)
    /// Probability (0..1) that a yellow pellet gets swapped for the
    /// arcade cherry bonus token, decided per-pellet from a stable
    /// hash of its position. ~8% gives 1-3 cherries on a typical
    /// 20-50 pellet stroke, with a high enough rate that even
    /// shorter strokes (~10 pellets) usually carry at least one.
    /// Only fires while the gesture is on-track (no cherries on the
    /// no-match crumb trail).
    private static let cherryProbability: Double = 0.08
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
    /// cursor (pt at scale=1). 90pt ≈ 3 face widths of gap, leaving
    /// enough corridor between the face and the cursor that the
    /// player can SEE the face approach an upcoming cherry before
    /// catching it — short of that, cherries appear and get eaten
    /// in the same frame and the "snack" beat is lost.
    private static let faceLag: CGFloat = 90
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
    /// thickness rows would fight the visual. Returns the face's
    /// arc-length from the polyline origin on this frame so the
    /// caller can feed it back as `previousFaceArcLength` next
    /// frame — that's how cherry-crossing detection stays stable
    /// without the renderer carrying mutable state.
    @discardableResult
    static func draw(state: State,
                      color: NSColor,
                      outline: NSColor?) -> CGFloat {
        let scale = max(1, state.strokeWidth)
        let dot = pelletDiameter * scale
        let interval = pelletInterval * scale
        let lag = faceLag * scale
        let radius = faceRadius * scale
        // Pellet fill dims to ~30% alpha when the in-progress
        // gesture has fallen off every rule (`valid == false`),
        // reading as "no more bonus to eat" / a stale crumb trail
        // beside the chased ghost. The bright 90% alpha stays for
        // the on-track case so the player still feels each pellet
        // as a reward as they draw past it.
        let pelletFill = color.withAlphaComponent(state.valid ? 0.9 : 0.3)

        // Cherry bonus token — rendered as a 12×13 pixel sprite in
        // place of a regular pellet at ~`cherryProbability`. Only
        // fires while the gesture is on-track; the no-match crumb
        // trail stays pure dimmed dots. Cell size scales with the
        // pellet so the sprite grows / shrinks with `strokeWidth`.
        let cherryCell = max(1, dot * cherryCellMultiplier)

        // Single shared point sequence — corridor, pellets, and the
        // face-anchor walk all consume the same axis-snapped
        // polyline. Computing it once here keeps the three layers
        // locked together: when the live cursor is mid-diagonal
        // between two committed corners, the snap keeps every
        // visual on the same line instead of splitting dots off
        // the walls.
        let snappedPts = snappedPoints(state: state)

        // 1) Black corridor + neon walls — two concentric strokes
        // of the snapped polyline:
        //   - first pass: thicker stroke in the outline colour
        //     (corridorWidth + 2 × wallThickness)
        //   - second pass: thinner stroke in black, drawn on top
        //     (corridorWidth)
        // The visible wall is the difference band between them.
        // Both passes use `.round` lineCap + lineJoin, so the
        // outer convex corner of an L turn rounds smoothly and the
        // inner concave corner stays a clean 90° (no lineJoin
        // applies on the inner side of a stroke).
        //
        // Earlier revisions built a boundary path via
        // `copy(strokingWithWidth:)` and then fill+stroked it. That
        // path has a sharp 90° vertex at the inner-corner
        // intersection; stroking it for the walls then ran the
        // wall's `.round` lineJoin through that vertex and
        // protruded a small arc into the corridor (the "blue
        // wedge poking the inside of the elbow" artifact). The
        // two-stroke approach has no boundary path → no vertex to
        // run a join through → no protrusion.
        if let outline,
           let ctx = NSGraphicsContext.current?.cgContext {
            let corridorWidth = wallOffset * 2 * scale
            let wallThickness = max(1, scale * wallStroke)
            let outerWidth = corridorWidth + wallThickness * 2
            let centerCGPath = toCGPath(
                buildCenterline(points: snappedPts))

            // Walls (thicker, drawn first).
            ctx.addPath(centerCGPath)
            ctx.setStrokeColor(
                outline.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(outerWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()

            // Road (thinner, drawn on top — covers the inner band
            // of the wall stroke so only the `wallThickness`-wide
            // outer band remains visible as neon).
            ctx.addPath(centerCGPath)
            ctx.setStrokeColor(
                NSColor.black.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(corridorWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()

            // Inner-corner fillets — at each interior turn vertex,
            // paint a tiny black circle at the road's inside-of-L
            // corner. This extends the road `filletRadius` into the
            // wall on the concave side, replacing the wall's sharp
            // inner edge with a small circular cut.
            //
            // Why only the inner edge (wall ↔ road), not the outer
            // edge (wall ↔ background): the wand overlay is a
            // click-through transparent NSWindow, so we can't paint
            // background colour over the wall's outer corner. The
            // road-side fillet is the half we CAN draw — and it's
            // enough to break the otherwise-stark sharp inside of
            // an arcade-maze L. `filletRadius` is kept smaller than
            // `wallThickness` so the eroded patch never reaches the
            // wall's outer edge against the background.
            let filletRadius = wallThickness * 0.5
            ctx.setFillColor(
                NSColor.black.withAlphaComponent(0.95).cgColor)
            for cornerPoint in innerCornerPoints(
                snappedPts: snappedPts,
                wallOffset: wallOffset * scale)
            {
                ctx.fillEllipse(in: CGRect(
                    x: cornerPoint.x - filletRadius,
                    y: cornerPoint.y - filletRadius,
                    width: filletRadius * 2,
                    height: filletRadius * 2))
            }
        }

        // 2) Locate where Pac-Man's face sits this frame: walk the
        // snapped polyline with the lag as `trimTail` — the final
        // step the walker emits is exactly the cutoff point. Skip
        // drawing in this pass; we only need the coordinate +
        // tangent + arc-length (the last fuels cherry-eaten
        // detection in the pellet pass below).
        var faceAnchor: (point: CGPoint, tangent: CGPoint, arc: CGFloat)?
        walkPolyline(points: snappedPts,
                     interval: interval,
                     trimTail: lag) { p, tangent, arc in
            faceAnchor = (p, tangent, arc)
        }
        let currentFaceArc = faceAnchor?.arc ?? 0

        // 3) Pellets across the full snapped polyline. Regular
        // pellets are the historical filled circle; on-track pellets
        // get swapped for a cherry emoji at ~8% probability per
        // position. Cherry selection is hashed off the pellet's
        // rounded position so a given pellet stays a cherry (or
        // doesn't) across redraws of the same stroke.
        //
        // Cherries the face has already walked past are not drawn
        // (= "eaten") — the arcade beat where Pac-Man's mouth lands
        // on the fruit and the fruit vanishes. When a cherry crosses
        // from "ahead" to "behind" the face on the current frame
        // (i.e. its arc-length is in (previousFaceArc, currentFaceArc]),
        // `state.onCherryEaten` fires once so TrailView can paint
        // the celebratory wall flash.
        //
        // The very last walker emit is the head pellet at `pts.last`
        // (≈ the live cursor) — its position moves every frame, so
        // its position-hash flickers between cherry / dot. Excluding
        // it from cherry selection keeps the head as a plain dot;
        // cherries land only on the interval-aligned pellets behind
        // it, which are stable.
        var pelletInfo: [(point: CGPoint, arc: CGFloat)] = []
        walkPolyline(points: snappedPts, interval: interval) { p, _, arc in
            pelletInfo.append((p, arc))
        }
        let headIdx = pelletInfo.count - 1
        for (i, info) in pelletInfo.enumerated() {
            let isHead = i == headIdx
            let isCherry = state.valid && !isHead
                && positionHash01(info.point) < cherryProbability
            if isCherry {
                // Eaten — don't draw, and fire the celebratory
                // callback if the face crossed it this frame.
                if info.arc <= currentFaceArc {
                    if info.arc > state.previousFaceArcLength {
                        state.onCherryEaten(info.point)
                    }
                    continue
                }
                drawCherry(at: info.point, cell: cherryCell)
            } else {
                pelletFill.setFill()
                let rect = NSRect(x: info.point.x - dot / 2,
                                  y: info.point.y - dot / 2,
                                  width: dot, height: dot)
                NSBezierPath(ovalIn: rect).fill()
            }
        }

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
                          radius: radius, color: color,
                          isFinalHold: state.isFinalHold)
            } else {
                drawGhost(at: anchor.point, tangent: anchor.tangent,
                           radius: radius, color: color)
            }
        }

        return currentFaceArc
    }

    // MARK: - Centerline helpers

    /// Shared point sequence for every pac-man-style geometry pass:
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

    /// Pac-man centerline = straight polyline through `pts`. No
    /// per-corner smoothing — `copy(strokingWithWidth:lineCap:.round
    /// ,lineJoin:.round,...)` in `draw(...)` then turns each 90°
    /// vertex into a rounded outer arc + sharp inner point, which
    /// is exactly the arcade-maze elbow we want. Kept as its own
    /// function (rather than inlined) so that future fillet /
    /// chamfer experiments can plug in here without disturbing the
    /// `draw(...)` pipeline.
    private static func buildCenterline(points pts: [CGPoint])
        -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.line(to: p) }
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
    private static func innerCornerPoints(
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
            // bisector. wand forces 90° turns under pac-man
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
    /// pellets and Pac-Man's face. The arc-length is what lets the
    /// cherry-eaten detection compare each pellet's position against
    /// the face's lag-adjusted arc-length.
    private static func walkPolyline(points pts: [CGPoint],
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

    // MARK: - Sprite rendering

    /// Draw the pac-man face as a chunky pixel-grid sprite — a
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
    ///
    /// `isFinalHold = true` freezes the mouth wide open instead of
    /// cycling — used during the post-fire hold so the moment a
    /// rule fires reads as Pac-Man "biting" the matched rule. The
    /// trail's `finalHoldMs` window also keeps the sprite on
    /// screen, so the wide-open frame stays visible for that
    /// duration before the trail fades.
    private static func drawFace(at p: CGPoint, tangent: CGPoint,
                                   radius: CGFloat, color: NSColor,
                                   isFinalHold: Bool) {
        let phase: CGFloat
        if isFinalHold {
            phase = 1.0
        } else {
            let frames = chompFrames
            let cyclePos = (CACurrentMediaTime() * chompHz)
                .truncatingRemainder(dividingBy: 1)
            let frameIdx = min(frames.count - 1,
                                Int(cyclePos * Double(frames.count)))
            phase = frames[frameIdx]
        }
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

    /// 14×14 ghost body sprite, traced from `/Users/tommy/Desktop/b/1.gif`
    /// frame A at 7 px / cell with the eye whites stripped — both
    /// eye whites AND pupils are drawn procedurally on top so the
    /// whole eye (white + blue) snaps through 4 cardinal
    /// directions per `2.gif`, not just the pupil. `R` cells fill
    /// with the passed-in body colour; `.` cells are transparent.
    /// The last 2 rows are leg pose A's skirt; on the alternate
    /// frame the renderer swaps them for `ghostSkirtAlt` to give
    /// the classic arcade leg shuffle.
    private static let ghostSprite: [String] = [
        ".....RRRR.....",
        "...RRRRRRRR...",
        "..RRRRRRRRRR..",
        ".RRRRRRRRRRRR.",
        ".RRRRRRRRRRRR.",
        ".RRRRRRRRRRRR.",
        "RRRRRRRRRRRRRR",
        "RRRRRRRRRRRRRR",
        "RRRRRRRRRRRRRR",
        "RRRRRRRRRRRRRR",
        "RRRRRRRRRRRRRR",
        "RRRRRRRRRRRRRR",
        "RR.RRR..RRR.RR",
        "R...RR..RR...R",
    ]
    /// Alternate skirt pose (last 2 rows of `1.gif` frame B). The
    /// renderer swaps `ghostSprite`'s last 2 rows with these when
    /// `legFrame == 1`, so over time the humps shift by half a
    /// hump-width and the silhouette reads as walking.
    private static let ghostSkirtAlt: [String] = [
        "RRRR.RRRR.RRRR",
        ".RR...RR...RR.",
    ]
    /// Eye-white dimensions in sprite-cell units (width × height).
    /// Drawn as a solid 4×4 rectangle (no rounded corners) so that
    /// when the eye shifts up/down, the corner cells of a rounded
    /// shape don't expose the red body underneath as
    /// "red dots in the white" — the source `2.gif` has the same
    /// rounding artefact, but on the trail overlay it reads
    /// worse, so we square the corners. Pupil keeps its 2×2.
    private static let ghostEyeWhiteCols: CGFloat = 4
    private static let ghostEyeWhiteRows: CGFloat = 4
    /// Pupil colour (arcade ghost blue). Sampled from `1.gif`.
    private static let ghostPupilColor = NSColor(srgbRed: 0.0,
                                                  green: 0.0,
                                                  blue: 0.93,
                                                  alpha: 1.0)
    /// Eye centres in `ghostSprite` grid coords (col, row) when
    /// looking forward (no direction shift applied). The 4-wide
    /// eye-white sprite sits centred on these points and then
    /// translates by one cell in the dominant `tangent` axis;
    /// the pupil rides one further cell in the same direction.
    /// Positioned symmetrically around the sprite's geometric
    /// centre (col 6.5) so left/right gaze reads even.
    private static let ghostLeftEyeCenter = CGPoint(x: 3.5, y: 5)
    private static let ghostRightEyeCenter = CGPoint(x: 9.5, y: 5)

    /// Draw the no-match ghost — pixel sprite traced from
    /// `1.gif`, with the skirt's last 2 rows alternating at
    /// `ghostSkirtHz` between frame A and frame B (`ghostSkirtAlt`)
    /// to give the classic arcade leg shuffle. Body sits upright
    /// (arcade ghosts don't rotate); only the pupils track
    /// `tangent`, snapped to 4 cardinals to match `2.gif`'s
    /// discrete eye-direction frames.
    ///
    /// The whole sprite picks up a `panic-jitter` offset
    /// (Lissajous-style, ~`cell × 1.0` pt amplitude with co-prime
    /// frequencies on each axis) so it reads as the chased ghost
    /// shaking from the no-match state — amplitude is visibly
    /// larger than a sub-pixel tremor but capped to roughly one
    /// pixel-grid cell so the sprite never tears free of the
    /// pellet line it's chasing.
    private static func drawGhost(at p: CGPoint, tangent: CGPoint,
                                    radius: CGFloat, color: NSColor) {
        let cell = max(2, radius * pixelCellRatio)
        let legFrame = Int(CACurrentMediaTime() * ghostSkirtHz) & 1

        let t = CACurrentMediaTime()
        let jitterAmp = cell * 1.0
        let jx = CGFloat(sin(t * 17.0)) * jitterAmp
        let jy = CGFloat(sin(t * 13.0 + 1.0)) * jitterAmp

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let xform = NSAffineTransform()
        xform.translateX(by: p.x + jx, yBy: p.y + jy)
        xform.concat()

        let rows = ghostSprite.count
        let cols = ghostSprite.first?.count ?? 0
        let bodyFill = color.withAlphaComponent(0.95)
        // Sprite row 0 is the top of the image; local +y is up,
        // so the top edge sits at +rows/2 * cell and rows step
        // down by `cell` as iy grows.
        let topY = CGFloat(rows) * cell / 2
        let leftX = -CGFloat(cols) * cell / 2
        bodyFill.setFill()
        for iy in 0..<rows {
            // The bottom 2 rows of the sprite are the skirt — on
            // alt-leg frames, swap them in from `ghostSkirtAlt` so
            // the humps shift by half a hump-width.
            let row: String
            if legFrame == 1 && iy >= rows - ghostSkirtAlt.count {
                row = ghostSkirtAlt[iy - (rows - ghostSkirtAlt.count)]
            } else {
                row = ghostSprite[iy]
            }
            for (ix, ch) in row.enumerated() {
                guard ch == "R" else { continue }
                let rect = NSRect(
                    x: leftX + CGFloat(ix) * cell,
                    y: topY - CGFloat(iy + 1) * cell,
                    width: cell, height: cell)
                NSBezierPath(rect: rect).fill()
            }
        }

        // Direction snap — eye whites AND pupils both ride the
        // dominant `tangent` axis, snapped to 4 cardinals to
        // mirror `2.gif` frames 1-4. With zero tangent the eyes
        // default to a rightward look (matching the 1.gif idle
        // pose) so they never sit dead-centre.
        let absX = abs(tangent.x), absY = abs(tangent.y)
        var dirX: CGFloat
        var dirY: CGFloat
        if absX < 1e-4 && absY < 1e-4 {
            dirX = 1; dirY = 0
        } else if absX >= absY {
            dirX = tangent.x >= 0 ? 1 : -1; dirY = 0
        } else {
            dirX = 0; dirY = tangent.y >= 0 ? 1 : -1
        }

        // Eye whites + pupils share the same direction shift, so
        // the whole eye reads as displaced — not just the iris on
        // a fixed white backing. Eye shifts one cell in `dir`;
        // the pupil shifts a further cell so it rides flush
        // against the eye-white's leading edge.
        let eyeShift = cell
        let pupilShift = cell
        let whiteW = ghostEyeWhiteCols * cell
        let whiteH = ghostEyeWhiteRows * cell
        for eyeCenter in [ghostLeftEyeCenter, ghostRightEyeCenter] {
            // Eye-centre sprite-grid coords → local rendering coords.
            // Cell (gx, gy) centre sits at:
            //   x = (gx - cols/2 + 0.5) * cell  →  for cols=14, (gx - 6.5) * cell
            //   y = (rows/2 - gy - 0.5) * cell  →  for rows=14, (6.5 - gy) * cell
            // …but the sprite is rendered cell-aligned, so eyes
            // sit at the cell corner (gx - cols/2) * cell instead
            // of the cell centre — this lets the 4-wide eye-white
            // rectangle drop in flush on the half-integer eye
            // centre.
            let baseX = (eyeCenter.x - CGFloat(cols) / 2) * cell
            let baseY = (CGFloat(rows) / 2 - eyeCenter.y) * cell
            let whiteCenterX = baseX + dirX * eyeShift
            let whiteCenterY = baseY + dirY * eyeShift

            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(
                x: whiteCenterX - whiteW / 2,
                y: whiteCenterY - whiteH / 2,
                width: whiteW, height: whiteH)).fill()

            // Pupil — 2×2 cells, rides one cell further in `dir`
            // so its edge aligns with the eye-white's leading
            // edge.
            let pupilCenterX = whiteCenterX + dirX * pupilShift
            let pupilCenterY = whiteCenterY + dirY * pupilShift
            ghostPupilColor.setFill()
            NSBezierPath(rect: NSRect(
                x: pupilCenterX - cell,
                y: pupilCenterY - cell,
                width: cell * 2,
                height: cell * 2)).fill()
        }
    }

    /// Draw the arcade cherry bonus as a pixel sprite from
    /// `cherrySprite`. Centred on `p`, no rotation — orientation
    /// stays fixed like in the reference image. Cells outside
    /// the palette (`.`) are skipped so the dark wedge between
    /// the two cherries falls through to whatever's behind the
    /// click-through overlay.
    private static func drawCherry(at p: CGPoint, cell: CGFloat) {
        let rows = cherrySprite.count
        let cols = cherrySprite.first?.count ?? 0
        guard rows > 0, cols > 0 else { return }
        // Sprite row 0 is the top of the image, but AppKit's y
        // axis grows upward — so the top edge sits at +height/2
        // and rows step down by `cell`.
        let topY = p.y + CGFloat(rows) * cell / 2
        let leftX = p.x - CGFloat(cols) * cell / 2
        for (iy, row) in cherrySprite.enumerated() {
            for (ix, ch) in row.enumerated() {
                let color: NSColor
                switch ch {
                case "R": color = cherryRed
                case "K": color = cherryOutline
                case "W": color = cherryHighlight
                case "B": color = cherryStem
                default:  continue
                }
                color.setFill()
                let rect = NSRect(
                    x: leftX + CGFloat(ix) * cell,
                    y: topY - CGFloat(iy + 1) * cell,
                    width: cell, height: cell)
                NSBezierPath(rect: rect).fill()
            }
        }
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

    /// Stable 0..1 hash of a screen position. Used to pick which
    /// pellets become cherries — the same coordinate always hashes
    /// the same way, so a cherry that appears on one frame stays a
    /// cherry on every subsequent redraw of the same stroke (instead
    /// of flickering between cherry / pellet on each repaint).
    /// Pellet positions only change when the user moves past a new
    /// sample, so the cherry set stays stable through the redraws
    /// the cursor triggers per-frame.
    private static func positionHash01(_ p: CGPoint) -> Double {
        let xi = Int(p.x.rounded())
        let yi = Int(p.y.rounded())
        // 64-bit Cantor-pairing-ish hash with two large primes; the
        // `&` arithmetic wraps cleanly so negative coords work too.
        let h = (UInt64(bitPattern: Int64(xi)) &* 2654435761)
            ^ (UInt64(bitPattern: Int64(yi)) &* 40503)
        return Double(h % 10000) / 10000.0
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
