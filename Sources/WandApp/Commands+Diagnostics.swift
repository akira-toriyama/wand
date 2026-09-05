// Read-only one-shots: `config --doctor`, `daemon --show`,
// `config --validate`, `tome --validate`. None of them touch the
// event tap or post to the daemon.

import AppKit
import Foundation
import CLIKit
import ConfigSchema
import WandCore
import WandAdapterMacOS

extension WandApp {

    /// Health report: Accessibility, config, daemon, event tap. Exit 0
    /// if everything's green, 1 if any check fails.
    static func runDoctor() -> Never {
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
        if cfg.tome.enabled {
            let lTap = MacOSTomeSource.canInstallTap(
                trigger: cfg.tome.trigger)
            ok = ok && lTap
            print(line(lTap, "Tome tap:",
                       lTap
                         ? "can install (button="
                           + "\(cfg.tome.trigger.button.rawValue), "
                           + "\(cfg.tome.items.count) item(s))"
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

    /// `wand daemon --show` — print the running daemon's status (rule
    /// count, trigger, last gesture …) from the status file it maintains.
    /// Exit 3 if no daemon is running.
    static func runShow() -> Never {
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
    static func runValidateConfig() -> Never {
        // Structural validation first (sill 1.29.0 `Spec.validate` bridge,
        // t-0029): the strict counterpart to the lenient `load()` below, which
        // clamps out-of-range values and drops typo'd keys. Surfaces the
        // type / enum / range / unknown-key mismatches the loader silently
        // accepts. Exit 2 if config.toml isn't parseable TOML at all; 1 if it
        // parses but violates the schema; otherwise fall through to the
        // bespoke parsed summary (clamp warnings + the failsafe-block check).
        let source = (try? String(contentsOfFile: WandConfig.path,
                                  encoding: .utf8)) ?? ""
        let schemaErrors: [ValidationError]
        do {
            schemaErrors = try WandConfig.validate(source)
        } catch {
            FileHandle.standardError.write(Data(
                "wand: config.toml: not parseable — \(error)\n".utf8))
            exit(2)
        }
        if !schemaErrors.isEmpty {
            for e in schemaErrors {
                FileHandle.standardError.write(Data("wand: \(e.message)\n".utf8))
            }
            FileHandle.standardError.write(Data(
                "wand: \(schemaErrors.count) validation error(s)\n".utf8))
            exit(1)
        }

        Log.resetLineCount()
        mirrorLineToStderr = true
        let cfg = WandConfig.load()
        let cfgWarnings = Log.lineCount
        requireFailsafeBlock(cfg)
        let tomeLine = cfg.tome.enabled
            ? ", tome=\(cfg.tome.trigger.button.rawValue) "
              + "(\(cfg.tome.items.count) item(s))"
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
    static func runValidateItems(path: String) -> Never {
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
}
