// Cache `(bundleID) → (localizedName, resized NSImage)`. The launcher
// header looks the target app's icon up on every menu popup, and
// `NSRunningApplication.runningApplications(withBundleIdentifier:)`
// enumerates the live process list — fine for one click, but each
// call is 5-20 ms on a busy system and the icon is identical from
// one click to the next while the app is alive.
//
// Invalidation: a NSWorkspace `didTerminateApplicationNotification`
// observer drops the entry for the terminated bundle id. New
// launches are picked up by the next miss (cache fills lazily).

import AppKit
import Foundation

@MainActor
final class AppIconCache {

    static let shared = AppIconCache()

    // `@unchecked Sendable` because NSImage isn't Sendable but we
    // never mutate the entries' icons after caching (we set `.size`
    // once during the miss path and from then on the image is
    // effectively read-only). Reads/writes happen only on the main
    // actor — same isolation guarantee the rest of this file uses.
    private struct Entry: @unchecked Sendable {
        let name: String
        let icon: NSImage?
    }
    private var entries: [String: Entry] = [:]

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                                as? NSRunningApplication)?.bundleIdentifier
            else { return }
            MainActor.assumeIsolated {
                self?.entries.removeValue(forKey: bid)
            }
        }
    }

    /// Resolve `(localizedName, icon)` for `bundleID`. Cache miss
    /// scans the running app list once; subsequent hits are O(1).
    /// `iconSize` lets the caller request a pre-sized image (the menu
    /// header wants 18×18; the gesture badge resizes its own copy).
    func lookup(bundleID: String, iconSize: CGFloat = 18)
        -> (name: String, icon: NSImage?) {
        if let cached = entries[bundleID] {
            return (cached.name, cached.icon)
        }
        let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID).first
        let name = app?.localizedName ?? bundleID
        var icon = app?.icon
        if let original = icon {
            // Copy then resize so we don't mutate the shared
            // NSImage AppKit hands us — that pointer might be in
            // use by Dock / Spotlight / etc.
            let resized = original.copy() as? NSImage ?? original
            resized.size = NSSize(width: iconSize, height: iconSize)
            icon = resized
        }
        entries[bundleID] = Entry(name: name, icon: icon)
        return (name, icon)
    }
}
