import CoreGraphics
import Foundation

/// `L U R D` is single-letter on purpose: grep-friendly in logs and
/// easy to type in TOML. Scroll-axis directions are not recognised yet.
public enum Direction: Character, Sendable, Hashable, CaseIterable {
    case left  = "L"
    case up    = "U"
    case right = "R"
    case down  = "D"
}

extension Array where Element == Direction {
    public var patternString: String {
        String(map { $0.rawValue })
    }
}

extension Direction {
    public var arrow: String {
        switch self {
        case .left:  return "←"
        case .up:    return "↑"
        case .right: return "→"
        case .down:  return "↓"
        }
    }
}

extension Array where Element == Sample {
    /// Largest absolute displacement from the first sample on each
    /// axis. Diagnostic for "why was nothing recognised" — a tiny
    /// span means the user barely moved.
    public var span: (dx: CGFloat, dy: CGFloat) {
        guard let first = first else { return (0, 0) }
        var dx: CGFloat = 0, dy: CGFloat = 0
        for s in self {
            dx = Swift.max(dx, abs(s.p.x - first.p.x))
            dy = Swift.max(dy, abs(s.p.y - first.p.y))
        }
        return (dx, dy)
    }
}

public struct Trigger: Sendable, Equatable {
    public enum Button: String, Sendable, CaseIterable {
        case right, middle, side1, side2
    }
    public let button: Button
    public let modifiers: Set<Modifier>
    public init(button: Button, modifiers: Set<Modifier> = []) {
        self.button = button
        self.modifiers = modifiers
    }
}

public enum Modifier: String, Sendable, Hashable, CaseIterable {
    case cmd, opt, ctrl, shift, fn
}

/// One row in `[[rules]]`. `apps` matches the **cursor-anchored
/// target** window's bundle id, not the focused app — the whole point
/// of the project. Wildcards `*` / `?`; entries starting with `!`
/// exclude (e.g. `!com.apple.dt.Xcode`).
public struct Rule: Sendable, Equatable {
    public let name: String
    public let pattern: String
    public let apps: [String]
    /// Optional title-glob filter — evaluated on top of `apps` at
    /// match time. Empty = no filter. See `Matcher.passesFilter`.
    public let filterTitle: String
    /// Optional shell predicate — evaluated on top of `apps` +
    /// `filterTitle`. Empty = no filter. The body runs via
    /// `BoundedShell.run` with a tight budget; exit 0 means the
    /// rule fires. The `WAND_TARGET_*` env vars carry the target
    /// identity into the shell, same shape as `Action.shell`.
    public let filterShell: String
    public let action: Action

    public init(name: String, pattern: String, apps: [String],
                filterTitle: String = "",
                filterShell: String = "",
                action: Action) {
        self.name = name
        self.pattern = pattern
        self.apps = apps
        self.filterTitle = filterTitle
        self.filterShell = filterShell
        self.action = action
    }
}

public enum Action: Sendable, Equatable {
    case key(String)        // e.g. `cmd+w`; the target is raised first
    case ax(String)         // `verb` ∈ axVerbs (no focus switch)
    case shell(String)      // env: WAND_TARGET_BUNDLE_ID / PID / TITLE / FRAME
    case url(String)        // open via NSWorkspace — handles https / file / custom schemes

    /// Source of truth shared by config validation (a typo drops the
    /// rule at load) and the dispatcher's switch — drift between the
    /// two would silently load no-op rules.
    public static let axVerbs: Set<String> = ["close", "minimize", "zoom", "raise"]
}

/// `t` is seconds since stroke start (NOT wall-clock) so recognition
/// is reproducible from a fixture.
public struct Sample: Sendable, Equatable {
    public let p: CGPoint
    public let t: TimeInterval
    public init(p: CGPoint, t: TimeInterval) {
        self.p = p
        self.t = t
    }
}

/// Exit-animation kind for the assist cards in the gesture overlay.
/// Raw values match the `[effect]` strings in `config.toml` so the
/// parser is a one-liner. `.random` is a selector — the adapter
/// resolves it to one of the renderable cases per card at queue time.
public enum Effect: String, Sendable, Hashable, CaseIterable {
    case none
    case drop
    case rise
    case slideLeft = "slide-left"
    case slideRight = "slide-right"
    case explode
    case vibrate
    case fade
    case fireworks
    case confetti
    case random

    /// How long the animation runs before the card is pruned. `.none`
    /// and `.random` are nonsensical here (the adapter resolves the
    /// latter first); 0 is just a placeholder so the switch stays
    /// exhaustive.
    public var duration: TimeInterval {
        switch self {
        case .none, .random:         return 0
        case .vibrate:               return 0.45
        case .fireworks, .confetti:  return 0.9
        default:                     return 0.35
        }
    }

    /// Pool that `.random` chooses from — every concrete renderable
    /// effect, excluding `.none` and the selector itself.
    public static let randomPool: [Effect] =
        Effect.allCases.filter { $0 != .none && $0 != .random }
}

/// Live "armed" decoration on the firing assist card while a stroke is
/// in progress (the card whose pattern would dispatch if the user
/// released the mouse right now). Distinct from `Effect`, which fires
/// once at button-up — `ArmedEffect` is a continuous, looping cue. The
/// rainbow border from PR #117 keeps carrying the baseline "fires on
/// release" read; these kinds layer on top.
///
/// The pac-man chomp pellet is **not** in this enum — it lives on its
/// own `chomp: Bool` flag so users can layer it on top of any `armed`
/// kind (e.g. `armed = "pulse"` + `chomp = true`).
public enum ArmedEffect: String, Sendable, Hashable, CaseIterable {
    case none
    /// Sine scale 1.0 ↔ 1.06 (~600 ms loop). Quiet — comfortable for
    /// long strokes.
    case pulse
    /// Outer halo whose alpha pulses (~700 ms loop). Reads as the
    /// card "glowing" without moving.
    case glow
    /// Continuous ±1 px tremor. Higher-frequency than `pulse` —
    /// reads as "armed / about to fire".
    case shake
    /// Twinkle particles around the card's edges (cheap dot field).
    case sparkle
    /// Marching-ants dashed border that scrolls around the rect.
    case marching
}

/// Overall size of the chosen `Effect`s. Multiplier is read by the
/// adapter to scale translation distance, scale delta, vibration
/// amplitude, and particle birth-rate / velocity. Lives in Core so the
/// parsing layer can store a typed value instead of a raw string.
public enum Intensity: String, Sendable, Hashable, CaseIterable {
    case subtle
    case normal
    case bold
    case wild

    public var multiplier: CGFloat {
        switch self {
        case .subtle: return 0.6
        case .normal: return 1.0
        case .bold:   return 1.6
        case .wild:   return 2.5
        }
    }
}

/// Trail-end burst — fire-moment effect emitted at the cursor
/// position when a gesture rule fires. Independent of the static
/// `DecalKind` (which lingers at the same point) and the assist-
/// card `Effect` (which animates the HUD card). Default `.off`.
public enum TrailEndKind: String, Sendable, Hashable, CaseIterable {
    case off
    case burst
    /// Arcade bonus-score popup: a yellow monospaced "+N" floats up
    /// from the cursor and fades, mirroring the arcade Pac-Man
    /// bonus-tile flash. Works regardless of `[cast].theme`, but
    /// reads best alongside the pac-man theme's other arcade
    /// flourishes. Picks a random value per fire from the
    /// canonical eight arcade bonus scores (100..5000).
    case arcadeScore = "arcade-score"
}

/// One of the small pac-man "pets" that walk the tome panel's
/// rounded outline when configured under
/// `[tome.decoration].line-pet`. Multiple pets ride the same path —
/// when more than one is configured they chase each other around the
/// rim in array order (first leads, the rest trail at a fixed gap).
/// Theme-agnostic: each pet's colours are baked into its silhouette.
public enum LinePet: String, Sendable, Hashable, CaseIterable {
    /// Classic yellow chomping pac-man wedge.
    case pacMan = "pac-man"
    /// Red Blinky-style ghost — dome top, two eyes, scalloped skirt.
    /// Sized larger than pac-man so the silhouette stays readable
    /// despite the small footprint.
    case ghost
}

/// Launcher panel border decoration. Default `.off` (no border).
/// `.rainbow` strokes the panel's rounded rect with a continuously
/// hue-rotating colour cycle. The remaining cases (`.terminal` etc)
/// are **static signature-colour rims** lifted from the per-theme
/// `borderColor` that lived on `TomeThemePalette` through PR #111
/// before the rim was decoupled from the theme. Each pairs visually
/// with the same-named `TomeTheme`, but the two are independent so
/// users can mix-and-match (e.g. `[tome].theme = "rainbow"` +
/// `[tome.decoration].border = "neon"`).
public enum LauncherBorder: String, Sendable, Hashable, CaseIterable {
    case off
    case rainbow
    case terminal
    case neon
    case splatoon
    case mono
    case vapor
    /// Yellow PAC-MAN rim. Renamed from `pacman` in v8 to match
    /// `TomeTheme.pacMan`.
    case pacMan = "pac-man"

    // Note: a `pacManTail` ("pac-man-tail") kind was explored and
    // dropped before landing on main — the arcade maze-wall decoration
    // (double blue line + pellets + bundled pet chase) didn't justify
    // a dedicated multi-element kind, and `border = "neon"` +
    // `[tome.decoration].line-pet = ["pac-man", "ghost"]` reproduces
    // the same look via the two single-purpose axes. Stale
    // `border = "pac-man-tail"` values fall through `parseEnum`'s
    // standard "unrecognised value" warning and clamp to `.off`.
}

/// Launcher panel open-animation. Default `.off` (panel pops in
/// instantly). `.fade` eases the panel's alpha 0 → 1; `.pop` adds a
/// brief scale-in (0.92 → 1.0) on top of the fade.
public enum LauncherOpenAnim: String, Sendable, Hashable, CaseIterable {
    case off
    case fade
    case pop
}

/// Launcher panel close-animation. Default `.off` (panel disappears
/// instantly). `.fade` eases alpha 1 → 0; `.pop` adds a scale-down
/// (1.0 → 0.92) on top.
public enum LauncherCloseAnim: String, Sendable, Hashable, CaseIterable {
    case off
    case fade
    case pop
}

/// Post-fire "ink decal" left at the cursor position when a gesture
/// fires — a Splatoon-style splatter / blob / scorch / star that
/// lingers for `fireDecalDurationMs` and fades out. Default `.off`
/// (no decal). The decal lives in its own click-through NSWindow so
/// it sits on top of every app without interfering with input.
public enum DecalKind: String, Sendable, Hashable, CaseIterable {
    case off
    case inkSplatter = "ink-splatter"
}

/// Named preset for the gesture trail's dash pattern. **Line shape
/// only — colour is always sourced from `[cast.overlay.trail].color`
/// / `color-no-match`**, so the trail's match-vs-no-match signal
/// isn't lost when the style changes. Width comes from
/// `[cast.overlay.trail].width`; glow is fixed (was previously
/// per-style on the retired `thin` / `thick` / `glow` presets).
///
/// Colour-decoration variants (rainbow / vapor / pencil) belong to a
/// separate axis applied to *other surfaces* (launcher panel border,
/// gesture tooltip border, etc.) — they're not trail-style values.
/// See `LauncherBorder` for the launcher-side counterpart.
///
/// Heavier line-shape styles — `brush` (variable width), `lightning`
/// (jagged jitter), `laser` (heavy bloom) — are reserved for follow-
/// up phases of #63 and not part of this enum until they ship.
///
/// Unknown values clamp to `.normal` (wand's typo-tolerant policy).
public enum TrailStyle: String, Sendable, Hashable, CaseIterable {
    case normal
    case dashed
    case dotted
    /// Pixel-art / retro 8-bit feel: trail is rasterised to a coarse
    /// square grid and drawn as filled cells, so the line reads as a
    /// chunky stepped pixel run instead of a smooth bezier. Colour
    /// still flows from `[cast.overlay.trail].color` per the
    /// "shape-only, not colour" invariant.
    case pixel
    /// ASCII-art trail: monospaced glyphs (`*`) placed at fixed
    /// intervals along the path, tinted with the trail colour. Same
    /// colour invariant as the other styles.
    case ascii
    /// Rainbow-road-themed pixel variant: same cell grid as
    /// `pixel`, but every 4 consecutive cells step through a
    /// spectrum-ordered palette (red → orange → yellow → green →
    /// blue → indigo → purple), so the trail reads as a
    /// rainbow track segment travelling along the path.
    /// **Style-specific exception to the "shape-only, not colour"
    /// invariant** — the palette IS the identity. `color-no-match`
    /// is still honoured: when the shape can no longer reach any
    /// rule, the whole trail switches to the no-match colour so
    /// the failure signal survives.
    case rainbowRoad = "rainbow-road"
    // Note: a `pacman` style lived here through v7 but was retired
    // in v8 — Pac-Man is now a **special theme** (`[cast].theme =
    // "pac-man"`) that locks the trail's style / width /
    // straighten-on-turn for the user, and exposes a single
    // `[cast.pac-man].size` knob (S/M/L) instead. Picking it
    // as a `TrailStyle` value silently dropped back to `.normal`,
    // which felt mis-configurable — the new shape makes "I want
    // Pac-Man" a single decision, not a four-key combo.
    /// Continuous arrow chain along the entire path — repeated
    /// chevron glyphs (`>`) rotated to match the path tangent so the
    /// trail reads as `-->-->-->` flowing toward the cursor.
    /// Replaces the cursor-only `arrowhead = true` indicator (its
    /// retired knob); use `arrow` whenever the goal is "show
    /// direction along the whole path", and any other style with
    /// the arrowhead-on-cursor look in mind needs to switch to
    /// `arrow` explicitly.
    case arrow
    /// Paw prints walking along the path — `pawprint.fill` SF
    /// Symbol drawn at fixed intervals, rotated to face the path
    /// tangent and offset alternately left / right of the
    /// centreline so consecutive prints read as L/R footprints.
    /// Tinted via `hierarchicalColor` so the trail colour flows
    /// through and match-vs-no-match stays in colour like the
    /// other styles. `width` is re-purposed as a scale multiplier
    /// on print size + spacing.
    case paws
}

/// The window the stroke acts on. Resolved at *button-down* time —
/// actions dispatch to **this** window, never to whichever has focus
/// at button-up. Plain data so Core stays free of AX types.
public struct Target: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String
    public let title: String
    public let frame: CGRect
    /// CGWindowID of the resolved window (0 when the window couldn't
    /// be resolved). Used as the side-table key in the adapter to map
    /// this value-type back to a live `AXUIElement` at action-dispatch
    /// time. Stored as `UInt32` so Core can carry it around without
    /// depending on CoreGraphics's `CGWindowID` typedef.
    public let windowID: UInt32
    public init(pid: Int32, bundleID: String, title: String,
                frame: CGRect, windowID: UInt32 = 0) {
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.windowID = windowID
    }
}
