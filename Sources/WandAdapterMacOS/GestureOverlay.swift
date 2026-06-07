// Translucent gesture-trail HUD — the project's only on-screen UI
// (wand is otherwise headless / LSUIElement). Lives in the adapter
// layer next to EventTap because it's pure AppKit/CG rendering fed by
// the sample stream; Core stays UI-free (points cross the seam as
// plain `CGPoint`). Threading: `addPoint` / `clear` fire on the
// event-tap main-thread callback, which is where AppKit wants them.

import AppKit
import CoreGraphics
import WandCore

/// What the overlay shows next to the cursor: the shape drawn so far
/// (as arrows) plus the rules still reachable from it. Each row's
/// `suffix` is only the *remaining* arrows (the drawn prefix is
/// stripped — you already see it), and `fires` marks the rule the
/// current shape triggers right now (its suffix is empty).
public struct GestureHint: Sendable {
    public struct Row: Sendable {
        public let suffix: String
        public let name: String
        public let fires: Bool
        public init(suffix: String, name: String, fires: Bool) {
            self.suffix = suffix; self.name = name; self.fires = fires
        }
    }
    public let shape: String
    public let rows: [Row]
    public init(shape: String, rows: [Row]) {
        self.shape = shape; self.rows = rows
    }
}

@MainActor
public final class GestureOverlay {

    private let window: NSWindow
    private let view: TrailView

    /// Spin up the window + view, then funnel every `[overlay]` field
    /// through `applyConfig` so the init and hot-reload paths share
    /// one setter — no chance of a knob landing in only one of them.
    public init(_ cfg: WandConfig) {
        let frame = Self.unionFrame()
        let v = TrailView(frame: CGRect(origin: .zero, size: frame.size),
                          blurEnabled: cfg.overlay.blurEnabled)
        v.originOffset = frame.origin    // global Cocoa origin of the union
        self.view = v

        let w = NSWindow(contentRect: frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        // Force dark appearance so the `.menu` NSVisualEffectMaterial
        // renders dark even when the system is in light mode — matches
        // the launcher panel (which also forces darkAqua).
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true                 // click-through
        w.level = .screenSaver                       // above normal windows
        w.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary, .ignoresCycle]
        w.contentView = v
        self.window = w

        // Single source of truth: the same setter the hot-reload path
        // calls. Drops the four-fold knob threading the audit flagged.
        applyConfig(cfg)
    }

    /// Order the (empty, transparent) window on screen. Safe to call
    /// once at startup; it stays up for the daemon's lifetime and is
    /// invisible until points arrive.
    public func show() {
        window.orderFrontRegardless()
    }

    /// Append one trail point (CG global coords, Y-down). `valid`
    /// recolors the whole trail: the match color when the current
    /// shape fires a rule, the no-match color otherwise. `hint` (the
    /// shape-so-far + reachable rules) is drawn near the cursor.
    /// Coalesced redraws keep this cheap at the per-mouse-move rate.
    public func addPoint(_ cg: CGPoint, valid: Bool, hint: GestureHint?) {
        view.append(cg, valid: valid, hint: hint)
    }

    /// Set the target-app icon shown at the gesture's start point.
    /// Drawn only once a direction has emerged (so a plain click never
    /// flashes a badge). Caller resolves the icon (it's an AppKit type
    /// — Core can't see it), passing it in once per stroke.
    public func setOriginIcon(_ icon: NSImage?) {
        view.originIcon = icon
    }

    /// Apply a config change live — drives `[overlay]` hot-reload from
    /// `ConfigWatcher`. Every overlay field is reflected without a
    /// daemon restart, including `blur-enabled` (the blur subview is
    /// added or removed in place via `TrailView.setBlurEnabled`). The
    /// only restart-required overlay transition is `enabled = false → true`
    /// when the daemon was started with `enabled = false` (the window
    /// was never created, so there's nothing for `applyConfig` to
    /// attach to). The converse — visible at startup, hidden later —
    /// is handled here by ordering the window out, and re-shown on
    /// the next flip back.
    public func applyConfig(_ cfg: WandConfig) {
        let ov = cfg.overlay
        let palette = cfg.theme.palette
        view.matchMode = TrailColorMode.parse(
            ov.trail.color, fallback: .systemBlue)
        view.noMatchMode = TrailColorMode.parse(
            ov.trail.colorNoMatch, fallback: .systemRed)
        view.outlineMode = ov.trail.colorOutline.isEmpty
            ? nil
            : TrailColorMode.parse(ov.trail.colorOutline,
                                    fallback: .black)
        view.colorCyclePeriod = TimeInterval(ov.colorCycleMs) / 1000.0
        view.strokeWidth = CGFloat(ov.trail.width)
        view.trailStyle = ov.trail.style
        view.straightenOnTurn = ov.trail.straightenOnTurn
        view.badgeEnabled = ov.badge.enabled
        view.badgeSize = CGFloat(ov.badge.size)
        view.animEnabled = ov.badge.animEnabled
        view.setBlurEnabled(ov.blurEnabled)
        view.effectUnmatch = ov.cards.unmatch
        view.effectMatch = ov.cards.match
        view.cardFontSize = CGFloat(ov.cards.fontSize)
        // Card colours come exclusively from the theme palette
        // (per-card-colour knobs retired in #116). Empty palette
        // entries fall back to the historical hard-coded values
        // here, preserving the `theme = "default"` look.
        view.cardBorderMode = TrailColorMode.parse(
            palette.cardsBorderColor,
            fallback: NSColor.white.withAlphaComponent(0.18))
        view.cardBodyMode = palette.cardsBodyColor.isEmpty
            ? nil
            : TrailColorMode.parse(palette.cardsBodyColor,
                                    fallback: .clear)
        view.cardTextMode = palette.cardsTextColor.isEmpty
            ? .static(.white)
            : TrailColorMode.parse(palette.cardsTextColor,
                                    fallback: .white)
        view.cardFiresMode = palette.cardsFiresColor.isEmpty
            ? nil
            : TrailColorMode.parse(palette.cardsFiresColor,
                                    fallback: .systemBlue)
        view.cardFiresTextMode = palette.cardsFiresTextColor.isEmpty
            ? nil
            : TrailColorMode.parse(palette.cardsFiresTextColor,
                                    fallback: .white)
        view.effectIntensity = cfg.intensity.multiplier
        view.minStrokePx = CGFloat(cfg.recognition.minStrokePx)
        view.finalHoldDuration = TimeInterval(ov.trail.finalHoldMs) / 1000.0
        if ov.enabled {
            if !window.isVisible { window.orderFrontRegardless() }
        } else if window.isVisible {
            window.orderOut(nil)
        }
    }

    /// Clear the trail (stroke ended).
    public func clear() {
        view.reset()
    }


    /// Cocoa-coordinate union of every screen — the window covers the
    /// whole virtual desktop so a gesture on any display is drawn.
    private static func unionFrame() -> CGRect {
        let screens = NSScreen.screens
        guard var u = screens.first?.frame else {
            return NSScreen.main?.frame ?? .zero
        }
        for s in screens.dropFirst() { u = u.union(s.frame) }
        return u
    }


}


private final class TrailView: NSView {
    /// Resolved trail-colour mode for the matching side. `.static` is
    /// the historical hex/named-colour path; reserved tokens
    /// (`rainbow`, `neon`, `splatoon`) drive dynamic resolution at
    /// `draw(_:)` time. Set live from `[cast.overlay.trail].color`.
    var matchMode: TrailColorMode = .static(.systemBlue)
    /// Optional outline / underlay colour mode. `nil` = no outline
    /// (historical behaviour); set live from
    /// `[cast.overlay.trail].color-outline`. Each style renders the
    /// outline differently — see `outlineColor(for:)`.
    var outlineMode: TrailColorMode? = nil
    /// Same as `matchMode`, but for the no-match side
    /// (`[cast.overlay.trail].color-no-match`).
    var noMatchMode: TrailColorMode = .static(.systemRed)
    /// Per-stroke random seed used by `splatoon` mode so the trail
    /// stays one team's colour through the whole drag. Re-rolled at
    /// the start of each stroke (via `reset()`).
    var strokeSeed: UInt64 = UInt64.random(in: 0..<UInt64.max)
    /// Cycle period in seconds for the dynamic modes (`rainbow` /
    /// `neon`). Smaller = faster strobe; larger = slower drift. Set
    /// live from `[cast.overlay.trail].color-cycle-ms` divided by
    /// 1000. Ignored by static and `splatoon` modes.
    var colorCyclePeriod: TimeInterval = 2.0
    var strokeWidth: CGFloat = 3
    /// Named preset that swaps the trail's whole personality (width,
    /// glow, dash, per-segment color). Resolved from
    /// `[gesture.overlay].trail-style` and reflected live via
    /// `GestureOverlay.applyConfig(_:)`. Heavier styles
    /// (`brush` / `splatoon` / …) are reserved for follow-up PRs of #63
    /// and not represented in this enum yet.
    var trailStyle: TrailStyle = .normal
    // `arrowheadEnabled` was retired in #115 — the cursor-only tip
    // is gone; `style = .arrow` provides direction along the whole
    // path instead.
    /// When `true` (default), every committed turn snaps the
    /// just-completed segment onto its axis so the trail reads as a
    /// clean orthogonal polyline — the historical hard-coded
    /// behaviour. When `false`, every sample is rendered as raw
    /// freehand (the trail follows the actual mouse path, jitter
    /// included). Recognition is unaffected — this only changes how
    /// the trail is drawn, not how directions are detected. Set live
    /// from `[cast.overlay.trail].straighten-on-turn`.
    var straightenOnTurn: Bool = true
    /// Cocoa-global origin of the window; subtracted to get view-local
    /// coords from a global point.
    var originOffset: CGPoint = .zero
    /// User-visible knobs from `[overlay]`. All hot-reloadable via
    /// `GestureOverlay.applyConfig(_:)` — colours and toggles update
    /// without restart; `setBlurEnabled` even adds/removes the
    /// `NSVisualEffectView` subview in place.
    fileprivate var blurEnabled: Bool
    var badgeEnabled: Bool = true
    var badgeSize: CGFloat = 56
    var animEnabled: Bool = true
    /// Exit-animation kinds from `[effect]`. Typed values come straight
    /// from `WandConfig` — `GestureOverlay.applyConfig` assigns them
    /// on init + hot-reload.
    var effectUnmatch: Effect = .none
    var effectMatch: Effect = .none
    /// Base font size for assist-card text (set live from
    /// `[cast.overlay.cards].font-size`). The arrow column rides at
    /// `cardFontSize + 1` so directional glyphs stay a hair taller
    /// than rule names. The card padding is fixed in pt, so a bigger
    /// font expands the card naturally.
    var cardFontSize: CGFloat = 13
    /// Border stroke mode for assist cards (set live from
    /// `[cast.overlay.cards].border-color`). `.static` covers the
    /// historical hex/named path; dynamic tokens (`rainbow` / `neon`
    /// / `splatoon`) animate alongside the trail using the same
    /// cycle period and stroke seed.
    var cardBorderMode: TrailColorMode = .static(
        NSColor.white.withAlphaComponent(0.18))
    /// Body fill mode for **non-firing** assist cards (set live from
    /// `[cast.overlay.cards].body-color`). `nil` = transparent
    /// (historical behaviour). The firing card always gets the
    /// trail-accent tint regardless of this — so the "fires on
    /// release" signal stays loud.
    var cardBodyMode: TrailColorMode? = nil
    /// Text colour mode for assist-card labels (rule name + direction
    /// arrows). Set live from `[cast.overlay.cards].text-color`;
    /// `.static(.white)` is the fallback for the historical
    /// hard-coded white. Dynamic tokens (`rainbow` / `neon` /
    /// `splatoon`) animate alongside the trail using the same cycle
    /// period and stroke seed.
    var cardTextMode: TrailColorMode = .static(.white)
    /// Body fill mode for the **firing** card (`nil` = inherit the
    /// trail accent, the historical default). Set live from
    /// `[cast.overlay.cards].fires-color`. Themes can flash the
    /// firing card in a different palette from the trail.
    var cardFiresMode: TrailColorMode? = nil
    /// Text colour mode for the firing card only (`nil` = inherit
    /// `cardTextMode`, the same text colour as directional cards).
    /// Set live from `[cast.overlay.cards].fires-text-color`. Lets
    /// a theme invert the firing card cleanly — e.g. directional
    /// cards run yellow-on-black and the firing card flips to
    /// black-on-yellow.
    var cardFiresTextMode: TrailColorMode? = nil
    /// Pre-resolved multiplier from `Intensity.multiplier` — scales
    /// translation distance, scale deltas, vibration amplitude, and
    /// particle birth-rate / velocity.
    var effectIntensity: CGFloat = 1.0
    /// Per-segment displacement threshold used to commit a direction
    /// — the same value `Recognition.recognize` uses, so the visual
    /// polyline elbows match where rules actually break a segment.
    var minStrokePx: CGFloat = 16

    /// Polyline state. `origin` = button-down point (badge anchor);
    /// `cursor` = latest sample (line head + HUD anchor); `corners` =
    /// every committed turn point in between. The trail is a hybrid:
    /// `origin → corners` draws as Figma-style orthogonal straight
    /// segments (the *confirmed* part — only finalised once the user
    /// turns), and `corners.last → freehandPoints → cursor` draws as
    /// the raw freehand tail of the current (un-confirmed) segment.
    /// Every `曲がる` (direction change) snaps the freehand tail into
    /// a new straight segment and restarts a fresh freehand.
    fileprivate var origin: CGPoint?
    fileprivate var cursor: CGPoint?
    fileprivate var corners: [CGPoint] = []
    /// Raw mouse samples for the *current* (un-confirmed) segment —
    /// `freehandPoints[0]` is the segment start (= `corners.last ??
    /// origin`), the rest are subsequent samples, and the last is
    /// `cursor`. Reset on every corner commit so the new segment
    /// starts at the snapped corner.
    private var freehandPoints: [CGPoint] = []
    /// Every raw mouse sample of the in-progress stroke, never
    /// trimmed at corner commits. Drives the `straightenOnTurn=false`
    /// render path so the trail shows the literal hand path. Reset
    /// in `_actualReset` alongside the other stroke state.
    private var rawTrail: [CGPoint] = []
    /// Index in `freehandPoints` of the most recent anchor update —
    /// samples *after* this index are the transition between the old
    /// anchor and the current sample, and get carried over into the
    /// next segment's freehand at corner-commit time (so the visual
    /// doesn't snap-jump from the snapped corner to the raw cursor).
    private var anchorIndex: Int = 0
    /// Live recognition state — mirrors `Recognition.recognize`:
    /// `anchor` is the point from which the next segment is being
    /// measured; `lastDir` is the most recently committed direction.
    /// When the next sample exceeds `minStrokePx` from `anchor` AND
    /// the dominant axis differs from `lastDir`, the current `anchor`
    /// is promoted to a corner.
    private var anchor: CGPoint?
    private var lastDir: Direction?
    fileprivate var valid = true            // current match state of the trail
    fileprivate var hint: GestureHint?      // shape + reachable rules
    /// Icon of the target app the gesture is acting on, drawn as a
    /// small badge at `origin`. Tells the user "you're operating
    /// on Chrome (the cursor-anchored window), even though VSCode has
    /// keyboard focus" — the whole reason cursor-anchored exists.
    var originIcon: NSImage?
    /// Time the badge first appeared (the first sample with hint set).
    /// Drives the scale-in animation. Reset to nil on stroke end.
    private var badgeAppearedAt: TimeInterval?

    /// Card identity for diffing across layout passes. `direction(c)`
    /// keys directional cards by their first arrow; `fires` keys the
    /// firing card. When a kind present in the previous layout is
    /// absent from the new one, that card "became unmatched" mid-
    /// gesture and triggers `effectUnmatch`.
    fileprivate enum CardKind: Hashable {
        case direction(Character)
        case fires
    }

    /// Swap `.random` for a concrete pick at queue time — per-card,
    /// so successive unmatch cards in one stroke each get their own
    /// dice roll. Other kinds pass through unchanged.
    fileprivate func resolveRandom(_ effect: Effect) -> Effect {
        guard effect == .random else { return effect }
        return Effect.randomPool.randomElement() ?? .none
    }

    /// Pre-computed positions of the currently-visible HUD elements.
    /// Single source of truth shared by the blur-mask updater (only
    /// these regions get vibrant blur) and `HUDContentView` (which
    /// draws the tint / border / text / icon on top of the blur).
    /// Rebuilt every `append` / `reset`.
    fileprivate struct CardLayout {
        let kind: CardKind
        let rect: CGRect
        let text: NSAttributedString
        let fill: NSColor?   // nil → frosted only; set → tint over frost
    }
    fileprivate struct BadgeLayout {
        let rect: CGRect
        let icon: NSImage
        let border: NSColor
        let scale: CGFloat
    }
    /// One card that's animating out — kept around past `layoutHUD`
    /// so its exit effect plays to completion regardless of subsequent
    /// state changes. Pruned by `tickExitAnimations` when the elapsed
    /// time exceeds the effect's duration.
    fileprivate struct ExitingCard {
        let layout: CardLayout
        let effect: Effect
        let startedAt: TimeInterval
    }
    fileprivate var cardLayouts: [CardLayout] = []
    fileprivate var badgeLayout: BadgeLayout?
    /// Last layoutHUD's cards, keyed by `CardKind`. Used to detect
    /// disappearing cards across passes and emit unmatch effects.
    private var prevCardsByKind: [CardKind: CardLayout] = [:]
    /// In-flight exit animations. Drained by `tickExitAnimations`.
    fileprivate var exitingCards: [ExitingCard] = []
    /// True while a `tickExitAnimations` is queued on the main loop —
    /// `kickExitAnimationTick` checks it before scheduling, so the
    /// concurrent `layoutHUD` + `reset` callers can't stack timers
    /// that then each reschedule themselves into an avalanche.
    private var tickScheduled = false
    /// Hold-and-fade for the trail when a rule fires. Set in `reset()`
    /// when the fires card was on screen at mouse-up. While true the
    /// trail keeps drawing (snapped to clean orthogonal lines via
    /// `commitFinalSegment`) instead of vanishing instantly, so the
    /// user sees the completed gesture as a tidy polyline for a beat
    /// before it fades out.
    fileprivate var holdingFinal: Bool = false
    fileprivate var finalizeStartedAt: TimeInterval?
    /// Seconds the post-fire snapped trail stays visible (hold +
    /// fade). Sourced from `[gesture.overlay].final-hold-ms`; `0`
    /// disables the hold and falls back to immediate clear.
    /// Reflected live via `GestureOverlay.applyConfig(_:)`.
    fileprivate var finalHoldDuration: TimeInterval = 0.40

    /// Behind-window vibrant blur, masked to the union of all current
    /// card + badge rounded rects so blur only appears where the HUD
    /// actually is — the rest of the overlay window stays fully
    /// transparent.
    private let blurView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        // `.menu` (not `.hudWindow`) so the vibrant frost matches the
        // launcher panel — same color/translucency the system uses
        // for context menus.
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.autoresizingMask = [.width, .height]
        return v
    }()

    /// HUD overlay drawn ON TOP of `blurView`: optional tint, hair
    /// border, text, icon. Subview ordering (blurView at index 0,
    /// hudContent at index 1) gives us the right z-stack without
    /// fighting AppKit's "subviews always above parent's draw" rule.
    fileprivate let hudContent: HUDContentView = {
        let v = HUDContentView()
        v.autoresizingMask = [.width, .height]
        return v
    }()

    init(frame frameRect: NSRect, blurEnabled: Bool = true) {
        self.blurEnabled = blurEnabled
        super.init(frame: frameRect)
        wantsLayer = true
        hudContent.frame = bounds
        if blurEnabled {
            blurView.frame = bounds
            // Empty mask initially — no HUD until a sample arrives.
            let mask = CAShapeLayer()
            mask.fillColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            blurView.layer?.mask = mask
            addSubview(blurView)
        }
        addSubview(hudContent)
        hudContent.owner = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }   // Cocoa default (Y-up)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // click-through

    /// Convert a CG global point (Y-down) to view-local (Y-up) coords.
    func append(_ cg: CGPoint, valid: Bool, hint: GestureHint?) {
        // A new stroke is starting while the previous fire is still
        // holding its snapped polyline — collapse the hold instantly
        // so the new gesture's trail doesn't overlay the old one.
        if holdingFinal {
            _actualReset()
        }
        if self.hint == nil && hint != nil {
            badgeAppearedAt = CACurrentMediaTime()
        }
        self.valid = valid
        self.hint = hint
        let cocoa = ScreenCoords.cocoaPoint(fromCG: cg)
        let p = CGPoint(x: cocoa.x - originOffset.x,
                        y: cocoa.y - originOffset.y)
        if origin == nil {
            origin = p
            anchor = p
            freehandPoints.removeAll(keepingCapacity: true)
            rawTrail.removeAll(keepingCapacity: true)
            rawTrail.append(p)
            anchorIndex = 0
        }
        cursor = p
        // Live direction tracking — same algorithm as
        // `Recognition.recognize` so the polyline elbows land
        // exactly where the recogniser would split a segment.
        var anchorUpdated = false
        if let a = anchor {
            let dx = p.x - a.x, dy = p.y - a.y
            let absX = abs(dx), absY = abs(dy)
            if max(absX, absY) >= minStrokePx {
                let dir: Direction =
                    absX >= absY ? (dx >= 0 ? .right : .left)
                                 : (dy >= 0 ? .up    : .down)
                if let last = lastDir, last != dir {
                    // Project the corner onto the previous segment's
                    // axis so the polyline is strictly orthogonal —
                    // raw `anchor` carries hand-jitter perpendicular
                    // to the intended direction.
                    let segStart = corners.last ?? origin ?? a
                    let corner = Self.snap(a, to: last, from: segStart)
                    corners.append(corner)
                    // Restart the freehand tail at the new corner.
                    // Carry over samples that arrived *after* the last
                    // anchor update — those were the user's actual
                    // transition motion into the new direction, so the
                    // new segment's freehand picks up smoothly from the
                    // corner instead of jumping straight to `p`.
                    let transitionStart = anchorIndex + 1
                    let transition: ArraySlice<CGPoint> =
                        transitionStart < freehandPoints.count
                        ? freehandPoints[transitionStart...]
                        : []
                    freehandPoints = [corner] + transition
                }
                lastDir = dir
                anchor = p
                anchorUpdated = true
            }
        }
        freehandPoints.append(p)
        rawTrail.append(p)
        if anchorUpdated {
            anchorIndex = freehandPoints.count - 1
        }
        layoutHUD()
        needsDisplay = true
        hudContent.needsDisplay = true
    }

    func reset() {
        guard origin != nil || hint != nil || originIcon != nil
        else { return }
        // If a `fires` card was on-screen the moment the user released,
        // a rule actually triggered — animate that card out with the
        // match effect. Clearing `prevCardsByKind` first prevents the
        // layoutHUD diff below from double-queueing it (and from
        // queueing unmatch effects for the directional cards that are
        // simply going away with the rest of the HUD).
        if effectMatch != .none, let fires = prevCardsByKind[.fires] {
            let now = CACurrentMediaTime()
            let e = resolveRandom(effectMatch)
            exitingCards.append(ExitingCard(
                layout: fires, effect: e, startedAt: now))
            scheduleParticleEffect(fires, effect: e)
        }
        // `prevCardsByKind` is only kept current when `effectMatch` /
        // `effectUnmatch` is configured (layoutHUD gates the update on
        // it), so we can't rely on it here. Detect fire directly from
        // the last `hint`: any row with an empty suffix == a `.fires`
        // card == the current shape exactly matches a rule.
        let firedThisStroke = hint?.rows.contains { $0.suffix.isEmpty }
                              ?? false
        prevCardsByKind.removeAll()

        // The trail-end burst used to fire here in v4; v5 moved it
        // into a standalone `BurstManager` so the burst still fires
        // when `[gesture.overlay].enabled = false`. The manager is
        // driven by the same `Controller.onGestureFire` hook the
        // decal uses.

        // Rule fired: snap the in-progress freehand onto the lastDir
        // axis so the completed gesture renders as a clean orthogonal
        // polyline, then hold for a beat before clearing. Skipped when
        // already holding (re-entrant `reset` during the hold), and
        // skipped when nothing fired (immediate clear, as before).
        if firedThisStroke && !holdingFinal && finalHoldDuration > 0 {
            commitFinalSegment()
            hint = nil
            originIcon = nil
            badgeAppearedAt = nil
            cardLayouts.removeAll()
            badgeLayout = nil
            holdingFinal = true
            finalizeStartedAt = CACurrentMediaTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + finalHoldDuration) {
                [weak self] in
                guard let self = self, self.holdingFinal else { return }
                self._actualReset()
            }
            layoutHUD()
            needsDisplay = true
            hudContent.needsDisplay = true
            kickExitAnimationTick()
            return
        }

        _actualReset()
    }

    /// Snap the in-progress freehand tail into a final straight segment
    /// along `lastDir`. Mirrors the corner-on-turn snap, but applied at
    /// stroke-end against `cursor` so the gesture's last leg also lands
    /// as a clean orthogonal segment when a rule actually fires.
    private func commitFinalSegment() {
        guard let lastDir, let cursor else { return }
        let segStart = corners.last ?? origin ?? cursor
        let snappedEnd = Self.snap(cursor, to: lastDir, from: segStart)
        corners.append(snappedEnd)
        freehandPoints = [snappedEnd]
        self.cursor = snappedEnd
    }

    /// The real reset — null out every piece of trail / HUD state and
    /// nudge a redraw. `reset()` defers here either immediately (no
    /// fire) or after `finalHoldDuration` (fire).
    private func _actualReset() {
        holdingFinal = false
        finalizeStartedAt = nil
        origin = nil
        cursor = nil
        corners.removeAll(keepingCapacity: true)
        freehandPoints.removeAll(keepingCapacity: true)
        rawTrail.removeAll(keepingCapacity: true)
        anchorIndex = 0
        anchor = nil
        lastDir = nil
        hint = nil
        originIcon = nil
        badgeAppearedAt = nil
        cardLayouts.removeAll()
        badgeLayout = nil
        // Re-roll the stroke seed so the NEXT stroke's `splatoon`-
        // mode trail picks a different team colour. The seed is also
        // ignored by static / rainbow / neon modes (they read time
        // or the literal colour), so the cost is one cheap roll per
        // stroke end across the board.
        strokeSeed = UInt64.random(in: 0..<UInt64.max)
        layoutHUD()
        needsDisplay = true
        hudContent.needsDisplay = true
        kickExitAnimationTick()
    }

    /// Add or remove the blur subview in place when `[overlay]
    /// blur-enabled` flips during a hot-reload. No-op if already at
    /// the requested state.
    func setBlurEnabled(_ enabled: Bool) {
        guard enabled != blurEnabled else { return }
        blurEnabled = enabled
        if enabled {
            if blurView.superview == nil {
                blurView.frame = bounds
                if blurView.layer?.mask == nil {
                    let mask = CAShapeLayer()
                    mask.fillColor = CGColor(srgbRed: 0, green: 0,
                                              blue: 0, alpha: 1)
                    blurView.layer?.mask = mask
                }
                // Keep hudContent on top of the blur, where it was at
                // first-launch wiring.
                addSubview(blurView,
                           positioned: .below, relativeTo: hudContent)
            }
        } else {
            blurView.removeFromSuperview()
        }
        layoutHUD()
        needsDisplay = true
        hudContent.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let origin, let cursor,
              origin != cursor || !corners.isEmpty
        else { return }
        // Resolve the current frame's colour from the active mode.
        // For dynamic modes (`rainbow` / `neon`) `CACurrentMediaTime`
        // drives the cycle; for `splatoon` the per-stroke seed picks
        // one team's colour and holds it. Static modes are a no-op
        // lookup.
        let mode = valid ? matchMode : noMatchMode
        let color = mode.currentColor(at: CACurrentMediaTime(),
                                       strokeSeed: strokeSeed,
                                       cyclePeriod: colorCyclePeriod)
        let outlineColor: NSColor? = outlineMode?.currentColor(
            at: CACurrentMediaTime(),
            strokeSeed: strokeSeed,
            cyclePeriod: colorCyclePeriod)

        // While holding the post-fire snapped polyline, fade the trail
        // out over the last third of the hold so it doesn't pop off.
        var alpha: CGFloat = 1.0
        if holdingFinal, let t0 = finalizeStartedAt {
            let elapsed = CACurrentMediaTime() - t0
            let fadeStart = finalHoldDuration * 0.66
            if elapsed > fadeStart {
                let p = (elapsed - fadeStart) / (finalHoldDuration - fadeStart)
                alpha = max(0.0, 1.0 - CGFloat(p))
            }
        }

        NSGraphicsContext.saveGraphicsState()
        if alpha < 1.0 {
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        }

        // Every remaining style shares the hybrid corner + freehand
        // polyline and only swaps the dash pattern. Colour always
        // comes from the resolved `color` so the match-vs-no-match
        // signal stays legible regardless of dash. Width / glow /
        // taper variants (`thin` / `thick` / `glow` / `comet`) were
        // retired — `width` and the future neon/rainbow colour
        // modes cover their use cases without a separate axis.
        switch trailStyle {
        case .normal, .dashed, .dotted:
            drawSinglePath(origin: origin, cursor: cursor,
                            color: color, outline: outlineColor)
        case .pixel:
            drawPixelPath(origin: origin, cursor: cursor,
                           color: color, outline: outlineColor)
        case .ascii:
            drawAsciiPath(origin: origin, cursor: cursor,
                           color: color, outline: outlineColor)
        case .rainbowRoad:
            drawRainbowRoadPath(origin: origin, cursor: cursor,
                                 color: color, outline: outlineColor)
        case .pacman:
            drawPacmanPath(origin: origin, cursor: cursor,
                            color: color, outline: outlineColor)
        case .arrow:
            drawArrowChainPath(origin: origin, cursor: cursor,
                                color: color, outline: outlineColor)
        case .paws:
            drawPawsPath(origin: origin, cursor: cursor,
                          color: color, outline: outlineColor)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Build the standard hybrid corner-smoothed + freehand polyline
    /// path used by every single-color style. Centralised so dashed /
    /// dotted / glow / thin / thick all share the same geometry and
    /// only differ in stroke parameters.
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

        // Straight part: origin → corners, with each interior corner
        // softened by a quadratic-style bezier (radius capped to half
        // each adjacent segment so tight corners never overshoot).
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

    /// Render a single-color trail. `normal` / `thin` / `thick` / `glow`
    /// / `dashed` / `dotted` all funnel through here — they only differ
    /// in lineWidth, glow radius, and dash pattern. When `outline` is
    /// set, the same path is stroked first with a wider line in the
    /// outline colour so the main stroke reads against backgrounds
    /// that would otherwise swallow it.
    private func drawSinglePath(origin: CGPoint, cursor: CGPoint,
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
        case .pixel, .ascii, .rainbowRoad, .pacman, .arrow,
             .paws:
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
        // path before emitting — used by the Pac-Man style to leave a
        // visible gap between the trailing pellets and the cursor's
        // face, so it reads as Pac-Man running ahead of the trail.
        // When set, compute total length once and derive the cutoff
        // distance; bail early if there isn't enough path to clear
        // the trim.
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
                    // cutoff position so callers (Pac-Man face) can
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
    /// to read as ドット絵 rather than a chunky bar. `strokeWidth`
    /// no longer drives this — it drives the thickness (cells across
    /// the path) instead.
    private static let pixelCellSize: CGFloat = 5

    /// 8-bit / pixel-art style: quantise the path to a fixed-size
    /// square grid and fill cells along the path. `strokeWidth` is
    /// re-purposed here as **thickness in cells**: a `width = 3`
    /// trail lays down a 3-cell-wide stripe perpendicular to the
    /// path. Colour comes from the resolved trail colour. Cells are
    /// de-duplicated via a Set so overlapping stripes never overdraw.
    private func drawPixelPath(origin: CGPoint, cursor: CGPoint,
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
                // Outline = full-cell outline-colour fill, then a
                // 1pt-inset main-colour fill on top. Adjacent cells
                // don't overdraw each other because both rects are
                // contained within the cell's own grid square.
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
    private func drawAsciiPath(origin: CGPoint, cursor: CGPoint,
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
                // Centre the glyph on the offset point.
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
    private func drawRainbowRoadPath(origin: CGPoint, cursor: CGPoint,
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

    /// Fixed sizes for the Pac-Man trail. Pellet = small dot lining
    /// the path; face = larger wedge that lags behind the cursor by
    /// `pacmanFaceLag` pt so it reads as Pac-Man running along the
    /// trail rather than sitting flat on the cursor.
    private static let pacmanPelletDiameter: CGFloat = 4
    private static let pacmanPelletInterval: CGFloat = 14
    private static let pacmanFaceRadius: CGFloat = 10
    /// Mouth half-angle bounds (degrees). The face animates between
    /// these via `cos`, giving the classic open-close chomp.
    /// `min` is just above zero so the mouth doesn't fully close
    /// (a sealed circle reads as "not Pac-Man anymore").
    private static let pacmanMouthHalfAngleMinDeg: CGFloat = 5
    private static let pacmanMouthHalfAngleMaxDeg: CGFloat = 45
    /// Chomp frequency (Hz). The cosine drive makes one full
    /// open→close→open cycle per period; ~4 Hz lands near the feel
    /// of the original arcade animation.
    private static let pacmanChompHz: Double = 4
    /// How far back along the path Pac-Man's face sits behind the
    /// live cursor (pt). Tuned by feel — too small reads as
    /// "Pac-Man sitting on the cursor" (no chase), too large feels
    /// like Pac-Man can never catch up. 50pt = roughly 2.5 face
    /// widths of gap, which lands as "actively chasing".
    private static let pacmanFaceLag: CGFloat = 50

    /// Pac-Man-themed trail: the cursor lays a single line of pellet
    /// dots along the path (origin → cursor), and the Pac-Man face
    /// chases along that same path `pacmanFaceLag` pt behind the
    /// cursor. `strokeWidth` is interpreted as a **scale multiplier**
    /// here — `width = 1` gives the default pellet / face size and
    /// spacing, higher values scale everything up proportionally.
    /// The arcade aesthetic is always a single line of pellets, so
    /// thickness rows would fight the visual.
    private func drawPacmanPath(origin: CGPoint, cursor: CGPoint,
                                 color: NSColor, outline: NSColor?) {
        let scale = max(1, strokeWidth)
        let dot = Self.pacmanPelletDiameter * scale
        let interval = Self.pacmanPelletInterval * scale
        let faceLag = Self.pacmanFaceLag * scale
        let faceRadius = Self.pacmanFaceRadius * scale
        let pelletFill = color.withAlphaComponent(0.9)
        let outlineFill = outline?.withAlphaComponent(0.9)
        let outlinePad = max(1, scale)

        // 1) Locate where Pac-Man's face sits this frame: walk the
        // path with the lag as `trimTail` — the final step the walker
        // emits is exactly the cutoff point. Skip drawing in this
        // pass; we only need the coordinate + tangent.
        var faceAnchor: (point: CGPoint, tangent: CGPoint)?
        walkPath(origin: origin,
                 interval: interval,
                 trimTail: faceLag) { p, tangent in
            faceAnchor = (p, tangent)
        }

        // 2) Draw the pellets across the full path (no trim) so the
        // dot trail extends from origin all the way to the cursor.
        // Single line — no thickness stacking.
        let plot: (CGPoint, CGPoint) -> Void = { p, _ in
            if let outlineFill {
                outlineFill.setFill()
                let outer = NSRect(x: p.x - dot / 2 - outlinePad,
                                   y: p.y - dot / 2 - outlinePad,
                                   width: dot + outlinePad * 2,
                                   height: dot + outlinePad * 2)
                NSBezierPath(ovalIn: outer).fill()
            }
            pelletFill.setFill()
            let rect = NSRect(x: p.x - dot / 2, y: p.y - dot / 2,
                              width: dot, height: dot)
            NSBezierPath(ovalIn: rect).fill()
        }
        walkPath(origin: origin, interval: interval, step: plot)

        // 3) Draw the face. Path too short for a meaningful lag (just
        // pressed the button) → fall back to the cursor so the face
        // is visible immediately instead of hiding for the first
        // stretch of motion.
        if let anchor = faceAnchor {
            drawPacmanFace(at: anchor.point, tangent: anchor.tangent,
                            radius: faceRadius,
                            color: color, outline: outline)
        } else {
            drawPacmanFace(at: cursor, tangent: CGPoint(x: 1, y: 0),
                            radius: faceRadius,
                            color: color, outline: outline)
        }
    }

    /// Draw a closed pie wedge centred on `p`, with the mouth
    /// opening (an angular slice cut out) facing along `tangent`.
    /// The mouth half-angle oscillates between
    /// `pacmanMouthHalfAngleMin/MaxDeg` at `pacmanChompHz` so the
    /// face chomps as it travels. Angles are in degrees for
    /// `NSBezierPath.appendArc`; the wedge sweeps the long way
    /// around (counter-clockwise from `+mouthHalf` to `-mouthHalf`)
    /// so the "closed" portion of the face fills.
    private func drawPacmanFace(at p: CGPoint, tangent: CGPoint,
                                 radius: CGFloat,
                                 color: NSColor, outline: NSColor?) {
        // Cosine remap to [0, 1]: 0 at min mouth, 1 at max mouth.
        let phase = (1 - cos(CACurrentMediaTime() * 2 * .pi
                              * Self.pacmanChompHz)) / 2
        let mouthHalf = Self.pacmanMouthHalfAngleMinDeg
            + (Self.pacmanMouthHalfAngleMaxDeg
                - Self.pacmanMouthHalfAngleMinDeg) * CGFloat(phase)
        let dirDeg = atan2(tangent.y, tangent.x) * 180 / .pi
        let startDeg = dirDeg + mouthHalf
        let endDeg = dirDeg - mouthHalf
        // Optional outer wedge in the outline colour. Rim width
        // scales with the face radius so it stays proportionally
        // visible at any `strokeWidth`.
        if let outline {
            let outer = NSBezierPath()
            outer.move(to: p)
            outer.appendArc(withCenter: p,
                             radius: radius + max(1.5, radius * 0.15),
                             startAngle: startDeg, endAngle: endDeg,
                             clockwise: false)
            outer.close()
            outline.withAlphaComponent(0.95).setFill()
            outer.fill()
        }
        let path = NSBezierPath()
        path.move(to: p)
        path.appendArc(withCenter: p, radius: radius,
                        startAngle: startDeg, endAngle: endDeg,
                        clockwise: false)
        path.close()
        color.withAlphaComponent(0.95).setFill()
        path.fill()
    }

    /// Snap `p` onto the axis defined by `dir` and the point `from` —
    /// horizontal directions preserve `from.y`, vertical preserve
    /// `from.x`. Used in two places: committing a corner that sits on
    /// the previous segment's axis, and projecting the live cursor
    /// onto the current segment's axis.
    private static func snap(_ p: CGPoint, to dir: Direction,
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
    private func drawArrowChainPath(origin: CGPoint, cursor: CGPoint,
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

    // MARK: - Paws style constants

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
    /// treatment as the pacman pellet outline. `strokeWidth` is
    /// re-purposed as a scale multiplier on every dimension.
    private func drawPawsPath(origin: CGPoint, cursor: CGPoint,
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

    // MARK: - HUD layout

    private let badgeAnimDuration: TimeInterval = 0.15

    /// Compute every HUD region's rect (cards + optional badge),
    /// update the blur mask path to match, and store the layouts so
    /// `HUDContentView` can draw text / borders / icon on top. Called
    /// from `append` (state change) and during the badge scale-in.
    private func layoutHUD() {
        cardLayouts.removeAll()
        badgeLayout = nil

        // Same resolver the trail uses — dynamic modes get the current
        // time + the stroke seed + the cycle period; static modes pass
        // through.
        let mode = valid ? matchMode : noMatchMode
        let accent = mode.currentColor(at: CACurrentMediaTime(),
                                        strokeSeed: strokeSeed,
                                        cyclePeriod: colorCyclePeriod)

        if let hint, let cursor = cursor {
            var byDir: [Character: [GestureHint.Row]] = [:]
            var fires: [GestureHint.Row] = []
            for row in hint.rows {
                if let first = row.suffix.first {
                    byDir[first, default: []].append(row)
                } else {
                    fires.append(row)
                }
            }
            let gap: CGFloat = 24
            for (arrow, rows) in byDir {
                let s = cardText(rows, textMode: cardTextMode)
                let size = cardSize(s)
                let o: CGPoint
                switch arrow {
                case "←": o = CGPoint(x: cursor.x - gap - size.width, y: cursor.y - size.height / 2)
                case "→": o = CGPoint(x: cursor.x + gap,               y: cursor.y - size.height / 2)
                case "↑": o = CGPoint(x: cursor.x - size.width / 2,    y: cursor.y + gap)
                case "↓": o = CGPoint(x: cursor.x - size.width / 2,    y: cursor.y - gap - size.height)
                default:  o = CGPoint(x: cursor.x + gap, y: cursor.y + gap)
                }
                cardLayouts.append(CardLayout(
                    kind: .direction(arrow),
                    rect: clampedCardRect(at: o, size: size),
                    text: s, fill: nil))
            }
            if !fires.isEmpty {
                let s = cardText(fires,
                                  textMode: cardFiresTextMode
                                    ?? cardTextMode)
                let size = cardSize(s)
                // Fires card fill: accent on its own over blur (alpha
                // 0.5 lets the frost show through). Without blur the
                // dark backdrop is missing too, so the tint goes more
                // opaque to keep the card a distinct surface.
                let firesAlpha: CGFloat = blurEnabled ? 0.5 : 0.78
                // Collision avoidance: when the user has rules that
                // share a prefix (e.g. `DL` + `DLU` + `DLU`), the
                // fires card's natural upper-right anchor overlaps
                // the ↑ directional card's rectangle. Try each
                // diagonal anchor in turn and pick the first one
                // that doesn't intersect any directional card. Order
                // — ↗ ↘ ↙ ↖ — keeps the natural diagonal first so
                // the simple case (no collision) is unchanged.
                let anchors: [CGPoint] = [
                    CGPoint(x: cursor.x + gap,
                            y: cursor.y + gap),
                    CGPoint(x: cursor.x + gap,
                            y: cursor.y - gap - size.height),
                    CGPoint(x: cursor.x - gap - size.width,
                            y: cursor.y - gap - size.height),
                    CGPoint(x: cursor.x - gap - size.width,
                            y: cursor.y + gap),
                ]
                var firesRect = clampedCardRect(at: anchors[0], size: size)
                for a in anchors {
                    let r = clampedCardRect(at: a, size: size)
                    if !cardLayouts.contains(where: { $0.rect.intersects(r) }) {
                        firesRect = r
                        break
                    }
                }
                // Firing card body: theme/config can override the
                // historical "trail accent as fill" with its own
                // palette (e.g. pacman's rainbow flash) via
                // `cardFiresMode`. Fall back to the trail accent
                // when unset.
                let firesBase = cardFiresMode?.currentColor(
                    at: CACurrentMediaTime(),
                    strokeSeed: strokeSeed,
                    cyclePeriod: colorCyclePeriod) ?? accent
                cardLayouts.append(CardLayout(
                    kind: .fires,
                    rect: firesRect, text: s,
                    fill: firesBase.withAlphaComponent(firesAlpha)))
            }
            // With blur disabled, regular cards still need a fill —
            // the frost would have been their backdrop. Re-run and
            // tag each non-fires layout with the solid dark fill.
            if !blurEnabled {
                for i in cardLayouts.indices where cardLayouts[i].fill == nil {
                    cardLayouts[i] = CardLayout(
                        kind: cardLayouts[i].kind,
                        rect: cardLayouts[i].rect,
                        text: cardLayouts[i].text,
                        fill: NSColor.black.withAlphaComponent(0.8))
                }
            }
        }

        if badgeEnabled,
           hint != nil, let icon = originIcon, let origin = origin {
            let s = badgeSize
            var rect = CGRect(x: origin.x - s / 2, y: origin.y - s / 2,
                              width: s, height: s)
            rect.origin.x = min(max(rect.origin.x, 8), bounds.maxX - s - 8)
            rect.origin.y = min(max(rect.origin.y, 8), bounds.maxY - s - 8)

            // 0.85 → 1.0 ease-out cubic over 150 ms. Re-layout each
            // frame until done so the mask scales with the visible
            // badge — otherwise blur briefly extends past the border.
            var scale: CGFloat = 1.0
            if animEnabled, let t0 = badgeAppearedAt {
                let elapsed = CACurrentMediaTime() - t0
                if elapsed < badgeAnimDuration {
                    let p = elapsed / badgeAnimDuration
                    let eased = 1 - pow(1 - p, 3)
                    scale = 0.85 + 0.15 * CGFloat(eased)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                        [weak self] in
                        self?.layoutHUD()
                        self?.hudContent.needsDisplay = true
                    }
                }
            }
            badgeLayout = BadgeLayout(rect: rect, icon: icon,
                                      border: accent, scale: scale)
        }

        let maskPath = CGMutablePath()
        for c in cardLayouts {
            maskPath.addRoundedRect(in: c.rect,
                                    cornerWidth: 10, cornerHeight: 10)
        }
        if let b = badgeLayout {
            // Scale the badge cutout from its centre so the blur
            // region pulses with the visible badge.
            let cx = b.rect.midX, cy = b.rect.midY
            let t = CGAffineTransform(translationX: cx, y: cy)
                .scaledBy(x: b.scale, y: b.scale)
                .translatedBy(x: -cx, y: -cy)
            maskPath.addRoundedRect(in: b.rect,
                                    cornerWidth: 10, cornerHeight: 10,
                                    transform: t)
        }
        // Skip mask update when blur is disabled — blurView isn't
        // even in the hierarchy then; the mask layer is moot.
        if blurEnabled, let mask = blurView.layer?.mask as? CAShapeLayer {
            mask.path = maskPath
        }

        // Diff drives the unmatch effect and feeds reset()'s match
        // effect — skip both bookkeeping and dict construction when
        // neither hook is active (this runs on every mouse-move).
        if effectUnmatch != .none || effectMatch != .none {
            let newByKind = Dictionary(uniqueKeysWithValues:
                cardLayouts.map { ($0.kind, $0) })
            if effectUnmatch != .none {
                let now = CACurrentMediaTime()
                for (kind, oldLayout) in prevCardsByKind
                    where newByKind[kind] == nil {
                    let e = resolveRandom(effectUnmatch)
                    exitingCards.append(ExitingCard(
                        layout: oldLayout, effect: e, startedAt: now))
                    scheduleParticleEffect(oldLayout, effect: e)
                }
            }
            prevCardsByKind = newByKind
            kickExitAnimationTick()
        }
    }

    /// Emit a CAEmitterLayer for particle effects. No-op for the non-
    /// particle effects — those are drawn each frame in
    /// `HUDContentView`. The emitter auto-cleans after the effect's
    /// duration via a `DispatchQueue.main.asyncAfter`.
    private func scheduleParticleEffect(_ layout: CardLayout,
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
    private func kickExitAnimationTick() {
        guard (!exitingCards.isEmpty || holdingFinal), !tickScheduled
        else { return }
        tickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
            [weak self] in self?.tickExitAnimations()
        }
    }

    private func tickExitAnimations() {
        tickScheduled = false
        let now = CACurrentMediaTime()
        exitingCards.removeAll { (now - $0.startedAt) >= $0.effect.duration }
        hudContent.needsDisplay = true
        // The trail's fade alpha is sampled in `draw`, so it needs a
        // redraw on each tick too — otherwise the fade is frozen at
        // its first frame when no exit-card animation is running.
        if holdingFinal { needsDisplay = true }
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

    private func clampedCardRect(at origin: CGPoint, size: CGSize) -> CGRect {
        var rect = CGRect(origin: origin, size: size)
        rect.origin.x = min(max(rect.origin.x, 6), bounds.maxX - size.width - 6)
        rect.origin.y = min(max(rect.origin.y, 6), bounds.maxY - size.height - 6)
        return rect
    }

    fileprivate static func mono(_ sz: CGFloat, _ w: NSFont.Weight) -> NSFont {
        .monospacedSystemFont(ofSize: sz, weight: w)
    }
    fileprivate static let textOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
    fileprivate let cardPadX: CGFloat = 12, cardPadY: CGFloat = 9

    /// One card's text. Directional cards (`fires == false` rows)
    /// stay tab-aligned past the widest arrows. The firing card has
    /// no arrows left, so it drops the tab — its accent-tinted fill
    /// (set in `layoutHUD`) does the "firing" signal. `textMode`
    /// lets the caller pick a different colour for the firing card
    /// (`cardFiresTextMode`) from the directional cards
    /// (`cardTextMode`).
    fileprivate func cardText(_ rows: [GestureHint.Row],
                               textMode: TrailColorMode) -> NSAttributedString {
        let arrowFont = Self.mono(cardFontSize + 1, .semibold)
        var arrowMax: CGFloat = 0
        for r in rows {
            let w = (r.suffix as NSString).size(withAttributes: [.font: arrowFont]).width
            arrowMax = max(arrowMax, w)
        }
        let useTab = arrowMax > 0
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        if useTab {
            para.tabStops = [NSTextTab(textAlignment: .left, location: arrowMax + 12)]
        }

        // Resolve current text colour from the supplied mode —
        // honours dynamic tokens (`rainbow` / `neon` / `splatoon`)
        // alongside static hex / named values.
        let textColor = textMode.currentColor(
            at: CACurrentMediaTime(),
            strokeSeed: strokeSeed,
            cyclePeriod: colorCyclePeriod)

        let s = NSMutableAttributedString()
        for (i, r) in rows.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "\n")) }
            if !r.suffix.isEmpty {
                s.append(NSAttributedString(string: r.suffix, attributes: [
                    .font: arrowFont, .foregroundColor: textColor]))
            }
            s.append(NSAttributedString(string: (useTab ? "\t" : "") + r.name, attributes: [
                .font: Self.mono(cardFontSize, .regular),
                .foregroundColor: textColor]))
        }
        s.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: s.length))
        return s
    }

    fileprivate func cardSize(_ s: NSAttributedString) -> CGSize {
        let t = s.boundingRect(with: CGSize(width: 600, height: 800),
                               options: Self.textOpts).size
        return CGSize(width: ceil(t.width) + cardPadX * 2,
                      height: ceil(t.height) + cardPadY * 2)
    }
}

/// HUD overlay drawn on top of `TrailView.blurView`: optional tint
/// fill (for the firing card), the hair border, the text — and for
/// the badge, the scale-in transform, the 2pt accent border, and the
/// icon. Reads state from its `owner` (TrailView) instead of holding
/// its own copy; layout was already computed there in `layoutHUD`.
private final class HUDContentView: NSView {
    weak var owner: TrailView?
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner else { return }

        for c in o.cardLayouts {
            drawCard(c, in: o, alpha: 1, dx: 0, dy: 0, scale: 1)
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
                     alpha: s.alpha, dx: s.dx, dy: s.dy, scale: s.scale)
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
            // Without blur the badge needs its own dark backdrop
            // for icon contrast (otherwise the icon sits on whatever
            // page content is behind the transparent overlay).
            if !o.blurEnabled {
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
    /// `scale` place the rect through the exit animation.
    private func drawCard(_ c: TrailView.CardLayout,
                          in o: TrailView,
                          alpha: CGFloat,
                          dx: CGFloat, dy: CGFloat, scale: CGFloat) {
        let bg = NSBezierPath(roundedRect: c.rect,
                              xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        if alpha < 1 {
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        }
        if dx != 0 || dy != 0 || scale != 1 {
            let cx = c.rect.midX, cy = c.rect.midY
            let tx = NSAffineTransform()
            tx.translateX(by: cx + dx, yBy: cy + dy)
            tx.scaleX(by: scale, yBy: scale)
            tx.translateX(by: -cx, yBy: -cy)
            tx.concat()
        }
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
        let border = o.cardBorderMode.currentColor(
            at: now, strokeSeed: o.strokeSeed,
            cyclePeriod: o.colorCyclePeriod)
        border.setStroke()
        bg.lineWidth = 1
        bg.stroke()
        c.text.draw(with: c.rect.insetBy(dx: o.cardPadX, dy: o.cardPadY),
                    options: TrailView.textOpts)
        NSGraphicsContext.restoreGraphicsState()
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
        case .none, .random:
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
