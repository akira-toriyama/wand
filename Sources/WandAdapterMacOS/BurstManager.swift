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

    /// Footprint of one burst window. Sized to comfortably hold every
    /// particle's `velocity * lifetime` displacement, with a margin
    /// for the dot's own radius. Generous on purpose — clipping a
    /// particle mid-flight reads as a bug.
    private static let frameSize: CGFloat = 320

    /// Drop a single burst at `point` (Cocoa global coords, Y-up)
    /// with the gesture's accent `color` and the configured
    /// `intensity` multiplier. No-op for `.off`. Auto-removes after
    /// ~0.8s.
    public func emit(at point: CGPoint,
                      color: NSColor,
                      kind: TrailEndKind,
                      intensity: CGFloat) {
        guard kind == .burst else { return }

        // Centre the window on the fire point. Pick the screen that
        // contains the point so multi-display setups don't end up
        // with a window straddling two screens.
        let half = Self.frameSize / 2
        let frame = CGRect(x: point.x - half, y: point.y - half,
                           width: Self.frameSize, height: Self.frameSize)
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(point)
        }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.frame,
              screenFrame.intersects(frame) else { return }

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
            cell.lifetime = 0.6
            cell.lifetimeRange = 0.2
            cell.velocity = 220 * intensity
            cell.velocityRange = 70 * intensity
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
