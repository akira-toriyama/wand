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
            if item.dynamic.isEmpty {
                // Static row — usual path.
                let mi = NSMenuItem(title: item.name,
                                    action: #selector(MenuActionTarget.fire(_:)),
                                    keyEquivalent: "")
                mi.target = actionTarget
                mi.representedObject = item
                if !item.icon.isEmpty {
                    mi.image = resolveItemIcon(item.icon)
                }
                parent.addItem(mi)
            } else {
                // Dynamic row — submenu populated at expand time.
                // The shell runs synchronously inside `expand` (we're
                // already on the main thread inside popUp, which
                // blocks anyway), so the children are ready before
                // the user has a chance to hover the parent.
                let header = NSMenuItem(title: item.name,
                                        action: nil, keyEquivalent: "")
                if !item.icon.isEmpty {
                    header.image = resolveItemIcon(item.icon)
                }
                let sub = NSMenu(title: item.name)
                for child in DynamicItems.expand(
                    parent: item, actionTarget: actionTarget) {
                    sub.addItem(child)
                }
                header.submenu = sub
                parent.addItem(header)
            }
        }
        return root
    }

    /// Item-icon resolution. See `LauncherItem.icon` for the
    /// recognised string forms. Returns nil (which collapses to no
    /// image on the menu row) on miss; logs once so a typo is
    /// visible in `/tmp/wand.log` without spamming on every popup.
    /// `internal` so `DynamicItems` can reuse it for each expanded
    /// child row.
    static func resolveItemIcon(_ spec: String) -> NSImage? {
        let pt: CGFloat = 18  // match the app-header glyph size

        // SF Symbol prefix
        if spec.hasPrefix("SF:") {
            let name = String(spec.dropFirst(3))
            let cfg = NSImage.SymbolConfiguration(pointSize: pt,
                                                   weight: .regular)
            guard let img = NSImage(systemSymbolName: name,
                                     accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else {
                Log.line("launcher-menu: unknown SF Symbol \"\(name)\" "
                         + "in item icon — falling back to no icon")
                return nil
            }
            return img
        }

        // File path — absolute, tilde, or relative to the config dir.
        let looksLikePath = spec.hasPrefix("/")
            || spec.hasPrefix("~")
            || spec.contains("/")
            || spec.hasSuffix(".png")
            || spec.hasSuffix(".jpg")
            || spec.hasSuffix(".jpeg")
            || spec.hasSuffix(".gif")
            || spec.hasSuffix(".tiff")
            || spec.hasSuffix(".icns")
        if looksLikePath {
            let path = resolveIconPath(spec)
            guard let img = NSImage(contentsOfFile: path) else {
                Log.line("launcher-menu: could not load item icon "
                         + "from \(path) — falling back to no icon")
                return nil
            }
            img.size = NSSize(width: pt, height: pt)
            return img
        }

        // Text / emoji — draw the glyph into an NSImage.
        return textIcon(spec, pointSize: pt)
    }

    private static func resolveIconPath(_ spec: String) -> String {
        if spec.hasPrefix("/") { return spec }
        if spec.hasPrefix("~") {
            return (spec as NSString).expandingTildeInPath
        }
        // Relative — resolve against the config file's directory.
        let configDir = (WandConfig.path as NSString)
            .deletingLastPathComponent
        return "\(configDir)/\(spec)"
    }

    /// Render `text` (typically 1-2 chars, often emoji) into an
    /// NSImage at `pointSize` × `pointSize`. Used when the item
    /// `icon` field isn't an SF Symbol or a file path.
    private static func textIcon(_ text: String,
                                  pointSize pt: CGFloat) -> NSImage? {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pt * 0.85),
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let measured = attributed.size()
        guard measured.width > 0 && measured.height > 0 else { return nil }
        let size = NSSize(width: pt, height: pt)
        let img = NSImage(size: size)
        img.lockFocus()
        let origin = NSPoint(
            x: (size.width - measured.width) / 2,
            y: (size.height - measured.height) / 2)
        attributed.draw(at: origin)
        img.unlockFocus()
        return img
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
/// `internal` so `DynamicItems` can reuse the same instance when it
/// builds child rows — keeps the dispatch path identical for
/// static and dynamic items.
@MainActor
final class MenuActionTarget: NSObject {
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
