// Entry point. Three modes chosen by CLI flag: server (no flag —
// install tap, wait), client (`--reload` / `--quit` / `--status` —
// post DNC to the running server), standalone (`--validate` /
// `--doctor` / `--test` / `--record` / `--help`).
//
// `@main enum WandApp` — NOT top-level `main.swift`. The enum
// form lets a future XCTest `@testable import WandApp` work
// without launching the daemon (same trap as facet/ws-tabs —
// don't reintroduce main.swift).

import AppKit
import Foundation
import WandCore
import WandAdapterMacOS

@main
enum WandApp {

    static func printHelp() -> Never {
        let help = """
        wand — global mouse-gesture daemon for macOS.

        USAGE
          wand                       run as agent (CGEventTap loop)
          wand [COMMAND]             one-shot client command

        SERVER MODE
          wand                       run as agent
          wand --debug               verbose log to stderr +
                                       /tmp/wand.log

        CLIENT COMMANDS — need a running daemon (exit 3 if none)
          wand --reload              re-read ~/.config/wand/config.toml
                                       (also automatic on file save).
                                       Live: [[rules]] / exclude-apps /
                                       [recognition] timing / [overlay].
                                       Restart only: [trigger].
          wand --status              print rule count, trigger, last
                                       gestures, counters, last reload
          wand --quit                terminate the running daemon
          wand --show-menu           ask the daemon to pop the launcher
            --items <PATH>             menu at a screen point with the
            --at <X> <Y>               given [[item]] file. Cocoa coords
            [--selection <TEXT>]       (Y-up). For event-driven triggers
            [--title <TEXT>]           (eventfx text-selection etc).
                                       $SELECTION is exported to shell
                                       actions if --selection given.
                                       --title overrides AX-fetched
                                       focused-window title for
                                       $WAND_TARGET_TITLE (default:
                                       AX-fetch from frontmost app).

        STANDALONE COMMANDS — no daemon required (--record refuses if one runs)
          wand --validate            parse config.toml; exit 0 if valid
            [--items <PATH>]           also validate a standalone items
                                       file (for --show-menu)
          wand --doctor              health check: Accessibility, config,
                                       daemon, event tap, tuning + rules
          wand --test PATTERN [APP]  dry-run: which rule would fire for
                                       a pattern (optionally for a bundle id)
          wand --record              interactive recorder: draw a gesture,
                                       get a paste-ready [[rules]] snippet
                                       on stdout. Refuses if the daemon is
                                       running (would fight over the tap).
          wand --resign              re-sign Wand.app with the persistent
                                       "wand Local Signing" identity + restart
                                       (run once after `brew install` / upgrade)
          wand --help                this help

        EXIT CODES
          0   success
          2   bad flag / invalid config
          3   precondition mismatch: client cmd with no daemon, or
              --record with a daemon running

        CONFIG
          ~/.config/wand/config.toml is the single source of truth.
          wand never writes to it; runtime CLI flags affect the
          current session only.

        DOCS
          https://github.com/akira-toriyama/wand
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
        // recognised one, so `wand --reload --typo` fails loudly on
        // --typo instead of silently acting on --reload and never
        // looking at the rest (no silent fallback — the loud-reject
        // policy must hold even when flags are combined).
        let recognised: Set<String> = [
            "--help", "--debug", "--validate", "--record",
            "--reload", "--quit", "--status", "--doctor",
            "--resign", "--show-menu",
            "--items", "--at", "--selection", "--title",
        ]
        // Value-bearing flags' operand counts — scan skips that many
        // tokens after seeing the flag. Without this, `stroke
        // --show-menu --items /tmp/foo.toml` would reject the path
        // as an "unknown flag".
        let valueArities: [String: Int] = [
            "--items": 1, "--selection": 1, "--at": 2, "--title": 1,
        ]
        var ai = 0
        while ai < argv.count {
            let a = argv[ai]
            if let arity = valueArities[a] {
                ai += 1 + arity
                continue
            }
            if !recognised.contains(a) {
                let msg = "wand: unknown flag \"\(a)\" — see "
                    + "`wand --help`\n"
                FileHandle.standardError.write(Data(msg.utf8))
                exit(2)
            }
            ai += 1
        }

        // Standalone modes — no running daemon required.
        if argv.contains("--doctor") { runDoctor() }
        if argv.contains("--validate") {
            let cfg = WandConfig.load()
            let launcherLine = cfg.launcher.enabled
                ? ", launcher=\(cfg.launcher.trigger.button.rawValue) "
                  + "(\(cfg.launcher.items.count) item(s))"
                : ""
            FileHandle.standardError.write(Data((
                "wand: loaded \(cfg.rules.count) rule(s), "
                + "trigger=\(cfg.trigger.button.rawValue), "
                + "minStrokePx=\(cfg.minStrokePx)\(launcherLine)\n"
            ).utf8))
            // `--validate --items PATH` also validates a standalone
            // items file (intended for --show-menu) — parse + report
            // count, exit 2 on read failure.
            if let path = valueAfter("--items", in: argv) {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8)
                else {
                    FileHandle.standardError.write(Data((
                        "wand: --items: could not read \(path)\n"
                    ).utf8))
                    exit(2)
                }
                let parsed = WandConfig.parseItems(text)
                FileHandle.standardError.write(Data((
                    "wand: items file \(path) — "
                    + "\(parsed.items.count) item(s), "
                    + "layout=\(parsed.layout.rawValue)\n"
                ).utf8))
            }
            exit(0)
        }
        if argv.contains("--record") { runRecord() }
        if argv.contains("--resign") { runResign() }

        // Client commands — require a running daemon.
        if argv.contains("--status") { runStatus() }
        if argv.contains("--reload") { runClient(cmd: "reload") }
        if argv.contains("--quit")   { runClient(cmd: "quit") }
        if argv.contains("--show-menu") { runShowMenu(argv: argv) }

        // ----- Server mode -----
        runServer()
    }


    @MainActor
    private static func runServer() -> Never {
        let cfg = WandConfig.load()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)            // LSUIElement: no Dock icon
        AXTarget.ensureTrusted()

        let source = MacOSMouseSource(
            trigger: cfg.trigger,
            minStrokePx: cfg.minStrokePx,
            maxSegmentMs: cfg.maxSegmentMs,
            cancelReversals: cfg.cancelReversals,
            cancelWindowMs: cfg.cancelWindowMs
        )

        // Launcher trigger — only allocated when opted in at startup.
        // Like the gesture tap, its button is baked into the event
        // mask, so toggling enabled / changing button needs a restart
        // (surfaced as pending-restart in `--status`).
        let launcher: LauncherSource? = cfg.launcher.enabled
            ? MacOSLauncherSource(trigger: cfg.launcher.trigger)
            : nil

        // Construct Controller up front so the overlay's onSample
        // closure can read its live `config` snapshot per-sample,
        // instead of capturing the startup rules locally. Otherwise
        // dispatch (which reads `controller.config`) and the assist
        // tooltips (which would read captured locals) would drift
        // apart after a hot-reload — the user would see candidate
        // cards for the OLD rule set while a NEW rule fired.
        let controller = Controller(source: source,
                                    launcher: launcher,
                                    config: cfg)

        // Gesture-trail overlay (passive observer of the sample
        // stream). Held for the process lifetime via `app.run()`.
        // Declared `outside` the `if` so the live-reload hook below
        // can hot-apply `[overlay]` changes without a restart.
        var overlay: GestureOverlay?
        if cfg.overlayEnabled {
            overlay = GestureOverlay(cfg)
            overlay?.show()
            // Cache the target app icon across drag samples — a single
            // NSRunningApplication lookup per stroke (the bundleID is
            // frozen at button-down) keeps the per-sample path cheap.
            var lastIconBundle = ""
            source.onSample = { [weak controller] s in
                // Read rules + excludes from the live Controller so
                // a hot-reload is visible to the assist tooltips. The
                // tap callback fires these on the main thread but
                // isn't statically @MainActor — `assumeIsolated` is
                // the documented bridge.
                guard let live = controller?.config else { return }
                var valid = false
                var hint: GestureHint? = nil      // nil only before any direction
                if s.pattern.isEmpty {
                    valid = !s.expired            // neutral start
                } else if s.expired || s.cancelled
                    || Matcher.isExcluded(bundleID: s.bundleID,
                                          by: live.excludeApps) {
                    hint = GestureHint(shape: arrows(s.pattern), rows: [])
                } else {
                    // Match color when the *current* shape fires a
                    // rule; assist rows show every rule reachable
                    // from here.
                    // Overlay's "current shape fires?" check uses
                    // apps + filter-title (both cheap; title was
                    // captured at button-down on the TrailSample).
                    // filter-shell is skipped here — per-sample
                    // shell evaluation is too costly. So a rule
                    // gated by filter-shell may flash green in the
                    // overlay yet not fire at button-up.
                    let overlayTarget = Target(
                        pid: 0, bundleID: s.bundleID,
                        title: s.title, frame: .zero, windowID: 0)
                    valid = Matcher.match(pattern: s.pattern,
                                          target: overlayTarget,
                                          rules: live.rules) != nil
                    hint = assistHint(pattern: s.pattern,
                                      candidates: Matcher.candidates(
                                        prefix: s.pattern, bundleID: s.bundleID,
                                        rules: live.rules))
                }
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

        // Push `[overlay]` changes to the live overlay so edits take
        // effect without a restart. `applyConfig` covers every
        // overlay knob; `[trigger]` and the `[recognition]` timing
        // knobs still need a restart (Controller.reload logs them).
        if let overlay {
            controller.onConfigChanged = { [weak overlay] new in
                MainActor.assumeIsolated { overlay?.applyConfig(new) }
            }
        }
        controller.start()

        // Live-reload on config edits (no `--reload` needed). Held for
        // the process lifetime via `app.run()`.
        let watcher = ConfigWatcher(path: WandConfig.path) {
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
        print("wand doctor")

        let ax = AXTarget.isTrusted()
        ok = ok && ax
        print(line(ax, "Accessibility:",
                   ax ? "granted"
                      : "NOT granted — open Wand.app and grant it in "
                        + "System Settings → Privacy & Security → Accessibility"))

        let fileExists = FileManager.default.fileExists(atPath: WandConfig.path)
        let cfg = WandConfig.load()
        print(line(fileExists, "Config:",
                   fileExists
                     ? "\(WandConfig.path) — \(cfg.rules.count) rule(s), "
                       + "trigger=\(cfg.trigger.button.rawValue)"
                     : "no file at \(WandConfig.path) — using built-in "
                       + "defaults (curl the template)"))

        let running = isServerRunning()
        print(line(running, "Daemon:",
                   running ? "running" : "not running — start with `wand`"))

        let tap = MacOSMouseSource.canInstallTap()
        ok = ok && tap
        print(line(tap, "Event tap:",
                   tap ? "can install" : "cannot install (needs Accessibility)"))

        // Launcher diagnostics — only meaningful when opted in.
        if cfg.launcher.enabled {
            let lTap = MacOSLauncherSource.canInstallTap(
                trigger: cfg.launcher.trigger)
            ok = ok && lTap
            print(line(lTap, "Launcher tap:",
                       lTap
                         ? "can install (button="
                           + "\(cfg.launcher.trigger.button.rawValue), "
                           + "\(cfg.launcher.items.count) item(s))"
                         : "cannot install"))
        } else {
            print(line(true, "Launcher:",
                       "disabled (`[launcher] enabled = false`)"))
        }

        // Tuned values — the same ones the daemon would apply. Lets a
        // remote diagnosis confirm what's in effect without parsing
        // config.toml independently.
        print(line(true, "Tuning:",
                   "min-stroke-px=\(cfg.minStrokePx) "
                   + "max-segment-ms=\(cfg.maxSegmentMs) "
                   + "cancel-reversals=\(cfg.cancelReversals) "
                   + "cancel-window-ms=\(cfg.cancelWindowMs)"))

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
                "usage: wand --test PATTERN [bundle-id]\n".utf8))
            exit(2)
        }
        let cfg = WandConfig.load()
        if let bid = bundleID {
            if Matcher.isExcluded(bundleID: bid, by: cfg.excludeApps) {
                print("\(pattern) on \(bid) → app excluded, nothing fires")
            } else if let rule = Matcher.match(
                pattern: pattern,
                target: Target(pid: 0, bundleID: bid, title: "",
                               frame: .zero, windowID: 0),
                rules: cfg.rules) {
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
        case .url(let u):   return "url \(u)"
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
            FileHandle.standardError.write(Data((
                "wand: --status needs a running daemon (it reads the "
                + "status file the daemon maintains). Start one with "
                + "`wand` first.\n"
            ).utf8))
            exit(3)
        }
        if let s = try? String(contentsOfFile: statusPath, encoding: .utf8) {
            print(s)
        } else {
            print("wand: running (status file not written yet)")
        }
        exit(0)
    }


    /// `wand --resign` re-signs the installed Wand.app with the
    /// persistent `wand Local Signing` self-signed identity and
    /// restarts the daemon. Necessary after every `brew install` /
    /// `brew upgrade wand`, because Homebrew's build sandbox
    /// blocks the in-formula `setup-signing-cert.sh` from touching
    /// the user's login keychain — install falls back to ad-hoc
    /// signing and TCC re-prompts for Accessibility on every
    /// upgrade. Same pattern as chord 0.3.3's `--resign`.
    ///
    /// Exit codes:
    ///   0 — re-signed (restart attempted, best-effort)
    ///   1 — codesign failed
    ///   2 — no Wand.app found in any expected location
    ///   3 — signing identity missing (run setup-signing-cert.sh first)
    private static func runResign() -> Never {
        guard let appPath = findWandApp() else {
            FileHandle.standardError.write(Data((
                "wand: no Wand.app found at "
                + "/opt/homebrew/Cellar/wand/*/, /Applications, "
                + "or ~/Applications.\n"
                + "        install via "
                + "`brew install akira-toriyama/tap/wand` or "
                + "package locally first.\n"
            ).utf8))
            exit(2)
        }
        print("wand: detected Wand.app at \(appPath)")

        let identity = "wand Local Signing"
        guard hasSigningIdentity(identity) else {
            let setupHint = setupCertHint()
            FileHandle.standardError.write(Data((
                "wand: no '\(identity)' identity in your login keychain.\n"
                + "        run once:\n"
                + "          \(setupHint)\n"
                + "          wand --resign\n"
            ).utf8))
            exit(3)
        }

        print("wand: signing with identity '\(identity)'")
        let codesignExit = runProcess(
            "/usr/bin/codesign",
            args: ["--force", "--sign", identity, appPath])
        guard codesignExit == 0 else {
            FileHandle.standardError.write(Data((
                "wand: codesign failed (exit \(codesignExit))\n"
            ).utf8))
            exit(1)
        }

        print("wand: restarting daemon")
        let brewExit = runProcess(
            "/opt/homebrew/bin/brew",
            args: ["services", "restart", "wand"],
            captureOutput: true)
        if brewExit == 0 {
            print("wand: restarted via `brew services restart wand`")
            exit(0)
        }
        // Only `homebrew.mxcl.wand` — wand doesn't ship an
        // in-repo LaunchAgent template, so no `com.wand.wand`
        // label exists in the wild. Adding it as a fallback was
        // dead code (kickstart would always 113 / no such service).
        let label = "homebrew.mxcl.wand"
        let kick = runProcess(
            "/bin/launchctl",
            args: ["kickstart", "-k", "gui/\(getuid())/\(label)"],
            captureOutput: true)
        if kick == 0 {
            print("wand: restarted via `launchctl kickstart \(label)`")
            exit(0)
        }
        FileHandle.standardError.write(Data((
            "wand: re-signed, but couldn't restart the daemon — "
            + "start it manually.\n"
        ).utf8))
        exit(0)
    }

    /// Pick the first existing Wand.app from the canonical install
    /// locations. The brew Cellar (which carries the live binary) is
    /// preferred over manual /Applications copies.
    private static func findWandApp() -> String? {
        let cellar = "/opt/homebrew/Cellar/wand"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: cellar) {
            // `.numeric` makes "2.10.0" > "2.2.0" — a plain string
            // sort would silently pick the older 2.2.0 as "latest"
            // once a 2.10 series ships.
            let sorted = versions.sorted { a, b in
                a.compare(b, options: .numeric) == .orderedDescending
            }
            for v in sorted {
                let p = "\(cellar)/\(v)/Wand.app"
                if FileManager.default.fileExists(atPath: p) { return p }
            }
        }
        for candidate in [
            "/Applications/Wand.app",
            "\(NSHomeDirectory())/Applications/Wand.app",
        ] {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Untrusted self-signed certs don't appear in `find-identity`
    /// (that filter lists trusted identities only). Use
    /// `find-certificate` which surfaces untrusted entries too.
    private static func hasSigningIdentity(_ name: String) -> Bool {
        runProcess(
            "/usr/bin/security",
            args: ["find-certificate", "-c", name,
                   "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"],
            captureOutput: true
        ) == 0
    }

    /// Best-effort guess at where `setup-signing-cert.sh` lives on
    /// the user's machine. brew installs ship it under
    /// `share/wand/`, dev installs have it at the repo root.
    private static func setupCertHint() -> String {
        let brewShared = "/opt/homebrew/share/wand/setup-signing-cert.sh"
        if FileManager.default.fileExists(atPath: brewShared) {
            return brewShared
        }
        return "./setup-signing-cert.sh"
    }

    /// Spawn + wait. Returns the child's exit code on completion,
    /// or `-1` when `Process.run()` itself failed (executable not
    /// found, permission denied, etc.) — the catch path also emits
    /// a stderr line so the caller's generic "exit -1" message
    /// isn't the only signal.
    @discardableResult
    private static func runProcess(_ executable: String,
                                   args: [String],
                                   captureOutput: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if captureOutput {
            p.standardOutput = FileHandle.nullDevice
            p.standardError  = FileHandle.nullDevice
        }
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            FileHandle.standardError.write(Data(
                "wand: couldn't launch \(executable): \(error)\n".utf8))
            return -1
        }
    }

    /// `--items <PATH>` / `--selection <TEXT>` etc — return the
    /// token immediately after `flag`, or nil if `flag` isn't present
    /// or has no follower. Shared by `--show-menu` and `--validate`.
    private static func valueAfter(_ flag: String, in argv: [String]) -> String? {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count
        else { return nil }
        return argv[i + 1]
    }

    /// `wand --show-menu --items <PATH> --at <X> <Y> [--selection <TEXT>]`
    /// — external trigger entry to the launcher menu. Validates args
    /// locally (exit 2 on bad input), checks daemon liveness (exit 3),
    /// then posts a DNC notification with the parameters in userInfo
    /// and exits 0. The daemon does the rest async — resolves the
    /// frontmost app as the target (spine exception, see CLAUDE.md),
    /// builds the menu, pops it up.
    private static func runShowMenu(argv: [String]) -> Never {
        guard let itemsPath = valueAfter("--items", in: argv) else {
            FileHandle.standardError.write(Data((
                "wand: --show-menu: --items <PATH> is required\n"
            ).utf8))
            exit(2)
        }
        // Resolve to absolute so the daemon — which may be running
        // from a different working dir — can find the file.
        let absItems = (itemsPath as NSString).expandingTildeInPath
        let absPath = absItems.hasPrefix("/")
            ? absItems
            : FileManager.default.currentDirectoryPath + "/" + absItems
        guard let text = try? String(contentsOfFile: absPath, encoding: .utf8) else {
            FileHandle.standardError.write(Data((
                "wand: --show-menu: could not read items file "
                + "\(absPath)\n"
            ).utf8))
            exit(2)
        }
        // Local validation so a malformed file is rejected at the
        // client (exit 2) instead of silently dropping at the daemon.
        let parsed = WandConfig.parseItems(text)
        guard !parsed.items.isEmpty else {
            FileHandle.standardError.write(Data((
                "wand: --show-menu: items file \(absPath) yielded "
                + "0 items (no `[[item]]` rows, or all dropped — see "
                + "/tmp/wand.log for per-row diagnostics)\n"
            ).utf8))
            exit(2)
        }
        // --at X Y — parse two consecutive numeric tokens.
        guard let i = argv.firstIndex(of: "--at"),
              i + 2 < argv.count,
              let x = Double(argv[i + 1]),
              let y = Double(argv[i + 2]) else {
            FileHandle.standardError.write(Data((
                "wand: --show-menu: --at <X> <Y> is required "
                + "(Cocoa screen coords, Y-up)\n"
            ).utf8))
            exit(2)
        }
        let selection = valueAfter("--selection", in: argv) ?? ""
        // --title: caller-supplied window title to override the
        // daemon's AX fetch. Used by event triggers (eventfx) that
        // already know the source window at fire time and want it
        // surfaced verbatim — avoids racing the daemon's AX lookup
        // against window-switch latency.
        let title = valueAfter("--title", in: argv) ?? ""

        guard isServerRunning() else {
            FileHandle.standardError.write(Data((
                "wand: --show-menu: no daemon running — start it "
                + "with `wand` (or `wand --debug`) first\n"
            ).utf8))
            exit(3)
        }
        DistributedNotificationCenter.default().postNotificationName(
            .init(controlNotificationName),
            object: "show-menu",
            userInfo: [
                "items": absPath,
                "x": x,
                "y": y,
                "selection": selection,
                "title": title,
            ],
            deliverImmediately: true
        )
        exit(0)
    }

    /// Post `cmd` to the running daemon via DistributedNotificationCenter,
    /// then exit. Refuses (exit 3) if no daemon is running so the
    /// user doesn't get a silent no-op.
    private static func runClient(cmd: String) -> Never {
        guard isServerRunning() else {
            FileHandle.standardError.write(Data((
                "wand: no daemon running — start it with "
                + "`wand` (or `wand --debug`) first\n"
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

    /// `true` when another wand server process is currently
    /// running. Uses `pgrep` (part of macOS — no extra deps).
    /// Self-aware: this process's own pid is excluded so a
    /// client-mode invocation doesn't mis-detect itself.
    private static func isServerRunning() -> Bool {
        let myPid = ProcessInfo.processInfo.processIdentifier
        // Covers both raw SwiftPM builds (`.build/debug/wand` etc.)
        // and the bundled `Wand.app/Contents/MacOS/wand`.
        let patterns = ["/Contents/MacOS/wand", "\\.build/.*/wand"]
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
                "wand: daemon is running — `wand --quit` first, "
                + "then `wand --record`\n"
            ).utf8))
            exit(3)
        }

        let cfg = WandConfig.load()
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
            "wand --record: draw gestures with the configured "
            + "trigger button (\(cfg.trigger.button.rawValue) mouse, "
            + "minStrokePx=\(cfg.minStrokePx)). Ctrl-C to exit.\n"
        ).utf8))
        app.run()
        exit(0)
    }
}
