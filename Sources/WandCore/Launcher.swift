// Launcher data model — the second trigger family wand exposes,
// alongside the gesture trigger. A single button-press (default
// middle-click) pops up a contextual menu near the cursor; each
// entry is one of the existing `Action` cases, so the dispatcher
// stays trigger-agnostic.
//
// The TOML shape (`[[item]]`) is intentionally parallel to
// `[[rules]]` minus `pattern` plus `group` for nesting:
//
//   [[item]]
//   name = "タブを閉じる"
//   apps = ["*chrome*", "*safari*"]
//   action-type = "key"
//   action-keys = "cmd+w"
//
//   [[item]]
//   name = "なし"
//   group = ["表示順序"]            # in the "表示順序" submenu
//   separator-before = true
//   action-type = "shell"
//   action-cmd = "..."

import Foundation

/// One row of the launcher menu. Same target / app-filter / action
/// semantics as `Rule`, minus the gesture pattern, plus presentation
/// hints (`group`, `separatorBefore`).
/// Template for the rows a `dynamic` item expands to at menu-open
/// time. Each field can carry the `{line}` placeholder; the adapter
/// substitutes it with each stdout line from the dynamic shell
/// command. Kept as raw strings (not pre-parsed `Action`) so the
/// `{line}` placeholder survives until expansion.
public struct LauncherTemplate: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case key, ax, shell, url
    }
    public let kind: Kind
    /// Body string (action-keys / action-verb / action-cmd /
    /// action-url depending on `kind`). `{line}` placeholders here
    /// are filled per row.
    public let payload: String
    /// Display label template — defaults to `"{line}"` when the
    /// user doesn't override.
    public let name: String
    /// Optional icon template — same syntax as `LauncherItem.icon`,
    /// {line}-substituted.
    public let icon: String
    public init(kind: Kind, payload: String, name: String, icon: String) {
        self.kind = kind
        self.payload = payload
        self.name = name
        self.icon = icon
    }
}

public struct LauncherItem: Sendable, Equatable {
    public let name: String
    /// Path of parent submenus (top-down). Empty = top level. Adapter
    /// builds the tree by walking items in document order: a group
    /// folder is created on first reference and items append into it.
    public let group: [String]
    /// Draw a separator immediately above this item. Lets the user
    /// group entries visually without needing a folder.
    public let separatorBefore: Bool
    /// Same glob syntax as `Rule.apps` — matches against the cursor-
    /// anchored target. Items whose filter excludes the current
    /// target are pruned from the menu before it is shown.
    public let apps: [String]
    /// Optional section header — a short label drawn above this item
    /// when its value differs from the previous item's. Lets a long
    /// `[[launcher.item]]` list split into labelled bands ("Editing",
    /// "Window", "Tools") without nesting into submenus. Empty value
    /// (the default) inherits whatever the previous item used, so a
    /// run of items can share one header without repeating it on each
    /// row. Section headers only render in `.list` layout; toolbar
    /// variants ignore the field. After filter (apps / title / shell)
    /// drops every item in a section, the section's header is
    /// suppressed automatically — no orphan labels.
    public let header: String
    /// Optional icon spec. Resolved by the adapter at menu-build
    /// time. Recognised forms:
    ///   - `""` (empty) — no icon
    ///   - `"SF:<name>"` — SF Symbol (e.g. `SF:globe`, macOS 11+).
    ///   - `"/abs/path.png"` — absolute file path
    ///   - `"~/relative.png"` — tilde-expanded path
    ///   - `"icons/foo.png"` — path relative to `~/.config/wand/`
    ///     (or whatever directory holds the config that defined
    ///     this item — the adapter resolves against `WandConfig.
    ///     path`'s parent)
    ///   - anything else — drawn as a text/emoji glyph (1-2 chars
    ///     is typical: `"🌐"`, `"⚡"`, `"AI"`)
    /// Unresolvable specs log once and fall through to no-icon.
    public let icon: String
    /// Optional second line drawn under `name`. Use it to explain
    /// what an opaque `shell` action does, or to disambiguate two
    /// identically-named items. Empty = no second line and the row
    /// keeps its single-line height. Only rendered in `.list` layout
    /// (toolbar variants are too short for a subtitle to fit).
    /// `LauncherTemplate.{line}` substitution applies here too, so a
    /// dynamic-item template can carry `subtitle = "{line}"`.
    public let subtitle: String
    /// Optional tint color applied to **SF Symbol icons only**. Same
    /// grammar as the gesture-overlay colour keys: named colours
    /// (`"systemRed"` / `"red"` / `"orange"` / …, or `"accent"` for
    /// the system accent) and hex (`#rgb` / `#rrggbb` / `#rrggbbaa`).
    /// Empty (the default) renders the symbol in `.labelColor`.
    /// File / emoji / text icons ignore this — they have no
    /// hierarchical-color path.
    public let tint: String
    /// Optional **multi-colour palette** for SF Symbol icons. Each
    /// string uses the same grammar as `tint`. When non-empty, the
    /// palette wins over the single `tint` and is applied via
    /// `NSImage.SymbolConfiguration(paletteColors:)` — best for
    /// hierarchical / multicolor SF Symbol variants (`flame.fill`,
    /// `paintbrush.pointed.fill`, etc). Symbols without a multicolor
    /// variant still render the first palette colour. File / emoji /
    /// text icons ignore this entirely.
    public let tintColors: [String]
    /// Optional **SF Symbol icon animation**, fired on row hover.
    /// Recognised values: `"bounce"` / `"pulse"` (macOS 14+). Empty
    /// (default) = static icon. Unknown values log + fall back to
    /// no animation. macOS 13 ignores the field entirely. Only
    /// affects SF Symbol icons (file / emoji / text icons have no
    /// SymbolEffect path).
    public let iconAnim: String
    /// Title-glob filter on top of `apps`. Empty = no filter.
    /// Matched against the cursor-anchored target's window title at
    /// menu-open time. Same `*` / `?` glob as `apps`.
    public let filterTitle: String
    /// Shell predicate on top of `apps` + `filterTitle`. Empty = no
    /// filter. Evaluated at menu-open via `BoundedShell.run` with a
    /// tight budget; exit 0 keeps the item in the menu. Use for
    /// niche conditions that can't be expressed as a title glob —
    /// time of day, OS version, browser URL via AppleScript, etc.
    public let filterShell: String
    /// Checkmark / radio state spec. Empty = no marker. Recognised:
    ///   `"on"`          — always ✓
    ///   `"off"`         — explicit no-marker (same as empty)
    ///   `"mixed"`       — dash marker
    ///   `"shell:<cmd>"` — run `<cmd>` at panel open; exit 0 → ✓,
    ///                     non-zero → no marker. 100 ms timeout.
    /// Adapter evaluates this once per popup (no caching) and
    /// prepends the resolved glyph (`✓` / `–`) to the row title. Use
    /// it for toggle items where the active option should read as
    /// "selected" at a glance.
    public let state: String
    /// Dynamic-row producer. Non-empty marks the item as a
    /// submenu-with-shell-children: at every menu-open the adapter
    /// runs `dynamic` under `/bin/sh -c`, splits stdout by newline,
    /// and emits one child per line built from `template`. The
    /// item's own `action` is unused in that case (the parent only
    /// holds the submenu).
    public let dynamic: String
    /// Template for children of a dynamic item. Required when
    /// `dynamic` is non-empty; otherwise unused.
    public let template: LauncherTemplate?
    public let action: Action

    public init(name: String, group: [String] = [],
                separatorBefore: Bool = false,
                apps: [String] = ["*"],
                header: String = "",
                subtitle: String = "",
                icon: String = "",
                tint: String = "",
                tintColors: [String] = [],
                iconAnim: String = "",
                filterTitle: String = "",
                filterShell: String = "",
                state: String = "",
                dynamic: String = "",
                template: LauncherTemplate? = nil,
                action: Action) {
        self.name = name
        self.group = group
        self.separatorBefore = separatorBefore
        self.apps = apps
        self.header = header
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.tintColors = tintColors
        self.iconAnim = iconAnim
        self.filterTitle = filterTitle
        self.filterShell = filterShell
        self.state = state
        self.dynamic = dynamic
        self.template = template
        self.action = action
    }
}

/// Visual orientation of the launcher panel.
/// - `.list`            — vertical list of rows (icon + label). The
///                        default, fits up to ~30 items, supports
///                        submenus and dynamic items, scales
///                        naturally for menu-like usage.
/// - `.toolbar`         — horizontal row of icon-only buttons
///                        (PopClip style). The item's `name` becomes
///                        a tooltip. Best for short, focused command
///                        sets (text-selection actions, ~6-8 items).
/// - `.labeledToolbar`  — horizontal row of icon + label "pill"
///                        buttons. Same use case as `.toolbar` but
///                        labels are always visible, so each button
///                        is wider and item count budget is smaller
///                        (~4-6 items). Best when actions need
///                        their names to read at a glance.
/// In all toolbar variants, folder / dynamic items open a child
/// panel BELOW the hovered button, and the child panel itself uses
/// `.list` regardless of the parent's layout.
public enum LauncherLayout: String, Sendable, Hashable, CaseIterable {
    case list
    case toolbar
    case labeledToolbar = "labeled-toolbar"

    /// True for layouts whose root panel renders as a horizontal
    /// stack (toolbar variants). Children always open below in this
    /// case; for `.list` they open to the right.
    public var isHorizontal: Bool {
        switch self {
        case .list:                       return false
        case .toolbar, .labeledToolbar:   return true
        }
    }
}

// MARK: - Theme

/// Coordinated colour palette for the tome panel. Fields are paths
/// the colour-parser understands (named `"systemRed"` / `"accent"`,
/// hex `"#rrggbb"`, …) or empty string to fall back to the system
/// default. The palette only nudges a handful of surfaces — the
/// panel still rides on the system `NSVisualEffectView .menu`
/// material, so themes layer onto vibrancy instead of replacing it.
public struct TomeThemePalette: Sendable, Equatable {
    /// Hover-row background fill. Empty = `NSColor.controlAccentColor`
    /// (the macOS default). When a theme overrides this, the row's
    /// hover state reads in the theme's accent instead of the
    /// generic system blue.
    public let accentColor: String
    /// Text colour while a row is hovered. Empty = white (the
    /// historical default that paired with the system blue accent).
    /// Themes whose accent isn't dark-enough for white text override
    /// this — e.g. yellow accent → black hover text.
    public let accentTextColor: String
    /// Default idle row text colour. Empty = `.labelColor` (system
    /// semantic). Terminal-style themes use this to keep every row
    /// in the theme's signature hue.
    public let textColor: String
    /// Panel background fill. Empty (the default) keeps the system
    /// `NSVisualEffectView .menu` frosted blur (vibrancy). Non-empty
    /// **replaces** the blur with a solid colour — required for
    /// themes that need a saturated backdrop the blur can't deliver
    /// (e.g. pac-man's pure black, terminal's editor-black). Use a
    /// fully-opaque hex; alpha-channel suffixes work but read as
    /// "tinted blur" rather than "themed surface".
    public let backgroundColor: String

    // Note: a `borderColor` field lived here through PR #111 to draw a
    // 1pt static frame in the theme's signature hue. Retired because
    // it overlapped (and visually swallowed) the animated rim drawn
    // by `[tome.decoration].border`. Panel outlines are now solely a
    // `[tome.decoration]` axis concern.

    public init(accentColor: String = "",
                accentTextColor: String = "",
                textColor: String = "",
                backgroundColor: String = "") {
        self.accentColor = accentColor
        self.accentTextColor = accentTextColor
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }
}

/// `[tome].theme` — coordinated colour palette for the launcher
/// panel. Mirrors `[cast].theme`'s shape (same enum cases) so a
/// user can pick the same look for both surfaces, but the per-case
/// palette is tuned for a menu UI rather than a trail/HUD. Unknown
/// names clamp to `.default`.
public enum TomeTheme: String, Sendable, CaseIterable {
    case `default`
    case terminal
    case neon
    case splatoon
    case mono
    case vapor
    /// Pairs with `[cast].theme = "pac-man"` for a coordinated arcade
    /// look across both surfaces. Renamed from `pacman` in v8.
    case pacMan = "pac-man"
    /// Vivid rainbow palette inspired by facet's namesake — white
    /// text on a deep violet-black backdrop, hot-rose hover accent,
    /// electric-cyan static outline. Static palette: per-pixel hue
    /// cycling isn't a fit (the panel doesn't redraw per-frame).
    /// Pair with `[tome.decoration].border = "rainbow"` for an
    /// animated cycling outline that brings the "rainbow" name to
    /// life across the panel rim.
    case rainbow
    /// Polar-lights variant of `rainbow` — calmer pastel palette
    /// (deep-navy backdrop, pastel-mint accent, gold rim, soft off-
    /// white rows). Reads as the static cousin of `rainbow` for
    /// users who want the same colour family without the high-
    /// contrast vivid edge.
    case aurora

    // Dynamic per-frame colour cycling isn't a tome theme axis (the
    // panel doesn't redraw frame-by-frame). The animated "rainbow"
    // expression on this surface is `[tome.decoration].border =
    // "rainbow"` — a `CAKeyframeAnimation` on the panel outline that
    // pairs with the `.rainbow` theme above.

    public var palette: TomeThemePalette {
        switch self {
        case .default:
            return TomeThemePalette()
        case .terminal:
            // Tokyo-Night green text + green hover on a solid black
            // editor backdrop. Hover text inverts to black so the
            // row reads as a flat green chip when selected.
            return TomeThemePalette(
                accentColor: "#22c55e",
                accentTextColor: "#000000",
                textColor: "#22c55e",
                backgroundColor: "#000000")
        case .neon:
            return TomeThemePalette(
                accentColor: "#22d3ee",
                accentTextColor: "#0f0a1f",
                textColor: "#ffffff",
                backgroundColor: "#0f0a1f")
        case .splatoon:
            // Splatoon's per-stroke team-colour rotation isn't a fit
            // for the menu (which lives across many panel-opens, not
            // one stroke). Picks the hot-pink/lime canonical pair
            // statically — same vibe, no flicker.
            return TomeThemePalette(
                accentColor: "#ff3399",
                accentTextColor: "#ffffff",
                textColor: "#ffffff",
                backgroundColor: "#1a1a1a")
        case .mono:
            return TomeThemePalette(
                accentColor: "#ffffff",
                accentTextColor: "#000000",
                textColor: "#ffffff",
                backgroundColor: "#000000")
        case .vapor:
            return TomeThemePalette(
                accentColor: "#ff79c6",
                accentTextColor: "#282a36",
                textColor: "#f8f8f2",
                backgroundColor: "#282a36")
        case .pacMan:
            // Yellow PAC-MAN accent with black hover text on the
            // canonical arcade black backdrop — pairs with
            // `[cast].theme = "pac-man"` for a coordinated look
            // across both surfaces.
            return TomeThemePalette(
                accentColor: "#ffea00",
                accentTextColor: "#000000",
                textColor: "#ffea00",
                backgroundColor: "#000000")
        case .rainbow:
            // facet's `rainbow` shape: deep violet-black backdrop,
            // white rows, hot-rose hover (so the selection reads
            // unambiguously even against the saturated bg). Pairs
            // with `[tome.decoration].border = "rainbow"` for the
            // animated outline that supplies the spectrum cycle —
            // the panel rim is now solely a decoration concern.
            return TomeThemePalette(
                accentColor: "#ff3b6e",
                accentTextColor: "#ffffff",
                textColor: "#ffffff",
                backgroundColor: "#1a0a2e")
        case .aurora:
            // Polar-lights variant: deep navy backdrop, pastel-mint
            // hover, off-white rows. Calmer counterpart to `rainbow`
            // — same colour family, softer contrast.
            return TomeThemePalette(
                accentColor: "#88e1c9",
                accentTextColor: "#0a0e27",
                textColor: "#f0f0f5",
                backgroundColor: "#0a0e27")
        }
    }
}

/// `[launcher.row]` — per-row visual conventions that affect every
/// `[[launcher.item]]` uniformly. Split out of the bare `[launcher]`
/// block in v6 so the trigger-identity fields (button / modifiers /
/// enabled / layout) don't mix with row cosmetics.
public struct LauncherRowSpec: Sendable, Equatable {
    /// Auto-derive a `⌘W`-style glyph badge from an item's
    /// `action-keys` and render it right-aligned on `.list` rows
    /// whose action is `.key(...)`. `false` suppresses every badge
    /// globally. Default `true`. Has no effect on toolbar layouts.
    public let shortcutBadge: Bool
    /// Soft rounded chip behind emoji / text-glyph icons so they sit
    /// on the same visual footprint as SF Symbol icons. No effect on
    /// SF Symbol / file-path icons. Default `true`.
    public let iconChip: Bool

    public init(shortcutBadge: Bool = true,
                iconChip: Bool = true) {
        self.shortcutBadge = shortcutBadge
        self.iconChip = iconChip
    }

    public static let `default` = LauncherRowSpec()
}

/// `[launcher.animation]` — temporal panel transitions (open/close).
/// Split from v5's `[launcher.effect]` because animations and the
/// static `border` decoration sit on different axes — one moves in
/// time, the other paints once. v6 makes that axis split explicit.
public struct LauncherAnimationSpec: Sendable, Equatable {
    public let open: LauncherOpenAnim
    public let close: LauncherCloseAnim

    public init(open: LauncherOpenAnim = .off,
                close: LauncherCloseAnim = .off) {
        self.open = open
        self.close = close
    }

    public static let `default` = LauncherAnimationSpec()
}

/// `[launcher.decoration]` — static panel decoration. Currently just
/// the `border`, but the section name leaves room for solid hues /
/// vapor / pencil variants that paint once and don't animate.
public struct LauncherDecorationSpec: Sendable, Equatable {
    public let border: LauncherBorder
    /// Cycle period (ms) for animated decorations — currently only the
    /// `border = "rainbow"` outline. Clamped 500..10000. Static border
    /// kinds (`off`) ignore it.
    public let cycleMs: Int
    /// Stroke width (points) for the panel border. Clamped 1..10.
    /// Ignored when `border = "off"`. Default 2 matches the pre-knob
    /// hardcoded value, so existing configs stay visually identical.
    public let borderWidth: Int

    public init(border: LauncherBorder = .off,
                cycleMs: Int = 4000,
                borderWidth: Int = 2) {
        self.border = border
        self.cycleMs = cycleMs
        self.borderWidth = borderWidth
    }

    public static let `default` = LauncherDecorationSpec()
}

/// The whole `[launcher]` block. `trigger` lives here (not the top-
/// level `[trigger]` which gestures own) so each family has its own
/// button. `enabled = false` keeps the tap from being installed at
/// all — same opt-out shape as `overlay.enabled`. `layout` is the
/// orientation primitive (single value, kept inline).
///
/// Row cosmetics, panel animations, and static decorations live in
/// dedicated sub-blocks (`row` / `animation` / `decoration`) so each
/// concern is visible from the section path alone.
public struct LauncherSpec: Sendable, Equatable {
    public let enabled: Bool
    public let trigger: Trigger
    public let layout: LauncherLayout
    public let items: [LauncherItem]
    public let row: LauncherRowSpec
    public let animation: LauncherAnimationSpec
    public let decoration: LauncherDecorationSpec
    public let theme: TomeTheme

    public init(enabled: Bool, trigger: Trigger,
                layout: LauncherLayout = .list,
                items: [LauncherItem],
                row: LauncherRowSpec = .default,
                animation: LauncherAnimationSpec = .default,
                decoration: LauncherDecorationSpec = .default,
                theme: TomeTheme = .default) {
        self.enabled = enabled
        self.trigger = trigger
        self.layout = layout
        self.items = items
        self.row = row
        self.animation = animation
        self.decoration = decoration
        self.theme = theme
    }

    public static let `default` = LauncherSpec(
        enabled: false,
        trigger: Trigger(button: .middle, modifiers: []),
        layout: .list,
        items: [],
        row: .default,
        animation: .default,
        decoration: .default,
        theme: .default
    )
}

/// Result of parsing a standalone items file (the `--show-menu
/// --items <PATH>` input). Carries both the items and the file's
/// optional `[launcher].layout` declaration so the external-trigger
/// path can pick the right UI without consulting the main config.
public struct LauncherItemsFile: Sendable, Equatable {
    public let layout: LauncherLayout
    public let items: [LauncherItem]
    public init(layout: LauncherLayout, items: [LauncherItem]) {
        self.layout = layout
        self.items = items
    }
}
