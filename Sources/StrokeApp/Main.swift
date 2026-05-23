// Entry point. Three modes chosen by CLI flag: server (no flag —
// install tap, wait), client (`--reload` / `--quit` / `--status` —
// post DNC to the running server), standalone (`--validate` /
// `--doctor` / `--test` / `--record` / `--help`).
//
// `@main enum StrokeApp` — NOT top-level `main.swift`. The enum
// form lets a future XCTest `@testable import StrokeApp` work
// without launching the daemon (same trap as facet/ws-tabs —
// don't reintroduce main.swift).

import AppKit
import Foundation
import StrokeCore
import StrokeAdapterMacOS

@main
enum StrokeApp {

    static func printHelp() -> Never {
        let help = """
        stroke — global mouse-gesture daemon for macOS.

        USAGE
          stroke                       run as agent (CGEventTap loop)
          stroke [COMMAND]             one-shot client command

        SERVER MODE
          stroke                       run as agent
          stroke --debug               verbose log to stderr +
                                       /tmp/stroke.log

        CLIENT COMMANDS (talk to a running stroke daemon)
          stroke --reload              re-read ~/.config/stroke/config.toml
                                       without restarting (also automatic
                                       on file save; rules + excludes only —
                                       trigger/minStrokePx need a full restart)
          stroke --status              print rule count, trigger, last gesture
          stroke --quit                terminate the running daemon

        STANDALONE COMMANDS
          stroke --validate            parse config.toml; exit 0 if valid
          stroke --doctor              health check: Accessibility,
                                       config, daemon, event tap
          stroke --test PATTERN [APP]  dry-run: which rule would fire for
                                       a pattern (optionally for a bundle id)
          stroke --record              interactive recorder: draw a
                                       gesture, get a paste-ready
                                       [[rules]] snippet on stdout.
                                       Refuses if the daemon is running.
          stroke --help                this help

        EXIT CODES
          0   success
          2   bad flag / invalid config
          3   client command but no running daemon found

        CONFIG
          ~/.config/stroke/config.toml is the single source of truth.
          stroke never writes to it; runtime CLI flags affect the
          current session only.

        DOCS
          https://github.com/akira-toriyama/stroke
        """
        print(help)
        exit(0)
    }

    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())

        if argv.contains("--help") { printHelp() }
        if argv.contains("--debug") { debugMode = true }

        // `--test PATTERN [bundle-id]` consumes operands, so handle it
        // before the unknown-flag scan would reject that pattern.
        if let i = argv.firstIndex(of: "--test") {
            let pattern = i + 1 < argv.count ? argv[i + 1] : ""
            let bundleID = (i + 2 < argv.count && !argv[i + 2].hasPrefix("--"))
                ? argv[i + 2] : nil
            runTest(pattern: pattern, bundleID: bundleID)
        }

        // Two-pass: reject ANY unknown flag *before* dispatching a
        // recognised one, so `stroke --reload --typo` fails loudly on
        // --typo instead of silently acting on --reload and never
        // looking at the rest (no silent fallback — the loud-reject
        // policy must hold even when flags are combined).
        let recognised: Set<String> = [
            "--help", "--debug", "--validate", "--record",
            "--reload", "--quit", "--status", "--doctor",
        ]
        for a in argv where !recognised.contains(a) {
            let msg = "stroke: unknown flag \"\(a)\" — see "
                + "`stroke --help`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }

        // Standalone modes — no running daemon required.
        if argv.contains("--doctor") { runDoctor() }
        if argv.contains("--validate") {
            let cfg = StrokeConfig.load()
            FileHandle.standardError.write(Data((
                "stroke: loaded \(cfg.rules.count) rule(s), "
                + "trigger=\(cfg.trigger.button.rawValue), "
                + "minStrokePx=\(cfg.minStrokePx)\n"
            ).utf8))
            exit(0)
        }
        if argv.contains("--record") { runRecord() }

        // Client commands — require a running daemon.
        if argv.contains("--status") { runStatus() }
        if argv.contains("--reload") { runClient(cmd: "reload") }
        if argv.contains("--quit")   { runClient(cmd: "quit") }

        // ----- Server mode -----
        runServer()
    }


    @MainActor
    private static func runServer() -> Never {
        let cfg = StrokeConfig.load()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)            // LSUIElement: no Dock icon
        AXTarget.ensureTrusted()

        let source = MacOSMouseSource(
            trigger: cfg.trigger,
            minStrokePx: cfg.minStrokePx,
            maxStrokeMs: cfg.maxStrokeMs,
            cancelReversals: cfg.cancelReversals,
            cancelWindowMs: cfg.cancelWindowMs
        )

        // Gesture-trail overlay (passive observer of the sample
        // stream). Held for the process lifetime via `app.run()`.
        // Declared `outside` the `if` so the live-reload hook below
        // can hot-apply `[overlay]` changes without a restart.
        var overlay: GestureOverlay?
        if cfg.overlayEnabled {
            overlay = GestureOverlay(match: cfg.overlayColor,
                                     noMatch: cfg.overlayColorNoMatch,
                                     width: cfg.overlayWidth,
                                     badgeEnabled: cfg.overlayBadgeEnabled,
                                     blurEnabled: cfg.overlayBlurEnabled,
                                     badgeSize: cfg.overlayBadgeSize,
                                     animEnabled: cfg.overlayAnimEnabled)
            overlay?.show()
            let rules = cfg.rules
            let excludes = cfg.excludeApps
            // The tap callback fires these on the main thread, but
            // they're not statically @MainActor — assumeIsolated is
            // the documented bridge (same as the DNC observer).
            //
            // Color logic mirrors the Controller's dispatch decision:
            // the trail is "valid" (match color) when the shape so far
            // is empty (just started) or exactly matches a rule for the
            // cursor-anchored target; "no match" once it forms a shape
            // no rule wants, the app is excluded, or the stroke has
            // already run past maxStrokeMs (so the user sees it won't
            // fire).
            // Cache the target app icon across drag samples — a single
            // NSRunningApplication lookup per stroke (the bundleID is
            // frozen at button-down) keeps the per-sample path cheap.
            var lastIconBundle = ""
            source.onSample = { s in
                var valid = false
                var hint: GestureHint? = nil      // nil only before any direction
                if s.pattern.isEmpty {
                    valid = !s.expired            // neutral start
                } else if s.expired || s.cancelled
                    || Matcher.isExcluded(bundleID: s.bundleID, by: excludes) {
                    hint = GestureHint(shape: arrows(s.pattern), rows: [])
                } else {
                    // Blue when the *current* shape fires a rule; the
                    // assist rows show every rule reachable from here
                    // (so a red, still-incomplete shape shows the way).
                    valid = Matcher.match(pattern: s.pattern,
                                          bundleID: s.bundleID,
                                          rules: rules) != nil
                    hint = assistHint(pattern: s.pattern,
                                      candidates: Matcher.candidates(
                                        prefix: s.pattern, bundleID: s.bundleID,
                                        rules: rules))
                }
                // Resolve the badge icon at most once per stroke. The
                // bundleID is set at button-down and never changes
                // within a stroke, so this fires on the first sample
                // that carries a non-empty bundleID and is a no-op
                // afterwards.
                let iconToSet: NSImage??
                if !s.bundleID.isEmpty && s.bundleID != lastIconBundle {
                    lastIconBundle = s.bundleID
                    iconToSet = NSRunningApplication
                        .runningApplications(withBundleIdentifier: s.bundleID)
                        .first?.icon
                } else {
                    iconToSet = nil
                }
                MainActor.assumeIsolated {
                    if let icon = iconToSet { overlay?.setOriginIcon(icon) }
                    overlay?.addPoint(s.point, valid: valid, hint: hint)
                }
            }
            source.onStrokeEnd = {
                lastIconBundle = ""
                MainActor.assumeIsolated { overlay?.clear() }
            }
            Log.line("overlay: enabled (match=\(cfg.overlayColor), "
                     + "noMatch=\(cfg.overlayColorNoMatch), "
                     + "width=\(cfg.overlayWidth))")
        }

        let controller = Controller(source: source, config: cfg)
        // Push `[overlay]` changes to the live overlay so edits take
        // effect without a restart. `applyConfig` covers every
        // overlay knob; trigger and `min-stroke-px` still need a
        // restart (Controller.reload already logs the warning).
        if let overlay {
            controller.onConfigChanged = { [weak overlay] new in
                MainActor.assumeIsolated { overlay?.applyConfig(new) }
            }
        }
        controller.start()

        // Live-reload on config edits (no `--reload` needed). Held for
        // the process lifetime via `app.run()`.
        let watcher = ConfigWatcher(path: StrokeConfig.path) {
            Log.line("config: file changed — reloading")
            controller.reload(cause: "file-change")
        }
        watcher.start()

        app.run()
        exit(0)
    }


    /// Health report: Accessibility, config, daemon, event tap. Exit 0
    /// if everything's green, 1 if any check fails.
    private static func runDoctor() -> Never {
        func line(_ ok: Bool, _ label: String, _ detail: String) -> String {
            "  \(ok ? "✓" : "✗")  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(detail)"
        }
        var ok = true
        print("stroke doctor")

        let ax = AXTarget.isTrusted()
        ok = ok && ax
        print(line(ax, "Accessibility:",
                   ax ? "granted"
                      : "NOT granted — open Stroke.app and grant it in "
                        + "System Settings → Privacy & Security → Accessibility"))

        let fileExists = FileManager.default.fileExists(atPath: StrokeConfig.path)
        let cfg = StrokeConfig.load()
        print(line(fileExists, "Config:",
                   fileExists
                     ? "\(StrokeConfig.path) — \(cfg.rules.count) rule(s), "
                       + "trigger=\(cfg.trigger.button.rawValue)"
                     : "no file at \(StrokeConfig.path) — using built-in "
                       + "defaults (curl the template)"))

        let running = isServerRunning()
        print(line(running, "Daemon:",
                   running ? "running" : "not running — start with `stroke`"))

        let tap = MacOSMouseSource.canInstallTap()
        ok = ok && tap
        print(line(tap, "Event tap:",
                   tap ? "can install" : "cannot install (needs Accessibility)"))

        // Tuned values — the same ones the daemon would apply. Lets a
        // remote diagnosis confirm what's in effect without parsing
        // config.toml independently.
        print(line(true, "Tuning:",
                   "min-stroke-px=\(cfg.minStrokePx) "
                   + "max-stroke-ms=\(cfg.maxStrokeMs) "
                   + "cancel-reversals=\(cfg.cancelReversals) "
                   + "cancel-window-ms=\(cfg.cancelWindowMs) "
                   + "sample-hz=\(cfg.sampleHz)"))

        // Rule patterns — confirms the user's edits parsed where they
        // expect. Truncate at 12 to keep --doctor scannable.
        if !cfg.rules.isEmpty {
            print("  ·  Rules:")
            let maxShown = 12
            for r in cfg.rules.prefix(maxShown) {
                let appList = r.apps.joined(separator: ",")
                print("       \(r.pattern.padding(toLength: 6, withPad: " ", startingAt: 0))"
                      + "\(r.name)  [\(appList)]")
            }
            if cfg.rules.count > maxShown {
                print("       … +\(cfg.rules.count - maxShown) more")
            }
        }

        exit(ok ? 0 : 1)
    }


    /// `--test PATTERN [bundle-id]`: resolve which rule a pattern would
    /// fire. With a bundle id, report the single firing rule (honouring
    /// app filters + excludes); without one, list every rule that uses
    /// the pattern. Reads config; touches no event tap.
    private static func runTest(pattern: String, bundleID: String?) -> Never {
        guard !pattern.isEmpty else {
            FileHandle.standardError.write(Data(
                "usage: stroke --test PATTERN [bundle-id]\n".utf8))
            exit(2)
        }
        let cfg = StrokeConfig.load()
        if let bid = bundleID {
            if Matcher.isExcluded(bundleID: bid, by: cfg.excludeApps) {
                print("\(pattern) on \(bid) → app excluded, nothing fires")
            } else if let rule = Matcher.match(pattern: pattern,
                                               bundleID: bid, rules: cfg.rules) {
                print("\(pattern) on \(bid) → \"\(rule.name)\"  "
                      + "[\(actionDescription(rule.action))]")
            } else {
                print("\(pattern) on \(bid) → no matching rule")
            }
        } else {
            let matches = cfg.rules.filter { $0.pattern == pattern }
            if matches.isEmpty {
                print("no rule has pattern \"\(pattern)\"")
            } else {
                print("pattern \"\(pattern)\" is used by:")
                for r in matches {
                    print("  \"\(r.name)\"  apps=\(r.apps)  "
                          + "[\(actionDescription(r.action))]")
                }
            }
        }
        exit(0)
    }

    private static func actionDescription(_ action: Action) -> String {
        switch action {
        case .key(let k):   return "key \(k)"
        case .ax(let v):    return "ax \(v)"
        case .shell(let c): return "shell \(c)"
        }
    }


    /// Render a `L U R D` pattern as arrow glyphs (`DL` → `↓←`).
    private static func arrows(_ pattern: String) -> String {
        pattern.compactMap { Direction(rawValue: $0)?.arrow }.joined()
    }

    /// Build the overlay hint: the shape so far, plus a row per rule
    /// reachable from here. Each row shows only the *remaining* arrows
    /// (the already-drawn prefix is stripped), and `fires` marks the
    /// rule the current shape triggers now. Capped so a permissive
    /// prefix can't grow a wall.
    private static func assistHint(pattern: String, candidates: [Rule]) -> GestureHint {
        let rows = candidates.prefix(6).map { r in
            GestureHint.Row(
                suffix: arrows(String(r.pattern.dropFirst(pattern.count))),
                name: r.name,
                fires: r.pattern == pattern)
        }
        return GestureHint(shape: arrows(pattern), rows: Array(rows))
    }


    /// Print the running daemon's status (rule count, trigger, last
    /// gesture …) from the status file it maintains. Exit 3 if no
    /// daemon is running.
    private static func runStatus() -> Never {
        guard isServerRunning() else {
            FileHandle.standardError.write(Data(
                "stroke: no daemon running\n".utf8))
            exit(3)
        }
        if let s = try? String(contentsOfFile: statusPath, encoding: .utf8) {
            print(s)
        } else {
            print("stroke: running (status file not written yet)")
        }
        exit(0)
    }


    /// Post `cmd` to the running daemon via DistributedNotificationCenter,
    /// then exit. Refuses (exit 3) if no daemon is running so the
    /// user doesn't get a silent no-op.
    private static func runClient(cmd: String) -> Never {
        guard isServerRunning() else {
            FileHandle.standardError.write(Data((
                "stroke: no daemon running — start it with "
                + "`stroke` (or `stroke --debug`) first\n"
            ).utf8))
            exit(3)
        }
        DistributedNotificationCenter.default().postNotificationName(
            .init(controlNotificationName),
            object: cmd,
            userInfo: nil,
            deliverImmediately: true
        )
        exit(0)
    }

    /// `true` when another stroke server process is currently
    /// running. Uses `pgrep` (part of macOS — no extra deps).
    /// Self-aware: this process's own pid is excluded so a
    /// client-mode invocation doesn't mis-detect itself.
    private static func isServerRunning() -> Bool {
        let myPid = ProcessInfo.processInfo.processIdentifier
        // Covers both raw SwiftPM builds (`.build/debug/stroke` etc.)
        // and a future bundled `stroke.app/Contents/MacOS/stroke`.
        let patterns = ["/Contents/MacOS/stroke", "\\.build/.*/stroke"]
        for pattern in patterns {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", pattern]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                // pgrep itself unavailable → can't tell. Assume
                // alive so we don't false-positive a "no daemon"
                // message on broken systems.
                return true
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8)
            else { continue }
            let pids = text.split(separator: "\n")
                .compactMap { Int32($0) }
            if pids.contains(where: { $0 != myPid }) { return true }
        }
        return false
    }


    /// Interactive recorder. Installs an event tap in "recording"
    /// mode (no actions fire, every stroke including too-short ones
    /// is delivered to the print handler), refuses if the daemon
    /// is already running (would fight over the tap). Ctrl-C to
    /// exit.
    @MainActor
    private static func runRecord() -> Never {
        if isServerRunning() {
            FileHandle.standardError.write(Data((
                "stroke: daemon is running — `stroke --quit` first, "
                + "then `stroke --record`\n"
            ).utf8))
            exit(3)
        }

        let cfg = StrokeConfig.load()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AXTarget.ensureTrusted()

        let source = MacOSMouseSource(
            trigger: cfg.trigger,
            minStrokePx: cfg.minStrokePx,
            isRecording: true
        )
        source.start { event in
            let dirs = Recognition.recognize(samples: event.samples,
                                              minStrokePx: cfg.minStrokePx)
            let (dx, dy) = event.samples.span
            guard !dirs.isEmpty else {
                FileHandle.standardOutput.write(Data((
                    "(too short)  samples=\(event.samples.count)  "
                    + "max|dx|=\(Int(dx)) max|dy|=\(Int(dy))  "
                    + "threshold=\(cfg.minStrokePx)  "
                    + "target=\(event.target.bundleID)\n"
                ).utf8))
                return
            }
            let pattern = dirs.patternString
            // A paste-ready rule skeleton: pattern + the exact target
            // bundle id pre-filled; the user picks an action.
            let snippet = """
            pattern=\(pattern)  samples=\(event.samples.count)  \
            max|dx|=\(Int(dx)) max|dy|=\(Int(dy))  target=\(event.target.bundleID)

            [[rules]]
            name = "\(pattern)"
            pattern = "\(pattern)"
            apps = ["\(event.target.bundleID)"]
            action-type = "key"        # key | ax | shell
            action-keys = "cmd+w"      # ← edit me

            """
            FileHandle.standardOutput.write(Data(snippet.utf8))
        }

        FileHandle.standardError.write(Data((
            "stroke --record: draw gestures with the configured "
            + "trigger button (\(cfg.trigger.button.rawValue) mouse, "
            + "minStrokePx=\(cfg.minStrokePx)). Ctrl-C to exit.\n"
        ).utf8))
        app.run()
        exit(0)
    }
}
