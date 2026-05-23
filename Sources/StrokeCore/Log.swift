// Two-level log: `Log.line` always-on, `Log.debug` gated by
// `debugMode` (set once at startup from `--debug`). Both write to
// /tmp/stroke.log; stderr only mirrors under --debug so a
// backgrounded `stroke &` doesn't pollute the launching shell.

import Foundation

/// Write-once at startup from `--debug`. Never mutated after that.
nonisolated(unsafe) public var debugMode = false

public enum Log {
    public static let path = "/tmp/stroke.log"

    public static func line(_ s: String) {
        emit(s, prefix: "")
    }

    public static func debug(_ s: String) {
        guard debugMode else { return }
        emit(s, prefix: "DEBUG ")
    }

    // Serialises writes so concurrent log calls don't interleave bytes
    // mid-line or race on the file handle. The handler closures aren't
    // strictly main-bound (ConfigWatcher debounces on a DispatchSource,
    // shell terminationHandlers fire on an arbitrary queue) — without
    // this lock two callers can `closeFile` each other's handle.
    private static let lock = NSLock()

    private static func emit(_ s: String, prefix: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let msg = "\(ts) \(prefix)\(s)\n"
        let data = Data(msg.utf8)
        lock.lock()
        defer { lock.unlock() }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? msg.write(toFile: path, atomically: false, encoding: .utf8)
        }
        if debugMode {
            FileHandle.standardError.write(data)
        }
    }
}
