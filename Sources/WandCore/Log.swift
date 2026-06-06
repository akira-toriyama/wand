// Two-level log: `Log.line` always-on, `Log.debug` gated by
// `debugMode` (set once at startup from the WAND_DEBUG env var). Both
// write to /tmp/wand.log; stderr only mirrors when WAND_DEBUG is set so
// a backgrounded `wand &` doesn't pollute the launching shell.

import Foundation

/// Write-once at startup from the WAND_DEBUG env var. Never mutated after that.
nonisolated(unsafe) public var debugMode = false

/// Opt-in stderr mirror for `Log.line` only. `--validate` flips this so
/// every parse-time warning (clamp / migration / collision / typo) reaches
/// the user instead of being buried in `/tmp/wand.log` — the file the user
/// is least likely to tail while testing config edits.
nonisolated(unsafe) public var mirrorLineToStderr = false

public enum Log {
    public static let path = "/tmp/wand.log"

    /// Count of `Log.line` calls since reset. `--validate` uses this to
    /// derive an "n warning(s)" summary without re-parsing.
    nonisolated(unsafe) public static var lineCount = 0

    public static func resetLineCount() { lineCount = 0 }

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
        if prefix.isEmpty { lineCount += 1 }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? msg.write(toFile: path, atomically: false, encoding: .utf8)
        }
        // Stderr mirror policy:
        //  - debugMode (WAND_DEBUG=1): everything mirrors — live tail UX.
        //  - mirrorLineToStderr (--validate): only line() mirrors, never
        //    debug() — debug noise would drown the validation summary,
        //    and validate only ever calls line() through the parser.
        if debugMode || (mirrorLineToStderr && prefix.isEmpty) {
            FileHandle.standardError.write(data)
        }
    }
}
