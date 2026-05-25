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
    public let action: Action

    public init(name: String, group: [String] = [],
                separatorBefore: Bool = false,
                apps: [String] = ["*"], action: Action) {
        self.name = name
        self.group = group
        self.separatorBefore = separatorBefore
        self.apps = apps
        self.action = action
    }
}

/// The whole `[launcher]` block. `trigger` lives here(not the top-
/// level `[trigger]` which gestures own) so each family has its own
/// button. `enabled = false` keeps the tap from being installed at
/// all — same opt-out shape as `overlay.enabled`.
public struct LauncherSpec: Sendable, Equatable {
    public let enabled: Bool
    public let trigger: Trigger
    public let items: [LauncherItem]

    public init(enabled: Bool, trigger: Trigger, items: [LauncherItem]) {
        self.enabled = enabled
        self.trigger = trigger
        self.items = items
    }

    public static let `default` = LauncherSpec(
        enabled: false,
        trigger: Trigger(button: .middle, modifiers: []),
        items: []
    )
}
