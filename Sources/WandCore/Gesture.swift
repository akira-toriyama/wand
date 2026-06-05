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
    /// Stroke width in points. Clamped 1..40. Style presets may
    /// adjust this — `thin` halves, `thick` doubles, etc.
    public let width: Int
    /// Named preset bundling width × glow × dash. Shape only — colour
    /// always comes from `color` / `colorNoMatch`.
    public let style: TrailStyle
    /// How long (ms) the trail lingers after a gesture fires.
    /// Clamped 0..2000; `0` = instant clear.
    public let finalHoldMs: Int

    public init(color: String = "#3b82f6",
                colorNoMatch: String = "#ef4444",
                width: Int = 3,
                style: TrailStyle = .normal,
                finalHoldMs: Int = 400) {
        self.color = color
        self.colorNoMatch = colorNoMatch
        self.width = width
        self.style = style
        self.finalHoldMs = finalHoldMs
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

    public init(match: Effect = .none,
                unmatch: Effect = .none) {
        self.match = match
        self.unmatch = unmatch
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
    public let trail: GestureOverlayTrailSpec
    public let badge: GestureOverlayBadgeSpec
    public let cards: GestureOverlayCardsSpec

    public init(enabled: Bool = true,
                blurEnabled: Bool = true,
                trail: GestureOverlayTrailSpec = .default,
                badge: GestureOverlayBadgeSpec = .default,
                cards: GestureOverlayCardsSpec = .default) {
        self.enabled = enabled
        self.blurEnabled = blurEnabled
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

    public init(kind: TrailEndKind = .off) {
        self.kind = kind
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
    /// Decal footprint in points. Clamped 10..200.
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
