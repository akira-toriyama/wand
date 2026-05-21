// Two-level log, ported from facet's FacetCore/Log.swift.
//
//   - ``Log.line(_:)``  always on. Stroke recognised, rule matched,
//                       AX target failures — anything the developer
//                       wants to see after the fact.
//   - ``Log.debug(_:)`` only when ``debugMode == true`` (set from
//                       ``stroke --debug``). Use freely for sample
//                       ticks, event-tap callbacks. Zero overhead
//                       in normal runs (one bool check).
//
// Output:
//   - File ``/tmp/stroke.log`` — always (both levels).
//   - stderr — only when ``debugMode == true`` so a backgrounded
//     ``stroke &`` doesn't pollute the launching shell.

import Foundation

/// Set once at startup by ``Main.swift`` from the ``--debug`` flag.
/// Write-once, then read-only — never mutated after the agent starts.
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

    private static func emit(_ s: String, prefix: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let msg = "\(ts) \(prefix)\(s)\n"
        let data = Data(msg.utf8)
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
