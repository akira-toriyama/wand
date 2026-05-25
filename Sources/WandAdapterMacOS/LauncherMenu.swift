// Build an NSMenu from `[LauncherItem]` and pop it up at a screen
// point. Uses native NSMenu so submenus, keyboard navigation (↑↓→←
// Enter Escape), hover-to-open, and click-outside dismiss all come
// for free.

import AppKit
import Foundation
import WandCore

@MainActor
public enum LauncherMenu {

    /// Show a menu for `target` at `cocoaPoint` (Cocoa screen coords,
    /// Y-up — what `NSMenu.popUp` and `NSEvent.mouseLocation` use).
    /// Native-trigger callers convert CG → Cocoa via
    /// `ScreenCoords.cocoaPoint(fromCG:)` before calling; external
    /// triggers (`--show-menu`) already supply Cocoa coords from CLI.
    ///
    /// `items` is the **already-filtered** list — the caller
    /// (Controller) ran `Matcher.itemsFor` so the menu builder doesn't
    /// repeat the work. `onSelect` fires synchronously when the user
    /// clicks; dismiss-without-selection fires nothing.
    public static func present(filteredItems items: [LauncherItem],
                                target: Target,
                                cocoaPoint: NSPoint,
                                onSelect: @escaping (LauncherItem, Target) -> Void) {
        guard !items.isEmpty else {
            Log.line("launcher-menu: no items for \(target.bundleID) — "
                     + "menu suppressed")
            return
        }
        // popUp blocks until dismissed, so this local strong reference
        // keeps `actionTarget` alive for the menu's whole lifetime
        // even though NSMenuItem.target is unowned.
        let actionTarget = MenuActionTarget(onSelect: onSelect, target: target)
        let menu = buildMenu(items, target: target, actionTarget: actionTarget)
        menu.popUp(positioning: nil, at: cocoaPoint, in: nil)
        _ = actionTarget  // keep alive past popUp
    }

    /// Walk items in document order, building the tree from `group`.
    /// First mention of a path creates the folder (NSMenuItem +
    /// submenu); subsequent items with the same path append into it.
    /// `separator-before` inserts a separator just above the item.
    private static func buildMenu(_ items: [LauncherItem],
                                   target: Target,
                                   actionTarget: MenuActionTarget) -> NSMenu {
        let root = NSMenu()
        // App-icon header so the user sees which window the menu is
        // acting on — the cursor-anchored target is often NOT the
        // focused app, and an unmarked "閉じる" would be ambiguous.
        if let header = makeAppHeader(for: target) {
            root.addItem(header)
            root.addItem(.separator())
        }
        // Cache submenus keyed by joined path so repeated `group =
        // ["A","B"]` entries land in the same NSMenu instance.
        var submenus: [String: NSMenu] = [:]

        for item in items {
            let parent = resolveParent(item.group, root: root, cache: &submenus)
            if item.separatorBefore && !parent.items.isEmpty {
                parent.addItem(.separator())
            }
            let mi = NSMenuItem(title: item.name,
                                action: #selector(MenuActionTarget.fire(_:)),
                                keyEquivalent: "")
            mi.target = actionTarget
            mi.representedObject = item
            parent.addItem(mi)
        }
        return root
    }

    /// Disabled NSMenuItem showing the target app's icon + name.
    /// Returns nil only if the bundle id resolves to no localized
    /// name AND no icon (rare for the cursor-anchored target).
    private static func makeAppHeader(for target: Target) -> NSMenuItem? {
        let (name, icon) = AppIconCache.shared.lookup(
            bundleID: target.bundleID, iconSize: 18)
        if name.isEmpty && icon == nil { return nil }
        let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.image = icon
        return header
    }

    /// Walk down `path`, creating folder NSMenuItems as needed.
    private static func resolveParent(_ path: [String],
                                       root: NSMenu,
                                       cache: inout [String: NSMenu]) -> NSMenu {
        var current = root
        var key = ""
        for segment in path {
            key = key.isEmpty ? segment : "\(key)\u{1F}\(segment)"
            if let cached = cache[key] {
                current = cached
                continue
            }
            let folder = NSMenuItem(title: segment, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: segment)
            folder.submenu = sub
            current.addItem(folder)
            cache[key] = sub
            current = sub
        }
        return current
    }
}

/// Bridge between NSMenuItem's @objc selection callback and Swift
/// closures. Holds the chosen target so the click handler can route
/// the item's action to the correct cursor-anchored window.
@MainActor
private final class MenuActionTarget: NSObject {
    private let onSelect: (LauncherItem, Target) -> Void
    private let target: Target
    init(onSelect: @escaping (LauncherItem, Target) -> Void,
         target: Target) {
        self.onSelect = onSelect
        self.target = target
    }
    @objc func fire(_ sender: Any?) {
        guard let mi = sender as? NSMenuItem,
              let item = mi.representedObject as? LauncherItem
        else { return }
        onSelect(item, target)
    }
}
