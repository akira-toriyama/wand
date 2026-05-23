// Watches config.toml and fires `onChange` when it's edited, so the
// daemon live-reloads without an explicit `stroke --reload`.
//
// Editors save in two flavors: in-place writes (`.write`) and atomic
// replace (write temp + rename over the original — fires `.rename` /
// `.delete` and invalidates our file descriptor). We handle both: a
// debounced reload for writes, and a re-arm (re-open the new inode)
// for atomic replaces. A short debounce coalesces the burst of events
// a single save produces.
//
// Pure Foundation/GCD — no AppKit/AX. Delivers on the main queue so
// the reload runs on the same thread as the stroke handler.

import Foundation
import StrokeCore

final class ConfigWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?
    /// Cap the file-appearance poll so a daemon that never sees a
    /// config file doesn't tick every 2s for the whole process
    /// lifetime. After this many tries (≈60 s) we stop watching —
    /// a `stroke --reload` after creating the file picks back up.
    private var armAttemptsRemaining = 30

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() { arm() }

    private func arm() {
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // No file yet (running on defaults). Poll until it appears,
            // up to `armAttemptsRemaining` times — cheap while absent
            // but bounded so the daemon doesn't tick forever.
            armAttemptsRemaining -= 1
            guard armAttemptsRemaining > 0 else {
                Log.line("config: no file at \(path) after polling — "
                         + "watcher stopped. Create the file and run "
                         + "`stroke --reload` to pick it up.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.arm()
            }
            return
        }
        armAttemptsRemaining = 30   // reset for re-arm after atomic replace
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main)
        s.setEventHandler { [weak self] in
            guard let self, let s = self.source else { return }
            if s.data.contains(.delete) || s.data.contains(.rename) {
                // Atomic save replaced the inode — re-open the new one.
                self.disarm()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.arm()
                    self.fire()
                }
            } else {
                self.fire()           // in-place write
            }
        }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = s
        s.resume()
    }

    private func disarm() {
        source?.cancel()
        source = nil
    }

    /// Debounce: a single save fires several events; reload once.
    private func fire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
