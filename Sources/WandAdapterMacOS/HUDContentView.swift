// HUD content layer of the cast overlay: draws the assist cards,
// the origin badge, and the armed decoration on top of `TrailView`'s
// blur. Holds no state of its own — every rect / colour / string was
// computed by `TrailView.layoutHUD`; this view only paints it.

import AppKit
import CoreGraphics
import Effects   // drawLinePets (shared line-pet drawing; re-exports Palette)
import Palette
import WandCore

/// HUD overlay drawn on top of `TrailView.blurView`: optional tint
/// fill (for the firing card), the hair border, the text — and for
/// the badge, the scale-in transform, the 2pt accent border, and the
/// icon. Reads state from its `owner` (TrailView) instead of holding
/// its own copy; layout was already computed there in `layoutHUD`.
final class HUDContentView: NSView {
    weak var owner: TrailView?
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner else { return }

        for c in o.cardLayouts {
            // Armed cue + line-pets run only on the firing card
            // mid-stroke; other cards always render at rest.
            // `holdingFinal` means the gesture already fired — past
            // the moment either cue makes sense.
            let live = c.kind == .fires && !o.holdingFinal
            let armed: ArmedEffect = live ? o.effectArmed : .off
            let pets: [LinePet] = live ? o.cardLinePets : []
            drawCard(c, in: o, alpha: 1, dx: 0, dy: 0, scale: 1,
                     armed: armed, linePets: pets)
        }

        // Exiting cards drawn on top so their final fade frame can't be
        // covered by a live card the next layout pass happens to put in
        // the same spot.
        let now = CACurrentMediaTime()
        for ex in o.exitingCards {
            let p = CGFloat(min(1.0, max(0.0,
                (now - ex.startedAt) / ex.effect.duration)))
            let s = exitTransform(for: ex.effect, progress: p,
                                   intensity: o.effectIntensity)
            drawCard(ex.layout, in: o,
                     alpha: s.alpha, dx: s.dx, dy: s.dy, scale: s.scale,
                     armed: .off, linePets: [])
        }

        if let b = o.badgeLayout {
            let cx = b.rect.midX, cy = b.rect.midY
            NSGraphicsContext.saveGraphicsState()
            let tx = NSAffineTransform()
            tx.translateX(by: cx, yBy: cy)
            tx.scaleX(by: b.scale, yBy: b.scale)
            tx.translateX(by: -cx, yBy: -cy)
            tx.concat()
            let bgPath = NSBezierPath(roundedRect: b.rect,
                                      xRadius: 10, yRadius: 10)
            // Badge backdrop priority:
            //   1. Themed solid (palette.badgeBackgroundColor) —
            //      drawn even when blur is on, so it sits between
            //      the vibrancy and the icon (the theme colour
            //      wins over the frost).
            //   2. Else, when blur is off, fall back to a dark
            //      rounded fill so the icon still has contrast on
            //      the transparent overlay window.
            //   3. Default (blur on, no theme) — no fill; the
            //      blurView under the masked badge rect carries
            //      the historical frosted look.
            if let themed = o.badgeBackgroundColor {
                themed.withAlphaComponent(0.95).setFill()
                bgPath.fill()
            } else if !o.blurEnabled {
                NSColor.black.withAlphaComponent(0.8).setFill()
                bgPath.fill()
            }
            b.border.withAlphaComponent(0.95).setStroke()
            bgPath.lineWidth = 2
            bgPath.stroke()
            // Padding so the app's own squircle isn't flush with the
            // badge's rounded edge.
            let pad: CGFloat = 6
            b.icon.draw(in: b.rect.insetBy(dx: pad, dy: pad),
                        from: .zero, operation: .sourceOver,
                        fraction: 1.0,
                        respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Draw one card (fill + border + text). `alpha` multiplies into
    /// the CGContext so the entire card fades uniformly; `dx`/`dy`/
    /// `scale` place the rect through the exit animation. `armed`
    /// layers a live "would-fire-on-release" cue on top; `linePets`
    /// walk the rect's outline, independent of `armed` so the two
    /// stack. Only the firing card mid-stroke passes a non-`.off`
    /// armed or a non-empty `linePets`.
    private func drawCard(_ c: TrailView.CardLayout,
                          in o: TrailView,
                          alpha: CGFloat,
                          dx: CGFloat, dy: CGFloat, scale: CGFloat,
                          armed: ArmedEffect, linePets: [LinePet]) {
        // Chomp theme thickens every card border (the default
        // 1pt reads too thin against the neon-blue / rainbow
        // palette this theme uses); standard themes keep the 1pt
        // baseline. Corner radius stays uniform across both card
        // states — under chomp the firing card distinguishes
        // itself via the rainbow border (palette's
        // `cardsFiresBorderColor`) rather than a separate shape
        // treatment.
        let cornerR: CGFloat = 10
        let borderW: CGFloat = o.chomp != nil ? 3 : 1

        // Armed-cue transform contribution. `pulse` breathes the
        // whole card, `shake` jitters it; the rest decorate around
        // the rect without moving it, so they leave dx/scale alone.
        let nowArmed = CACurrentMediaTime()
        var armedDx = dx, armedScale = scale
        switch armed {
        case .pulse:
            // sin period ~0.6s, amplitude 6% scale (1.0 → 1.06)
            let phase = sin(nowArmed * (2 * .pi / 0.6))
            armedScale *= 1.0 + 0.03 + 0.03 * CGFloat(phase)
        case .shake:
            // ~24 Hz tremor, ±1.2 px peak — high freq, low amplitude
            // so it reads as "armed" rather than "exiting".
            armedDx += 1.2 * CGFloat(sin(nowArmed * 2 * .pi * 24))
        case .off, .glow, .sparkle, .marching:
            break
        }

        NSGraphicsContext.saveGraphicsState()
        if alpha < 1 {
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        }
        if armedDx != 0 || dy != 0 || armedScale != 1 {
            let cx = c.rect.midX, cy = c.rect.midY
            let tx = NSAffineTransform()
            tx.translateX(by: cx + armedDx, yBy: cy + dy)
            tx.scaleX(by: armedScale, yBy: armedScale)
            tx.translateX(by: -cx, yBy: -cy)
            tx.concat()
        }
        let bg = NSBezierPath(roundedRect: c.rect,
                              xRadius: cornerR, yRadius: cornerR)
        // Resolve cycle-driven colours once per card draw. Trail's
        // strobe period + stroke seed feed cards too, so trail and
        // borders cycle in lockstep (and splatoon picks the same
        // team colour each stroke).
        let now = CACurrentMediaTime()
        // Fill priority: firing card's accent > body-color knob >
        // transparent (historical). The firing accent stays loud so
        // the "fires on release" signal isn't lost when body-color
        // is set.
        let bodyFill = c.fill
            ?? o.cardBodyMode?.currentColor(at: now,
                                             strokeSeed: o.strokeSeed,
                                             cyclePeriod: o.colorCyclePeriod)
        if let fill = bodyFill {
            fill.setFill()
            bg.fill()
        }
        // Firing-card border priority: `cardFiresBorderMode` (theme
        // override for the firing state only) > `cardBorderMode`
        // (shared default for every card). Empty fires-border mode
        // falls back so themes that don't care about per-state
        // borders keep the historical "one border colour" behaviour.
        let borderMode: TrailColorMode
        if c.kind == .fires, let firesBorder = o.cardFiresBorderMode {
            borderMode = firesBorder
        } else {
            borderMode = o.cardBorderMode
        }
        let border = borderMode.currentColor(
            at: now, strokeSeed: o.strokeSeed,
            cyclePeriod: o.colorCyclePeriod)
        border.setStroke()
        bg.lineWidth = borderW
        bg.stroke()
        c.text.draw(with: c.rect.insetBy(dx: o.cardPadX, dy: o.cardPadY),
                    options: TrailView.textOpts)
        // Decorations that paint *around* the card rather than
        // transforming it. Drawn after text so they overlay any glyph
        // bleed at the edge. The `border` colour above feeds these so
        // they always read as the card's own accent.
        drawArmedDecoration(armed, on: c.rect, cornerR: cornerR,
                            accent: border, now: nowArmed, in: o)
        // Line-pets walk the card's outline, independent of `armed`.
        // Theme-agnostic: each pet's silhouette is its own colour
        // signature (yellow chomp / red ghost), so the array
        // renders the same under any `[cast].theme`. Pets chase each
        // other in array order — first leads, the rest trail by a
        // fixed `petChaseGapPt` so the listing reads as a chase
        // rather than evenly spaced dots. Pet sizes scale with
        // `cardFontSize` so a larger card font gets proportionally
        // larger pets — without this, the ghost shrinks visually as
        // the card grows.
        if !linePets.isEmpty {
            let petScale = max(1.0, o.cardFontSize / 13.0)
            // Shared sill drawing. `insetBy(-1)` keeps the pet riding ON
            // the card border (just outside it); cast runs a calmer 110
            // pt/s than the tome rim; chaseGap omitted = sill's 24*scale
            // default (== wand's prior `24 * petScale`).
            drawLinePets(linePets, on: c.rect.insetBy(dx: -1, dy: -1),
                         now: nowArmed, scale: petScale, speed: 110)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Continuous "armed" decoration drawn around the firing card
    /// while a stroke is in progress. Distinct from the in-card
    /// transform (`pulse` / `shake`) which is baked into `drawCard`'s
    /// affine — these kinds add separate paint passes around the
    /// existing card.
    private func drawArmedDecoration(_ armed: ArmedEffect,
                                      on rect: CGRect,
                                      cornerR: CGFloat,
                                      accent: NSColor,
                                      now: CFTimeInterval,
                                      in o: TrailView) {
        switch armed {
        case .off, .pulse, .shake:
            return
        case .glow:
            // Outer halo: a wider, softer stroke sitting outside the
            // rect, alpha pulsing on a ~0.7s cycle.
            let phase = 0.5 + 0.5 * sin(now * (2 * .pi / 0.7))
            let alpha = 0.25 + 0.45 * CGFloat(phase)
            let halo = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4),
                                    xRadius: cornerR + 4,
                                    yRadius: cornerR + 4)
            halo.lineWidth = 6
            accent.withAlphaComponent(alpha).setStroke()
            halo.stroke()
        case .sparkle:
            // Twinkles spaced around the card's perimeter. Positions
            // are deterministic per-slot (no RNG — would strobe across
            // frames anyway); brightness modulates with `now` so each
            // star blinks on its own phase offset.
            let starCount = 14
            let perim = 2 * (rect.width + rect.height)
            for i in 0..<starCount {
                // Anchor each slot at a fixed fraction of the perimeter
                // plus a per-slot jitter that drifts slowly so the
                // field doesn't feel locked to the rect's grid.
                let frac = (CGFloat(i) + 0.5) / CGFloat(starCount)
                let drift = 0.04 * CGFloat(sin(now * 0.6
                                                + Double(i) * 1.3))
                let walk = ((frac + drift)
                            .truncatingRemainder(dividingBy: 1.0)
                            + 1.0).truncatingRemainder(dividingBy: 1.0)
                    * perim
                // Outward offset so the star sits just outside the
                // rect; jitter on each slot keeps the ring uneven.
                let outset: CGFloat = 5
                    + 4 * abs(CGFloat(sin(Double(i) * 2.1)))
                var px: CGFloat = 0, py: CGFloat = 0
                let w = rect.width, h = rect.height
                if walk < w {
                    px = rect.minX + walk
                    py = rect.maxY + outset
                } else if walk < w + h {
                    px = rect.maxX + outset
                    py = rect.maxY - (walk - w)
                } else if walk < 2 * w + h {
                    px = rect.maxX - (walk - w - h)
                    py = rect.minY - outset
                } else {
                    px = rect.minX - outset
                    py = rect.minY + (walk - 2 * w - h)
                }
                let phase = sin(now * (2 * .pi / 0.9)
                                + Double(i) * 0.73)
                let a = max(0, CGFloat(phase))
                if a < 0.05 { continue }
                let r: CGFloat = 1.6
                let dot = NSBezierPath(ovalIn:
                    CGRect(x: px - r, y: py - r,
                           width: 2 * r, height: 2 * r))
                accent.withAlphaComponent(0.4 + 0.6 * a).setFill()
                dot.fill()
            }
        case .marching:
            // Dashed border whose dash phase advances over time —
            // "marching ants" reading. Drawn over the existing solid
            // border so the underlying colour bleeds through the gaps.
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: cornerR, yRadius: cornerR)
            let pattern: [CGFloat] = [6, 4]
            let phase = (now.truncatingRemainder(dividingBy: 1.0))
                * Double(pattern.reduce(0, +))
            path.setLineDash(pattern,
                             count: pattern.count,
                             phase: CGFloat(phase))
            path.lineWidth = 2
            accent.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }
        _ = o   // currently no kind needs the owner ref; held for future
    }

    /// Per-effect transform + alpha for an exiting card at `progress`
    /// (0..1 across the effect's duration). Cards rest with dx/dy=0,
    /// scale=1, alpha=1; the function eases them away on the chosen
    /// axis. Particle effects (`fireworks`, `confetti`) fade the card
    /// fast so the CAEmitterLayer carries the show.
    private func exitTransform(for effect: Effect,
                                progress p: CGFloat,
                                intensity k: CGFloat)
        -> (dx: CGFloat, dy: CGFloat, scale: CGFloat, alpha: CGFloat) {
        switch effect {
        case .off, .random:
            // .random is resolved at queue time; reaching it here
            // would mean a card slipped through unresolved — render
            // as an identity transform rather than crash.
            return (0, 0, 1, 1)
        case .drop:
            // Accelerating fall: y goes UP in Cocoa, so subtract.
            return (0, -240 * k * p * p, 1, 1 - p)
        case .rise:
            return (0, 120 * k * p, 1, 1 - p)
        case .slideLeft:
            return (-260 * k * p, 0, 1, 1 - p)
        case .slideRight:
            return (260 * k * p, 0, 1, 1 - p)
        case .explode:
            return (0, 0, 1 + 0.6 * k * p, 1 - p)
        case .vibrate:
            // Damped sine: 4 cycles, amplitude decays linearly.
            let dx = 10 * k * sin(p * .pi * 8) * (1 - p)
            return (dx, 0, 1, 1 - p)
        case .fade:
            return (0, 0, 1, 1 - p)
        case .fireworks, .confetti:
            // Fade card faster than the particles' duration so the
            // emitter visibly takes over.
            return (0, 0, 1, max(0, 1 - 2 * p))
        }
    }
}
