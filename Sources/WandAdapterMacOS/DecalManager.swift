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
    /// points). No-op for `.off`, zero duration, or non-positive size.
    public func emit(at point: CGPoint,
                      color: NSColor,
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

        let view = DecalView(kind: kind, color: color, margin: margin)
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
    /// Pixel margin between the drawable square (the original `size`)
    /// and the view's bounds — gives the splatter geometry a few px
    /// of slack so anti-aliased edges aren't clipped.
    private let margin: CGFloat
    /// Frozen RNG seed per decal so the splatter shape doesn't
    /// re-roll on every `needsDisplay`. Used by `drawInkSplatter` for
    /// main blob jitter + satellite offsets so successive draws of
    /// the same window stay visually consistent.
    private let seed: UInt64

    init(kind: DecalKind, color: NSColor, margin: CGFloat) {
        self.kind = kind
        self.color = color
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

    /// Splatoon-style splatter, four layers stacked centre-out. The
    /// composition is deliberately scattered — 3-5 **primary** blobs
    /// of varying size + position fill the splat region instead of
    /// one big centred blob, mirroring how an in-game ink shot
    /// scatters across multiple impact points. Smaller satellites
    /// and droplet specks fill the gaps and the outer fringe.
    ///
    ///   0. ink rings   — one darkened underlayer per primary blob,
    ///                    so each primary reads as a "wet ink puddle
    ///                    with a darker pooled edge" rather than a
    ///                    flat sticker.
    ///   1. primaries   — 3-5 mid/large irregular polygons. The first
    ///                    one sits near (but not exactly at) the
    ///                    splat centre and is slightly larger so it
    ///                    reads as the lead splat; the rest orbit at
    ///                    random angles with random size + jitter.
    ///   2. satellites  — 5-9 smaller blobs filling gaps between
    ///                    primaries and out to the perimeter.
    ///   3. specks      — 10-17 tiny droplets in the outer fringe,
    ///                    the "wet ink, droplets fly outward" polish.
    ///
    /// All distances are bounded so the splatter stays inside the
    /// configured `size` footprint rather than clipping against the
    /// view bounds. The frozen per-decal seed governs every layer so
    /// the shape doesn't re-roll on each `needsDisplay`.
    private func drawInkSplatter(in rect: CGRect, rng: inout SplitMix64) {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let baseR = rect.width * 0.30

        // Pre-compute the primary blob positions so the ink-ring pass
        // (Layer 0) and the primary fill pass (Layer 1) agree on where
        // each puddle sits — we want the ring painted UNDER each
        // primary, not in a separate pre-computed grid.
        struct Primary {
            let centre: CGPoint
            let radius: CGFloat
            let jitter: CGFloat
            let points: Int
        }
        var primaries: [Primary] = []

        // Lead primary — near (not exactly at) centre, slightly bigger
        // than the orbiters so it still reads as the impact focus.
        do {
            let r = baseR * (0.55 + CGFloat(rng.nextUnit()) * 0.20)
            let dx = (CGFloat(rng.nextUnit()) - 0.5) * baseR * 0.30
            let dy = (CGFloat(rng.nextUnit()) - 0.5) * baseR * 0.30
            primaries.append(Primary(
                centre: CGPoint(x: centre.x + dx, y: centre.y + dy),
                radius: r, jitter: 0.42, points: 20))
        }

        // 2..4 additional primaries orbiting the centre.
        let extras = 2 + Int(rng.next() % 3)
        for _ in 0..<extras {
            let angle = CGFloat(rng.nextUnit()) * .pi * 2
            let dist = baseR * (0.40 + CGFloat(rng.nextUnit()) * 0.45)
            let r = baseR * (0.20 + CGFloat(rng.nextUnit()) * 0.25)
            let jitter: CGFloat = 0.42 + CGFloat(rng.nextUnit()) * 0.08
            let pts = 16 + Int(rng.next() % 6)
            primaries.append(Primary(
                centre: CGPoint(x: centre.x + cos(angle) * dist,
                                 y: centre.y + sin(angle) * dist),
                radius: r, jitter: jitter, points: pts))
        }

        // Layer 0 — ink rings under each primary (darker rim).
        // `blended(withFraction:of:)` mixes 45% black into the team
        // colour for the "pooled wet edge" shade.
        let ring = NSColor.black.blended(withFraction: 0.45, of: color)?
            .withAlphaComponent(0.78) ?? color
        ring.setFill()
        for p in primaries {
            irregularBlobPath(at: p.centre,
                               baseRadius: p.radius * 1.10,
                               jitter: p.jitter * 0.85,
                               points: p.points + 2,
                               rng: &rng).fill()
        }

        // Layer 1 — primary blobs.
        color.withAlphaComponent(0.95).setFill()
        for p in primaries {
            irregularBlobPath(at: p.centre,
                               baseRadius: p.radius,
                               jitter: p.jitter,
                               points: p.points,
                               rng: &rng).fill()
        }

        // Layer 2 — mid-tier satellites filling gaps (5..9).
        let satelliteCount = 5 + Int(rng.next() % 5)
        color.withAlphaComponent(0.88).setFill()
        for _ in 0..<satelliteCount {
            let angle = CGFloat(rng.nextUnit()) * .pi * 2
            let dist = baseR * (0.55 + CGFloat(rng.nextUnit()) * 0.80)
            let r = baseR * (0.08 + CGFloat(rng.nextUnit()) * 0.16)
            let c = CGPoint(x: centre.x + cos(angle) * dist,
                             y: centre.y + sin(angle) * dist)
            irregularBlobPath(at: c, baseRadius: r,
                               jitter: 0.45, points: 12, rng: &rng).fill()
        }

        // Layer 3 — droplet specks (10..17).
        let speckCount = 10 + Int(rng.next() % 8)
        color.withAlphaComponent(0.78).setFill()
        for _ in 0..<speckCount {
            let angle = CGFloat(rng.nextUnit()) * .pi * 2
            let dist = baseR * (1.05 + CGFloat(rng.nextUnit()) * 0.50)
            let r = baseR * (0.04 + CGFloat(rng.nextUnit()) * 0.08)
            let c = CGPoint(x: centre.x + cos(angle) * dist,
                             y: centre.y + sin(angle) * dist)
            irregularBlobPath(at: c, baseRadius: r,
                               jitter: 0.5, points: 8, rng: &rng).fill()
        }
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
