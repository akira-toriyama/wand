// Wires MouseSource → Recognition → Matcher → Dispatch, plus the
// DNC IPC channel used by `wand --reload` / `wand --quit`. Lives
// in App (not Core) because adapter selection and IPC are startup
// concerns. `@unchecked Sendable` because `config` mutation lives
// only on the main thread (stroke handler + DNC observer both run
// there).

import AppKit
import Foundation
import WandCore
import WandAdapterMacOS

public final class Controller: @unchecked Sendable {

    private let source: MouseSource
    /// Optional launcher tap — created at init only when
    /// `cfg.launcher.enabled` was true at startup, so the second
    /// CGEventTap isn't even allocated when the user hasn't opted in.
    /// Like `[trigger]`, the launcher's button / modifiers are baked
    /// into the tap at install; flipping them needs a daemon restart
    /// (surfaced in --status as pending-restart).
    private let launcher: LauncherSource?
    /// Mutated by `reload()` on the main thread. The stroke handler
    /// reads `self.config` per-event (not captured locals) so a
    /// reload takes effect on the very next stroke without
    /// reinstalling the event tap. Exposed read-only so the overlay's
    /// `onSample` closure reads the same live snapshot — otherwise
    /// the assist tooltips would stay frozen at startup rules while
    /// dispatch already saw the new ones.
    public private(set) var config: WandConfig
    /// Last few recognised gestures (newest last), for `wand --status` —
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
    /// `shown` only increments when the menu actually appears (items
    /// remain after filtering). A middle-click on the Dock / desktop
    /// where no items qualify is a no-op, not a "shown" event.
    private var counterLauncherShown = 0
    private var counterLauncherDispatched = 0
    /// Same semantics as `Launcher*` but for the external `--show-menu`
    /// entry point (event-driven daemons posting via IPC).
    private var counterShowMenuShown = 0
    private var counterShowMenuDispatched = 0
    /// Last reload timestamp + cause, surfaced via `--status`.
    private var lastReload: (when: Date, cause: String) =
        (Date(), "initial-load")
    /// Frozen at init so we can diff later edits against startup. A
    /// `[trigger]` change or `overlay.enabled = false → true` only
    /// takes effect on restart; `--status` flags the divergence so
    /// users notice without needing to scan the log.
    private let startupConfig: WandConfig
    /// Fires after `reload()` swaps the in-memory config, with the new
    /// snapshot. Used by the overlay wiring to hot-apply `[overlay]`
    /// changes (colours, badge toggles, blur, …) without a restart.
    public var onConfigChanged: ((WandConfig) -> Void)?

    public init(source: MouseSource,
                launcher: LauncherSource? = nil,
                config: WandConfig) {
        self.source = source
        self.launcher = launcher
        self.config = config
        self.startupConfig = config
    }

    public func start() {
        Log.line("controller: start — \(config.rules.count) rule(s), "
                 + "minStrokePx=\(config.minStrokePx), "
                 + "trigger=\(config.trigger.button.rawValue)"
                 + (launcher == nil ? "" :
                    ", launcher=\(config.launcher.trigger.button.rawValue)"
                    + " (\(config.launcher.items.count) item(s))"))
        source.start { [weak self] event in
            self?.handle(event)
        }
        launcher?.start { [weak self] event in
            // Launcher fires on the event-tap main thread; menu popup
            // and dispatch both need the main actor.
            MainActor.assumeIsolated {
                self?.handleLauncher(event)
            }
        }
        installCLIControl()
        writeStatus()
    }

    public func stop() {
        source.stop()
        launcher?.stop()
    }


    private func handle(_ event: WandEvent) {
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
        let evalShell = shellEvaluator(for: target)
        let rule = Matcher.match(pattern: pattern, target: target,
                                 rules: cfg.rules, evalShell: evalShell)
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

    @MainActor
    private func handleLauncher(_ event: LauncherEvent) {
        let cfg = config
        // Filter once: pass the result to `present` so the menu
        // builder doesn't repeat the work. `counterLauncherShown`
        // increments only when the menu actually has items to show
        // — a click on the Dock / desktop is a "trigger" but not a
        // "shown" event, so the counter stays honest.
        let evalShell = shellEvaluator(for: event.target)
        let visibleItems = Matcher.itemsFor(
            target: event.target, items: cfg.launcher.items,
            excludes: cfg.excludeApps, evalShell: evalShell)
        Log.line("controller: launcher fired on \(event.target.bundleID) "
                 + "— \(visibleItems.count)/\(cfg.launcher.items.count) item(s) "
                 + "visible")
        record("launcher on \(event.target.bundleID) "
               + "(\(visibleItems.count) item(s))")
        guard !visibleItems.isEmpty else { writeStatus(); return }
        counterLauncherShown += 1
        writeStatus()
        // Capture the focused element's selected text at button-down
        // time, so shell actions can read it via `$SELECTION` — same
        // env-var contract the `--show-menu` external path already
        // honours, now native too. Captured once at button-down
        // (not at menu-close): the user's selection at the moment
        // they triggered the menu is what they intended to act on.
        let selection = AXTarget.selectedText()
        if let sel = selection {
            Log.line("controller: launcher captured $SELECTION = "
                     + "\(sel.count) char(s)")
        }
        let env: [String: String] = selection.map { ["SELECTION": $0] } ?? [:]
        LauncherPanel.present(
            filteredItems: visibleItems,
            target: event.target,
            cocoaPoint: ScreenCoords.cocoaPoint(fromCG: event.point),
            layout: cfg.launcher.layout
        ) { [weak self] item, target in
            self?.counterLauncherDispatched += 1
            Log.line("controller: → launcher item \"\(item.name)\"")
            self?.writeStatus()
            Dispatch.execute(item.action, on: target, extraEnv: env)
        }
    }

    /// External-trigger entry point. Wired in by `--show-menu` —
    /// `eventfx` (or any other event-driven daemon) posts a DNC
    /// notification carrying an items-TOML path, a Cocoa screen
    /// point, and an optional selection text. We resolve the target
    /// via `NSWorkspace.frontmostApplication` (the **cursor-anchored
    /// spine is intentionally bypassed here** — external triggers
    /// don't have a button-down moment), build a `LauncherMenu` from
    /// the parsed items, and pop it up. `$SELECTION` is exported to
    /// any shell action chosen from the resulting menu.
    @MainActor
    func handleShowMenu(itemsPath: String,
                        cocoaPoint: NSPoint,
                        selection: String?,
                        title: String? = nil) {
        let cfg = config
        guard let text = try? String(contentsOfFile: itemsPath, encoding: .utf8) else {
            Log.line("controller: --show-menu: items file unreadable "
                     + "at \(itemsPath) — request dropped")
            return
        }
        let parsed = WandConfig.parseItems(text)
        guard !parsed.items.isEmpty else {
            Log.line("controller: --show-menu: items file at \(itemsPath) "
                     + "yielded 0 items — request dropped")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier else {
            Log.line("controller: --show-menu: no frontmost app — "
                     + "request dropped")
            return
        }
        // CLI --title が来てればそれを使い、無ければ AX で frontmost
        // app の focused window title を取る。action-cmd 側に
        // $WAND_TARGET_TITLE として届く。AX-fetch は menu 表示時点の
        // スナップショット — 重い AX 応答の app では空文字に倒れる
        // ことがあるので、確実性が要る trigger 側は --title を渡す。
        let resolvedTitle = title
            ?? AXTarget.focusedWindowTitle(pid: app.processIdentifier)
        let target = Target(pid: app.processIdentifier,
                            bundleID: bid, title: resolvedTitle,
                            frame: .zero, windowID: 0)
        let evalShell = shellEvaluator(for: target)
        let visible = Matcher.itemsFor(target: target, items: parsed.items,
                                        excludes: cfg.excludeApps,
                                        evalShell: evalShell)
        Log.line("controller: --show-menu (external trigger) on "
                 + "\(bid) at \(cocoaPoint) — "
                 + "\(visible.count)/\(parsed.items.count) item(s) visible"
                 + ", layout=\(parsed.layout.rawValue)"
                 + (selection == nil ? ""
                    : ", $SELECTION=\(selection!.count) char(s)"))
        record("show-menu on \(bid) (\(visible.count) item(s))")
        guard !visible.isEmpty else { writeStatus(); return }
        counterShowMenuShown += 1
        writeStatus()
        // Capture selection in the closure so Dispatch can export it
        // as an env var — keeps the LauncherMenu signature trigger-
        // agnostic (no `selection` field on items or menu state).
        let env: [String: String] = selection.map { ["SELECTION": $0] } ?? [:]
        LauncherPanel.present(
            filteredItems: visible,
            target: target,
            cocoaPoint: cocoaPoint,
            layout: parsed.layout
        ) { [weak self] item, target in
            self?.counterShowMenuDispatched += 1
            Log.line("controller: → show-menu item \"\(item.name)\"")
            self?.writeStatus()
            Dispatch.execute(item.action, on: target, extraEnv: env)
        }
    }

    /// Build a `ShellFilterEval` closure scoped to `target`. The
    /// closure runs `filter-shell` commands via `BoundedShell.run`
    /// with a tight 100 ms budget and the same `WAND_TARGET_*` env
    /// shape `Action.shell` exports — so a filter shell can inspect
    /// the window title / bundle id / frame the same way an action
    /// shell would. Returns true (visible) only when the child
    /// exits 0 inside the budget; anything else (non-zero, timeout,
    /// spawn fail) hides the item.
    private func shellEvaluator(for target: Target) -> ShellFilterEval {
        let env: [String: String] = [
            "WAND_TARGET_BUNDLE_ID": target.bundleID,
            "WAND_TARGET_PID": String(target.pid),
            "WAND_TARGET_TITLE": target.title,
            "WAND_TARGET_FRAME":
                "\(Int(target.frame.minX)),\(Int(target.frame.minY)),"
                + "\(Int(target.frame.width)),\(Int(target.frame.height))",
        ]
        return { cmd in
            switch BoundedShell.run(cmd, timeoutMs: 100, env: env) {
            case .exited(_, let exitCode): return exitCode == 0
            case .timeout, .spawnFailed:   return false
            }
        }
    }

    /// Append to the ring buffer, dropping the oldest entry past the cap.
    private func record(_ entry: String) {
        recentGestures.append(entry)
        if recentGestures.count > recentGesturesCap {
            recentGestures.removeFirst(recentGestures.count - recentGesturesCap)
        }
    }


    /// Re-read `~/.config/wand/config.toml` and swap the in-memory
    /// config. Rules, excludes, every `[recognition]` timing knob, and
    /// (mostly) the full `[overlay]` block apply live. Two transitions
    /// require a full daemon restart, since the underlying object was
    /// never created at startup (or is baked into `tapCreate`'s mask):
    ///   - `[trigger]` (button / modifiers)
    ///   - `[overlay].enabled = false → true` when the window was
    ///     never instantiated
    /// Both are flagged here and surfaced in `--status` as
    /// `pending-restart`.
    public func reload(cause: String = "manual") {
        let new = WandConfig.load()
        let oldRules = config.rules.count, newRules = new.rules.count
        if new.trigger != config.trigger {
            Log.line("controller: reload — [trigger] changed; full restart "
                     + "required to apply (the event mask is baked into the "
                     + "running tap at startup)")
        }
        if new.overlayEnabled && !startupConfig.overlayEnabled {
            Log.line("controller: reload — [overlay].enabled was false at "
                     + "startup so no overlay window exists; flipping to "
                     + "true now needs a full daemon restart")
        }
        if new.launcher.enabled != startupConfig.launcher.enabled {
            Log.line("controller: reload — [launcher].enabled toggled "
                     + "(\(startupConfig.launcher.enabled) → "
                     + "\(new.launcher.enabled)); the tap is installed at "
                     + "startup, restart required to apply")
        }
        if new.launcher.trigger != startupConfig.launcher.trigger {
            Log.line("controller: reload — [launcher].trigger changed; "
                     + "the event mask is baked into the running tap, "
                     + "restart required to apply")
        }
        config = new
        lastReload = (Date(), cause)
        Log.line("controller: reload (\(cause)) — "
                 + "\(oldRules) → \(newRules) rule(s)")
        source.updateConfig(new)
        onConfigChanged?(new)
        writeStatus()
    }


    private func writeStatus() {
        let fmt = ISO8601DateFormatter()
        let recent = recentGestures.isEmpty
            ? "(none yet)"
            : recentGestures.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        // Restart-required diff against startup. Two cases:
        // - `[trigger]` is baked into `tapCreate`'s event mask
        // - overlay.enabled = false → true: the window was never
        //   created at startup, so applyConfig has nothing to show
        var pending: [String] = []
        if config.trigger != startupConfig.trigger {
            pending.append("[trigger]")
        }
        if config.overlayEnabled && !startupConfig.overlayEnabled {
            pending.append("[overlay].enabled = false→true")
        }
        if config.launcher.enabled != startupConfig.launcher.enabled {
            pending.append("[launcher].enabled "
                + "\(startupConfig.launcher.enabled)→\(config.launcher.enabled)")
        }
        if config.launcher.trigger != startupConfig.launcher.trigger {
            pending.append("[launcher].trigger")
        }
        let pendingLine = pending.isEmpty
            ? ""
            : "\npending-restart: \(pending.joined(separator: ", "))"
        let launcherLine = config.launcher.enabled
            ? "\nlauncher=on (button=\(config.launcher.trigger.button.rawValue), "
              + "items=\(config.launcher.items.count), "
              + "shown=\(counterLauncherShown), "
              + "dispatched=\(counterLauncherDispatched))"
            : "\nlauncher=off"
        // `show-menu` line surfaces only after the external trigger
        // has fired at least once — keeps `--status` quiet for users
        // who haven't wired an external daemon (eventfx).
        let showMenuLine = counterShowMenuShown > 0
            ? "\nshow-menu: shown=\(counterShowMenuShown), "
              + "dispatched=\(counterShowMenuDispatched)"
            : ""
        let s = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        rules=\(config.rules.count)
        trigger=\(config.trigger.button.rawValue)
        min-stroke-px=\(config.minStrokePx)
        max-segment-ms=\(config.maxSegmentMs)
        cancel-reversals=\(config.cancelReversals)
        cancel-window-ms=\(config.cancelWindowMs)
        overlay=\(config.overlayEnabled ? "on" : "off")\(launcherLine)\(showMenuLine)
        counters: recognised=\(counterRecognised) \
        dispatched=\(counterDispatched) \
        no-rule=\(counterNoRule) excluded=\(counterExcluded)
        last-reload=\(fmt.string(from: lastReload.when)) \
        (\(lastReload.cause))\(pendingLine)
        recent:
        \(recent)
        """
        try? s.write(toFile: statusPath, atomically: true, encoding: .utf8)
    }


    private func installCLIControl() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init(controlNotificationName),
            object: nil, queue: .main
        ) { [weak self] note in
            let cmd = (note.object as? String) ?? ""
            // Extract Sendable values from userInfo BEFORE crossing
            // into the MainActor closure — Swift 6 strict concurrency
            // flags capturing the (non-Sendable) [AnyHashable: Any]
            // dict across isolation, but Strings/Doubles individually
            // are fine.
            let ui = note.userInfo
            let items = ui?["items"] as? String
            let x = ui?["x"] as? Double
            let y = ui?["y"] as? Double
            let selection = ui?["selection"] as? String
            let title = ui?["title"] as? String
            // queue:.main delivers on the main thread but Swift 6
            // doesn't infer @MainActor on the closure — `NSApp` is
            // main-isolated, so wrap explicitly. Same workaround
            // facet uses in `installCLIControl`.
            MainActor.assumeIsolated {
                Log.line("ipc: cmd=\(cmd)")
                switch cmd {
                case "quit":   NSApp.terminate(nil)
                case "reload": self?.reload(cause: "ipc")
                case "show-menu":
                    guard let items, let x, let y else {
                        Log.line("ipc: show-menu missing required keys "
                                 + "(items, x, y) — dropped")
                        return
                    }
                    self?.handleShowMenu(
                        itemsPath: items,
                        cocoaPoint: NSPoint(x: x, y: y),
                        selection: (selection?.isEmpty ?? true) ? nil : selection,
                        title: (title?.isEmpty ?? true) ? nil : title)
                default:
                    Log.line("ipc: unknown command \"\(cmd)\" — ignored")
                }
            }
        }
    }
}
