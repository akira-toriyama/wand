// Trail style renderers for `TrailView` — the `[cast.overlay.trail].style`
// presets (`normal` / `dashed` / `dotted` / `pixel` / `ascii` /
// `rainbow-road` / `arrow` / `paws`) plus the geometry they share.
// Chomp is NOT here: it is a theme, not a style, and lives in
// `ChompRenderer`. Colour never originates in this file — every
// renderer takes the already-resolved match / outline colours from
// `TrailView.draw`.

import AppKit
import CoreGraphics
import WandCore

extension TrailView {
    /// Build the standard hybrid corner-smoothed + freehand polyline
    /// path shared by `normal` / `dashed` / `dotted`. Centralised so
    /// they differ only in stroke parameters, never in geometry.
    ///
    /// When `straightenOnTurn = false`, return a pure polyline through
    /// every raw mouse sample instead — no corner snapping, no
    /// orthogonal axes. Recognition still uses `corners` / `lastDir`
    /// to drive the rule matcher; this only affects what's drawn.
    private func buildHybridPath(origin: CGPoint,
                                  lineWidth: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if !straightenOnTurn {
            // Pure freehand: trace every raw sample as-is. `rawTrail`
            // is seeded with `origin` on stroke start so this always
            // begins at the button-down point.
            guard let first = rawTrail.first else { return path }
            path.move(to: first)
            for p in rawTrail.dropFirst() { path.line(to: p) }
            return path
        }

        // The corner-softening radius is capped to half of each
        // adjacent segment so tight corners never overshoot.
        let straight = [origin] + corners
        path.move(to: straight[0])
        if straight.count == 2 {
            path.line(to: straight[1])
        } else if straight.count > 2 {
            let desiredR = lineWidth * 4
            for i in 1..<straight.count - 1 {
                let A = straight[i - 1]
                let B = straight[i]
                let C = straight[i + 1]
                let inLen = hypot(B.x - A.x, B.y - A.y)
                let outLen = hypot(C.x - B.x, C.y - B.y)
                let r = min(desiredR, inLen / 2, outLen / 2)
                let inU = CGPoint(x: (B.x - A.x) / max(inLen, 1),
                                  y: (B.y - A.y) / max(inLen, 1))
                let outU = CGPoint(x: (C.x - B.x) / max(outLen, 1),
                                   y: (C.y - B.y) / max(outLen, 1))
                let P = CGPoint(x: B.x - inU.x * r, y: B.y - inU.y * r)
                let Q = CGPoint(x: B.x + outU.x * r, y: B.y + outU.y * r)
                path.line(to: P)
                path.curve(to: Q, controlPoint1: B, controlPoint2: B)
            }
            path.line(to: straight.last!)
        }

        // Freehand tail: `freehandPoints[0]` equals the last straight
        // point (= corners.last ?? origin), so skip it to avoid a
        // zero-length segment, then trace through to the cursor.
        for fp in freehandPoints.dropFirst() {
            path.line(to: fp)
        }
        return path
    }

    /// `normal` / `dashed` / `dotted` all funnel through here — they
    /// differ only in lineWidth, glow radius, and dash pattern. When
    /// `outline` is set, the same path is stroked first with a wider
    /// line in the outline colour so the main stroke reads against
    /// backgrounds that would otherwise swallow it.
    func drawSinglePath(origin: CGPoint, cursor: CGPoint,
                                 color: NSColor, outline: NSColor?) {
        let p = styleParams(base: strokeWidth)
        let path = buildHybridPath(origin: origin, lineWidth: p.width)
        if !p.lineDash.isEmpty {
            path.setLineDash(p.lineDash, count: p.lineDash.count, phase: 0)
        }
        if let outline {
            // 2pt total extra (1pt each side) — visible without
            // dominating the trail.
            let underlay = buildHybridPath(origin: origin,
                                            lineWidth: p.width + 2)
            if !p.lineDash.isEmpty {
                underlay.setLineDash(p.lineDash,
                                      count: p.lineDash.count, phase: 0)
            }
            outline.withAlphaComponent(0.9).setStroke()
            underlay.stroke()
        }
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.5)
        glow.shadowBlurRadius = p.glowRadius
        glow.set()
        color.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    /// Per-style stroke parameters. The remaining styles all share the
    /// same width and glow; only the dash pattern differs. Kept as a
    /// struct (rather than inlined) so adding a future style only
    /// touches one switch.
    private struct TrailStyleParams {
        let width: CGFloat
        let glowRadius: CGFloat
        let lineDash: [CGFloat]
    }

    private func styleParams(base: CGFloat) -> TrailStyleParams {
        switch trailStyle {
        case .normal:
            return TrailStyleParams(width: base, glowRadius: 7,
                                     lineDash: [])
        case .dashed:
            return TrailStyleParams(width: base, glowRadius: 7,
                                     lineDash: [base * 3, base * 2])
        case .dotted:
            return TrailStyleParams(width: base, glowRadius: 7,
                                     lineDash: [base * 0.6, base * 2])
        case .pixel, .ascii, .rainbowRoad, .arrow, .paws:
            // Unused — these styles route through their own
            // renderers and never call `drawSinglePath`. Returning a
            // safe baseline keeps the switch exhaustive without
            // pretending these styles share stroke parameters.
            return TrailStyleParams(width: base, glowRadius: 0,
                                     lineDash: [])
        }
    }

    /// Walk the same hybrid corner + freehand polyline that
    /// `buildHybridPath` produces, but instead of emitting a bezier,
    /// invoke `step` once per `interval`-pt advance along the path.
    /// Used by the pixel and ascii renderers to place discrete marks
    /// at a fixed spacing regardless of original sample density.
    private func walkPath(origin: CGPoint,
                           interval: CGFloat,
                           trimTail: CGFloat = 0,
                           step: (CGPoint, CGPoint) -> Void) {
        // Freehand mode walks the raw sample stream; straightened
        // mode walks the snapped corner polyline + active freehand.
        let pts: [CGPoint] = straightenOnTurn
            ? ([origin] + corners + Array(freehandPoints.dropFirst()))
            : rawTrail
        guard !pts.isEmpty, interval > 0 else { return }
        // `trimTail` (pt) trims that much distance off the end of the
        // path before emitting — used by the Chomp style to leave a
        // visible gap between the trailing pellets and the cursor's
        // face, so it reads as Chomp running ahead of the trail.
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
        // Tangent for the very first point: peek forward to the first
        // non-zero segment so the leading mark is oriented along the
        // path instead of an arbitrary axis. Defaults to (1, 0) until
        // a real direction is available.
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
                    // Reached the trim boundary — emit the exact
                    // cutoff position so callers (Chomp face) can
                    // anchor against it, then stop. The final-sample
                    // emit below is skipped because we never reached
                    // the path end.
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
        // Always emit the final sample (== cursor for live strokes) so
        // the head of the trail is marked even when the last segment
        // is shorter than `interval`. Skipped when `cutoff` is in
        // effect — callers that pass `trimTail` don't want the final
        // sample because the trail is meant to end short of it.
        if cutoff == nil, let last = pts.last {
            step(last, lastTangent)
        }
    }

    /// Fixed grid cell size for the `pixel` style (pt). Small enough
    /// to read as pixel art rather than a chunky bar. `strokeWidth`
    /// no longer drives this — it drives the thickness (cells across
    /// the path) instead.
    private static let pixelCellSize: CGFloat = 5

    /// 8-bit / pixel-art style: quantise the path to a fixed-size
    /// square grid and fill cells along the path. `strokeWidth` is
    /// re-purposed here as **thickness in cells**: a `width = 3`
    /// trail lays down a 3-cell-wide stripe perpendicular to the
    /// path. Colour comes from the resolved trail colour. Cells are
    /// de-duplicated via a Set so overlapping stripes never overdraw.
    func drawPixelPath(origin: CGPoint, cursor: CGPoint,
                                color: NSColor, outline: NSColor?) {
        let cell = Self.pixelCellSize
        let thickness = max(1, Int(strokeWidth.rounded()))
        let offsetBase = CGFloat(thickness - 1) / 2
        var seen = Set<UInt64>()
        let fill = color.withAlphaComponent(0.95)
        let outlineFill = outline?.withAlphaComponent(0.95)
        let plot: (CGPoint, CGPoint) -> Void = { p, tangent in
            // Normal to the path: rotate tangent 90°.
            let nx = -tangent.y
            let ny =  tangent.x
            for i in 0..<thickness {
                let d = (CGFloat(i) - offsetBase) * cell
                let cx = p.x + nx * d
                let cy = p.y + ny * d
                let gx = Int((cx / cell).rounded(.down))
                let gy = Int((cy / cell).rounded(.down))
                // Pack two Int32 into UInt64 for set key.
                let key = (UInt64(bitPattern: Int64(Int32(gx))) << 32)
                    | UInt64(UInt32(bitPattern: Int32(gy)))
                guard seen.insert(key).inserted else { continue }
                let rect = NSRect(x: CGFloat(gx) * cell,
                                  y: CGFloat(gy) * cell,
                                  width: cell, height: cell)
                // Both rects stay inside the cell's own grid square,
                // so adjacent cells never overdraw each other.
                if let outlineFill {
                    outlineFill.setFill()
                    NSBezierPath(rect: rect).fill()
                    fill.setFill()
                    NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                        .fill()
                } else {
                    fill.setFill()
                    NSBezierPath(rect: rect).fill()
                }
            }
        }
        // Sample slightly finer than the cell so diagonal segments
        // don't leave gaps; the dedupe set absorbs the redundancy.
        walkPath(origin: origin, interval: cell * 0.5, step: plot)
    }

    /// Palette of ASCII glyphs used by `drawAsciiPath`. Chosen for
    /// visual variety while staying readable as text — mixes solid
    /// (`*` / `#` / `@`), open (`o` / `+`), and punctuation (`.` /
    /// `:` / `=`) shapes so the trail reads as scattered ASCII art
    /// rather than a single repeating mark.
    private static let asciiGlyphs: [String] = [
        "*", "+", "x", "o", "#", ".", ":", "=", "~", "^",
    ]

    /// Cheap deterministic 64-bit hash (SplitMix64). Combined with
    /// `strokeSeed` so each stroke gets its own glyph sequence but
    /// the sequence is stable across redraws within a stroke (no
    /// flicker as the trail extends frame to frame).
    private static func splitmix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Fixed monospaced font size for the `ascii` style (pt).
    /// `strokeWidth` is re-purposed as the thickness (glyph count
    /// perpendicular to the path).
    private static let asciiFontSize: CGFloat = 14

    /// How fast each glyph slot reshuffles. The picker seed is
    /// quantised by `floor(time * frequency)`, so a frequency of
    /// 8 means each slot can pick a fresh glyph 8 times per second.
    /// Slow enough to read as flicker, fast enough to feel alive.
    private static let asciiGlyphFlickerHz: Double = 8

    /// ASCII-art style: place varied glyphs along the path, tinted
    /// with the resolved trail colour. Monospaced font so the
    /// rhythm reads as text. Glyph at each position is picked
    /// deterministically from `asciiGlyphs` via `strokeSeed`,
    /// giving each stroke its own randomised mix. `strokeWidth` is
    /// re-purposed as **thickness in glyphs**: a `width = 3` trail
    /// lays down a 3-glyph-wide band perpendicular to the path.
    func drawAsciiPath(origin: CGPoint, cursor: CGPoint,
                                color: NSColor, outline: NSColor?) {
        let fontSize = Self.asciiFontSize
        let font = NSFont.monospacedSystemFont(ofSize: fontSize,
                                                weight: .bold)
        // `color-outline` on ascii means **backing rect** (cmatrix
        // feel), not glyph stroke: each glyph gets painted onto a
        // solid block of the outline colour. A black outline + green
        // accent gives the classic Matrix-rain look. Earlier this
        // used `.strokeColor` for outlined characters, but that
        // produced "outlined letters" rather than the terminal
        // backdrop users actually expected.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(0.95),
        ]
        // Pre-build one NSAttributedString per palette entry — cheap
        // cache (~10 small strings) so the per-step draw doesn't
        // re-allocate.
        let glyphs = Self.asciiGlyphs.map {
            NSAttributedString(string: $0, attributes: attrs)
        }
        // Monospaced font → every glyph reports the same width, so a
        // single size value is correct for placement.
        let glyphSize = glyphs[0].size()
        let interval = fontSize * 0.9
        let thickness = max(1, Int(strokeWidth.rounded()))
        let offsetBase = CGFloat(thickness - 1) / 2
        let seed = strokeSeed
        // Time-quantised component so the picker shuffles each slot
        // a few times per second — the trail's glyphs flicker as the
        // animation tick redraws the view, without changing so fast
        // they smear into noise.
        let timeTick = UInt64(
            (CACurrentMediaTime() * Self.asciiGlyphFlickerHz)
                .rounded(.down))
        var index: UInt64 = 0
        let backing = outline?.withAlphaComponent(0.95)
        let draw: (CGPoint, CGPoint) -> Void = { p, tangent in
            // Normal to the path: rotate tangent 90°.
            let nx = -tangent.y
            let ny =  tangent.x
            for i in 0..<thickness {
                let d = (CGFloat(i) - offsetBase) * glyphSize.width
                let cx = p.x + nx * d
                let cy = p.y + ny * d
                let pick = Int(
                    Self.splitmix(seed &+ index &+ (timeTick &<< 16))
                        % UInt64(glyphs.count))
                index &+= 1
                let r = NSRect(x: cx - glyphSize.width / 2,
                               y: cy - glyphSize.height / 2,
                               width: glyphSize.width,
                               height: glyphSize.height)
                if let backing {
                    backing.setFill()
                    NSBezierPath(rect: r).fill()
                }
                glyphs[pick].draw(in: r)
            }
        }
        walkPath(origin: origin, interval: interval, step: draw)
    }

    /// Rainbow-road palette — spectrum-ordered (ROYGBIV) so the
    /// trail reads as a rainbow track. Indexed by `(cellIndex / 4)`
    /// so every 4 consecutive cells share a colour, giving the
    /// track its segment-like rhythm.
    private static let rainbowRoadColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemIndigo, .systemPurple,
    ]

    /// Rainbow-road-themed pixel variant: same fixed-cell grid as
    /// `drawPixelPath`, but the fill colour steps through a
    /// spectrum-ordered palette every 4 cells. When the in-progress
    /// shape can no longer reach any rule (`!valid`), the whole trail
    /// switches to `color` (= the resolved no-match colour) so the
    /// failure signal still reads even with the bespoke palette.
    func drawRainbowRoadPath(origin: CGPoint, cursor: CGPoint,
                                      color: NSColor,
                                      outline: NSColor?) {
        let cell = Self.pixelCellSize
        let thickness = max(1, Int(strokeWidth.rounded()))
        let offsetBase = CGFloat(thickness - 1) / 2
        var seen = Set<UInt64>()
        // Cell counter drives both the dedup key and the colour
        // rotation. Bumped per *placed* cell (not per attempted) so
        // a track segment's 4 cells stay the same colour even when
        // some would-be cells are skipped by dedup.
        var cellIndex = 0
        let useFallback = !valid
        let outlineFill = outline?.withAlphaComponent(0.95)
        let plot: (CGPoint, CGPoint) -> Void = { p, tangent in
            let nx = -tangent.y
            let ny =  tangent.x
            for i in 0..<thickness {
                let d = (CGFloat(i) - offsetBase) * cell
                let cx = p.x + nx * d
                let cy = p.y + ny * d
                let gx = Int((cx / cell).rounded(.down))
                let gy = Int((cy / cell).rounded(.down))
                let key = (UInt64(bitPattern: Int64(Int32(gx))) << 32)
                    | UInt64(UInt32(bitPattern: Int32(gy)))
                guard seen.insert(key).inserted else { continue }
                let fill: NSColor
                if useFallback {
                    fill = color
                } else {
                    let pick = (cellIndex / 4)
                        % Self.rainbowRoadColors.count
                    fill = Self.rainbowRoadColors[pick]
                }
                cellIndex += 1
                let rect = NSRect(x: CGFloat(gx) * cell,
                                  y: CGFloat(gy) * cell,
                                  width: cell, height: cell)
                if let outlineFill {
                    outlineFill.setFill()
                    NSBezierPath(rect: rect).fill()
                    fill.withAlphaComponent(0.95).setFill()
                    NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                        .fill()
                } else {
                    fill.withAlphaComponent(0.95).setFill()
                    NSBezierPath(rect: rect).fill()
                }
            }
        }
        walkPath(origin: origin, interval: cell * 0.5, step: plot)
    }

    // Chomp trail rendering — every chomp/ghost-specific
    // constant + helper now lives in `ChompRenderer.swift`. The
    // `draw(_:)` dispatch hands the relevant TrailView state over
    // via `ChompRenderer.State`.

    /// Snap `p` onto the axis defined by `dir` and the point `from` —
    /// horizontal directions preserve `from.y`, vertical preserve
    /// `from.x`. Used in two places: committing a corner that sits on
    /// the previous segment's axis, and projecting the live cursor
    /// onto the current segment's axis.
    static func snap(_ p: CGPoint, to dir: Direction,
                              from: CGPoint) -> CGPoint {
        switch dir {
        case .left, .right: return CGPoint(x: p.x, y: from.y)
        case .up, .down:    return CGPoint(x: from.x, y: p.y)
        }
    }

    /// Continuous arrow chain along the path — filled chevron glyphs
    /// (`>`) rotated to follow the local tangent, so the trail reads
    /// as `-->-->-->` pointing toward the cursor. Each chevron is
    /// rendered as a small NSBezierPath (two strokes that meet at a
    /// point) instead of a text glyph so the rotation is per-pixel
    /// crisp at any angle and the size scales cleanly with
    /// `strokeWidth`.
    func drawArrowChainPath(origin: CGPoint, cursor: CGPoint,
                                     color: NSColor,
                                     outline: NSColor?) {
        // Geometry scales with `strokeWidth`: a `width = 3` (the
        // default) chevron is ~12pt long with a ~9pt half-height,
        // and chevrons sit ~14pt apart. Higher widths grow
        // proportionally; the chain density stays the same.
        let len = max(8, strokeWidth * 4)
        let half = max(5, strokeWidth * 3)
        let lineWidth = max(1.5, strokeWidth * 0.8)
        let interval = max(len * 1.4, strokeWidth * 5)
        let stroke = color.withAlphaComponent(0.95)
        let outlineStroke = outline?.withAlphaComponent(0.95)
        let drawChevron: (CGPoint, CGPoint) -> Void = { p, tangent in
            // Tangent gives the forward direction (the open side of
            // the `>`). The chevron's two arms reach BACK from the
            // tip, each at a fixed angle to the tangent.
            let tx = tangent.x, ty = tangent.y
            // Perpendicular (90° CCW): (-ty, tx).
            let nx = -ty, ny = tx
            // Tip = a bit ahead of `p`; back-corners are length `len`
            // behind the tip, ±`half` along the normal.
            let tipX = p.x + tx * (len * 0.4)
            let tipY = p.y + ty * (len * 0.4)
            let backCenterX = p.x - tx * (len * 0.6)
            let backCenterY = p.y - ty * (len * 0.6)
            let p1 = CGPoint(x: backCenterX + nx * half,
                             y: backCenterY + ny * half)
            let p2 = CGPoint(x: backCenterX - nx * half,
                             y: backCenterY - ny * half)
            let path = NSBezierPath()
            path.move(to: p1)
            path.line(to: CGPoint(x: tipX, y: tipY))
            path.line(to: p2)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if let outlineStroke {
                outlineStroke.setStroke()
                path.lineWidth = lineWidth + 2
                path.stroke()
            }
            stroke.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }
        walkPath(origin: origin, interval: interval, step: drawChevron)
    }

    /// Spacing between paw prints along the path (pt at scale=1).
    /// Has to clear the print's rendered size with visible gap,
    /// otherwise consecutive prints bleed into a continuous line.
    private static let pawsSpacing: CGFloat = 36
    /// Base SF Symbol point size for `pawprint.fill` (pt at
    /// scale=1). The symbol's natural rendered size is bigger than
    /// the point value because the symbol fills its glyph cell —
    /// this lands ~22pt of print at scale=1.
    private static let pawsPointSize: CGFloat = 18
    /// How far each paw print drifts off the path centreline,
    /// alternating left/right (pt at scale=1). Reads as "footprints
    /// from two paws walking" instead of a centred chain.
    private static let pawsSideOffset: CGFloat = 5

    /// Stylised paw prints walking along the path — `pawprint.fill`
    /// SF Symbol drawn at `pawsSpacing` intervals, rotated so the
    /// toes face the path tangent and offset perpendicularly by
    /// `pawsSideOffset` alternating side-to-side so consecutive
    /// prints read as L/R footprints. Tinted via `hierarchicalColor`
    /// so the trail colour flows through like the other styles, and
    /// dynamic colour modes (`rainbow` / `neon` / `splatoon`) animate
    /// naturally. `outline` (when set) is drawn as a slightly-larger
    /// halo of the same symbol behind the main one — same legibility
    /// treatment as the chomp pellet outline. `strokeWidth` is
    /// re-purposed as a scale multiplier on every dimension.
    func drawPawsPath(origin: CGPoint, cursor: CGPoint,
                               color: NSColor, outline: NSColor?) {
        let scale = max(0.5, strokeWidth / 3)
        let spacing = Self.pawsSpacing * scale
        let pointSize = Self.pawsPointSize * scale
        let sideOff = Self.pawsSideOffset * scale

        // Build the tinted SF Symbol once per frame. drawPawsPath
        // runs once per redraw (not per print), so rebuilding here
        // costs one image-build per frame regardless of stroke
        // length. Dynamic colour modes update the tint as `color`
        // shifts frame-to-frame.
        let baseCfg = NSImage.SymbolConfiguration(
            pointSize: pointSize, weight: .semibold, scale: .medium)
        let tintedCfg = baseCfg.applying(
            NSImage.SymbolConfiguration(hierarchicalColor: color))
        guard let symbol = NSImage(
                systemSymbolName: "pawprint.fill",
                accessibilityDescription: nil)?
            .withSymbolConfiguration(tintedCfg) else { return }
        let symbolSize = symbol.size

        let outlineSymbol: NSImage?
        if let outline {
            let outlineCfg = baseCfg.applying(
                NSImage.SymbolConfiguration(hierarchicalColor: outline))
            outlineSymbol = NSImage(
                systemSymbolName: "pawprint.fill",
                accessibilityDescription: nil)?
                .withSymbolConfiguration(outlineCfg)
        } else {
            outlineSymbol = nil
        }
        let outlinePad = max(1.5, scale * 1.2)

        var idx: Int = 0
        let plot: (CGPoint, CGPoint) -> Void = { p, tangent in
            let tx = tangent.x, ty = tangent.y
            // Perpendicular (rotated 90° CCW) for the L/R drift.
            let nx = -ty, ny = tx
            let side: CGFloat = (idx % 2 == 0) ? 1 : -1
            idx += 1
            let cx = p.x + nx * side * sideOff
            let cy = p.y + ny * side * sideOff

            // `pawprint.fill` renders toes-toward-+y natively, so
            // map "up" onto the tangent (atan2 - π/2).
            let angle = atan2(ty, tx) - .pi / 2

            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let xform = NSAffineTransform()
            xform.translateX(by: cx, yBy: cy)
            xform.rotate(byRadians: angle)
            xform.concat()

            let drawRect = NSRect(
                x: -symbolSize.width / 2,
                y: -symbolSize.height / 2,
                width: symbolSize.width,
                height: symbolSize.height)

            if let outlineSymbol {
                let outlineRect = drawRect.insetBy(
                    dx: -outlinePad, dy: -outlinePad)
                outlineSymbol.draw(in: outlineRect)
            }
            symbol.draw(in: drawRect)
        }
        walkPath(origin: origin, interval: spacing, step: plot)
    }
}
