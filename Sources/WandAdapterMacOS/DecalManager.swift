// Post-fire "ink decal" — a Splatoon-style splatter left at the
// cursor position when a gesture fires. Lives in its own tiny
// click-through NSWindow so it can sit on top of every app without
// interfering with input. Fades out and self-releases.
//
// The class is intentionally separate from `GestureOverlay`: that
// window is sized to the whole virtual desktop and lives for the
// daemon's lifetime; decals are per-fire, short-lived, and one
// window-per-decal lets multiple stack visually (a Splatoon-y
// "paint on top of paint" effect when the user fires repeatedly).
//
// Lifecycle:
//   - `emit(at:color:kind:durationSec:size:)` creates a new window
//     + view, schedules an alpha fade in the last third of the
//     duration, and releases on completion.
//   - `clearAll()` immediately removes every active decal (used by
//     `--quit` / daemon teardown to avoid orphaned windows).
//
// Multi-display: each decal's NSWindow is created on the screen
// containing the fire point — no union frame needed (the overlay
// already covers that case for the trail, but a decal is local so
// per-screen placement is the simpler / cheaper read).

import AppKit
import WandCore

@MainActor
public final class DecalManager {

    public init() {}

    /// Active decal windows, kept so `clearAll` can dismiss them all
    /// without depending on each window's own auto-release timer.
    private var live: [NSWindow] = []

    /// Drop a single decal at `point` (Cocoa global coords, Y-up) with
    /// `color` (the gesture's accent — typically the overlay match
    /// color), `kind` (which shape to draw), `durationSec` (total
    /// time-to-live including fade), and `size` (decal footprint in
    /// points). When `palette` is non-empty, each splat unit inside
    /// the decal picks its own colour from the palette — so a single
    /// decal can end up with 2-3 differently-coloured splats, the
    /// Splatoon "multi-shot" feel. Empty palette = every unit uses
    /// `color`. No-op for `.off`, zero duration, or non-positive size.
    public func emit(at point: CGPoint,
                      color: NSColor,
                      palette: [NSColor] = [],
                      kind: DecalKind,
                      durationSec: TimeInterval,
                      size: CGFloat) {
        guard kind != .off, durationSec > 0, size > 0 else { return }

        // Window centred on the fire point, large enough to hold the
        // decal even when it animates a tiny bit outward (small extra
        // margin = a few pixels of room for stroke / glow).
        let margin: CGFloat = 4
        let frame = CGRect(x: point.x - size / 2 - margin,
                            y: point.y - size / 2 - margin,
                            width: size + margin * 2,
                            height: size + margin * 2)
        // Skip only when the window frame doesn't intersect ANY
        // connected screen. The earlier `frame.contains(point)`-based
        // lookup mis-fired in multi-display layouts where the cursor
        // can land in regions not strictly contained by any NSScreen
        // frame (gaps between displays, mirror-with-scaling, or
        // coordinate quirks crossing scale boundaries — the symptom
        // was a silently-discarded decal even though the fire point
        // was clearly on-screen for the user).
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) })
        else { return }

        let win = NSWindow(contentRect: frame,
                            styleMask: .borderless,
                            backing: .buffered,
                            defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true               // click-through
        win.level = .screenSaver                    // above normal windows
        win.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                  .fullScreenAuxiliary, .ignoresCycle]

        let view = DecalView(kind: kind, color: color,
                              palette: palette, margin: margin)
        win.contentView = view
        win.orderFrontRegardless()
        live.append(win)

        // Fade-out: hold at full alpha for the first 2/3, then ease
        // alpha → 0 over the last 1/3. Matches the gesture overlay's
        // post-fire `final-hold-ms` curve so they feel related.
        let fadeStart = durationSec * 0.66
        let fadeDuration = durationSec - fadeStart
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeStart) {
            [weak self, weak win] in
            guard let win = win else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fadeDuration
                win.animator().alphaValue = 0
            } completionHandler: { [weak win] in
                guard let win = win else { return }
                win.orderOut(nil)
                self?.live.removeAll { $0 === win }
            }
        }
    }

    /// Immediately dismiss every active decal — used by daemon
    /// teardown / `--quit` so windows don't linger past the process.
    public func clearAll() {
        for win in live { win.orderOut(nil) }
        live.removeAll()
    }
}

/// Custom NSView that draws the chosen decal shape. The dispatch
/// switch lives in `draw(_:)` so adding a second shape later only
/// touches one place.
@MainActor
private final class DecalView: NSView {

    private let kind: DecalKind
    private let color: NSColor
    /// Optional palette for per-unit colour variation. When non-empty,
    /// each splat unit inside the decal picks its own colour from
    /// here — used by `"splatoon"` mode so a single decal can stack
    /// 2-3 differently-coloured splats. Empty = every unit uses
    /// `color`.
    private let palette: [NSColor]
    /// Pixel margin between the drawable square (the original `size`)
    /// and the view's bounds — gives the splatter geometry a few px
    /// of slack so anti-aliased edges aren't clipped.
    private let margin: CGFloat
    /// Frozen RNG seed per decal so the splatter shape doesn't
    /// re-roll on every `needsDisplay`. Used by `drawInkSplatter` for
    /// unit placement + tendril jitter + colour picks so successive
    /// draws of the same window stay visually consistent.
    private let seed: UInt64

    init(kind: DecalKind, color: NSColor,
         palette: [NSColor], margin: CGFloat) {
        self.kind = kind
        self.color = color
        self.palette = palette
        self.margin = margin
        self.seed = UInt64.random(in: 0..<UInt64.max)
        super.init(frame: .zero)
        wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // click-through

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: margin, dy: margin)
        // Local RNG: per-decal deterministic so the shape stays
        // identical across redraws (NSWindow does redraw on display
        // changes etc).
        var rng = SplitMix64(seed: seed)
        switch kind {
        case .off:          return
        case .inkSplatter:  drawInkSplatter(in: inner, rng: &rng)
        }
    }

    /// Splatoon-style splat composition: 2-3 independent **splat
    /// units** stacked at random offsets, each a complete classic
    /// "ink splat" silhouette in the SVG sense (round body with
    /// radial tendril spikes + small detached droplet specks). The
    /// lead unit sits near the centre and is the largest; the 1-2
    /// additional units orbit at random angles and are smaller.
    ///
    /// Each unit independently composes:
    ///   - ink ring underlayer (darkened rim, "wet ink puddle" cue)
    ///   - tendril body (round-ish blob with radial spike extensions
    ///     via `tendrilBlobPath`'s 3-tier radius distribution)
    ///   - 3-6 detached droplet specks immediately around it
    ///
    /// When `palette` is non-empty each unit picks its own colour
    /// from it (Splatoon "multi-shot" feel — two splats from the
    /// same fire can land different team colours). Empty palette =
    /// every unit uses `color`.
    ///
    /// The frozen per-decal seed governs every roll (unit count,
    /// positions, sizes, tendril radii, speck offsets, colour picks)
    /// so a window's shape doesn't re-shuffle on `needsDisplay`.
    private func drawInkSplatter(in rect: CGRect, rng: inout SplitMix64) {
        let viewCentre = CGPoint(x: rect.midX, y: rect.midY)
        let unitCount = 2 + Int(rng.next() % 2)   // 2..3

        for i in 0..<unitCount {
            // Position + size per unit.
            let unitCentre: CGPoint
            let unitR: CGFloat
            if i == 0 {
                // Lead unit — near (not exactly at) centre, largest.
                let dx = (CGFloat(rng.nextUnit()) - 0.5)
                    * rect.width * 0.12
                let dy = (CGFloat(rng.nextUnit()) - 0.5)
                    * rect.width * 0.12
                unitCentre = CGPoint(x: viewCentre.x + dx,
                                      y: viewCentre.y + dy)
                unitR = rect.width
                    * (0.15 + CGFloat(rng.nextUnit()) * 0.05)
            } else {
                // Orbit unit — random angle, smaller.
                let angle = CGFloat(rng.nextUnit()) * .pi * 2
                let dist = rect.width
                    * (0.18 + CGFloat(rng.nextUnit()) * 0.10)
                unitCentre = CGPoint(
                    x: viewCentre.x + cos(angle) * dist,
                    y: viewCentre.y + sin(angle) * dist)
                unitR = rect.width
                    * (0.07 + CGFloat(rng.nextUnit()) * 0.06)
            }

            // Per-unit colour: from palette if set, else fixed.
            let unitColor: NSColor
            if !palette.isEmpty {
                let idx = Int(rng.next() % UInt64(palette.count))
                unitColor = palette[idx]
            } else {
                unitColor = color
            }

            // Layer 0 — ink ring underlayer (darker rim).
            let ring = NSColor.black
                .blended(withFraction: 0.45, of: unitColor)?
                .withAlphaComponent(0.78) ?? unitColor
            ring.setFill()
            tendrilBlobPath(at: unitCentre,
                             baseRadius: unitR * 1.08,
                             rng: &rng).fill()

            // Layer 1 — main body with tendrils.
            unitColor.withAlphaComponent(0.96).setFill()
            tendrilBlobPath(at: unitCentre,
                             baseRadius: unitR,
                             rng: &rng).fill()

            // Layer 2 — 3..6 detached droplet specks near this unit.
            let speckCount = 3 + Int(rng.next() % 4)
            unitColor.withAlphaComponent(0.88).setFill()
            for _ in 0..<speckCount {
                let angle = CGFloat(rng.nextUnit()) * .pi * 2
                let dist = unitR
                    * (1.4 + CGFloat(rng.nextUnit()) * 0.8)
                let dr = unitR
                    * (0.04 + CGFloat(rng.nextUnit()) * 0.10)
                let c = CGPoint(
                    x: unitCentre.x + cos(angle) * dist,
                    y: unitCentre.y + sin(angle) * dist)
                irregularBlobPath(at: c, baseRadius: dr,
                                   jitter: 0.4, points: 8,
                                   rng: &rng).fill()
            }
        }
    }

    /// SVG-style classic ink-splat path: round-ish body with radial
    /// tendril spikes. 22-29 vertices placed at uniform angle steps;
    /// each vertex's radius rolls into one of three tiers:
    ///
    ///   - body   (60% prob): 0.70-1.05× baseR — keeps the blob
    ///            silhouette close to a jittered circle.
    ///   - medium (30% prob): 1.20-1.55× baseR — short tendril.
    ///   - long   (10% prob): 1.80-2.30× baseR — full tendril spike.
    ///
    /// Vertices are then connected via Catmull-Rom-to-bezier curves
    /// (standard 1/6 tension) so the long-tendril vertices read as
    /// rounded teardrop spikes rather than triangular notches. The
    /// random tier roll per vertex avoids any regular pattern — the
    /// tendrils land at unpredictable angles and lengths, mirroring
    /// the irregular SVG ink-splat shapes.
    private func tendrilBlobPath(at centre: CGPoint,
                                  baseRadius r: CGFloat,
                                  rng: inout SplitMix64) -> NSBezierPath {
        let vertCount = 22 + Int(rng.next() % 8)
        var verts: [CGPoint] = []
        verts.reserveCapacity(vertCount)
        for i in 0..<vertCount {
            let angle = CGFloat(i) * (.pi * 2 / CGFloat(vertCount))
            let roll = CGFloat(rng.nextUnit())
            let mult: CGFloat
            if roll < 0.10 {
                mult = 1.80 + CGFloat(rng.nextUnit()) * 0.50
            } else if roll < 0.40 {
                mult = 1.20 + CGFloat(rng.nextUnit()) * 0.35
            } else {
                mult = 0.70 + CGFloat(rng.nextUnit()) * 0.35
            }
            let radius = r * mult
            verts.append(CGPoint(x: centre.x + cos(angle) * radius,
                                  y: centre.y + sin(angle) * radius))
        }
        // Same Catmull-Rom-to-bezier smoothing as irregularBlobPath.
        let path = NSBezierPath()
        guard !verts.isEmpty else { return path }
        path.move(to: verts[0])
        let n = verts.count
        for i in 0..<n {
            let p1 = verts[i]
            let p2 = verts[(i + 1) % n]
            let p0 = verts[(i - 1 + n) % n]
            let p3 = verts[(i + 2) % n]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                               y: p1.y + (p2.y - p0.y) / 6.0)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                               y: p2.y - (p3.y - p1.y) / 6.0)
            path.curve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
        }
        path.close()
        return path
    }

    /// Closed smooth-curve path radiating from `centre`, with each
    /// vertex pushed outward from `baseRadius` by a `±jitter` factor
    /// (in units of the radius). The vertices are then connected by
    /// Catmull-Rom-derived cubic bezier segments so the silhouette
    /// reads as a rounded blob (real ink puddle) rather than a hard-
    /// angled polygon — the difference is most visible on the large
    /// primary blobs and the ink-ring underlayers. Used as the
    /// building block for every layer of the splatter.
    private func irregularBlobPath(at centre: CGPoint,
                                    baseRadius r: CGFloat,
                                    jitter: CGFloat,
                                    points: Int,
                                    rng: inout SplitMix64) -> NSBezierPath {
        // Vertex positions — same jittered-circle layout as before.
        var verts: [CGPoint] = []
        verts.reserveCapacity(points)
        for i in 0..<points {
            let angle = CGFloat(i) * (.pi * 2 / CGFloat(points))
            let jitterAmt = (CGFloat(rng.nextUnit()) - 0.5) * 2 * jitter
            let actualR = r * (1 + jitterAmt)
            verts.append(CGPoint(x: centre.x + cos(angle) * actualR,
                                  y: centre.y + sin(angle) * actualR))
        }

        // Connect with Catmull-Rom-to-bezier curves so adjacent
        // segments share C1 continuity. The 1/6 tension factor is the
        // standard "uniform Catmull-Rom → cubic bezier" conversion —
        // tighter values give a more polygon-like look, looser values
        // can overshoot when consecutive vertices have very different
        // radii (jitter > ~0.5).
        let path = NSBezierPath()
        guard !verts.isEmpty else { return path }
        path.move(to: verts[0])
        let n = verts.count
        for i in 0..<n {
            let p1 = verts[i]
            let p2 = verts[(i + 1) % n]
            let p0 = verts[(i - 1 + n) % n]
            let p3 = verts[(i + 2) % n]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                               y: p1.y + (p2.y - p0.y) / 6.0)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                               y: p2.y - (p3.y - p1.y) / 6.0)
            path.curve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
        }
        path.close()
        return path
    }
}

/// Deterministic 64-bit RNG so the decal shape stays fixed across
/// redraws of the same window. Stdlib's `Int.random(in:)` would
/// re-roll on every `draw(_:)`, making the shape jitter.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform 0..1 double for jitter / angle picking.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / Double(1 << 53))
    }
}
