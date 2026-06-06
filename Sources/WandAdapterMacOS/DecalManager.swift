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

    /// 1 main blob + 3-6 satellite splatters at random offsets. Each
    /// blob is an irregular polygon with the corners pulled out from
    /// its centre by a randomised radius so it reads as a paint
    /// splatter rather than a clean circle.
    private func drawInkSplatter(in rect: CGRect, rng: inout SplitMix64) {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let baseR = rect.width * 0.32

        color.withAlphaComponent(0.92).setFill()
        irregularBlobPath(at: centre, baseRadius: baseR,
                           jitter: 0.35, points: 16, rng: &rng).fill()

        let satelliteCount = 3 + Int(rng.next() % 4)   // 3..6
        let lighter = color.withAlphaComponent(0.7)
        lighter.setFill()
        for _ in 0..<satelliteCount {
            let angle = CGFloat(rng.nextUnit()) * .pi * 2
            let dist = baseR * (0.7 + CGFloat(rng.nextUnit()) * 0.6)
            let r = baseR * (0.12 + CGFloat(rng.nextUnit()) * 0.22)
            let c = CGPoint(x: centre.x + cos(angle) * dist,
                             y: centre.y + sin(angle) * dist)
            irregularBlobPath(at: c, baseRadius: r,
                               jitter: 0.4, points: 10, rng: &rng).fill()
        }
    }

    /// Closed polygon path radiating from `centre`, with each vertex
    /// pushed outward from `baseRadius` by a `±jitter` factor (in
    /// units of the radius). Used as the building block for the main
    /// splatter blob + satellite spatter.
    private func irregularBlobPath(at centre: CGPoint,
                                    baseRadius r: CGFloat,
                                    jitter: CGFloat,
                                    points: Int,
                                    rng: inout SplitMix64) -> NSBezierPath {
        let path = NSBezierPath()
        for i in 0..<points {
            let angle = CGFloat(i) * (.pi * 2 / CGFloat(points))
            let jitterAmt = (CGFloat(rng.nextUnit()) - 0.5) * 2 * jitter
            let actualR = r * (1 + jitterAmt)
            let p = CGPoint(x: centre.x + cos(angle) * actualR,
                             y: centre.y + sin(angle) * actualR)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
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
