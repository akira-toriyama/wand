// Exit animations and particle effects for the assist cards
// (`[cast.overlay.cards].cancel` / `.fire`): the CAEmitterLayer
// factory and the 60 fps tick loop that keeps the overlay redrawing
// between mouse samples. The tick loop is also what animates chomp's
// wall flash and the post-fire hold — anything that needs frames
// without a sample stream goes through `kickExitAnimationTick`.

import AppKit
import CoreGraphics
import WandCore

extension TrailView {
    /// No-op for the non-particle effects — those are drawn each frame
    /// in `HUDContentView`. The emitter auto-cleans after the effect's
    /// duration via a `DispatchQueue.main.asyncAfter`.
    func scheduleParticleEffect(_ layout: CardLayout,
                                         effect: Effect) {
        guard effect == .fireworks || effect == .confetti else { return }
        let layer = makeEmitter(for: effect, at: layout.rect)
        hudContent.wantsLayer = true
        hudContent.layer?.addSublayer(layer)
        DispatchQueue.main.asyncAfter(deadline: .now() + effect.duration) {
            [weak layer] in layer?.removeFromSuperlayer()
        }
    }

    /// Drive redraws while exit animations OR the post-fire hold are
    /// running. Idempotent — the `tickScheduled` flag absorbs repeat
    /// calls within a frame.
    func kickExitAnimationTick() {
        // Anything that needs continuous redraws between mouse
        // samples (the trail+HUD only naturally redraw when a new
        // sample arrives or focus changes, so animated effects
        // without their own sample stream rely on this 60fps
        // ticker).
        let chompWallFlashActive: Bool = {
            guard chomp != nil, let t = noMatchFlashStartedAt
            else { return false }
            return (CACurrentMediaTime() - t) * 1000
                < Self.noMatchFlashDurationMs
        }()
        // Chomp stroke-active animation tick: the face's chomp
        // cycle, the ghost's skirt + panic-jitter, the rainbow
        // border on the firing card — all of those advance via
        // `CACurrentMediaTime()` lookups in `draw`, so they
        // freeze the moment the mouse stops emitting samples.
        // Driving a tick while a chomp stroke is in progress
        // keeps them moving even when the user holds the button
        // still mid-gesture.
        let chompStrokeActive = chomp != nil
            && origin != nil
            && !holdingFinal
        // Live armed cue on the firing card needs a steady tick too —
        // the per-frame transform / decoration is sampled at draw
        // time from `CACurrentMediaTime()`, so without a tick the
        // animation freezes whenever the cursor holds still. Line-
        // pets on the firing card count here too: any configured pet
        // is a continuous motion even when no `armed` kind is set.
        let armedActive = (effectArmed != .off || !cardLinePets.isEmpty)
            && origin != nil
            && !holdingFinal
            && cardLayouts.contains(where: { $0.kind == .fires })
        let needsTick = !exitingCards.isEmpty
            || holdingFinal
            || chompWallFlashActive
            || chompStrokeActive
            || armedActive
        guard needsTick, !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
            [weak self] in self?.tickExitAnimations()
        }
    }

    private func tickExitAnimations() {
        tickScheduled = false
        let now = CACurrentMediaTime()
        exitingCards.removeAll { (now - $0.startedAt) >= $0.effect.duration }
        // Wall flash auto-expires by elapsed-time check at draw
        // time, but clearing the timestamp here is harmless and
        // lets `kickExitAnimationTick` drop the tick when the
        // flash window passes.
        if let t = noMatchFlashStartedAt,
           (now - t) * 1000 >= Self.noMatchFlashDurationMs {
            noMatchFlashStartedAt = nil
        }
        hudContent.needsDisplay = true
        // The trail's fade alpha + face chomp + ghost jitter + wall
        // flash are all sampled per-draw, so the trail needs a
        // redraw on each tick too. Triggers cover: hold window,
        // wall-flash window, AND any in-progress chomp stroke
        // (so the face / ghost / rainbow border keep animating
        // even when the user holds the button still mid-gesture).
        let chompStrokeActive = chomp != nil
            && origin != nil
            && !holdingFinal
        if holdingFinal
            || noMatchFlashStartedAt != nil
            || chompStrokeActive
        {
            needsDisplay = true
        }
        kickExitAnimationTick()
    }

    /// Build a CAEmitterLayer configured for either `.fireworks`
    /// (burst upward from the card's bottom) or `.confetti` (raining
    /// down from the card's top). Both auto-fade via cell lifetime.
    private func makeEmitter(for effect: Effect, at rect: CGRect) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.emitterSize = CGSize(width: rect.width, height: 1)
        emitter.emitterShape = .line
        // Particles wear small alpha-modulated dots; colour comes from
        // each cell's `color` channel multiplying the white texel.
        let dot = Self.particleDot
        let palette: [NSColor] = [
            .systemBlue, .systemGreen, .systemYellow,
            .systemOrange, .systemPink, .systemPurple,
        ]
        // Intensity scales count and reach but not lifetime — keeps
        // the burst timing consistent so particles always disappear
        // around the same moment the card has fully faded.
        let k = Float(effectIntensity)
        let cells: [CAEmitterCell] = palette.map { c in
            let cell = CAEmitterCell()
            cell.contents = dot
            cell.color = c.cgColor
            cell.birthRate = (effect == .fireworks ? 80 : 30) * k
            cell.lifetime = effect == .fireworks ? 0.7 : 1.0
            cell.lifetimeRange = 0.2
            cell.velocity = CGFloat((effect == .fireworks ? 180 : 90)) * effectIntensity
            cell.velocityRange = 60 * effectIntensity
            cell.emissionRange = effect == .fireworks ? .pi * 0.5 : 0.4
            cell.scale = 1.0
            cell.scaleRange = 0.4
            cell.scaleSpeed = -0.4
            cell.alphaSpeed = -1.2
            cell.spin = 1.0
            cell.spinRange = 4.0
            // Gravity: fireworks fall back down, confetti rains down.
            cell.yAcceleration = CGFloat(effect == .fireworks ? -160 : 90) * effectIntensity
            return cell
        }
        emitter.emitterCells = cells
        // Cocoa is Y-up: fireworks emit at the card's bottom edge
        // with longitude +π/2 (towards larger Y), confetti at the top
        // edge with -π/2.
        if effect == .fireworks {
            emitter.emitterPosition = CGPoint(
                x: rect.midX, y: rect.minY + 4)
            for cell in emitter.emitterCells ?? [] {
                cell.emissionLongitude = .pi / 2
            }
        } else {
            emitter.emitterPosition = CGPoint(
                x: rect.midX, y: rect.maxY - 4)
            for cell in emitter.emitterCells ?? [] {
                cell.emissionLongitude = -.pi / 2
            }
        }
        // Brief burst: birthRate goes to 0 after a short window so
        // particles stop spawning before the layer is removed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            [weak emitter] in emitter?.birthRate = 0
        }
        return emitter
    }

    /// Cached white-disc texel shared by every emitter cell — no point
    /// re-rasterising the same 6×6 image on each fireworks burst.
    private static let particleDot: CGImage = makeParticleDot(diameter: 6)

    private static func makeParticleDot(diameter d: CGFloat) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: Int(d), height: Int(d),
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
        return ctx.makeImage()!
    }
}
