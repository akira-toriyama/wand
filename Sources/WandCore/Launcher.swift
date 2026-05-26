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
                icon: String = "",
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
        self.icon = icon
        self.filterTitle = filterTitle
        self.filterShell = filterShell
        self.state = state
        self.dynamic = dynamic
        self.template = template
        self.action = action
    }
}

/// Visual orientation of the launcher panel.
/// - `.list`    — vertical list of rows (icon + label). The default,
///                fits up to ~30 items, supports submenus and dynamic
///                items, scales naturally for menu-like usage.
/// - `.toolbar` — horizontal row of icon-only buttons (PopClip
///                style). The item's `name` becomes a tooltip. Best
///                for short, focused command sets (text-selection
///                actions, ~6-8 items). Folder / dynamic items still
///                open a child panel below, which uses `.list`
///                regardless of the parent's layout.
public enum LauncherLayout: String, Sendable, Hashable, CaseIterable {
    case list
    case toolbar
}

/// The whole `[launcher]` block. `trigger` lives here (not the top-
/// level `[trigger]` which gestures own) so each family has its own
/// button. `enabled = false` keeps the tap from being installed at
/// all — same opt-out shape as `overlay.enabled`.
///
/// The launcher UI is always a non-activating NSPanel — the user
/// keeps keyboard focus in the underlying app while picking. There
/// is no NSMenu fallback (it was removed once panel-mode covered the
/// schema completely). `layout` chooses the panel's orientation;
/// the items-file `[launcher].layout` overrides this one for the
/// `wand --show-menu` external-trigger path.
public struct LauncherSpec: Sendable, Equatable {
    public let enabled: Bool
    public let trigger: Trigger
    public let layout: LauncherLayout
    public let items: [LauncherItem]

    public init(enabled: Bool, trigger: Trigger,
                layout: LauncherLayout = .list,
                items: [LauncherItem]) {
        self.enabled = enabled
        self.trigger = trigger
        self.layout = layout
        self.items = items
    }

    public static let `default` = LauncherSpec(
        enabled: false,
        trigger: Trigger(button: .middle, modifiers: []),
        layout: .list,
        items: []
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
