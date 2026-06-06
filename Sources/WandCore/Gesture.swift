// Gesture-family configuration containers. Mirrors the TOML
// nesting: each `[gesture.<sub>]` (and `[gesture.<sub>.<sub>]`)
// section maps to one struct. v6.0 explicitly splits previously
// flat fields (`badge-enabled`, `trail-style`, `card-match`, ...)
// into scoped sub-blocks so each field's responsibility is visible
// from the section path alone.
//
// Consumers reach values via dotted paths on `WandConfig`:
//   `cfg.overlay.trail.color`
//   `cfg.overlay.cards.match`
//   `cfg.fire.decal.kind`
// — no flat-prefix soup, no ambiguity about what `anim-enabled`
// means (in v5 it could only have been the badge; v6 makes that
// explicit via `[gesture.overlay.badge].anim-enabled`).

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
    /// distinct firing-card flash (e.g. `pacman`'s power-pellet
    /// rainbow) override this without touching the trail colour.
    public let cardsFiresColor: String
    /// Burst particle colour. Empty = inherit `trail.color`. Same
    /// grammar as the trail colour fields.
    public let burstColor: String

    // Note: a `decalColor` entry lived here through #114 but was
    // retired alongside `[cast.fire.decal].color` — decal is always
    // the Splatoon multi-team palette when enabled.

    public init(trailColor: String, trailColorNoMatch: String,
                trailColorOutline: String,
                cardsBorderColor: String, cardsBodyColor: String,
                cardsTextColor: String,
                cardsFiresColor: String = "",
                burstColor: String = "") {
        self.trailColor = trailColor
        self.trailColorNoMatch = trailColorNoMatch
        self.trailColorOutline = trailColorOutline
        self.cardsBorderColor = cardsBorderColor
        self.cardsBodyColor = cardsBodyColor
        self.cardsTextColor = cardsTextColor
        self.cardsFiresColor = cardsFiresColor
        self.burstColor = burstColor
    }
}

/// `[cast].theme` — picks a coordinated palette for the cast HUD.
/// Each theme supplies defaults for trail + cards colour fields;
/// individual keys still override the theme value when explicitly
/// set in the TOML (non-empty string). Unknown names clamp to
/// `.default`, which preserves the historical hard-coded values.
public enum CastTheme: String, Sendable, CaseIterable {
    case `default`
    case terminal
    case neon
    case splatoon
    case rainbow
    case mono
    case vapor
    case pacman

    // Note: a `paper` (light-background) theme lived here through
    // #115 but was retired — wand's HUD overlays a dark blur on
    // whatever's behind, so a light theme's dark trail blended into
    // the dark backing and the bright cards floated as detached
    // patches. Light themes need a different overlay model than what
    // wand ships, so dropping the option beats shipping one that
    // reads as broken.

    public var palette: CastThemePalette {
        switch self {
        case .default:
            return CastThemePalette(
                trailColor: "#3b82f6",
                trailColorNoMatch: "#ef4444",
                trailColorOutline: "",
                cardsBorderColor: "",
                cardsBodyColor: "",
                cardsTextColor: "")
        case .terminal:
            return CastThemePalette(
                trailColor: "#22c55e",
                trailColorNoMatch: "#fbbf24",
                trailColorOutline: "#000000",
                cardsBorderColor: "#22c55e",
                cardsBodyColor: "#000000",
                cardsTextColor: "#22c55e")
        case .neon:
            return CastThemePalette(
                trailColor: "neon",
                trailColorNoMatch: "#ec4899",
                trailColorOutline: "#000000",
                cardsBorderColor: "neon",
                cardsBodyColor: "#0f0a1f",
                cardsTextColor: "#ffffff")
        case .splatoon:
            return CastThemePalette(
                trailColor: "splatoon",
                trailColorNoMatch: "#000000",
                trailColorOutline: "#ffffff",
                cardsBorderColor: "splatoon",
                cardsBodyColor: "#1a1a1a",
                cardsTextColor: "#ffffff",
                // Burst inherits trail (one team's colour per stroke,
                // matching the line). Decal is always Splatoon
                // multi-team regardless of theme.
                burstColor: "")
        case .rainbow:
            return CastThemePalette(
                trailColor: "rainbow",
                trailColorNoMatch: "#1a1a1a",
                trailColorOutline: "#ffffff",
                cardsBorderColor: "rainbow",
                cardsBodyColor: "#000000",
                cardsTextColor: "#ffffff")
        case .mono:
            return CastThemePalette(
                trailColor: "#ffffff",
                trailColorNoMatch: "#ef4444",
                trailColorOutline: "#000000",
                cardsBorderColor: "#ffffff",
                cardsBodyColor: "#000000",
                cardsTextColor: "#ffffff")
        case .vapor:
            return CastThemePalette(
                trailColor: "#ff79c6",
                trailColorNoMatch: "#50fa7b",
                trailColorOutline: "#6272a4",
                cardsBorderColor: "#ff79c6",
                cardsBodyColor: "#282a36",
                cardsTextColor: "#f8f8f2")
        case .pacman:
            // Pac-Man arcade palette: yellow Pac-Man on a black
            // backdrop, red-ghost no-match. The yellow accent pairs
            // particularly well with `style = "pacman"`, where the
            // wedge face inherits the trail colour and ends up the
            // canonical arcade yellow.
            //
            // Card scheme: yellow pellet-coloured body with black
            // text on every directional card. The firing card flips
            // to rainbow — Pac-Man eating the power pellet and
            // entering the invincible flashing state.
            return CastThemePalette(
                trailColor: "#ffea00",
                trailColorNoMatch: "#ff0000",
                trailColorOutline: "#000000",
                cardsBorderColor: "#ffea00",
                cardsBodyColor: "#ffea00",
                cardsTextColor: "#000000",
                cardsFiresColor: "rainbow")
        }
    }
}

// MARK: - Recognition tuning

/// `[gesture.recognition]` — knobs that tune how raw mouse samples
/// turn into a direction string. Independent of any visual output;
/// purely a recognition-quality axis. v5 had these flat under
/// `[gesture]` next to `button` / `modifiers`, which conflated
/// trigger identity with recognition behaviour.
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

/// `[gesture.overlay.trail]` — the line itself.
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
    /// ascii gets a glyph stroke, pacman pellets / face get a
    /// concentric outer ring.
    public let colorOutline: String
    /// Stroke width in points. Clamped 1..40. Style presets may
    /// adjust this — `thin` halves, `thick` doubles, etc.
    public let width: Int
    /// Named preset bundling width × glow × dash. Shape only — colour
    /// always comes from `color` / `colorNoMatch`.
    public let style: TrailStyle
    // Note: an `arrowhead` (cursor-tip glyph) field lived here
    // through #115 but was retired in favour of the `arrow`
    // TrailStyle, which draws a continuous chevron chain along the
    // whole path. The cursor-only tip wasn't expressive enough and
    // duplicated direction information the path itself already
    // carried.
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

/// `[gesture.overlay.badge]` — origin badge that shows the target
/// app's icon at the gesture's start point.
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

/// `[gesture.overlay.cards]` — assist-card exit animations. These
/// animate cards inside the overlay, so they require
/// `[gesture.overlay].enabled = true`. Default `.none` (cards just
/// vanish).
public struct GestureOverlayCardsSpec: Sendable, Equatable {
    /// Animation when the firing card actually fires at button-up.
    public let match: Effect
    /// Animation when a card becomes unreachable mid-gesture.
    public let unmatch: Effect
    /// Card-text base font size in points. The arrow column rides at
    /// `fontSize + 1` so the directional glyphs stay a hair taller
    /// than the rule name (legibility on dense layouts). The card's
    /// padding is fixed in pt, so a larger font expands the card
    /// naturally rather than just changing typography. Clamped 8..32.
    public let fontSize: Int
    /// Card border colour. Empty falls back to the historical
    /// `NSColor.white.withAlphaComponent(0.18)` (a 1pt hairline that
    /// reads against the blurred backing). Accepts the same grammar
    /// as `[cast.overlay.trail].color` — hex / named, plus the
    /// dynamic tokens `"rainbow"` / `"neon"` / `"splatoon"`. Dynamic
    /// modes share `[cast.overlay.trail].color-cycle-ms` for cadence
    /// and the trail's per-stroke seed for `splatoon` (so the trail
    /// and the card borders pick the same team colour each stroke).
    public let borderColor: String
    /// Card body fill colour for the **non-firing** (directional)
    /// cards. Empty leaves the body transparent over the blurred
    /// backing (historical behaviour). The firing card is always
    /// tinted with the trail accent regardless of this knob — so the
    /// "this rule fires on release" signal stays visible. Same
    /// grammar as `borderColor`; dynamic modes work here too.
    public let bodyColor: String
    /// Card text colour (rule name + direction arrows). Empty falls
    /// back to white — the historical hard-coded value. Same grammar
    /// as `borderColor` / `bodyColor`: named / hex / dynamic tokens
    /// (`rainbow` / `neon` / `splatoon`).
    public let textColor: String
    /// Body fill colour for the **firing** card (the one that will
    /// trigger on release). Empty falls back to the trail accent —
    /// the historical "this card fires on release" tint. Same
    /// grammar as the other colour fields, including dynamic tokens.
    /// Useful for themes that want the firing card to flash
    /// differently from the trail (e.g. the `pacman` theme's
    /// power-pellet rainbow flash while the trail itself stays
    /// arcade yellow).
    public let firesColor: String

    public init(match: Effect = .none,
                unmatch: Effect = .none,
                fontSize: Int = 13,
                borderColor: String = "",
                bodyColor: String = "",
                textColor: String = "",
                firesColor: String = "") {
        self.match = match
        self.unmatch = unmatch
        self.fontSize = fontSize
        self.borderColor = borderColor
        self.bodyColor = bodyColor
        self.textColor = textColor
        self.firesColor = firesColor
    }

    public static let `default` = GestureOverlayCardsSpec()
}

/// `[gesture.overlay]` — the whole HUD (trail + badge + cards) plus
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

    public init(enabled: Bool = true,
                blurEnabled: Bool = true,
                colorCycleMs: Int = 2000,
                trail: GestureOverlayTrailSpec = .default,
                badge: GestureOverlayBadgeSpec = .default,
                cards: GestureOverlayCardsSpec = .default) {
        self.enabled = enabled
        self.blurEnabled = blurEnabled
        self.colorCycleMs = colorCycleMs
        self.trail = trail
        self.badge = badge
        self.cards = cards
    }

    public static let `default` = GestureOverlaySpec()
}

// MARK: - Fire-moment sub-blocks

/// `[gesture.fire.burst]` — omnidirectional particle explosion at
/// the cursor when a rule fires. Lives in its own click-through
/// window so the burst fires even when `[gesture.overlay].enabled =
/// false`.
public struct GestureFireBurstSpec: Sendable, Equatable {
    public let kind: TrailEndKind
    /// Burst particle colour. Same three-mode grammar as
    /// `[cast.fire.decal].color`:
    ///   `""` / `"trail"`  — inherit `[cast.overlay.trail].color`
    ///                       (the historical default — burst reads
    ///                       as tied to the trail accent).
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

/// `[gesture.fire.decal]` — post-fire ink decal at the cursor.
/// Independent of overlay; sits above every app in its own click-
/// through window.
public struct GestureFireDecalSpec: Sendable, Equatable {
    public let kind: DecalKind
    /// How long the decal stays visible. Clamped 0..10000;
    /// `0` collapses to `.off` regardless of `kind`.
    public let durationMs: Int
    /// Decal footprint in points. Clamped 10..500.
    public let size: Int

    // Note: a `color` knob lived here through #114 but was retired —
    // the decal's identity is the Splatoon-style multi-team ink, and
    // letting users force it to a single colour fought the whole
    // point of the shape. The dispatch path now hard-codes the
    // Splatoon palette when `kind != .off`.

    public init(kind: DecalKind = .off,
                durationMs: Int = 3000,
                size: Int = 60) {
        self.kind = kind
        self.durationMs = durationMs
        self.size = size
    }

    public static let `default` = GestureFireDecalSpec()
}

/// `[gesture.fire]` — fire-moment cursor-anchored effects. Both
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
