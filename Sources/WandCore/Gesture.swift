// Cast-family configuration containers. Mirrors the TOML nesting:
// each `[cast.<sub>]` (and `[cast.<sub>.<sub>]`) section maps to one
// struct. Consumers reach values via dotted paths on `WandConfig`:
//   `cfg.overlay.trail.color`
//   `cfg.overlay.cards.fire`
//   `cfg.fire.decal.kind`

import CoreGraphics
import Foundation

// MARK: - Theme

/// Coordinated colour palette for the cast HUD — supplies defaults
/// for `[cast.overlay.trail]` + `[cast.overlay.cards]` colour
/// fields. Individual config keys override per field, so
/// `theme = "terminal"` + `color = "red"` gives a Terminal HUD
/// with a red trail line.
public struct CastThemePalette: Sendable, Equatable {
    public let trailColor: String
    public let trailColorNoMatch: String
    public let trailColorOutline: String
    public let cardsBorderColor: String
    public let cardsBodyColor: String
    public let cardsTextColor: String
    /// Body fill for the **firing** card. Empty = inherit the trail
    /// accent (the historical behaviour). Themes that want a
    /// distinct firing-card flash override this without touching
    /// the trail colour.
    public let cardsFiresColor: String
    /// Text colour for the **firing** card only. Empty = inherit
    /// `cardsTextColor`. Lets a theme invert the firing card cleanly
    /// — e.g. directional cards use yellow-on-black, firing card
    /// flips to black-on-yellow.
    public let cardsFiresTextColor: String
    /// Border colour for the **firing** card only. Empty = inherit
    /// `cardsBorderColor` (the historical behaviour, where the
    /// firing card shares its border treatment with the directional
    /// cards). Themes that want different border colours per card
    /// state (e.g. chomp: neon-blue maze-wall border on
    /// directional cards but yellow body-matched border on the
    /// firing tile) set this to a non-empty value.
    public let cardsFiresBorderColor: String
    /// Burst particle colour. Empty = inherit `trail.color`. Same
    /// grammar as the trail colour fields.
    public let burstColor: String
    /// Solid backdrop colour for the app-icon badge. Empty = keep the
    /// system frosted blur behind the badge. Non-empty draws a solid
    /// theme colour underneath the badge icon — pairs with the
    /// matching tome `[tome].theme` so the app icon doesn't visually
    /// float on a frosted patch while the rest of the HUD reads as
    /// themed.
    public let badgeBackgroundColor: String

    public init(trailColor: String, trailColorNoMatch: String,
                trailColorOutline: String,
                cardsBorderColor: String, cardsBodyColor: String,
                cardsTextColor: String,
                cardsFiresColor: String = "",
                cardsFiresTextColor: String = "",
                cardsFiresBorderColor: String = "",
                burstColor: String = "",
                badgeBackgroundColor: String = "") {
        self.trailColor = trailColor
        self.trailColorNoMatch = trailColorNoMatch
        self.trailColorOutline = trailColorOutline
        self.cardsBorderColor = cardsBorderColor
        self.cardsBodyColor = cardsBodyColor
        self.cardsTextColor = cardsTextColor
        self.cardsFiresColor = cardsFiresColor
        self.cardsFiresTextColor = cardsFiresTextColor
        self.cardsFiresBorderColor = cardsFiresBorderColor
        self.burstColor = burstColor
        self.badgeBackgroundColor = badgeBackgroundColor
    }
}

// MARK: - Recognition tuning

/// `[cast.recognition]` — knobs that tune how raw mouse samples turn
/// into a direction string. Independent of any visual output; purely
/// a recognition-quality axis.
public struct GestureRecognitionSpec: Sendable, Equatable {
    /// Minimum displacement (px) before a new direction is emitted.
    /// Smaller = catches small flicks, bigger = tolerant of jitter.
    /// Clamped 4..200.
    public let minStrokePx: Int
    /// Maximum time (ms) a single segment may take. The clock resets
    /// on every turn, so each leg gets the full budget; only a
    /// stalled single direction (an ordinary slow drag) runs past it
    /// and the gesture is abandoned. `0` = no limit. Clamped 100..60000
    /// when set.
    public let maxSegmentMs: Int
    /// Scribble-to-cancel: number of 180° direction reversals that
    /// abandons the in-progress stroke. `0` = off. Clamped 1..20 when
    /// set.
    public let cancelReversals: Int
    /// Speed gate for the scribble — reversals must land within this
    /// window (ms). `0` = any speed. Clamped 100..5000 when set.
    public let cancelWindowMs: Int

    public init(minStrokePx: Int = 16,
                maxSegmentMs: Int = 0,
                cancelReversals: Int = 2,
                cancelWindowMs: Int = 500) {
        self.minStrokePx = minStrokePx
        self.maxSegmentMs = maxSegmentMs
        self.cancelReversals = cancelReversals
        self.cancelWindowMs = cancelWindowMs
    }

    public static let `default` = GestureRecognitionSpec()
}

// MARK: - Overlay sub-blocks

/// `[cast.overlay.trail]` — the line itself.
public struct GestureOverlayTrailSpec: Sendable, Equatable {
    /// While the in-progress shape matches a rule (or is too short to
    /// match anything yet).
    public let color: String
    /// While the in-progress shape can no longer reach any rule.
    public let colorNoMatch: String
    /// Outline / underlay colour drawn behind / around the trail
    /// so the main `color` reads against backgrounds that would
    /// otherwise swallow it (e.g. `color = "black"` on a dark
    /// app). Empty = no outline (historical behaviour). Same
    /// grammar as `color`: named / hex / dynamic tokens
    /// (`rainbow` / `neon` / `splatoon`). The exact rendering is
    /// style-specific — bezier styles get a wider underlay stroke,
    /// pixel / rainbow-road get a 1pt frame inset into each cell,
    /// ascii gets a glyph stroke. Under `[cast].theme = "chomp"`
    /// the outline becomes the corridor's flanking wall colour
    /// (the theme palette already supplies neon-arcade blue).
    public let colorOutline: String
    /// Stroke width in points. Clamped 1..40.
    public let width: Int
    /// Named line-shape preset. Shape only — colour always comes from
    /// `color` / `colorNoMatch`.
    public let style: TrailStyle
    /// How long (ms) the trail lingers after a gesture fires.
    /// Clamped 0..2000; `0` = instant clear.
    public let finalHoldMs: Int
    /// When `true`: each time a turn is detected (e.g. `D` → `L`
    /// in `DLD`), the just-completed segment snaps onto its axis
    /// so it renders as an orthogonal straight line — the trail
    /// looks like a Figma diagram of the gesture.
    /// When `false` (default): every segment stays as the raw
    /// freehand polyline through the actual mouse samples — the
    /// trail looks like a hand-drawn sketch. Recognition is
    /// unaffected either way; this is a render-only knob.
    public let straightenOnTurn: Bool

    public init(color: String = "#3b82f6",
                colorNoMatch: String = "#ef4444",
                colorOutline: String = "",
                width: Int = 3,
                style: TrailStyle = .normal,
                finalHoldMs: Int = 400,
                straightenOnTurn: Bool = false) {
        self.color = color
        self.colorNoMatch = colorNoMatch
        self.colorOutline = colorOutline
        self.width = width
        self.style = style
        self.finalHoldMs = finalHoldMs
        self.straightenOnTurn = straightenOnTurn
    }

    public static let `default` = GestureOverlayTrailSpec()
}

/// `[cast.overlay.badge]` — origin badge that shows the target app's
/// icon at the gesture's start point.
public struct GestureOverlayBadgeSpec: Sendable, Equatable {
    public let enabled: Bool
    /// Badge size in points. Clamped 32..96.
    public let size: Int
    /// Tiny scale-in pop when the badge first appears.
    public let animEnabled: Bool

    public init(enabled: Bool = true,
                size: Int = 56,
                animEnabled: Bool = true) {
        self.enabled = enabled
        self.size = size
        self.animEnabled = animEnabled
    }

    public static let `default` = GestureOverlayBadgeSpec()
}

/// `[cast.overlay.cards]` — assist-card exit animations. These animate
/// cards inside the overlay, so they require `[cast.overlay].enabled
/// = true`. Default `.off` (cards just vanish).
public struct GestureOverlayCardsSpec: Sendable, Equatable {
    /// Animation when the firing card actually fires at button-up.
    public let fire: Effect
    /// Animation when a card becomes unreachable mid-gesture.
    public let cancel: Effect
    /// Live decoration on the currently-armed firing card while the
    /// stroke is still in progress. Distinct from `fire` (one-shot
    /// at button-up) — `armed` is a continuous, looping cue layered
    /// on top of the existing rainbow-border firing signal.
    public let armed: ArmedEffect
    /// Chomp "pets" walking the firing card's rounded outline.
    /// Empty `[]` (default) draws nothing. Theme-agnostic — each
    /// pet's silhouette is its own colour signature, so they
    /// stand alongside any `[cast].theme`. When more than one is
    /// listed they chase each other around the card in array
    /// order (first leads, the rest trail at a fixed gap). Mirrors
    /// `[tome.decoration].line-pets` on the menu side so the two
    /// surfaces share a vocabulary.
    public let linePets: [LinePet]
    /// Card-text base font size in points. The arrow column rides at
    /// `fontSize + 1` so the directional glyphs stay a hair taller
    /// than the rule name. The card's padding is fixed in pt, so a
    /// larger font expands the card naturally. Clamped 8..32.
    public let fontSize: Int
    /// Prepend the target-app icon to the firing card's row(s) —
    /// reads as "this rule will fire against THIS app on release",
    /// the same confirmation the origin badge gives but on the
    /// firing-card surface. Only applied to the firing card; the
    /// directional candidate cards keep their `arrow → icon → name`
    /// layout. When the cursor sits on a surface with no resolvable
    /// AX target (Desktop / menu bar) the column collapses so the
    /// firing row stays flush against the rule icon / name.
    public let firesAppIcon: Bool

    public init(fire: Effect = .off,
                cancel: Effect = .off,
                armed: ArmedEffect = .off,
                linePets: [LinePet] = [],
                fontSize: Int = 13,
                firesAppIcon: Bool = true) {
        self.fire = fire
        self.cancel = cancel
        self.armed = armed
        self.linePets = linePets
        self.fontSize = fontSize
        self.firesAppIcon = firesAppIcon
    }

    public static let `default` = GestureOverlayCardsSpec()
}

/// `[cast.overlay.no-match]` — banner shown at the cursor while the
/// in-progress gesture is currently off every reachable rule. Default
/// `kind = .off`. Decoupled from `[cast].theme` so the GAME OVER cue
/// can pair with any theme.
public struct GestureOverlayNoMatchSpec: Sendable, Equatable {
    public let kind: NoMatchBanner

    public init(kind: NoMatchBanner = .off) {
        self.kind = kind
    }

    public static let `default` = GestureOverlayNoMatchSpec()
}

/// `[cast.overlay]` — the whole HUD (trail + badge + cards) plus
/// shared toggles. `enabled = false` keeps the overlay window from
/// being created at all (the daemon must restart to flip back on —
/// surfaced as pending-restart in `--status`).
public struct GestureOverlaySpec: Sendable, Equatable {
    public let enabled: Bool
    /// Frosted blur (`NSVisualEffectView`) under the HUD cards +
    /// badge. `false` falls back to a solid dark fill.
    public let blurEnabled: Bool
    /// Cycle period in milliseconds for the dynamic colour modes
    /// (`rainbow` / `neon`). Smaller = faster strobe; larger =
    /// slower drift. Clamped 100..10000. Shared by trail + cards
    /// (border / body / text) + outline — anything that resolves
    /// a `TrailColorMode` uses this period, so a `rainbow` trail
    /// and a `rainbow` card border cycle in lockstep. Placed at
    /// overlay scope (not under `trail`) because of that cross-
    /// surface scope. Ignored by static and `splatoon` modes (the
    /// latter is per-stroke fixed).
    public let colorCycleMs: Int
    public let trail: GestureOverlayTrailSpec
    public let badge: GestureOverlayBadgeSpec
    public let cards: GestureOverlayCardsSpec
    public let noMatch: GestureOverlayNoMatchSpec

    public init(enabled: Bool = true,
                blurEnabled: Bool = true,
                colorCycleMs: Int = 2000,
                trail: GestureOverlayTrailSpec = .default,
                badge: GestureOverlayBadgeSpec = .default,
                cards: GestureOverlayCardsSpec = .default,
                noMatch: GestureOverlayNoMatchSpec = .default) {
        self.enabled = enabled
        self.blurEnabled = blurEnabled
        self.colorCycleMs = colorCycleMs
        self.trail = trail
        self.badge = badge
        self.cards = cards
        self.noMatch = noMatch
    }

    public static let `default` = GestureOverlaySpec()
}

// MARK: - Fire-moment sub-blocks

/// `[cast.fire.burst]` — omnidirectional particle explosion at the
/// cursor when a rule fires. Lives in its own click-through window so
/// the burst fires even when `[cast.overlay].enabled = false`.
public struct GestureFireBurstSpec: Sendable, Equatable {
    public let kind: TrailEndKind
    /// Burst particle colour:
    ///   `""` / `"trail"`  — inherit `[cast.overlay.trail].color`.
    ///   `"splatoon"`     — pick a random hue from the Splatoon ink
    ///                       palette at each fire (Turf War feel).
    ///   `<hex / name>`   — any value `trail.color` accepts.
    public let color: String

    public init(kind: TrailEndKind = .off, color: String = "") {
        self.kind = kind
        self.color = color
    }

    public static let `default` = GestureFireBurstSpec()
}

/// `[cast.fire.decal]` — post-fire ink decal at the cursor.
/// Independent of overlay; sits above every app in its own click-
/// through window.
public struct GestureFireDecalSpec: Sendable, Equatable {
    public let kind: DecalKind
    /// How long the decal stays visible. Clamped 0..10000;
    /// `0` collapses to `.off` regardless of `kind`.
    public let durationMs: Int
    /// Decal footprint in points. Clamped 10..500.
    public let size: Int

    public init(kind: DecalKind = .off,
                durationMs: Int = 3000,
                size: Int = 60) {
        self.kind = kind
        self.durationMs = durationMs
        self.size = size
    }

    public static let `default` = GestureFireDecalSpec()
}

/// `[cast.fire]` — fire-moment cursor-anchored effects. Both
/// sub-blocks render in their own click-through windows and are
/// triggered from `Controller.onGestureFire` regardless of the
/// overlay's enabled state.
public struct GestureFireSpec: Sendable, Equatable {
    public let burst: GestureFireBurstSpec
    public let decal: GestureFireDecalSpec

    public init(burst: GestureFireBurstSpec = .default,
                decal: GestureFireDecalSpec = .default) {
        self.burst = burst
        self.decal = decal
    }

    public static let `default` = GestureFireSpec()
}
