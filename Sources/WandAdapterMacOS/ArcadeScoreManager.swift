// Arcade-style bonus-score popup at the cursor position when a
// gesture rule fires (`[cast.fire.burst].kind = "arcade-score"`).
// Lives in its own tiny click-through NSWindow — sibling of
// BurstManager + DecalManager — so the effect works regardless of
// `[cast.overlay].enabled`, same way the other fire-moment effects
// do.
//
// Visually: a single monospaced "+N" label rises ~40pt over 800ms
// and fades to transparent. The value picks at random per fire
// from the canonical arcade bonus-tile scores (100 / 200 / 300 /
// 500 / 700 / 1000 / 2000 / 5000) so successive fires don't all
// flash the same number. Distinct from the chomp card-level
// popup (which floats from the firing HUD card) — this popup
// lands at the cursor instead, matching where the arcade frame
// flashes "+200" right next to Chomp as he eats the fruit.

import AppKit
import WandCore

@MainActor
public final class ArcadeScoreManager {

    public init() {}

    /// Active popup windows, kept alive until their auto-release
    /// timer fires. Tracked so `clearAll` can dismiss every popup
    /// at daemon teardown.
    private var live: [NSWindow] = []

    /// Total animation length (rise + fade). Matches the HUD-side
    /// `TrailView.scorePopupDurationMs` so the two popup surfaces
    /// (cursor / card) stay in lockstep when both are enabled.
    private static let durationSec: TimeInterval = 0.8
    /// How far the label rises during its animation.
    private static let riseDistancePt: CGFloat = 40
    /// Footprint of the popup window. Wide enough for the longest
    /// "+5000" string at 22pt monospaced; the rise distance pads
    /// the height. Cell size kept small so the window doesn't
    /// flash a noticeable rectangle through to whatever app sits
    /// underneath.
    private static let windowSize = CGSize(width: 140, height: 80)
    /// Canonical arcade Chomp bonus-tile scores (cherry /
    /// strawberry / orange / apple / melon / Galaxian / bell /
    /// key). Picked at random per fire so consecutive bursts don't
    /// repeat the same number.
    private static let scoreValues = [
        "+100", "+200", "+300", "+500",
        "+700", "+1000", "+2000", "+5000",
    ]

    /// Emit a single popup centred horizontally on `point` (Cocoa
    /// global coords, Y-up). The label rises + fades over
    /// `durationSec` then the host window is torn down. No-op for
    /// any `kind` other than `.arcadeScore` so the call site can
    /// share the same dispatch shape as `BurstManager.emit`.
    public func emit(at point: CGPoint,
                      color: NSColor,
                      kind: TrailEndKind) {
        guard kind == .arcadeScore else { return }

        let frame = CGRect(
            x: point.x - Self.windowSize.width / 2,
            y: point.y - Self.windowSize.height / 2,
            width: Self.windowSize.width,
            height: Self.windowSize.height)
        guard NSScreen.screens.contains(where: {
            $0.frame.intersects(frame)
        }) else { return }

        let win = NSWindow(contentRect: frame,
                            styleMask: .borderless,
                            backing: .buffered,
                            defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true                // click-through
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                  .fullScreenAuxiliary, .ignoresCycle]

        let host = NSView(frame: NSRect(origin: .zero,
                                         size: Self.windowSize))
        host.wantsLayer = true

        // CATextLayer in monospaced bold for the arcade-frame
        // numeric look. Y-up CG coord, so we sit the label slightly
        // below centre — the rise animation carries it upward
        // through the window's vertical space.
        let textLayer = CATextLayer()
        textLayer.string = Self.scoreValues.randomElement() ?? "+200"
        textLayer.foregroundColor = color.cgColor
        textLayer.font = NSFont.monospacedSystemFont(
            ofSize: 22, weight: .bold)
        textLayer.fontSize = 22
        textLayer.alignmentMode = .center
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor
            ?? 2.0
        textLayer.frame = CGRect(
            x: 0, y: Self.windowSize.height * 0.20,
            width: Self.windowSize.width, height: 32)
        host.layer?.addSublayer(textLayer)

        win.contentView = host
        win.orderFrontRegardless()
        live.append(win)

        // Rise (translate.y up by riseDistancePt) + fade (alpha 1 →
        // 0). `fillMode = .forwards` keeps the final values applied
        // after the animation ends, so the layer stays invisible
        // and positioned correctly until the window is torn down.
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 0
        rise.toValue = Self.riseDistancePt
        rise.duration = Self.durationSec
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rise.isRemovedOnCompletion = false
        rise.fillMode = .forwards

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = Self.durationSec
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards

        textLayer.add(rise, forKey: "rise")
        textLayer.add(fade, forKey: "fade")

        // Tear down the window once the animation completes (small
        // pad so the final frame fully paints before the window
        // disappears).
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.durationSec + 0.1
        ) { [weak self, weak win] in
            guard let win = win else { return }
            win.orderOut(nil)
            self?.live.removeAll { $0 === win }
        }
    }

    /// Dismiss every active popup — used by daemon teardown /
    /// `--quit` so windows don't linger past the process lifetime.
    public func clearAll() {
        for win in live { win.orderOut(nil) }
        live.removeAll()
    }
}
