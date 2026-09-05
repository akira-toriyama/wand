// Translucent gesture-trail HUD — the project's only on-screen UI
// (wand is otherwise headless / LSUIElement). Lives in the adapter
// layer next to EventTap because it's pure AppKit/CG rendering fed by
// the sample stream; Core stays UI-free (points cross the seam as
// plain `CGPoint`). Threading: `addPoint` / `clear` fire on the
// event-tap main-thread callback, which is where AppKit wants them.
//
// This file owns the `CastOverlay` facade and `TrailView`'s
// stored state, stroke tracking, draw dispatch, and HUD layout. The
// rest of `TrailView` is split by responsibility into sibling files:
// `TrailView+StyleRenderers.swift` (trail style presets),
// `TrailView+Particles.swift` (exit animations / emitters / tick),
// `HUDContentView.swift` (the view that paints the computed layouts).
// Members those files reach are internal on purpose — `TrailView`
// itself is module-internal, never public.

import AppKit
import CoreGraphics
import Effects   // drawLinePets (shared line-pet drawing; re-exports Palette)
import Palette
import WandCore

/// What the overlay shows next to the cursor: the shape drawn so far
/// (as arrows) plus the rules still reachable from it. Each row's
/// `suffix` is only the *remaining* arrows (the drawn prefix is
/// stripped — you already see it), and `fires` marks the rule the
/// current shape triggers right now (its suffix is empty).
public struct CastHint: Sendable {
    public struct Row: Sendable {
        public let suffix: String
        public let name: String
        /// Optional icon spec from `[[cast.cursor.rule]].icon`. Same syntax
        /// as `[[tome.cursor.item]].icon` (SF:<name> / emoji / file path /
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
public final class CastOverlay {

    private let window: NSWindow
    private let view: TrailView

    /// Every `[cast.overlay]` field is applied through `applyConfig`
    /// so init and hot-reload share one setter — a knob cannot land in
    /// only one of them.
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

        applyConfig(cfg)
    }

    /// Called once at startup: the window stays up for the daemon's
    /// lifetime and is invisible until points arrive.
    public func show() {
        window.orderFrontRegardless()
    }

    /// Append one trail point (CG global coords, Y-down). `valid`
    /// recolors the whole trail: the match color when the current
    /// shape fires a rule, the no-match color otherwise. `hint` (the
    /// shape-so-far + reachable rules) is drawn near the cursor.
    /// Coalesced redraws keep this cheap at the per-mouse-move rate.
    public func addPoint(_ cg: CGPoint, valid: Bool, hint: CastHint?) {
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

    /// Apply a config change live — drives `[cast.overlay]` hot-reload
    /// from `ConfigWatcher`. Every overlay field is reflected without a
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
        let palette = wandCastPalette(cfg.theme)
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
        // Empty palette entries fall back to the system semantic colour,
        // preserving the native `system` theme look.
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
        view.effectIntensity = CGFloat(cfg.intensity.multiplier)
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

final class TrailView: NSView {
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
    /// `[cast.overlay.trail].style` and reflected live via
    /// `CastOverlay.applyConfig(_:)`. Colour is never part of a
    /// style — it flows from `[cast.overlay.trail].color` (see
    /// `TrailStyle`).
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
    /// User-visible knobs from `[cast.overlay]`. All hot-reloadable via
    /// `CastOverlay.applyConfig(_:)` — colours and toggles update
    /// without restart; `setBlurEnabled` even adds/removes the
    /// `NSVisualEffectView` subview in place.
    var blurEnabled: Bool
    var badgeEnabled: Bool = true
    var badgeSize: CGFloat = 56
    var animEnabled: Bool = true
    /// Exit-animation kinds from `[cast.overlay.cards]`. Typed values
    /// come straight from `WandConfig` — `CastOverlay.applyConfig`
    /// assigns them on init + hot-reload.
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
    /// Every bend (direction change) snaps the freehand tail into
    /// a new straight segment and restarts a fresh freehand.
    var origin: CGPoint?
    var cursor: CGPoint?
    var corners: [CGPoint] = []
    /// Raw mouse samples for the *current* (un-confirmed) segment —
    /// `freehandPoints[0]` is the segment start (= `corners.last ??
    /// origin`), the rest are subsequent samples, and the last is
    /// `cursor`. Reset on every corner commit so the new segment
    /// starts at the snapped corner.
    var freehandPoints: [CGPoint] = []
    /// Every raw mouse sample of the in-progress stroke, never
    /// trimmed at corner commits. Drives the `straightenOnTurn=false`
    /// render path so the trail shows the literal hand path. Reset
    /// in `_actualReset` alongside the other stroke state.
    var rawTrail: [CGPoint] = []
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
    var valid = true            // current match state of the trail
    /// Wall-time of the moment the trail's match state transitioned
    /// from `true` to `false`. Used by the chomp wall-flash effect:
    /// for `noMatchFlashDurationMs` after this timestamp the corridor
    /// walls render in red instead of the theme outline colour,
    /// signalling "you've just fallen off every rule". `nil` outside
    /// the flash window. Re-armed on every fresh true → false
    /// transition, so a no-match → re-match → no-match sequence
    /// flashes again on the second drop.
    var noMatchFlashStartedAt: TimeInterval?
    static let noMatchFlashDurationMs: Double = 200
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
    /// the cherry's Cocoa-global position (Y-up). `CastOverlay`
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
    fileprivate var hint: CastHint?      // shape + reachable rules
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
    enum CardKind: Hashable {
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
    struct CardLayout {
        let kind: CardKind
        let rect: CGRect
        let text: NSAttributedString
        let fill: NSColor?   // nil → frosted only; set → tint over frost
    }
    struct BadgeLayout {
        let rect: CGRect
        let icon: NSImage
        let border: NSColor
        let scale: CGFloat
    }
    /// One card that's animating out — kept around past `layoutHUD`
    /// so its exit effect plays to completion regardless of subsequent
    /// state changes. Pruned by `tickExitAnimations` when the elapsed
    /// time exceeds the effect's duration.
    struct ExitingCard {
        let layout: CardLayout
        let effect: Effect
        let startedAt: TimeInterval
    }
    var cardLayouts: [CardLayout] = []
    var badgeLayout: BadgeLayout?
    /// Last layoutHUD's cards, keyed by `CardKind`. Used to detect
    /// disappearing cards across passes and emit unmatch effects.
    private var prevCardsByKind: [CardKind: CardLayout] = [:]
    /// In-flight exit animations. Drained by `tickExitAnimations`.
    var exitingCards: [ExitingCard] = []
    /// True while a `tickExitAnimations` is queued on the main loop —
    /// `kickExitAnimationTick` checks it before scheduling, so the
    /// concurrent `layoutHUD` + `reset` callers can't stack timers
    /// that then each reschedule themselves into an avalanche.
    var tickScheduled = false
    /// Hold-and-fade for the trail when a rule fires. Set in `reset()`
    /// when the fires card was on screen at mouse-up. While true the
    /// trail keeps drawing (snapped to clean orthogonal lines via
    /// `commitFinalSegment`) instead of vanishing instantly, so the
    /// user sees the completed gesture as a tidy polyline for a beat
    /// before it fades out.
    var holdingFinal: Bool = false
    fileprivate var finalizeStartedAt: TimeInterval?
    /// Seconds the post-fire snapped trail stays visible (hold +
    /// fade). Sourced from `[cast.overlay.trail].final-hold-ms`; `0`
    /// disables the hold and falls back to immediate clear.
    /// Reflected live via `CastOverlay.applyConfig(_:)`.
    fileprivate var finalHoldDuration: TimeInterval = 0.40

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
    let hudContent: HUDContentView = {
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
    func append(_ cg: CGPoint, valid: Bool, hint: CastHint?) {
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
        // when `[cast.overlay].enabled = false`. The manager is
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

    /// `reset()` defers here either immediately (no fire) or after
    /// `finalHoldDuration` (fire).
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

    /// Add or remove the blur subview in place when
    /// `[cast.overlay].blur-enabled` flips during a hot-reload.
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
        // default) with the longer `chompFireHoldDuration`;
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

    /// Arcade "GAME OVER" banner anchored at the assist-card position
    /// (upper-right diagonal off `cursor` by `gap`) so the message
    /// lands where the firing card would have appeared had a rule
    /// been reachable. Chomp theme only — called from the chomp
    /// branch of `draw`, gated on `gameOverStartedAt != nil`.
    ///
    /// Pop-then-blink is the classic arcade "respawn screen" cue, and
    /// hot arcade-red on black with a yellow outline matches chomp's
    /// danger palette.
    private func drawGameOverOverlay(cursor: CGPoint,
                                      startedAt: TimeInterval) {
        let now = CACurrentMediaTime()
        let elapsed = now - startedAt
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

    private let badgeAnimDuration: TimeInterval = 0.15

    /// Compute every HUD region's rect (cards + optional badge),
    /// update the blur mask path to match, and store the layouts so
    /// `HUDContentView` can draw text / borders / icon on top. Called
    /// from `append` (state change) and during the badge scale-in.
    private func layoutHUD() {
        cardLayouts.removeAll()
        badgeLayout = nil

        // Same resolver the trail uses, so cards and trail cycle in
        // lockstep under the dynamic modes.
        let mode = valid ? matchMode : noMatchMode
        let accent = mode.currentColor(at: CACurrentMediaTime(),
                                        strokeSeed: strokeSeed,
                                        cyclePeriod: colorCyclePeriod)

        if let hint, let cursor = cursor {
            var byDir: [Character: [CastHint.Row]] = [:]
            var fires: [CastHint.Row] = []
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

    private func clampedCardRect(at origin: CGPoint, size: CGSize) -> CGRect {
        var rect = CGRect(origin: origin, size: size)
        rect.origin.x = min(max(rect.origin.x, 6), bounds.maxX - size.width - 6)
        rect.origin.y = min(max(rect.origin.y, 6), bounds.maxY - size.height - 6)
        return rect
    }

    fileprivate static func mono(_ sz: CGFloat, _ w: NSFont.Weight) -> NSFont {
        .monospacedSystemFont(ofSize: sz, weight: w)
    }
    static let textOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
    let cardPadX: CGFloat = 12, cardPadY: CGFloat = 9

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
    fileprivate func cardText(_ rows: [CastHint.Row],
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
