// Tome data model — the second trigger family wand exposes,
// alongside the cast trigger. A single button-press (default
// middle-click) pops up a contextual menu near the cursor; each
// entry is one of the existing `Action` cases, so the dispatcher
// stays trigger-agnostic.
//
// The TOML shape (`[[tome.cursor.item]]`) is intentionally parallel to
// `[[cast.cursor.rule]]` minus `pattern` plus `group` for nesting.

import Foundation
import Palette   // LinePet (shared pet vocabulary)

/// One row of the tome menu. Same target / app-filter / action
/// semantics as `Rule`, minus the cast pattern, plus presentation
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
    /// `[[tome.cursor.item]]` list split into labelled bands ("Editing",
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
///                        (toolbar-style). The item's `name` becomes
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
    /// (e.g. chomp's pure black, terminal's editor-black). Use a
    /// fully-opaque hex; alpha-channel suffixes work but read as
    /// "tinted blur" rather than "themed surface".
    public let backgroundColor: String

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

/// `[tome.row]` — per-row visual conventions that affect every
/// `[[tome.cursor.item]]` uniformly.
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
    /// Title font size (points). Drives the whole row's footprint:
    /// row height and icon size scale proportionally so larger
    /// fonts get a larger panel rather than truncated text. Clamped
    /// 11..32. Default 13 matches macOS' menu font baseline (the
    /// pre-knob hardcoded size), so the historical look survives
    /// when the key is omitted.
    public let fontSize: Int

    public init(shortcutBadge: Bool = true,
                iconChip: Bool = true,
                fontSize: Int = 13) {
        self.shortcutBadge = shortcutBadge
        self.iconChip = iconChip
        self.fontSize = fontSize
    }

    public static let `default` = LauncherRowSpec()
}

/// `[tome.animation]` — temporal panel transitions (open/close).
/// Distinct from `[tome.decoration]` (which paints once and stays).
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

/// `[tome.decoration]` — static panel decoration that paints once.
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
    /// macOS window drop shadow under the panel. Default `false`:
    /// avoids a thin dark halo just outside the rim that some users
    /// read as a fringe on the border decoration. Set `true` to
    /// restore the system menu shadow look.
    public let shadow: Bool
    /// Chomp "pets" that walk the panel's rounded outline. Default
    /// `[]` (no pets). Theme-agnostic — each pet's silhouette is
    /// baked in, so they stand alongside any `[tome].theme`. When
    /// more than one is configured they chase each other in array
    /// order around the rim.
    public let linePets: [LinePet]

    public init(border: LauncherBorder = .off,
                cycleMs: Int = 4000,
                borderWidth: Int = 2,
                shadow: Bool = false,
                linePets: [LinePet] = []) {
        self.border = border
        self.cycleMs = cycleMs
        self.borderWidth = borderWidth
        self.shadow = shadow
        self.linePets = linePets
    }

    public static let `default` = LauncherDecorationSpec()
}

/// The whole `[tome]` block. `trigger` lives here (not at top level)
/// so each trigger family has its own button. `enabled = false` keeps
/// the tap from being installed at all. Row cosmetics, panel
/// animations, and static decorations live in dedicated sub-blocks
/// (`row` / `animation` / `decoration`).
public struct LauncherSpec: Sendable, Equatable {
    public let enabled: Bool
    public let trigger: Trigger
    public let layout: LauncherLayout
    public let items: [LauncherItem]
    public let row: LauncherRowSpec
    public let animation: LauncherAnimationSpec
    public let decoration: LauncherDecorationSpec
    /// `[tome].theme` — canonical theme name (sill catalog + wand
    /// engine themes); the tome palette is derived via `wandTomePalette`.
    public let theme: String

    public init(enabled: Bool, trigger: Trigger,
                layout: LauncherLayout = .list,
                items: [LauncherItem],
                row: LauncherRowSpec = .default,
                animation: LauncherAnimationSpec = .default,
                decoration: LauncherDecorationSpec = .default,
                theme: String = wandDefaultThemeName) {
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
        theme: wandDefaultThemeName
    )
}

/// Result of parsing a standalone items file (the `tome --open
/// --items <PATH>` input). Carries both the items and the file's
/// optional `[tome].layout` declaration so the external-trigger
/// path can pick the right UI without consulting the main config.
public struct LauncherItemsFile: Sendable, Equatable {
    public let layout: LauncherLayout
    public let items: [LauncherItem]
    public init(layout: LauncherLayout, items: [LauncherItem]) {
        self.layout = layout
        self.items = items
    }
}
