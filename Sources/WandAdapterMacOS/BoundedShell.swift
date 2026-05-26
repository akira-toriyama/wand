// Shared time-bounded `/bin/sh -c` runner. Used inside main-thread
// hot paths (NSMenu.popUp blocks the run loop while children resolve)
// where a slow command would freeze the UI — `BoundedShell.run` kills
// the process after `timeoutMs` so the menu can't hang.
//
// Synchronous on purpose: callers (`DynamicItems`, the checkmark
// state evaluator) need the result before the menu paints.

import Foundation
import WandCore

enum BoundedShell {

    enum Outcome {
        /// Process exited normally — `stdout` is the captured output,
        /// `exitCode` is the child's exit status (zero or non-zero).
        case exited(stdout: String, exitCode: Int32)
        /// Child was still running at `timeoutMs` and got SIGTERM'd.
        case timeout
        /// Failed before we ever saw a child process.
        case spawnFailed
    }

    /// Run `cmd` under `/bin/sh -c`, blocking for at most `timeoutMs`
    /// milliseconds. Stdout is captured (stderr discarded — caller
    /// inspects exit code for failure detection). Safe to call on
    /// the main thread; the bounded wait keeps the UI responsive.
    static func run(_ cmd: String, timeoutMs: Int) -> Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        do { try p.run() } catch {
            Log.line("bounded-shell: spawn failed for \"\(cmd)\" — \(error)")
            return .spawnFailed
        }

        // Kill the child if it outlives the budget. We schedule on
        // the global queue (not main) since the caller might already
        // be on main with run-loop blocked.
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        let killer = DispatchWorkItem {
            if p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)

        // Read pipe + wait — readToEnd unblocks when stdout closes
        // (process exit, including SIGTERM-induced exit).
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        let stdout = String(data: data, encoding: .utf8) ?? ""
        if p.terminationReason == .uncaughtSignal {
            return .timeout
        }
        return .exited(stdout: stdout, exitCode: p.terminationStatus)
    }
}
