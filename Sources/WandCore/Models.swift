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

/// Activation context for a cast rule — which target-resolution
/// regime the rule belongs to. The TOML namespace the row was declared
/// under (`[[cast.cursor.rule]]` vs `[[cast.focused.rule]]`) maps
/// 1-to-1 onto this enum, so the rule's behaviour at match time is
/// visible from the section header alone — no per-row boolean
/// scattered through the file.
public enum RuleContext: Sendable, Hashable {
    /// `[[cast.cursor.rule]]` — the default. Fires only when the
    /// cursor-anchored AX walk resolves a target (the spine
    /// guarantee). On non-AX surfaces (Desktop / Dock / menu bar) the
    /// stroke is dropped entirely.
    case cursor
    /// `[[cast.focused.rule]]` — frontmost-app fallback. Fires only
    /// when the cursor-anchored AX walk FAILED and EventTap
    /// synthesised a target from `NSWorkspace.frontmostApplication`.
    /// `apps` is matched against that frontmost bundle id, so a rule
    /// scoped to a specific app stays predictable. A rule that should
    /// fire in both regimes must be declared in both namespaces.
    case focused
}

/// One row in `[[cast.cursor.rule]]` or `[[cast.focused.rule]]`.
/// `apps` matches the **cursor-anchored target** window's bundle id
/// (cursor rules) or the **frontmost app's** bundle id (focused
/// rules) — see `RuleContext`. Wildcards `*` / `?`; entries starting
/// with `!` exclude (e.g. `!com.apple.dt.Xcode`).
public struct Rule: Sendable, Equatable {
    public let name: String
    public let pattern: String
    public let apps: [String]
    /// Optional icon shown to the left of `name` in the assist card.
    /// Same syntax as `LauncherItem.icon` — `SF:<name>`, an emoji /
    /// text glyph, an absolute / tilde / config-relative file path, or
    /// `app:<bundle-id>`. Empty = no icon (the card collapses its icon
    /// column). Unresolvable specs log once and fall through to no icon.
    public let icon: String
    /// Optional title-glob filter — evaluated on top of `apps` at
    /// match time. Empty = no filter. See `Matcher.passesFilter`.
    public let filterTitle: String
    /// Optional shell predicate — evaluated on top of `apps` +
    /// `filterTitle`. Empty = no filter. The body runs via
    /// `BoundedShell.run` with a tight budget; exit 0 means the
    /// rule fires. The `WAND_TARGET_*` env vars carry the target
    /// identity into the shell, same shape as `Action.shell`.
    public let filterShell: String
    /// Which TOML namespace this row came from — `.cursor` for
    /// `[[cast.cursor.rule]]`, `.focused` for `[[cast.focused.rule]]`.
    /// Matcher gates each stroke on this so cursor rules fire only on
    /// resolved AX targets and focused rules fire only on the
    /// frontmost-app fallback — strict partition, not a superset.
    public let context: RuleContext
    public let action: Action

    public init(name: String, pattern: String, apps: [String],
                icon: String = "",
                filterTitle: String = "",
                filterShell: String = "",
                context: RuleContext = .cursor,
                action: Action) {
        self.name = name
        self.pattern = pattern
        self.apps = apps
        self.icon = icon
        self.filterTitle = filterTitle
        self.filterShell = filterShell
        self.context = context
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
/// Raw values match the `[cast.overlay.cards]` strings in `config.toml`
/// so the parser is a one-liner. `.random` is a selector — the adapter
/// resolves it to one of the renderable cases per card at queue time.
public enum Effect: String, Sendable, Hashable, CaseIterable {
    case off
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

    /// How long the animation runs before the card is pruned. `.off`
    /// and `.random` are nonsensical here (the adapter resolves the
    /// latter first); 0 is just a placeholder so the switch stays
    /// exhaustive.
    public var duration: TimeInterval {
        switch self {
        case .off, .random:          return 0
        case .vibrate:               return 0.45
        case .fireworks, .confetti:  return 0.9
        default:                     return 0.35
        }
    }

    /// Pool that `.random` chooses from — every concrete renderable
    /// effect, excluding `.off` and the selector itself.
    public static let randomPool: [Effect] =
        Effect.allCases.filter { $0 != .off && $0 != .random }
}

/// Live "armed" decoration on the firing assist card while a stroke is
/// in progress (the card whose pattern would dispatch if the user
/// released the mouse right now). Distinct from `Effect`, which fires
/// once at button-up — `ArmedEffect` is a continuous, looping cue. The
/// rainbow border carries the baseline "fires on release" read; these
/// kinds layer on top.
public enum ArmedEffect: String, Sendable, Hashable, CaseIterable {
    case off
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

// `Intensity` (subtle/normal/bold/wild magnitude knob) was promoted to
// sill's `Palette` module as `EffectIntensity` (atelier block-6 — wand
// and perch hand-copied the identical 0.6/1.0/1.6/2.5 vocabulary). The
// config now stores `EffectIntensity`; its `.multiplier` returns a
// `Double`, so adapter sites that want `CGFloat` wrap at the use site.

/// Trail-end burst — fire-moment effect emitted at the cursor
/// position when a gesture rule fires. Independent of the static
/// `DecalKind` (which lingers at the same point) and the assist-
/// card `Effect` (which animates the HUD card). Default `.off`.
public enum TrailEndKind: String, Sendable, Hashable, CaseIterable {
    case off
    case burst
    /// Arcade bonus-score popup: a yellow monospaced "+N" floats up
    /// from the cursor and fades, mirroring the arcade Chomp
    /// bonus-tile flash. Works regardless of `[cast].theme`, but
    /// reads best alongside the chomp theme's other arcade
    /// flourishes. Picks a random value per fire from the
    /// canonical eight arcade bonus scores (100..5000).
    case arcadeScore = "arcade-score"
}

// `LinePet` (the chomp / ghost pets walking a surface outline) lives in
// sill's `Palette` since 0.6.0 — pure (no-AppKit) so Core can validate it,
// and the drawing (`Effects.drawLinePets`) is shared family-wide. Imported
// from `Palette`, not redefined here (was a wand-local duplicate).

/// Tome panel border decoration. Default `.off` (no border).
/// `.rainbow` strokes the panel's rounded rect with a continuously
/// hue-rotating colour cycle. The remaining cases are **static
/// signature-colour rims** that each pair visually with the same-named
/// `[tome].theme` but are independent of it, so users can mix-and-match
/// (e.g. `[tome].theme = "rainbow"` + `[tome.decoration.border].effect =
/// "neon"`).
public enum LauncherBorder: String, Sendable, Hashable, CaseIterable {
    case off
    case rainbow
    case terminal
    case neon
    case splatoon
    case mono
    case vapor
    case chomp = "chomp"
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

/// Banner shown at the cursor when the in-progress gesture falls off
/// every reachable rule (the trail flips into the no-match colour).
/// Drawn from `[cast.overlay.no-match].kind`; default `.off` (no
/// banner). Decoupled from `[cast].theme` so users can pair the
/// arcade GAME OVER cue with any theme — chomp's red-wall flash is
/// a separate, theme-specific effect that fires independently.
public enum NoMatchBanner: String, Sendable, Hashable, CaseIterable {
    case off
    /// Arcade-style "GAME OVER" banner anchored at the cursor's
    /// upper-right (where the firing card would have been). Brief
    /// scale-in pop on first appearance + 2 Hz blink while the
    /// stroke remains off every rule.
    case gameOver = "game-over"
}

/// Named preset for the cast trail's dash pattern. **Line shape only
/// — colour is always sourced from `[cast.overlay.trail].color` /
/// `color-no-match`**, so the trail's match-vs-no-match signal isn't
/// lost when the style changes. Width comes from
/// `[cast.overlay.trail].width`.
///
/// Colour-decoration variants belong to a separate axis applied to
/// other surfaces (tome panel border, etc.) — they're not trail-style
/// values. See `LauncherBorder` for the tome-side counterpart.
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
    /// Continuous arrow chain along the entire path — repeated
    /// chevron glyphs (`>`) rotated to match the path tangent so the
    /// trail reads as `-->-->-->` flowing toward the cursor.
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
    /// `true` when this target was synthesised from
    /// `NSWorkspace.frontmostApplication` because the cursor-anchored
    /// AX walk + CGWindowList fallback both came back empty (cursor
    /// over Desktop / Dock / menu bar). Routed to the Matcher so only
    /// `[[cast.focused.rule]]` rules fire here; `[[cast.cursor.rule]]`
    /// rules treat a synthesised target as "no spine, no fire" and
    /// drop the stroke. Default `false` keeps the strict cursor-rule
    /// regime for code paths that don't know about the fallback.
    public let isFocusedFallback: Bool
    public init(pid: Int32, bundleID: String, title: String,
                frame: CGRect, windowID: UInt32 = 0,
                isFocusedFallback: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.windowID = windowID
        self.isFocusedFallback = isFocusedFallback
    }
}
