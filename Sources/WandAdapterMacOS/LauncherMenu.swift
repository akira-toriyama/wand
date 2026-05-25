// Build an NSMenu from `[LauncherItem]` filtered for a target, and
// pop it up at a screen point. Uses native NSMenu so submenus,
// keyboard navigation (↑↓→← Enter Escape), hover-to-open, and click-
// outside dismiss all come for free.

import AppKit
import Foundation
import WandCore

@MainActor
public enum LauncherMenu {

    /// Show a menu for `target` at `cgPoint` (CG global coords, Y-down).
    /// `onSelect` fires with the chosen item synchronously when the
    /// user clicks it; a dismiss without selection fires nothing.
    public static func present(items: [LauncherItem],
                                excludes: [String],
                                target: Target,
                                cgPoint: CGPoint,
                                onSelect: @escaping (LauncherItem, Target) -> Void) {
        let filtered = Matcher.itemsFor(target: target,
                                         items: items,
                                         excludes: excludes)
        guard !filtered.isEmpty else {
            Log.line("launcher-menu: no items for \(target.bundleID) — "
                     + "menu suppressed")
            return
        }

        let actionTarget = MenuActionTarget(onSelect: onSelect, target: target)
        let menu = buildMenu(filtered, target: target, actionTarget: actionTarget)
        // `popUp` blocks until dismissed, so this local strong
        // reference keeps `actionTarget` alive for the menu's whole
        // lifetime even though NSMenuItem.target is unowned.
        withExtendedLifetime(actionTarget) {

        // CG (Y-down) → Cocoa screen coords (Y-up about the primary
        // display). Same flip the gesture overlay does — anchored to
        // the primary screen so points on secondary displays still
        // land where the user clicked.
        let primaryH = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? cgPoint.y
        let cocoa = NSPoint(x: cgPoint.x, y: primaryH - cgPoint.y)

        // popUp blocks until dismissed (or a click selects an item +
        // the @objc action fires). We're on the main thread already
        // (event-tap callback) so this is safe.
            menu.popUp(positioning: nil, at: cocoa, in: nil)
        }
    }

    /// Walk items in document order, building the tree from `group`.
    /// First mention of a path creates the folder (NSMenuItem +
    /// submenu); subsequent items with the same path append into it.
    /// `separator-before` inserts a separator just above the item.
    private static func buildMenu(_ items: [LauncherItem],
                                   target: Target,
                                   actionTarget: MenuActionTarget) -> NSMenu {
        let root = NSMenu()
        // Header: app icon + name as a disabled marker, so the user
        // sees at a glance which window the menu is acting on. The
        // launcher acts on the **cursor-anchored** target, which is
        // often NOT the focused app — without this marker, picking
        // "閉じる" on a Chrome menu that popped up over a VSCode
        // window could look ambiguous.
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
    /// Returns nil if the app isn't a `NSRunningApplication` we can
    /// resolve (rare for the cursor-anchored target; we'd fall back
    /// to no header rather than display a generic icon).
    private static func makeAppHeader(for target: Target) -> NSMenuItem? {
        let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: target.bundleID).first
        let name = app?.localizedName ?? target.bundleID
        let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let icon = app?.icon {
            // NSMenuItem renders the image at roughly the menu row
            // height; pinning the size keeps high-DPI icons from
            // ballooning the row.
            let resized = icon.copy() as? NSImage ?? icon
            resized.size = NSSize(width: 18, height: 18)
            header.image = resized
        }
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
