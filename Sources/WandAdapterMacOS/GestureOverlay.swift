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
        /// Optional icon spec from `[[cast.rule]].icon`. Same syntax
        /// as `[[tome.item]].icon` (SF:<name> / emoji / file path /
        /// `app:<bundle-id>`). Empty = the card collapses its icon
        /// column for this row.
        public let icon: String
        public let fires: Bool
        public init(suffix: String, name: String,
                    icon: String = "", fires: Bool) {
            self.suffix = suffix; self.name = name
            self.icon = icon; self.fires = fires
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

    /// Called when Chomp's face crosses a cherry on the trail
    /// (`[cast].theme = "chomp"` only). The point is in Cocoa
    /// global screen coordinates (Y-up) — same shape
    /// `ArcadeScoreManager.emit(at:)` and the rest of the App-layer
    /// fire-moment effects expect, so the App layer can wire this
    /// straight in.
    public var onCherryEaten: ((CGPoint) -> Void)? {
        get { view.onCherryEatenGlobal }
        set { view.onCherryEatenGlobal = newValue }
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
        // Chomp special theme: scale + straighten come from
        // `[cast.chomp]`, not from `[cast.overlay.trail]`.
        // `cfg.chomp` is `nil` under every other theme — the
        // historical width / style / straighten path then applies
        // unchanged.
        view.chomp = cfg.chomp
        if let pm = cfg.chomp {
            view.strokeWidth = pm.size.scale
            view.straightenOnTurn = true
        } else {
            view.strokeWidth = CGFloat(ov.trail.width)
            view.straightenOnTurn = ov.trail.straightenOnTurn
        }
        view.trailStyle = ov.trail.style
        view.badgeEnabled = ov.badge.enabled
        view.badgeSize = CGFloat(ov.badge.size)
        view.animEnabled = ov.badge.animEnabled
        view.setBlurEnabled(ov.blurEnabled)
        view.effectCancel = ov.cards.cancel
        view.effectFire = ov.cards.fire
        view.effectArmed = ov.cards.armed
        view.cardLinePets = ov.cards.linePets
        view.cardFontSize = CGFloat(ov.cards.fontSize)
        view.firesAppIcon = ov.cards.firesAppIcon
        view.noMatchBanner = ov.noMatch.kind
        // Card colours come exclusively from the theme palette.
        // Empty palette entries fall back to the hard-coded defaults,
        // preserving the `theme = "default"` look.
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
        view.cardFiresBorderMode = palette.cardsFiresBorderColor.isEmpty
            ? nil
            : TrailColorMode.parse(palette.cardsFiresBorderColor,
                                    fallback: NSColor.white.withAlphaComponent(0.18))
        view.badgeBackgroundColor = palette.badgeBackgroundColor.isEmpty
            ? nil
            : NSColorParse.nsColor(palette.badgeBackgroundColor)
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
    /// `[cast.chomp]` payload. Non-nil flips the whole
    /// trail render path to `ChompRenderer` (bypassing the
    /// `trailStyle` switch entirely) and locks straighten-on-turn.
    /// `nil` under every theme other than `.chomp`, so the
    /// historical `trailStyle` switch is the default path.
    var chomp: ChompSpec? = nil
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
    var effectCancel: Effect = .off
    var effectFire: Effect = .off
    /// Live "armed" cue for the firing assist card while a stroke is
    /// in progress (`[cast.overlay.cards].armed`). Drives a per-frame
    /// transform / decoration in `HUDContentView.drawCard` and gates
    /// the tick loop in `kickExitAnimationTick` so the animation
    /// keeps running even when the cursor holds still mid-gesture.
    var effectArmed: ArmedEffect = .off
    /// Chomp "pets" walking the firing card's outline. Each entry
    /// is rendered every frame at a position lagging the previous
    /// one in the array, so listing `["chomp", "ghost"]` reads as
    /// the ghost chasing chomp. Empty array = no decoration.
    /// Theme-agnostic — silhouettes carry their own colour.
    var cardLinePets: [LinePet] = []
    /// `[cast.overlay.cards].fires-app-icon` — prepend the target-
    /// app icon to the firing card so the "this fires against THIS
    /// app" cue lives on the firing surface, not just the origin
    /// badge. Only the firing card uses it; candidate cards keep
    /// their `arrow → icon → name` layout. Falls through to the
    /// historical layout when no app icon is resolved.
    var firesAppIcon: Bool = true
    /// `[cast.overlay.no-match].kind` — banner shown at the cursor
    /// while the in-progress stroke is off every reachable rule.
    /// Decoupled from `[cast].theme` so the GAME OVER cue can pair
    /// with any theme.
    var noMatchBanner: NoMatchBanner = .off
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
    /// Border colour mode for the firing card only (`nil` = inherit
    /// `cardBorderMode`, same border as directional cards). Set
    /// live from `[cast].theme`'s palette via
    /// `cardsFiresBorderColor`. Lets a theme reserve one border
    /// colour for the directional state and a different one for
    /// the firing state — e.g. chomp: blue maze-wall border on
    /// directional cards, yellow body-matched border on the firing
    /// tile so the blue stays the "approach" signal.
    var cardFiresBorderMode: TrailColorMode? = nil
    /// Solid backdrop for the app-icon badge. `nil` (the default)
    /// keeps the historical frosted-blur behind the badge — the
    /// icon rides on whatever vibrancy the `[cast.overlay].blur-
    /// enabled` knob delivers. Non-nil draws this colour as a
    /// rounded fill underneath the badge icon instead, used by
    /// non-default cast themes that need an opaque themed surface.
    var badgeBackgroundColor: NSColor? = nil
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
    /// Wall-time of the moment the trail's match state transitioned
    /// from `true` to `false`. Used by the chomp wall-flash effect:
    /// for `noMatchFlashDurationMs` after this timestamp the corridor
    /// walls render in red instead of the theme outline colour,
    /// signalling "you've just fallen off every rule". `nil` outside
    /// the flash window. Re-armed on every fresh true → false
    /// transition, so a no-match → re-match → no-match sequence
    /// flashes again on the second drop.
    fileprivate var noMatchFlashStartedAt: TimeInterval?
    fileprivate static let noMatchFlashDurationMs: Double = 200
    /// Wall-time of the most recent cherry-eaten event under the
    /// chomp theme. While within `cherryFlashDurationMs` of this
    /// timestamp, the corridor walls render as a hue-cycling rainbow
    /// instead of the theme outline — the visible "bonus!" beat when
    /// Chomp catches a cherry along the trail. Set by the
    /// `onCherryEaten` callback wired into `ChompRenderer.draw`,
    /// cleared at stroke end.
    fileprivate var cherryFlashStartedAt: TimeInterval?
    fileprivate static let cherryFlashDurationMs: Double = 450
    /// Face's arc-length from the origin on the previous frame.
    /// Fed back into `ChompRenderer.draw` so cherry-crossing
    /// detection can compare against a stable reference frame.
    /// Reset to 0 at stroke end.
    fileprivate var prevFaceArcLength: CGFloat = 0
    /// App-layer hook called once per cherry the face eats, with
    /// the cherry's Cocoa-global position (Y-up). `GestureOverlay`
    /// exposes this via its own `onCherryEaten` property so the
    /// daemon's `ArcadeScoreManager` can fire a "+N" popup at the
    /// exact cherry location.
    var onCherryEatenGlobal: ((CGPoint) -> Void)?
    /// Wall-time of the most recent `true` → `false` transition that
    /// HASN'T been cleared yet. Drives the chomp "GAME OVER" arcade
    /// overlay rendered above the stroke's origin point. Distinct
    /// from `noMatchFlashStartedAt` (a brief 200 ms wall flash):
    /// `gameOverStartedAt` lingers for the rest of the stroke (or
    /// until the gesture re-matches a rule) so the "you're off-track
    /// → no rule will fire on release" message stays visible. `nil`
    /// when no GAME OVER is currently shown.
    fileprivate var gameOverStartedAt: TimeInterval?
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
    /// gesture and triggers `effectCancel`.
    fileprivate enum CardKind: Hashable {
        case direction(Character)
        case fires
    }

    /// Swap `.random` for a concrete pick at queue time — per-card,
    /// so successive unmatch cards in one stroke each get their own
    /// dice roll. Other kinds pass through unchanged.
    fileprivate func resolveRandom(_ effect: Effect) -> Effect {
        guard effect == .random else { return effect }
        return Effect.randomPool.randomElement() ?? .off
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

    // MARK: - Chomp post-fire "eat the app icon" sequence
    //
    // chomp theme only: when a rule fires, place the target-app icon
    // one chomp-cell past the trail's snapped end, advance the face
    // forward over `chompFireAdvanceDuration` to catch up, then fire
    // the same `onCherryEaten` callback the regular cherry / icon-
    // pellet pickups use so the arcade-score "+N" floats up from the
    // icon's position. After the eat moment the icon stops drawing
    // and the trail continues its normal fade-out.
    //
    // All four fields are non-nil ONLY between fire-time and the
    // matching `_actualReset()`; they're set together in `_reset()`'s
    // chomp branch and cleared together in `_actualReset()`.
    fileprivate var chompFireStartedAt: TimeInterval?
    /// Cursor position (TrailView-local) at the moment the gesture
    /// fired, AFTER `commitFinalSegment` snapped it onto the
    /// lastDir axis. Source of truth for the advance animation's
    /// start point.
    fileprivate var chompFireSnapStart: CGPoint?
    /// Where the target-app icon sits — one chomp cell forward of
    /// `chompFireSnapStart` along `lastDir`. The animation ends with
    /// the face arriving here.
    fileprivate var chompFireBonusPos: CGPoint?
    /// `true` once the face has crossed `chompFireBonusPos` and the
    /// arcade-score popup has been emitted. Stops the icon rendering
    /// for the remainder of the hold so it disappears the moment
    /// Chomp "bites" it.
    fileprivate var chompFireBonusEaten: Bool = false
    /// Seconds the bonus icon hangs at `chompFireBonusPos` BEFORE
    /// the face starts sprinting toward it. Without a beat here the
    /// icon flashes in and gets eaten in the same eye-blink, so the
    /// user only registers the score popup — never the icon itself.
    /// 0.18 s is roughly two frames at human-noticeable resolution.
    fileprivate static let chompFirePreAdvanceDuration: TimeInterval = 0.18
    /// Seconds it takes the face to advance from `chompFireSnapStart`
    /// to `chompFireBonusPos` AFTER the pre-advance beat. Slower than
    /// the original 0.22 s — the deliberate glide reads as Pac-Man
    /// closing in on the pellet rather than a snap-eat.
    fileprivate static let chompFireAdvanceDuration: TimeInterval = 0.42
    /// Total post-fire hold under chomp. Reserves time AFTER the eat
    /// moment so the arcade-score popup gets a beat to register
    /// before the trail fades out underneath it. Sized as
    /// pre-advance + advance + ~0.5 s tail.
    fileprivate static let chompFireHoldDuration: TimeInterval = 1.10

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
        // Detect the true → false transition for the chomp wall
        // flash. Re-armed each time so a re-match → no-match
        // sequence flashes again on the second drop. GAME OVER
        // arcade overlay piggybacks on the same transition but
        // lingers (cleared on re-match below or on stroke end) so
        // the user keeps seeing "you're off-track" until they
        // recover or release.
        if self.valid && !valid {
            noMatchFlashStartedAt = CACurrentMediaTime()
            gameOverStartedAt = CACurrentMediaTime()
        } else if !self.valid && valid {
            // Recovered onto a matching shape — pull the overlay.
            gameOverStartedAt = nil
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
        // Chomp's wall-flash animation needs redraws between
        // mouse samples — the flash starts the instant `valid`
        // flips false (which can happen on a single sample that
        // also doesn't move the cursor any further), so without
        // the ticker the flash window would never get a second
        // frame. No-op when nothing chomp-flavoured is active.
        kickExitAnimationTick()
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
        if effectFire != .off, let fires = prevCardsByKind[.fires] {
            let now = CACurrentMediaTime()
            let e = resolveRandom(effectFire)
            exitingCards.append(ExitingCard(
                layout: fires, effect: e, startedAt: now))
            scheduleParticleEffect(fires, effect: e)
        }
        // `prevCardsByKind` is only kept current when `effectFire` /
        // `effectCancel` is configured (layoutHUD gates the update on
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
            // Chomp eat sequence: stage the bonus-icon target one
            // chomp cell forward in `lastDir`. The draw loop reads
            // these fields each frame to interpolate the face's
            // advance cursor and to draw the icon at the destination
            // until it gets "eaten". `originIcon` stays alive across
            // this branch (every other theme nils it out below) so
            // the icon has something to render.
            let runFireEat = chomp != nil
                && originIcon != nil
                && lastDir != nil
                && cursor != nil
            if runFireEat,
               let snapStart = cursor,
               let dir = lastDir
            {
                // Spacing matches `ChompRenderer.pelletInterval`
                // (14pt) scaled by the same `strokeWidth`
                // multiplier the renderer uses, so the bonus pellet
                // lands exactly where the next chomp pellet would
                // have been on a longer stroke. Slight extra (1.4×)
                // gives the face room to visibly traverse instead
                // of snapping onto the icon in a single frame.
                let cellStep: CGFloat = 14.0 * strokeWidth * 1.4
                let dx: CGFloat
                let dy: CGFloat
                switch dir {
                case .left:  dx = -cellStep; dy = 0
                case .right: dx =  cellStep; dy = 0
                case .up:    dx = 0; dy =  cellStep
                case .down:  dx = 0; dy = -cellStep
                }
                chompFireSnapStart = snapStart
                chompFireBonusPos = CGPoint(x: snapStart.x + dx,
                                             y: snapStart.y + dy)
                chompFireStartedAt = CACurrentMediaTime()
                chompFireBonusEaten = false
            }
            hint = nil
            // Keep originIcon alive across the chomp eat sequence;
            // clear it for every other theme so the historical
            // hold-then-fade path is unchanged.
            if !runFireEat { originIcon = nil }
            badgeAppearedAt = nil
            cardLayouts.removeAll()
            badgeLayout = nil
            holdingFinal = true
            finalizeStartedAt = CACurrentMediaTime()
            // Chomp's eat sequence needs longer than the historical
            // 0.40 s hold — the face has to advance, the popup needs
            // a beat to register, and only then does the trail fade.
            let holdSec = runFireEat
                ? Self.chompFireHoldDuration
                : finalHoldDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + holdSec) {
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
        noMatchFlashStartedAt = nil
        gameOverStartedAt = nil
        cherryFlashStartedAt = nil
        prevFaceArcLength = 0
        chompFireStartedAt = nil
        chompFireSnapStart = nil
        chompFireBonusPos = nil
        chompFireBonusEaten = false
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
        // Chomp's eat sequence overrides `finalHoldDuration` (0.40 s
        // default) with the longer `chompFireHoldDuration` (0.85 s);
        // the fade timing has to track THAT, otherwise the trail goes
        // transparent at 0.40 s — well before the eat animation, the
        // bonus-icon overlay, and the arcade-score popup are done.
        var alpha: CGFloat = 1.0
        if holdingFinal, let t0 = finalizeStartedAt {
            let elapsed = CACurrentMediaTime() - t0
            let totalHold = chompFireStartedAt != nil
                ? Self.chompFireHoldDuration
                : finalHoldDuration
            let fadeStart = totalHold * 0.66
            if elapsed > fadeStart {
                let p = (elapsed - fadeStart) / (totalHold - fadeStart)
                alpha = max(0.0, 1.0 - CGFloat(p))
            }
        }

        NSGraphicsContext.saveGraphicsState()
        if alpha < 1.0 {
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        }

        // Chomp special theme: skip the `trailStyle` switch
        // entirely and hand off to the dedicated renderer.
        // Branching here (rather than carrying a `.chomp` case in
        // `TrailStyle`) keeps style-decoration and theme-identity
        // on separate axes — `trailStyle` is "which dash pattern",
        // `chomp` is "the whole render shape is locked".
        if chomp != nil {
            // Wall colour during the no-match flash window: swap
            // the theme outline (arcade-blue) for hot red so the
            // moment the gesture falls off every rule, the
            // corridor walls briefly read as "danger" before
            // settling back to the standard signal-blue. After
            // `noMatchFlashDurationMs` the override expires and
            // the original `outlineColor` (theme outline) flows
            // through again.
            var chompOutline = outlineColor
            if let flashStart = noMatchFlashStartedAt {
                let elapsedMs = (CACurrentMediaTime() - flashStart) * 1000
                if elapsedMs < Self.noMatchFlashDurationMs {
                    chompOutline = NSColor(
                        srgbRed: 1.00, green: 0.10,
                        blue: 0.10, alpha: 1.0)
                }
            }
            // Cherry-eaten flash overrides the standard / no-match
            // wall colour with a hue-cycling rainbow for a brief
            // "bonus!" beat. Picks the latest event (no-match red
            // and cherry rainbow rarely coincide; if they do the
            // cherry win is the more interesting beat to show).
            if let cherryStart = cherryFlashStartedAt {
                let now = CACurrentMediaTime()
                let elapsedMs = (now - cherryStart) * 1000
                if elapsedMs < Self.cherryFlashDurationMs {
                    let cycleHz = 6.0   // ~3 full hue cycles in 450 ms
                    let hue = (now * cycleHz)
                        .truncatingRemainder(dividingBy: 1)
                    chompOutline = NSColor(
                        hue: CGFloat(hue),
                        saturation: 1.0,
                        brightness: 1.0,
                        alpha: 1.0)
                } else {
                    cherryFlashStartedAt = nil
                }
            }
            // Chomp post-fire eat sequence: interpolate the cursor
            // forward from `chompFireSnapStart` to `chompFireBonusPos`
            // over `chompFireAdvanceDuration`. The polyline ChompRenderer
            // walks lengthens accordingly, so the face visibly lurches
            // forward toward the bonus icon. The icon itself is drawn
            // separately below the renderer call so it sits on top of
            // the trail until the eat moment.
            //
            // The historical `faceLag * strokeWidth` (~90 × scale, so
            // 270 pt at chomp `.m`) parks the face well behind the
            // cursor during a live stroke — fine for the chase feel,
            // but it means a bare cursor advance leaves the face
            // stranded at the last corner. We ramp `faceLagOverride`
            // from the full lag down to zero alongside the cursor
            // advance so the face glides forward to MEET the icon at
            // the trail tip on the final frame.
            //
            // Only the chomp branch of `_reset()` populates these
            // fields — every other theme keeps them nil and falls
            // through to the historical `cursor` + default lag.
            var drawCursor = cursor
            var faceLagOverride: CGFloat? = nil
            if let start = chompFireSnapStart,
               let bonus = chompFireBonusPos,
               let fireT = chompFireStartedAt
            {
                let elapsed = CACurrentMediaTime() - fireT
                // Two-phase timing: first the icon hangs in place
                // (`chompFirePreAdvanceDuration`) so the user
                // actually SEES it; then the face glides forward
                // over `chompFireAdvanceDuration` to the bonus.
                // Without the hang, the icon flashes in and out in
                // a single eye-blink and only the score popup
                // registers.
                let advanceElapsed = elapsed
                    - Self.chompFirePreAdvanceDuration
                let rawProgress = advanceElapsed
                    / Self.chompFireAdvanceDuration
                let progress = min(max(rawProgress, 0), 1.0)
                // Ease-out cubic on the advance — face sets off fast
                // and decelerates onto the icon, reading as a
                // deliberate "bite" rather than a constant glide.
                let eased = 1 - pow(1 - CGFloat(progress), 3)
                drawCursor = CGPoint(
                    x: start.x + (bonus.x - start.x) * eased,
                    y: start.y + (bonus.y - start.y) * eased)
                // Collapse the lag in lock-step with the advance so
                // the face arrives at the cursor (= bonus) on the
                // final frame. Constant `lagBase` rather than reading
                // ChompRenderer's static is fine — both come from the
                // same `90 * scale` formula and the renderer caps the
                // override at `>= 0` anyway.
                let lagBase: CGFloat = 90 * strokeWidth
                faceLagOverride = lagBase * (1.0 - eased)
                if progress >= 1.0 && !chompFireBonusEaten {
                    chompFireBonusEaten = true
                    // Same beat the cherry / icon-pellet pickups
                    // use: rainbow corridor flash + arcade-score
                    // popup floating up from the bonus position.
                    // Bypassing ChompRenderer's eat detection
                    // (which only triggers on hash-banded pellets)
                    // is intentional — the bonus icon is a one-off
                    // forced pellet, not part of the renderer's
                    // pellet stream.
                    cherryFlashStartedAt = CACurrentMediaTime()
                    let cocoaGlobal = CGPoint(
                        x: bonus.x + originOffset.x,
                        y: bonus.y + originOffset.y)
                    onCherryEatenGlobal?(cocoaGlobal)
                    kickExitAnimationTick()
                }
            }
            // Keep the chomp cycle alive across the WHOLE post-fire
            // hold under chomp — through the advance to the bonus
            // icon AND the idle beat after the bite while the
            // arcade-score popup floats up. The historical wide-open
            // freeze (`isFinalHold = true` during `holdingFinal`)
            // would lock the mouth as soon as the rule fires; the
            // chomp theme reads better with Pac-Man continuing to
            // chomp in place, like it's still hungry for the next
            // pellet. Non-chomp-fire branches fall back to the
            // historical freeze.
            let faceFinalHold = chompFireStartedAt != nil
                ? false
                : holdingFinal
            let newFaceArc = ChompRenderer.draw(
                state: ChompRenderer.State(
                    origin: origin,
                    cursor: drawCursor,
                    corners: corners,
                    rawTrail: rawTrail,
                    lastDir: lastDir,
                    straightenOnTurn: straightenOnTurn,
                    strokeWidth: strokeWidth,
                    valid: valid,
                    isFinalHold: faceFinalHold,
                    previousFaceArcLength: prevFaceArcLength,
                    onCherryEaten: { [weak self] cherryPt in
                        guard let self = self else { return }
                        self.cherryFlashStartedAt = CACurrentMediaTime()
                        self.kickExitAnimationTick()
                        // Forward the cherry's screen position so the
                        // App layer can fire the arcade-score popup.
                        // `cherryPt` is in TrailView-local coords;
                        // `originOffset` shifts back to Cocoa global.
                        let cocoaGlobal = CGPoint(
                            x: cherryPt.x + self.originOffset.x,
                            y: cherryPt.y + self.originOffset.y)
                        self.onCherryEatenGlobal?(cocoaGlobal)
                    },
                    originIcon: originIcon,
                    faceLagOverride: faceLagOverride),
                color: color, outline: chompOutline)
            prevFaceArcLength = newFaceArc
            // Bonus icon overlay — drawn after the trail/face so it
            // sits visually on top of the corridor until Chomp eats
            // it (`chompFireBonusEaten` flips at the eat moment and
            // the icon stops drawing). Sized at ~1.5 chomp pellets so
            // it reads as an arcade pickup tile, not a giant overlay.
            if let bonus = chompFireBonusPos, !chompFireBonusEaten,
               let icon = originIcon
            {
                let iconSize = 14.0 * strokeWidth * 1.5
                let rect = NSRect(x: bonus.x - iconSize / 2,
                                   y: bonus.y - iconSize / 2,
                                   width: iconSize, height: iconSize)
                icon.draw(in: rect, from: .zero,
                          operation: .sourceOver, fraction: 1.0,
                          respectFlipped: true, hints: nil)
            }
            drawNoMatchBannerIfNeeded(cursor: cursor)
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        // Every remaining style shares the hybrid corner + freehand
        // polyline and only swaps the dash pattern. Colour always
        // comes from the resolved `color` so the match-vs-no-match
        // signal stays legible regardless of dash.
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
        case .arrow:
            drawArrowChainPath(origin: origin, cursor: cursor,
                                color: color, outline: outlineColor)
        case .paws:
            drawPawsPath(origin: origin, cursor: cursor,
                          color: color, outline: outlineColor)
        }
        drawNoMatchBannerIfNeeded(cursor: cursor)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Shared dispatch for the `[cast.overlay.no-match]` banner —
    /// pulled out of the chomp trail branch so every theme can opt
    /// in. The banner only renders when the in-progress stroke is
    /// currently off every reachable rule (`gameOverStartedAt != nil`,
    /// re-armed on each fresh true→false match transition).
    private func drawNoMatchBannerIfNeeded(cursor: CGPoint) {
        guard let gameOverAt = gameOverStartedAt else { return }
        switch noMatchBanner {
        case .off:
            return
        case .gameOver:
            drawGameOverOverlay(cursor: cursor, startedAt: gameOverAt)
        }
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

    /// Arcade "GAME OVER" banner anchored at the assist-card position
    /// (upper-right diagonal off `cursor` by `gap`) so the message
    /// lands where the firing card would have appeared had a rule
    /// been reachable. Chomp theme only — called from the chomp
    /// branch of `draw`, gated on `gameOverStartedAt != nil`.
    ///
    /// First ~140 ms after appearance: scale-in pop (0.7 → 1.0
    /// ease-out cubic) so the message lands with arcade impact. After
    /// the pop, a 2 Hz alpha blink (1.0 ↔ 0.55) sells the classic
    /// arcade "respawn screen" feel. Colour is hot arcade-red on a
    /// black backdrop with a yellow outline, matching chomp's
    /// danger palette.
    private func drawGameOverOverlay(cursor: CGPoint,
                                      startedAt: TimeInterval) {
        let now = CACurrentMediaTime()
        let elapsed = now - startedAt
        // Scale-in pop over the first 140 ms.
        let popDuration: Double = 0.14
        let scale: CGFloat
        if elapsed < popDuration {
            let p = elapsed / popDuration
            let eased = 1 - pow(1 - p, 3)  // ease-out cubic
            scale = 0.7 + 0.3 * CGFloat(eased)
        } else {
            scale = 1.0
        }
        // 2 Hz blink after the pop settles.
        let blinkAlpha: CGFloat = elapsed >= popDuration
            ? (sin(elapsed * 2 * .pi * 2) > 0 ? 1.0 : 0.55)
            : 1.0

        let text = "GAME OVER" as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 22, weight: .bold)
        let red = NSColor(srgbRed: 1.00, green: 0.10,
                          blue: 0.10, alpha: 1.0)
        let yellow = NSColor(srgbRed: 1.00, green: 0.92,
                             blue: 0.0, alpha: 1.0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: red,
            .strokeColor: yellow,
            // Negative stroke width fills + strokes; positive would
            // hollow the glyph. Yellow halo around the red letters
            // pops them off the dark backdrop.
            .strokeWidth: -3.0,
        ]
        let textSize = text.size(withAttributes: attrs)

        // Background card: rounded black rect inset around the text.
        let padX: CGFloat = 14
        let padY: CGFloat = 8
        let cardSize = CGSize(width: textSize.width + 2 * padX,
                               height: textSize.height + 2 * padY)
        // Anchor at the assist-card position — `cursor + (gap, gap)`,
        // matching the natural upper-right diagonal where the firing
        // card sits in `layoutHUD`. Card-edge coords clamped to the
        // overlay bounds so the banner never spills off-screen.
        let gap: CGFloat = 24
        var cardRect = CGRect(x: cursor.x + gap,
                               y: cursor.y + gap,
                               width: cardSize.width,
                               height: cardSize.height)
        cardRect.origin.x = min(max(cardRect.origin.x, 8),
                                 bounds.maxX - cardSize.width - 8)
        cardRect.origin.y = min(max(cardRect.origin.y, 8),
                                 bounds.maxY - cardSize.height - 8)
        let cx = cardRect.midX
        let cy = cardRect.midY

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(blinkAlpha)
        let tx = NSAffineTransform()
        tx.translateX(by: cx, yBy: cy)
        tx.scaleX(by: scale, yBy: scale)
        tx.concat()

        // Local rect centered on the transform's origin — separate
        // from `cardRect` above (in overlay-bounds coords) so the
        // post-transform draw is centred regardless of clamping.
        let drawRect = CGRect(x: -cardSize.width / 2,
                               y: -cardSize.height / 2,
                               width: cardSize.width,
                               height: cardSize.height)
        let card = NSBezierPath(roundedRect: drawRect,
                                 xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.92).setFill()
        card.fill()
        yellow.setStroke()
        card.lineWidth = 2
        card.stroke()

        let textOrigin = CGPoint(x: -textSize.width / 2,
                                  y: -textSize.height / 2)
        text.draw(at: textOrigin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
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

    // Chomp trail rendering — every chomp/ghost-specific
    // constant + helper now lives in `ChompRenderer.swift`. The
    // `draw(_:)` dispatch hands the relevant TrailView state over
    // via `ChompRenderer.State`.


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
    /// treatment as the chomp pellet outline. `strokeWidth` is
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

            // Pre-compute every directional card's size so the gap
            // can expand to prevent overlap. A vertical card (↑/↓)
            // wider than `2 * baseGap` would overlap the horizontal
            // cards' (←/→) column unless `horizGap` grows past it,
            // and vice versa.
            var dirTexts: [Character: NSAttributedString] = [:]
            var dirSizes: [Character: CGSize] = [:]
            for (arrow, rows) in byDir {
                let s = cardText(rows, textMode: cardTextMode)
                dirTexts[arrow] = s
                dirSizes[arrow] = cardSize(s)
            }
            let baseGap: CGFloat = 24
            let margin: CGFloat = 8
            let widestVertical: CGFloat = max(
                dirSizes["↑"]?.width ?? 0,
                dirSizes["↓"]?.width ?? 0)
            let tallestHorizontal: CGFloat = max(
                dirSizes["←"]?.height ?? 0,
                dirSizes["→"]?.height ?? 0)
            let horizGap = max(baseGap, widestVertical / 2 + margin)
            let vertGap = max(baseGap, tallestHorizontal / 2 + margin)

            for (arrow, size) in dirSizes {
                guard let s = dirTexts[arrow] else { continue }
                let o: CGPoint
                switch arrow {
                case "←": o = CGPoint(x: cursor.x - horizGap - size.width, y: cursor.y - size.height / 2)
                case "→": o = CGPoint(x: cursor.x + horizGap,               y: cursor.y - size.height / 2)
                case "↑": o = CGPoint(x: cursor.x - size.width / 2,         y: cursor.y + vertGap)
                case "↓": o = CGPoint(x: cursor.x - size.width / 2,         y: cursor.y - vertGap - size.height)
                default:  o = CGPoint(x: cursor.x + horizGap, y: cursor.y + vertGap)
                }
                cardLayouts.append(CardLayout(
                    kind: .direction(arrow),
                    rect: clampedCardRect(at: o, size: size),
                    text: s, fill: nil))
            }
            if !fires.isEmpty {
                // The firing card optionally leads with the
                // cursor-anchored app icon. Falls back to the plain
                // layout when the icon can't be resolved (Desktop,
                // menu bar — `originIcon` is nil) so the row stays
                // flush against the rule icon / name.
                let firingLeadingIcon: NSImage? =
                    firesAppIcon ? originIcon : nil
                let s = cardText(fires,
                                  textMode: cardFiresTextMode
                                    ?? cardTextMode,
                                  leadingAppIcon: firingLeadingIcon)
                let size = cardSize(s)
                // Fires card fill: accent on its own over blur (alpha
                // 0.5 lets the frost show through). Without blur the
                // dark backdrop is missing too, so the tint goes more
                // opaque to keep the card a distinct surface.
                let firesAlpha: CGFloat = blurEnabled ? 0.5 : 0.78
                // Collision avoidance: try each diagonal anchor in
                // turn and pick the first one that doesn't intersect
                // any directional card. Order — ↗ ↘ ↙ ↖ — keeps the
                // natural diagonal first so the simple case is
                // unchanged. Uses the expanded `horizGap`/`vertGap`
                // (which already pushed directional cards outward to
                // accommodate the widest neighbours), so the fires
                // card automatically lands clear of them.
                let anchors: [CGPoint] = [
                    CGPoint(x: cursor.x + horizGap,
                            y: cursor.y + vertGap),
                    CGPoint(x: cursor.x + horizGap,
                            y: cursor.y - vertGap - size.height),
                    CGPoint(x: cursor.x - horizGap - size.width,
                            y: cursor.y - vertGap - size.height),
                    CGPoint(x: cursor.x - horizGap - size.width,
                            y: cursor.y + vertGap),
                ]
                var firesRect = clampedCardRect(at: anchors[0], size: size)
                for a in anchors {
                    let r = clampedCardRect(at: a, size: size)
                    if !cardLayouts.contains(where: { $0.rect.intersects(r) }) {
                        firesRect = r
                        break
                    }
                }
                // Firing card body fill priority:
                //   1. `cardFiresMode` (palette's `cardsFiresColor`)
                //      → flash colour explicitly chosen by theme.
                //   2. `nil` under chomp when `cardFiresMode` is
                //      empty → the firing card opts out of the
                //      accent fallback so it lands on the same
                //      frosted backdrop as the directional cards;
                //      the rainbow border carries the "fires on
                //      release" signal alone.
                //   3. trail `accent` — historical default for
                //      every other theme that doesn't override.
                let firesFill: NSColor?
                if let mode = cardFiresMode {
                    let base = mode.currentColor(
                        at: CACurrentMediaTime(),
                        strokeSeed: strokeSeed,
                        cyclePeriod: colorCyclePeriod)
                    firesFill = base.withAlphaComponent(firesAlpha)
                } else if chomp != nil {
                    firesFill = nil
                } else {
                    firesFill = accent.withAlphaComponent(firesAlpha)
                }
                cardLayouts.append(CardLayout(
                    kind: .fires,
                    rect: firesRect, text: s,
                    fill: firesFill))
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
        if effectCancel != .off || effectFire != .off {
            let newByKind = Dictionary(uniqueKeysWithValues:
                cardLayouts.map { ($0.kind, $0) })
            if effectCancel != .off {
                let now = CACurrentMediaTime()
                for (kind, oldLayout) in prevCardsByKind
                    where newByKind[kind] == nil {
                    let e = resolveRandom(effectCancel)
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
    fileprivate func kickExitAnimationTick() {
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

    /// One card's text. Each row is laid out independently so a row
    /// without an `icon` packs tight against its arrow rather than
    /// reserving the icon column space for an icon that never
    /// arrives. Columns per row:
    ///   - Iconless row, arrow present:     `arrow → name`
    ///   - Iconed row, arrow present:       `arrow → icon → name`
    ///   - Iconless firing row (no arrow):  `name`
    ///   - Iconed firing row (no arrow):    `icon → name`
    /// Arrow column width is shared across rows (so all arrows align
    /// past the widest one in this card); name x positions can differ
    /// per row when iconed and iconless rows are mixed, the
    /// deliberate trade-off for tight per-row packing.
    ///
    /// `leadingAppIcon` (firing card only) prepends an app-icon
    /// column at x=0, shifting every subsequent column right by one
    /// icon's worth. Passing `nil` is the historical layout — the
    /// firing card just leads with its rule icon (or name, if
    /// iconless). Candidate cards always pass `nil`; only the firing
    /// card surfaces the cursor-anchored target's identity.
    fileprivate func cardText(_ rows: [GestureHint.Row],
                               textMode: TrailColorMode,
                               leadingAppIcon: NSImage? = nil) -> NSAttributedString {
        // Suffix renders in two styles. The FIRST arrow (`nextArrow*`)
        // is the direction the user has to draw next — boosted in
        // size + weight and tinted with the trail's match colour so
        // it stands out as a single, unambiguous cue. The remaining
        // arrows stay on the historical `arrowFont` + `labelColor`,
        // reading as "still to come" without competing for attention.
        let arrowFont = Self.mono(cardFontSize + 1, .semibold)
        let nextArrowFont = Self.mono(cardFontSize + 3, .bold)
        let nameFont = Self.mono(cardFontSize, .regular)

        // Mixed-font measurement: first char on `nextArrowFont`, the
        // rest on `arrowFont`. Without this the tab stop reserves the
        // old (smaller) width and the boosted glyph either overflows
        // its column or visually clashes with the rule icon.
        var arrowMax: CGFloat = 0
        for r in rows where !r.suffix.isEmpty {
            let firstChar = String(r.suffix.prefix(1))
            let restChars = String(r.suffix.dropFirst())
            let w1 = (firstChar as NSString)
                .size(withAttributes: [.font: nextArrowFont]).width
            let w2 = (restChars as NSString)
                .size(withAttributes: [.font: arrowFont]).width
            arrowMax = max(arrowMax, w1 + w2)
        }

        // Resolve current text colour from the supplied mode —
        // honours dynamic tokens (`rainbow` / `neon` / `splatoon`)
        // alongside static hex / named values.
        let textColor = textMode.currentColor(
            at: CACurrentMediaTime(),
            strokeSeed: strokeSeed,
            cyclePeriod: colorCyclePeriod)

        // Icon size matches the tome panel's `IconResolver.pt`
        // scaling so the same SF Symbol reads at the same legibility
        // on both surfaces (~24pt for the user's 18pt cards).
        let iconBoxSize = IconResolver.pt(forFontSize: Int(cardFontSize))

        // Centre the icon's geometric middle with the text's
        // cap-height middle so arrow / icon / name all share a
        // visual centreline (instead of baseline-aligning, which
        // pushes the taller icon visibly above the text).
        let iconYOffset = (nameFont.capHeight - iconBoxSize) / 2

        // Pre-resolve icons once per layout pass. Tint via
        // `NSColor.labelColor` — same effective colour the tome
        // panel uses (white in dark mode), which reads more clearly
        // than text-coloured icons on dark card bodies. The palette
        // is applied via `paletteColors` so the SF Symbol carries
        // its colour as raster pixels rather than as a template
        // image (NSTextAttachment doesn't apply text foreground to
        // template images, so without an explicit colour the icon
        // renders transparent).
        let iconTint = NSColor.labelColor
        let iconImages: [NSImage?] = rows.map { r in
            guard !r.icon.isEmpty else { return nil }
            return IconResolver.resolve(r.icon,
                                         pointSize: iconBoxSize,
                                         tintColor: iconTint)
        }
        // Shift the whole column structure right by an icon's width
        // when a leading app icon is present. With `nil` the offset
        // is zero — every other code path below collapses cleanly to
        // the original layout.
        let hasLeading = leadingAppIcon != nil
        let appIconColEnd: CGFloat = hasLeading ? iconBoxSize + 6 : 0
        let arrowColEnd: CGFloat = appIconColEnd
            + (arrowMax > 0 ? arrowMax + 10 : 0)
        let iconColEnd: CGFloat = arrowColEnd + iconBoxSize + 6

        let s = NSMutableAttributedString()
        for (i, r) in rows.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "\n")) }
            let lineStart = s.length
            let hasIcon = iconImages[i] != nil

            // Leading app icon — sits at x=0, before everything
            // else. Drawn per row so it aligns under the same
            // column when the firing card carries multiple rules;
            // in practice the firing card almost always has a
            // single row, so the duplication is cheap.
            if let appIcon = leadingAppIcon {
                let att = NSTextAttachment()
                att.image = appIcon
                att.bounds = CGRect(x: 0, y: iconYOffset,
                                     width: iconBoxSize,
                                     height: iconBoxSize)
                s.append(NSAttributedString(attachment: att))
            }

            if !r.suffix.isEmpty {
                // Arrow shares the icon's `labelColor` tint — same
                // visual weight as the SF Symbol next to it, instead
                // of inheriting the theme's text colour. Keeps the
                // glyphs reading as a single "this is a direction +
                // its icon" cue rather than two competing accents.
                // The FIRST arrow is the special case: it's the next
                // direction the user has to draw, so we boost it to
                // `nextArrowFont` + trail-match colour to lift it out
                // of the line.
                if hasLeading {
                    s.append(NSAttributedString(string: "\t"))
                }
                let nextArrowColor = matchMode.currentColor(
                    at: CACurrentMediaTime(),
                    strokeSeed: strokeSeed,
                    cyclePeriod: colorCyclePeriod)
                let firstChar = String(r.suffix.prefix(1))
                let restChars = String(r.suffix.dropFirst())
                s.append(NSAttributedString(string: firstChar, attributes: [
                    .font: nextArrowFont,
                    .foregroundColor: nextArrowColor]))
                if !restChars.isEmpty {
                    s.append(NSAttributedString(string: restChars, attributes: [
                        .font: arrowFont, .foregroundColor: iconTint]))
                }
            }
            if hasIcon {
                // Tab into the icon column only when something
                // precedes it (arrow or leading app icon); a
                // firing-card row with neither places its icon at
                // x=0 directly.
                if arrowMax > 0 || hasLeading {
                    s.append(NSAttributedString(string: "\t"))
                }
                let att = NSTextAttachment()
                att.image = iconImages[i]!
                att.bounds = CGRect(x: 0, y: iconYOffset,
                                     width: iconBoxSize,
                                     height: iconBoxSize)
                s.append(NSAttributedString(attachment: att))
            }
            // Tab into the name column — skipped only when nothing
            // precedes the name (iconless firing row with no leading
            // app icon).
            let needsNameTab = arrowMax > 0 || hasIcon || hasLeading
            if needsNameTab {
                s.append(NSAttributedString(string: "\t"))
            }
            s.append(NSAttributedString(string: r.name, attributes: [
                .font: nameFont, .foregroundColor: textColor]))

            // Per-row paragraph style — iconless rows skip the icon
            // column entirely so the name sits flush against the
            // arrow.
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 4
            var stops: [NSTextTab] = []
            if hasLeading {
                stops.append(NSTextTab(textAlignment: .left,
                                        location: appIconColEnd))
            }
            if arrowMax > 0 {
                stops.append(NSTextTab(textAlignment: .left,
                                        location: arrowColEnd))
            }
            if hasIcon {
                // Without an arrow column the icon stop lives at the
                // first available slot — right after the leading app
                // icon when one is present, or at x=`iconBoxSize+6`
                // for the historical firing-card-with-icon case.
                let nameStop: CGFloat
                if arrowMax > 0 {
                    nameStop = iconColEnd
                } else if hasLeading {
                    nameStop = appIconColEnd + iconBoxSize + 6
                } else {
                    nameStop = iconBoxSize + 6
                }
                stops.append(NSTextTab(textAlignment: .left,
                                        location: nameStop))
            }
            para.tabStops = stops
            let lineRange = NSRange(location: lineStart,
                                    length: s.length - lineStart)
            s.addAttribute(.paragraphStyle, value: para, range: lineRange)
        }
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
    /// layers a live "would-fire-on-release" cue on top; `chomp`
    /// adds a chomp pellet orbiting the rect, independent of
    /// `armed` so the two stack. Only the firing card mid-stroke
    /// passes a non-`.off` armed or a non-empty `linePets`.
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
            drawCardLinePets(linePets, on: c.rect, now: nowArmed,
                              petScale: petScale)
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

    /// Chomp "pets" walking the firing card's outline. Mirrors the
    /// tome-side `TomePetsView.draw` shape — first entry leads, each
    /// follower trails by a fixed pt-along-the-perimeter gap. The
    /// pellet's centre traces the rect's outer edge directly, so its
    /// visible half rides on top of the card border.
    private func drawCardLinePets(_ pets: [LinePet],
                                   on rect: CGRect,
                                   now: CFTimeInterval,
                                   petScale: CGFloat) {
        // Travel just outside the card edge so the pet sits ON TOP
        // of the border, not under it.
        let path = rect.insetBy(dx: -1, dy: -1)
        guard path.width > 0, path.height > 0 else { return }
        let perim = 2 * (path.width + path.height)
        let speed: CGFloat = 110  // pt/s — calmer than the tome
                                   // rim so a small card doesn't
                                   // look like the pet is sprinting
        let leader = CGFloat(now).truncatingRemainder(
            dividingBy: perim / speed
        ) * speed
        let chaseGap: CGFloat = 24 * petScale  // ~2× ghost width
        for (i, pet) in pets.enumerated() {
            var pos = leader - CGFloat(i) * chaseGap
            pos = pos.truncatingRemainder(dividingBy: perim)
            if pos < 0 { pos += perim }
            let (px, py, rot) = positionOnRect(rect: path,
                                                 distance: pos)
            NSGraphicsContext.saveGraphicsState()
            let tx = NSAffineTransform()
            tx.translateX(by: px, yBy: py)
            tx.rotate(byRadians: rot)
            tx.concat()
            switch pet {
            case .chomp: drawCardChomp(now: now, petScale: petScale)
            case .ghost:  drawCardGhost(now: now, petScale: petScale)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Walk `rect`'s perimeter linearly (top → right → bottom → left)
    /// and return the centre + travel-direction rotation. Each pet's
    /// draw code can stay in a "facing-right" canonical frame; the
    /// transform handles lap orientation.
    private func positionOnRect(rect r: CGRect, distance t: CGFloat)
        -> (x: CGFloat, y: CGFloat, rot: CGFloat) {
        let topLen = r.width
        let rightLen = r.height
        let bottomLen = r.width
        if t < topLen {
            return (r.minX + t, r.maxY, 0)
        } else if t < topLen + rightLen {
            return (r.maxX, r.maxY - (t - topLen), -.pi / 2)
        } else if t < topLen + rightLen + bottomLen {
            return (r.maxX - (t - topLen - rightLen), r.minY, .pi)
        } else {
            return (r.minX,
                    r.minY + (t - topLen - rightLen - bottomLen),
                    .pi / 2)
        }
    }

    /// Yellow chomp wedge with the mouth chomp on a ~0.25 s cycle,
    /// drawn centred on the current transform origin. Matches the
    /// tome-side variant verbatim so both surfaces' pellets read as
    /// the same character. `petScale` keeps it proportional to the
    /// card's font size.
    private func drawCardChomp(now: CFTimeInterval,
                                 petScale: CGFloat) {
        let r: CGFloat = 7 * petScale
        let chompPhase = 0.5 - 0.5 * cos(now * (2 * .pi / 0.25))
        let openRad = chompPhase * (35.0 * .pi / 180.0)
        let yellow = NSColor(calibratedRed: 1.0, green: 0.85,
                             blue: 0.0, alpha: 1.0)
        let p = NSBezierPath()
        p.move(to: .zero)
        p.appendArc(withCenter: .zero, radius: r,
                     startAngle: CGFloat(openRad * 180 / .pi),
                     endAngle: CGFloat(360 - openRad * 180 / .pi),
                     clockwise: false)
        p.close()
        yellow.setFill(); p.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        p.lineWidth = 0.5; p.stroke()
    }

    /// Red Blinky-style ghost: dome + 3-wave skirt + eyes pointing
    /// along travel direction. Same geometry as `TomePetsView`'s
    /// ghost so both surfaces ship identical silhouettes.
    private func drawCardGhost(now: CFTimeInterval,
                                petScale: CGFloat) {
        let w: CGFloat = 14 * petScale
        let h: CGFloat = 16 * petScale
        let bob = CGFloat(sin(now * (2 * .pi / 0.4))) * 0.6 * petScale
        let halfW = w / 2
        let halfH = h / 2
        let red = NSColor(calibratedRed: 1.0, green: 0.0,
                          blue: 0.10, alpha: 1.0)
        let body = NSBezierPath()
        body.move(to: CGPoint(x: -halfW, y: 0))
        body.appendArc(withCenter: CGPoint(x: 0, y: 0),
                        radius: halfW,
                        startAngle: 180, endAngle: 0,
                        clockwise: false)
        body.line(to: CGPoint(x: halfW, y: -halfH + bob))
        let segments = 3
        let segW = w / CGFloat(segments)
        let waveDepth: CGFloat = 1.5 * petScale
        for i in (0..<segments).reversed() {
            let startX = -halfW + CGFloat(i + 1) * segW
            let endX = -halfW + CGFloat(i) * segW
            let midX = (startX + endX) / 2
            body.curve(to: CGPoint(x: endX, y: -halfH + bob),
                        controlPoint1: CGPoint(x: midX,
                                               y: -halfH - waveDepth - bob),
                        controlPoint2: CGPoint(x: midX,
                                               y: -halfH - waveDepth - bob))
        }
        body.line(to: CGPoint(x: -halfW, y: 0))
        body.close()
        red.setFill(); body.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        body.lineWidth = 0.5 * petScale; body.stroke()
        let eyeR: CGFloat = 2.0 * petScale
        let pupilR: CGFloat = 1.0 * petScale
        let eyeY: CGFloat = halfH * 0.35
        let eyeDx: CGFloat = 2.6 * petScale
        let pupilOffset: CGFloat = 0.7 * petScale
        let eyeShift: CGFloat = 1.0 * petScale
        for sign in [-1.0, 1.0] {
            let cx = CGFloat(sign) * eyeDx + eyeShift
            let sclera = NSBezierPath(ovalIn: CGRect(
                x: cx - eyeR, y: eyeY - eyeR,
                width: 2 * eyeR, height: 2 * eyeR))
            NSColor.white.setFill(); sclera.fill()
            let pupil = NSBezierPath(ovalIn: CGRect(
                x: cx - pupilR + pupilOffset, y: eyeY - pupilR,
                width: 2 * pupilR, height: 2 * pupilR))
            NSColor(calibratedRed: 0.10, green: 0.18,
                    blue: 0.95, alpha: 1.0).setFill()
            pupil.fill()
        }
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
