// Trail-end "burst" — omnidirectional particle explosion at the
// cursor position when a gesture rule fires. Lives in its own tiny
// click-through NSWindow (sibling of DecalManager) so the effect
// works regardless of `[gesture.overlay].enabled` — the burst is a
// fire-moment effect, not a trail decoration, and v5 splits it out
// of the overlay accordingly.
//
// Lifecycle:
//   - `emit(at:color:kind:intensity:)` creates a transient window,
//     adds a CAEmitterLayer, kills the birth rate after a brief
//     flash, and releases the window after the particles fade.
//   - `clearAll()` tears down every active burst window (used by
//     `--quit` / daemon teardown).
//
// Multi-display: each burst's window is created on the screen that
// contains the fire point, sized to a small square big enough for
// the longest particle path. Same approach as DecalManager.

import AppKit
import WandCore

@MainActor
public final class BurstManager {

    public init() {}

    /// Active burst windows, kept alive until the auto-release timer
    /// removes them. Tracked so `clearAll` can dismiss everything at
    /// once on daemon teardown.
    private var live: [NSWindow] = []

    /// Per-cell motion parameters used by both the emitter
    /// (`makeOmniBurstEmitter`) and the window-frame sizer
    /// (`frameSize(for:)`). Kept in one place so the frame can never
    /// drift smaller than the actual particle reach at the configured
    /// intensity — earlier we hard-coded 320pt here and particle tips
    /// clipped once `intensity > ~1.1`.
    private static let baseVelocity: CGFloat = 220
    private static let velocityRange: CGFloat = 70
    private static let lifetime: CGFloat = 0.6
    private static let lifetimeRange: CGFloat = 0.2
    /// Extra pad around the particle reach: ~half the dot sprite plus
    /// a few pixels so the soft edge of a fully-grown dot still has
    /// room before the window clip.
    private static let frameMargin: CGFloat = 24

    /// Window footprint that comfortably contains every particle's
    /// max displacement (`(velocity + velocityRange) * (lifetime +
    /// lifetimeRange) * intensity`) plus margin. Floored at 320pt so
    /// low-intensity bursts still have headroom; scales up linearly
    /// past that.
    private static func frameSize(for intensity: CGFloat) -> CGFloat {
        let reach = (baseVelocity + velocityRange)
            * (lifetime + lifetimeRange) * max(intensity, 0)
        return max(320, ceil(2 * (reach + frameMargin)))
    }

    /// Drop a single burst at `point` (Cocoa global coords, Y-up)
    /// with the gesture's accent `color` and the configured
    /// `intensity` multiplier. No-op for `.off`. Auto-removes after
    /// ~0.8s.
    public func emit(at point: CGPoint,
                      color: NSColor,
                      kind: TrailEndKind,
                      intensity: CGFloat) {
        guard kind == .burst else { return }

        // Centre the window on the fire point. Skip only when no
        // connected screen overlaps the burst window — the earlier
        // `frame.contains(point)`-based lookup mis-fired in multi-
        // display layouts where the cursor can land in regions not
        // strictly contained by any NSScreen frame (gaps between
        // displays, mirror-with-scaling, scale-boundary quirks).
        let size = Self.frameSize(for: intensity)
        let half = size / 2
        let frame = CGRect(x: point.x - half, y: point.y - half,
                           width: size, height: size)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) })
        else { return }

        let win = NSWindow(contentRect: frame,
                            styleMask: .borderless,
                            backing: .buffered,
                            defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true                // click-through
        win.level = .screenSaver                     // above normal windows
        win.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                  .fullScreenAuxiliary, .ignoresCycle]

        // Single CAEmitterLayer hosted on the window's content view.
        // The emitter sits at the centre of the view (= the fire
        // point in screen coords), so all particle origins land on
        // the cursor regardless of the window's screen-space frame.
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        let emitter = Self.makeOmniBurstEmitter(
            at: CGPoint(x: half, y: half),
            color: color, intensity: intensity)
        host.layer?.addSublayer(emitter)
        win.contentView = host
        win.orderFrontRegardless()
        live.append(win)

        // Kill the birth rate after a brief flash so the burst reads
        // as a single explosion rather than a continuous fountain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            [weak emitter] in emitter?.birthRate = 0
        }
        // Tear down the window once the longest particle has faded
        // (lifetime 0.6 + lifetimeRange 0.2 = ~0.8s ceiling).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            [weak self, weak win] in
            guard let win = win else { return }
            win.orderOut(nil)
            self?.live.removeAll { $0 === win }
        }
    }

    /// Immediately dismiss every active burst — used by daemon
    /// teardown / `--quit` so windows don't linger past the process.
    public func clearAll() {
        for win in live { win.orderOut(nil) }
        live.removeAll()
    }

    /// Same emitter geometry the overlay used in v4 — palette cycles
    /// across the gesture accent + adjacent hues, particles fly out
    /// in every direction with a slight downward acceleration so
    /// they drift rather than holding their initial radius.
    private static func makeOmniBurstEmitter(
        at point: CGPoint,
        color: NSColor,
        intensity: CGFloat
    ) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterShape = .point
        emitter.emitterSize = .zero
        let dot = particleDot()
        let palette: [NSColor] = [
            color,
            .systemYellow, .systemOrange,
            .systemPink, .systemPurple,
        ]
        let k = Float(intensity)
        let cells: [CAEmitterCell] = palette.map { c in
            let cell = CAEmitterCell()
            cell.contents = dot
            cell.color = c.cgColor
            cell.birthRate = 90 * k
            cell.lifetime = Float(lifetime)
            cell.lifetimeRange = Float(lifetimeRange)
            cell.velocity = baseVelocity * intensity
            cell.velocityRange = velocityRange * intensity
            cell.emissionLongitude = 0
            cell.emissionRange = .pi * 2
            cell.scale = 1.0
            cell.scaleRange = 0.4
            cell.scaleSpeed = -0.6
            cell.alphaSpeed = -1.5
            cell.spin = 1.0
            cell.spinRange = 4.0
            cell.yAcceleration = -80 * intensity
            return cell
        }
        emitter.emitterCells = cells
        return emitter
    }

    /// Tiny soft-edged white circle — the base sprite tinted via
    /// `CAEmitterCell.color`. Built once per call (cheap) since the
    /// burst is short-lived; caching across emits isn't worth the
    /// state.
    private static func particleDot() -> CGImage? {
        let size: CGFloat = 6
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor.white.setFill()
        let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0,
                                                width: size, height: size))
        path.fill()
        img.unlockFocus()
        var rect = CGRect(origin: .zero, size: NSSize(width: size,
                                                      height: size))
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
