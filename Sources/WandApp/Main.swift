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
import CLIKit
import WandCore
import WandAdapterMacOS

@main
enum WandApp {

    static func printHelp() -> Never {
        let help = """
        wand — global mouse-gesture daemon for macOS.

        USAGE
          wand                              run as agent (CGEventTap loop)
          wand <domain> --<verb> [VALUE …]  one-shot control command

        SERVER MODE
          wand                              run as agent. Set WAND_DEBUG=1 in
                                              the environment for verbose log to
                                              stderr + /tmp/wand.log (run.sh sets it).

        daemon — lifecycle (need a running daemon; exit 3 if none)
          wand daemon --reload              re-read ~/.config/wand/config.toml
                                              (also automatic on file save). Live:
                                              [[cast.cursor.rule]] / [exclude].apps /
                                              [cast.recognition] / [cast.overlay] /
                                              [cast.fire]. Restart only: [cast]
                                              button+modifiers, [tome] enabled+
                                              button+modifiers.
          wand daemon --show                print rule count, trigger, last
                                              gestures, counters, last reload
          wand daemon --quit                terminate the running daemon
          wand daemon --resign              re-sign Wand.app with the persistent
                                              "wand Local Signing" identity + restart
                                              (run once after `brew install` / upgrade)

        cast — gesture engine
          wand cast --test PATTERN [APP]    dry-run: which rule would fire for a
                                              pattern (optionally for a bundle id)
          wand cast --record                interactive recorder: draw a gesture,
                                              get a paste-ready [[cast.cursor.rule]] on
                                              stdout. Refuses if the daemon runs.

        tome — launcher menu
          wand tome --open                  ask the daemon to pop the tome menu
            --items <PATH>                    at a screen point with the given
            --at <X> <Y>                      [[tome.cursor.item]] file. Cocoa coords
            [--selection <TEXT>]              (Y-up; --at accepts negatives). For an
            [--title <TEXT>]                  upstream trigger. $SELECTION is exported
                                              to shell actions if --selection given;
                                              --title overrides the AX-fetched
                                              focused-window title for $WAND_TARGET_TITLE.
          wand tome --validate --items <PATH>
                                            validate a standalone items file.

        config — settings
          wand config --validate            parse config.toml; exit 0 if valid.
                                              Warnings (clamps, collisions, typos)
                                              print to stderr + /tmp/wand.log.
          wand config --doctor              health check: Accessibility, config,
                                              daemon, event tap, tuning + rules
          wand config --emit-schema         print the config.toml JSON Schema
                                              (Draft-07) to stdout. Generated from
                                              wand's own parser, so it always matches
                                              the binary. Regenerate with:
                                                wand config --emit-schema > config.schema.json

          wand --help, -h                   this help

        EXIT CODES
          0   success
          2   usage / bad flag / invalid config (loud on stderr)
          3   daemon precondition: a daemon command with no daemon running,
              or `cast --record` with a daemon running

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

        // Debug logging is triggered by the WAND_DEBUG env var (set by
        // run.sh), NOT a CLI flag — run.sh and a brew/raw launch start the
        // same artifact, so the signal is injected at launch time. A normal
        // launch sets nothing and stays quiet; `--debug` on argv now exits 2.
        debugMode = ProcessInfo.processInfo.environment["WAND_DEBUG"] != nil

        // Bare `wand` = server mode (the LSUIElement launch path). Every
        // other invocation is a yabai-style `wand <domain> --<verb>` control
        // command. The domain noun is peeled here; CLIKit then tokenizes the
        // rest against that domain's verb-arity spec (so e.g. `--at -100 50`
        // negatives are consumed as values, not mistaken for flags).
        guard let domain = argv.first else { runServer() }
        switch domain {
        case "--help", "-h": printHelp()
        case "daemon": dispatchDaemon(Array(argv.dropFirst()))
        case "cast":   dispatchCast(Array(argv.dropFirst()))
        case "tome":   dispatchTome(Array(argv.dropFirst()))
        case "config": dispatchConfig(Array(argv.dropFirst()))
        default:
            CLIKit.die("wand",
                "unknown command '\(domain)'. Domains: daemon cast tome config "
                + "(or bare `wand` for server). See `wand --help`.")
        }
    }

    // MARK: domain dispatch (CLIKit tokenizes; wand keeps verb policy — D4)

    /// Parse `argv` against `spec`, mapping any usage error to a loud
    /// exit 2. (CLIKit's tokenizer is pure; wand owns the exit.)
    private static func parseOrDie(_ argv: [String], _ spec: CLIKit.Spec) -> CLIKit.Invocation {
        do { return try CLIKit.parse(argv, spec: spec) }
        catch let e as CLIKit.ParseError { CLIKit.die("wand", e.usageMessage) }
        catch { CLIKit.die("wand", "\(error)") }
    }

    /// Exactly one of `verbs` must be present. CLIKit already rejected
    /// unknown flags; this is wand's mutual-exclusion policy (a domain
    /// has one action; modifiers attach to it).
    private static func requireOneVerb(_ inv: CLIKit.Invocation, among verbs: [String],
                                       domain: String) -> String {
        let present = inv.names.filter { verbs.contains($0) }
        if present.count == 1 { return present[0] }
        if present.isEmpty {
            CLIKit.die("wand", "`wand \(domain)` needs a verb: "
                + verbs.joined(separator: " ") + ". See `wand --help`.")
        }
        CLIKit.die("wand", "`wand \(domain)`: incompatible verbs "
            + present.joined(separator: " ") + " — pick one. See `wand --help`.")
    }

    @MainActor
    private static func dispatchDaemon(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--reload": .flag, "--quit": .flag, "--show": .flag, "--resign": .flag,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--reload", "--quit", "--show", "--resign"],
                              domain: "daemon") {
        case "--reload": runClient(cmd: "reload")
        case "--quit":   runClient(cmd: "quit")
        case "--show":   runShow()
        case "--resign": runResign()
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }

    @MainActor
    private static func dispatchCast(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--test": .requiredThenOptional(1), "--record": .flag,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--test", "--record"], domain: "cast") {
        case "--test":
            let vs = inv.values("--test")               // PATTERN [APP]
            runTest(pattern: vs.first ?? "", bundleID: vs.count > 1 ? vs[1] : nil)
        case "--record": runRecord()
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }

    @MainActor
    private static func dispatchTome(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--open": .flag, "--validate": .flag,
            "--items": .value, "--at": .values(2), "--selection": .value, "--title": .value,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--open", "--validate"], domain: "tome") {
        case "--open":
            runTomeOpen(inv)
        case "--validate":
            guard let path = inv.value("--items") else {
                CLIKit.die("wand", "`wand tome --validate` needs --items <PATH>. "
                    + "See `wand --help`.")
            }
            runValidateItems(path: path)
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }

    @MainActor
    private static func dispatchConfig(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--validate": .flag, "--doctor": .flag, "--emit-schema": .flag,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--validate", "--doctor", "--emit-schema"],
                              domain: "config") {
        case "--validate": runValidateConfig()
        case "--doctor":   runDoctor()
        case "--emit-schema":
            // Generated from the same declarative `configSpec` that decodes
            // the config, so editor schema and parser can't drift.
            print(WandConfig.jsonSchema, terminator: "")
            exit(0)
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }


    /// Exit fatally when `[failsafe]` is missing — same policy for
    /// both `--validate` and `runServer()` so they don't drift.
    /// See CLAUDE.md "Safety invariants" for the WHY of the
    /// mandatory-block rule.
    private static func requireFailsafeBlock(_ cfg: WandConfig) {
        guard !cfg.failsafeBlockPresent else { return }
        let msg = "wand: FATAL: config.toml is missing the required "
            + "[failsafe] block. wand refuses to start without it "
            + "(low-level mouse interception needs the safety net "
            + "configured explicitly). Copy the [failsafe] block "
            + "from the bundled template:\n"
            + "  https://raw.githubusercontent.com/akira-toriyama/"
            + "wand/main/config.toml\n"
        FileHandle.standardError.write(Data(msg.utf8))
        Log.line("startup: [failsafe] block missing — refusing to start")
        exit(2)
    }

    @MainActor
    private static func runServer() -> Never {
        // Refresh the taplo schema sidecar next to the user config so
        // editor completion / validation just works (idempotent; writes
        // only on change). The ConfigWatcher tracks config.toml itself —
        // not the directory — so this sibling write never triggers a
        // reload. Best-effort: a failure is non-fatal (never blocks
        // start), so the daemon is unaffected if ~/.config/wand isn't
        // writable.
        WandConfig.installSchema()

        let cfg = WandConfig.load()
        requireFailsafeBlock(cfg)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)            // LSUIElement: no Dock icon
        AXTarget.ensureTrusted()

        let source = MacOSMouseSource(
            trigger: cfg.trigger,
            minStrokePx: cfg.recognition.minStrokePx,
            maxSegmentMs: cfg.recognition.maxSegmentMs,
            cancelReversals: cfg.recognition.cancelReversals,
            cancelWindowMs: cfg.recognition.cancelWindowMs
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

        // Fire-moment effect managers — owned by Main for the
        // daemon's lifetime. Declared up here (instead of after the
        // overlay block) so the overlay's `onCherryEaten` hook can
        // close over `arcadeScoreManager` directly.
        let decalManager = DecalManager()
        let burstManager = BurstManager()
        let arcadeScoreManager = ArcadeScoreManager()

        // Gesture-trail overlay (passive observer of the sample
        // stream). Held for the process lifetime via `app.run()`.
        // Declared `outside` the `if` so the live-reload hook below
        // can hot-apply `[overlay]` changes without a restart.
        var overlay: GestureOverlay?
        if cfg.overlay.enabled {
            overlay = GestureOverlay(cfg)
            overlay?.show()
            // Chomp cherry pickup — `+N` arcade-score popup floats
            // up from the cherry's screen position when the face
            // catches it. Always uses the `.arcadeScore` kind here
            // (independent of `[cast.fire.burst].kind` which only
            // governs the rule-fire moment); cherries are a chomp-
            // theme flourish and the popup is part of that vibe.
            overlay?.onCherryEaten = { [weak controller] cocoaPt in
                MainActor.assumeIsolated {
                    guard let cfg = controller?.config else { return }
                    // Trail colour resolved per-fire so the popup
                    // matches the live theme even if the user has
                    // overridden `[cast.overlay.trail].color`.
                    let color = TrailColorMode.parse(
                        cfg.overlay.trail.color, fallback: .systemYellow
                    ).currentColor(
                        at: CACurrentMediaTime(),
                        strokeSeed: UInt64.random(in: 0..<UInt64.max),
                        cyclePeriod: TimeInterval(
                            cfg.overlay.colorCycleMs) / 1000.0)
                    arcadeScoreManager.emit(
                        at: cocoaPt, color: color,
                        kind: .arcadeScore)
                }
            }
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
                    // `valid` = the current shape is still a prefix
                    // of at least one reachable rule — i.e. NOT off
                    // every rule yet. We deliberately don't gate on
                    // exact-match-fires-now: drawing just `D` when
                    // rules `DL` / `DLU` exist is still on-track and
                    // should keep the trail in the match colour
                    // (and skip the chomp ghost + GAME OVER cues
                    // until a non-prefix direction lands). The exact-
                    // match-fires signal is still available — any
                    // `hint.rows.fires = true` carries it.
                    let cands = Matcher.candidates(
                        prefix: s.pattern, bundleID: s.bundleID,
                        rules: live.rules,
                        isFocusedFallback: s.isFocusedFallback)
                    valid = !cands.isEmpty
                    hint = assistHint(pattern: s.pattern,
                                      candidates: cands)
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
            Log.line("overlay: enabled (match=\(cfg.overlay.trail.color), "
                     + "noMatch=\(cfg.overlay.trail.colorNoMatch), "
                     + "width=\(cfg.overlay.trail.width))")
        }

        // Push `[overlay]` changes to the live overlay so edits take
        // effect without a restart. `applyConfig` covers every
        // overlay knob; `[trigger]` and the `[recognition]` timing
        // knobs still need a restart (Controller.reload logs them).
        // The favicon prewarm rides on the same callback so the
        // moment a user adds `icon = "favicon:..."` to their config
        // and saves, the host(s) start downloading in the background
        // — no need to wait for the next panel open to populate the
        // cache. The outer `if let overlay` is gone so prewarm fires
        // even on configs that disable the overlay; `overlay?` makes
        // the applyConfig call a no-op when the overlay is nil.
        controller.onConfigChanged = { [weak overlay] new in
            MainActor.assumeIsolated {
                overlay?.applyConfig(new)
                FaviconCache.prewarm(from: new)
                IconSetCache.prewarm(from: new)
            }
        }
        // Boot-time prewarm: kick off background fetches for every
        // remote icon referenced in the current config (favicons
        // and external icon-set entries — lucide / phosphor /
        // tabler / heroicons) before the first panel open. The
        // cache hits are populated by the time the user
        // middle-clicks, so the placeholder flash collapses to
        // "happens only on stale cache / network failure".
        FaviconCache.prewarm(from: controller.config)
        IconSetCache.prewarm(from: controller.config)

        // Post-fire fire-moment effects — decal (Splatoon-style
        // splatter/blob/scorch/star) AND trail-end burst (particle
        // explosion). Both live in their own click-through windows,
        // INDEPENDENT of `[cast.overlay].enabled`, so the user can
        // disable the trail HUD and still get the cursor-anchored
        // fire effects. The managers themselves are declared
        // earlier (so the overlay's cherry hook can close over the
        // arcade-score manager); here we just wire the rule-fire
        // dispatch into them.
        controller.onGestureFire = { [weak controller] cgPoint in
            MainActor.assumeIsolated {
                guard let cfg = controller?.config else { return }
                let cocoaPoint = ScreenCoords.cocoaPoint(fromCG: cgPoint)
                // Resolve the trail colour via TrailColorMode so the
                // decal "trail" fallback honours the dynamic modes
                // (`rainbow` / `neon` / `splatoon`) rather than
                // collapsing to `.systemBlue` when the user picks one.
                let color = TrailColorMode.parse(
                    cfg.overlay.trail.color, fallback: .systemBlue
                ).currentColor(at: CACurrentMediaTime(),
                               strokeSeed: UInt64.random(in: 0..<UInt64.max),
                               cyclePeriod: TimeInterval(
                                cfg.overlay.colorCycleMs) / 1000.0)
                let decalSpec = cfg.fire.decal
                if decalSpec.kind != .off, decalSpec.durationMs > 0 {
                    // Decal is always the Splatoon multi-team palette
                    // (#115 dropped the `color` knob). The full
                    // palette flows through so each splat unit can
                    // pick its own team colour — the Splatoon
                    // "multi-shot" feel where one decal lands a
                    // mix of team inks at the cursor.
                    decalManager.emit(
                        at: cocoaPoint,
                        color: NSColorParse.randomSplatoonInk(),
                        palette: NSColorParse.splatoonInks,
                        kind: decalSpec.kind,
                        durationSec: TimeInterval(decalSpec.durationMs)
                            / 1000.0,
                        size: CGFloat(decalSpec.size))
                }
                if cfg.fire.burst.kind != .off {
                    // Resolve burst colour with the same three-mode
                    // grammar as decal: `""` / `"trail"` inherits the
                    // trail accent, `"splatoon"` picks a random ink,
                    // anything else parses as static colour.
                    let burstSpec = cfg.fire.burst
                    let burstColor: NSColor
                    switch burstSpec.color.trimmingCharacters(
                        in: .whitespaces).lowercased() {
                    case "", "trail":
                        burstColor = color
                    case "splatoon":
                        burstColor = NSColorParse.randomSplatoonInk()
                    default:
                        burstColor = NSColorParse.nsColor(
                            burstSpec.color) ?? color
                    }
                    // Dispatch by kind — only one of the managers
                    // gates on the kind it handles (others no-op),
                    // so the same call shape works regardless of
                    // which arcade-flavour the user picked.
                    burstManager.emit(
                        at: cocoaPoint, color: burstColor,
                        kind: burstSpec.kind,
                        intensity: CGFloat(cfg.intensity.multiplier))
                    arcadeScoreManager.emit(
                        at: cocoaPoint, color: burstColor,
                        kind: burstSpec.kind)
                }
            }
        }
        _ = decalManager   // hold a reference for the process lifetime
        _ = burstManager   // ditto — fire-moment effects need both alive
        _ = arcadeScoreManager   // arcade-score popup manager

        controller.start()

        // Live-reload on config edits (no `--reload` needed). Held for
        // the process lifetime via `app.run()`.
        let watcher = ConfigWatcher(path: WandConfig.path) {
            Log.line("config: file changed — reloading")
            controller.reload(cause: "file-change")
        }
        watcher.start()

        let failsafe = FailsafeMonitor(config: cfg.failsafe)
        failsafe.start()

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

        // Tome diagnostics — only meaningful when opted in.
        if cfg.launcher.enabled {
            let lTap = MacOSLauncherSource.canInstallTap(
                trigger: cfg.launcher.trigger)
            ok = ok && lTap
            print(line(lTap, "Tome tap:",
                       lTap
                         ? "can install (button="
                           + "\(cfg.launcher.trigger.button.rawValue), "
                           + "\(cfg.launcher.items.count) item(s))"
                         : "cannot install"))
        } else {
            print(line(true, "Tome:",
                       "disabled (`[tome].enabled = false`)"))
        }

        // Tuned values — the same ones the daemon would apply. Lets a
        // remote diagnosis confirm what's in effect without parsing
        // config.toml independently.
        let rec = cfg.recognition
        print(line(true, "Tuning:",
                   "min-stroke-px=\(rec.minStrokePx) "
                   + "max-segment-ms=\(rec.maxSegmentMs) "
                   + "cancel-reversals=\(rec.cancelReversals) "
                   + "cancel-window-ms=\(rec.cancelWindowMs)"))

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
                icon: r.icon,
                fires: r.pattern == pattern)
        }
        return GestureHint(shape: arrows(pattern), rows: Array(rows))
    }


    /// `wand daemon --show` — print the running daemon's status (rule
    /// count, trigger, last gesture …) from the status file it maintains.
    /// Exit 3 if no daemon is running.
    private static func runShow() -> Never {
        guard isServerRunning() else {
            FileHandle.standardError.write(Data((
                "wand: `daemon --show` needs a running daemon (it reads the "
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

    /// `wand config --validate` — parse config.toml, mirror every parser
    /// warning (clamp / migration / collision / typo) to stderr so the
    /// user actually sees them (otherwise a happy rule count could hide a
    /// half-dropped config). Warnings still also go to /tmp/wand.log.
    private static func runValidateConfig() -> Never {
        Log.resetLineCount()
        mirrorLineToStderr = true
        let cfg = WandConfig.load()
        let cfgWarnings = Log.lineCount
        requireFailsafeBlock(cfg)
        let tomeLine = cfg.launcher.enabled
            ? ", tome=\(cfg.launcher.trigger.button.rawValue) "
              + "(\(cfg.launcher.items.count) item(s))"
            : ""
        FileHandle.standardError.write(Data((
            "wand: loaded \(cfg.rules.count) rule(s), "
            + "trigger=\(cfg.trigger.button.rawValue), "
            + "minStrokePx=\(cfg.recognition.minStrokePx)\(tomeLine)"
            + " — \(cfgWarnings) warning(s)\n"
        ).utf8))
        exit(0)
    }

    /// `wand tome --validate --items PATH` — validate a standalone items
    /// file (the same shape `tome --open --items` consumes). Parse +
    /// report count; exit 2 on read failure.
    private static func runValidateItems(path: String) -> Never {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data((
                "wand: tome --validate: could not read \(path)\n"
            ).utf8))
            exit(2)
        }
        Log.resetLineCount()
        mirrorLineToStderr = true
        let parsed = WandConfig.parseItems(text)
        let itemsWarnings = Log.lineCount
        FileHandle.standardError.write(Data((
            "wand: items file \(path) — "
            + "\(parsed.items.count) item(s), "
            + "layout=\(parsed.layout.rawValue)"
            + " — \(itemsWarnings) warning(s)\n"
        ).utf8))
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

    /// `wand tome --open --items <PATH> --at <X> <Y> [--selection <TEXT>]
    /// [--title <TEXT>]` — external trigger entry to the launcher menu.
    /// Values are already tokenized by CLIKit (so `--at` accepts negative
    /// Cocoa coords). Validates locally (exit 2 on bad input), checks
    /// daemon liveness (exit 3), then posts a DNC notification with the
    /// parameters and exits 0. The daemon does the rest async — resolves
    /// the frontmost app as the target, builds the menu, pops it up.
    private static func runTomeOpen(_ inv: CLIKit.Invocation) -> Never {
        guard let itemsPath = inv.value("--items") else {
            FileHandle.standardError.write(Data((
                "wand: tome --open: --items <PATH> is required\n"
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
                "wand: tome --open: could not read items file "
                + "\(absPath)\n"
            ).utf8))
            exit(2)
        }
        // Local validation so a malformed file is rejected at the
        // client (exit 2) instead of silently dropping at the daemon.
        let parsed = WandConfig.parseItems(text)
        guard !parsed.items.isEmpty else {
            FileHandle.standardError.write(Data((
                "wand: tome --open: items file \(absPath) yielded "
                + "0 items (no `[[item]]` rows, or all dropped — see "
                + "/tmp/wand.log for per-row diagnostics)\n"
            ).utf8))
            exit(2)
        }
        // --at X Y — two numeric values (CLIKit consumed them, signs OK).
        let at = inv.values("--at")
        guard at.count == 2, let x = Double(at[0]), let y = Double(at[1]) else {
            FileHandle.standardError.write(Data((
                "wand: tome --open: --at <X> <Y> is required "
                + "(Cocoa screen coords, Y-up)\n"
            ).utf8))
            exit(2)
        }
        let selection = inv.value("--selection") ?? ""
        // --title: caller-supplied window title to override the daemon's
        // AX fetch. Used by an upstream trigger that already knows the
        // source window at fire time and wants it surfaced verbatim —
        // avoids racing the daemon's AX lookup against window-switch latency.
        let title = inv.value("--title") ?? ""

        guard isServerRunning() else {
            FileHandle.standardError.write(Data((
                "wand: tome --open: no daemon running — start it "
                + "with `wand` (or `WAND_DEBUG=1 wand`) first\n"
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
                + "`wand` (or `WAND_DEBUG=1 wand`) first\n"
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
                "wand: daemon is running — `wand daemon --quit` first, "
                + "then `wand cast --record`\n"
            ).utf8))
            exit(3)
        }

        let cfg = WandConfig.load()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AXTarget.ensureTrusted()

        let source = MacOSMouseSource(
            trigger: cfg.trigger,
            minStrokePx: cfg.recognition.minStrokePx,
            isRecording: true
        )
        source.start { event in
            let dirs = Recognition.recognize(samples: event.samples,
                                              minStrokePx: cfg.recognition.minStrokePx)
            let (dx, dy) = event.samples.span
            guard !dirs.isEmpty else {
                FileHandle.standardOutput.write(Data((
                    "(too short)  samples=\(event.samples.count)  "
                    + "max|dx|=\(Int(dx)) max|dy|=\(Int(dy))  "
                    + "threshold=\(cfg.recognition.minStrokePx)  "
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

            [[cast.cursor.rule]]
            name = "\(pattern)"
            pattern = "\(pattern)"
            apps = ["\(event.target.bundleID)"]
            action-type = "key"        # key | ax | shell | url
            action-keys = "cmd+w"      # ← edit me

            """
            FileHandle.standardOutput.write(Data(snippet.utf8))
        }

        FileHandle.standardError.write(Data((
            "wand --record: draw gestures with the configured "
            + "trigger button (\(cfg.trigger.button.rawValue) mouse, "
            + "minStrokePx=\(cfg.recognition.minStrokePx)). Ctrl-C to exit.\n"
        ).utf8))
        app.run()
        exit(0)
    }
}
