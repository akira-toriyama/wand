// Wires MouseSource → Recognition → Matcher → Dispatch, plus the
// runtime IPC channel used by `stroke --reload` / `stroke --quit`.
//
// The Controller owns no AppKit / UI state — it's a single-purpose
// coordinator. Lives in StrokeApp (the executable) rather than Core
// because the adapter selection (real vs synthetic) and the IPC
// surface are both app-startup concerns.

import AppKit
import Foundation
import StrokeCore
import StrokeAdapterMacOS

// `@unchecked Sendable`: the only mutable state (`config`) is read
// and written exclusively on the main thread — the stroke handler
// runs on the event-tap callback (main run loop) and `reload()` is
// invoked from the main-queue DNC observer. No cross-thread access,
// so no lock is needed.
public final class Controller: @unchecked Sendable {

    private let source: MouseSource
    /// Mutated by `reload()` on the main thread. The stroke handler
    /// reads `self.config` per-event (not captured locals) so a
    /// reload takes effect on the very next stroke without
    /// reinstalling the event tap.
    private var config: StrokeConfig
    /// Last few recognised gestures (newest last), for `stroke --status` —
    /// a ring buffer big enough to read out "user drew DR then D then DRU"
    /// while diagnosing remotely.
    private var recentGestures: [String] = []
    private let recentGesturesCap = 5
    /// Counters surfaced via `--status`. Numbers survive between gestures
    /// so a remote agent can see "the daemon HAS seen events" even when
    /// no recent gesture matches.
    private var counterRecognised = 0
    private var counterDispatched = 0
    private var counterNoRule = 0
    private var counterExcluded = 0
    /// Last reload timestamp + cause, surfaced via `--status`.
    private var lastReload: (when: Date, cause: String) =
        (Date(), "initial-load")

    public init(source: MouseSource, config: StrokeConfig) {
        self.source = source
        self.config = config
    }

    public func start() {
        Log.line("controller: start — \(config.rules.count) rule(s), "
                 + "minStrokePx=\(config.minStrokePx), "
                 + "trigger=\(config.trigger.button.rawValue)")
        source.start { [weak self] event in
            self?.handle(event)
        }
        installCLIControl()
        writeStatus()
    }

    public func stop() { source.stop() }

    // MARK: - Stroke handling

    private func handle(_ event: StrokeEvent) {
        let cfg = config
        let target = event.target
        if Matcher.isExcluded(bundleID: target.bundleID, by: cfg.excludeApps) {
            counterExcluded += 1
            Log.line("controller: excluded app \(target.bundleID)")
            writeStatus()
            return
        }
        let dirs = Recognition.recognize(samples: event.samples,
                                          minStrokePx: cfg.minStrokePx)
        guard !dirs.isEmpty else {
            // Reachable only if EventTap and Controller disagree on
            // recognition — i.e. either threshold drift after reload, or
            // a real bug. Either way it's worth surfacing without --debug.
            Log.line("controller: EventTap delivered but Recognition "
                     + "found 0 directions on \(target.bundleID) "
                     + "(samples=\(event.samples.count), "
                     + "minStrokePx=\(cfg.minStrokePx)) — ignored")
            return
        }
        counterRecognised += 1
        let pattern = dirs.patternString
        Log.line("controller: recognised \(pattern) on \(target.bundleID)")
        let rule = Matcher.match(pattern: pattern, bundleID: target.bundleID,
                                 rules: cfg.rules)
        record("\(pattern) on \(target.bundleID)"
               + (rule.map { " → \"\($0.name)\"" } ?? " (no rule)"))
        guard let rule else {
            counterNoRule += 1
            let n = Matcher.candidates(prefix: pattern,
                                       bundleID: target.bundleID,
                                       rules: cfg.rules).count
            Log.line("controller: no rule matched \(pattern) for "
                     + "\(target.bundleID) — check `apps` filter in "
                     + "config.toml (\(n) prefix candidate(s))")
            writeStatus()
            return
        }
        counterDispatched += 1
        Log.line("controller: → rule \"\(rule.name)\"")
        writeStatus()
        Dispatch.execute(rule.action, on: target)
    }

    /// Append to the ring buffer, dropping the oldest entry past the cap.
    private func record(_ entry: String) {
        recentGestures.append(entry)
        if recentGestures.count > recentGesturesCap {
            recentGestures.removeFirst(recentGestures.count - recentGesturesCap)
        }
    }

    // MARK: - Reload

    /// Re-read `~/.config/stroke/config.toml` and swap the in-memory
    /// rules + excludes. Trigger and `minStrokePx` are not swapped
    /// live — those are baked into the running event tap; logging
    /// flags them so the user knows a full restart is needed.
    public func reload(cause: String = "manual") {
        let new = StrokeConfig.load()
        let oldRules = config.rules.count, newRules = new.rules.count
        if new.trigger != config.trigger
            || new.minStrokePx != config.minStrokePx {
            Log.line("controller: reload — trigger / minStrokePx "
                     + "changed in config; full restart required to "
                     + "apply (event tap won't pick them up live)")
        }
        config = new
        lastReload = (Date(), cause)
        Log.line("controller: reload (\(cause)) — "
                 + "\(oldRules) → \(newRules) rule(s)")
        writeStatus()
    }

    // MARK: - Status file (for `stroke --status`)

    private func writeStatus() {
        let fmt = ISO8601DateFormatter()
        let recent = recentGestures.isEmpty
            ? "(none yet)"
            : recentGestures.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        let s = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        rules=\(config.rules.count)
        trigger=\(config.trigger.button.rawValue)
        min-stroke-px=\(config.minStrokePx)
        max-stroke-ms=\(config.maxStrokeMs)
        cancel-reversals=\(config.cancelReversals)
        cancel-window-ms=\(config.cancelWindowMs)
        sample-hz=\(config.sampleHz)
        overlay=\(config.overlayEnabled ? "on" : "off")
        counters: recognised=\(counterRecognised) \
        dispatched=\(counterDispatched) \
        no-rule=\(counterNoRule) excluded=\(counterExcluded)
        last-reload=\(fmt.string(from: lastReload.when)) \
        (\(lastReload.cause))
        recent:
        \(recent)
        """
        try? s.write(toFile: statusPath, atomically: true, encoding: .utf8)
    }

    // MARK: - CLI ↔ daemon IPC

    private func installCLIControl() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init(controlNotificationName),
            object: nil, queue: .main
        ) { [weak self] note in
            let cmd = (note.object as? String) ?? ""
            // queue:.main delivers on the main thread but Swift 6
            // doesn't infer @MainActor on the closure — `NSApp` is
            // main-isolated, so wrap explicitly. Same workaround
            // facet uses in `installCLIControl`.
            MainActor.assumeIsolated {
                Log.line("ipc: cmd=\(cmd)")
                switch cmd {
                case "quit":   NSApp.terminate(nil)
                case "reload": self?.reload(cause: "ipc")
                default:
                    Log.line("ipc: unknown command \"\(cmd)\" — ignored")
                }
            }
        }
    }
}
