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
                _ = self?.entries.removeValue(forKey: bid)
            }
        }
    }

    /// Resolve `(localizedName, icon)` for `bundleID`. Cache miss
    /// scans the running app list first; if the app isn't running it
    /// falls back to LaunchServices (`urlForApplication`) so installed
    /// but inactive apps still resolve — important for "Open Chrome"-
    /// style launcher items that should display Chrome's icon even
    /// when Chrome isn't currently running. Subsequent hits are O(1).
    /// `iconSize` is the requested image size; the cache resizes the
    /// returned `NSImage` to it once on the miss path.
    func lookup(bundleID: String, iconSize: CGFloat = 18)
        -> (name: String, icon: NSImage?) {
        if let cached = entries[bundleID] {
            return (cached.name, cached.icon)
        }
        let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID).first
        var name = app?.localizedName ?? bundleID
        var icon = app?.icon
        // Fall back to LaunchServices for installed-but-not-running
        // apps. NSWorkspace caches its own internal lookup, so the
        // hit here is bounded.
        if icon == nil,
           let url = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
            // Derive a friendlier name from the bundle if we got one,
            // since LaunchServices doesn't carry `localizedName`. The
            // `.deletingPathExtension().lastPathComponent` strips
            // `Google Chrome.app` → `Google Chrome`.
            if name == bundleID {
                name = url.deletingPathExtension().lastPathComponent
            }
        }
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
