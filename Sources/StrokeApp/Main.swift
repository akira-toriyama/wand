// stroke entry point. Three modes (server / client / standalone),
// chosen by CLI flag — mirrors facet's split:
//
//   1. **Server mode** (no recognised flag): wake the AppKit run
//      loop, install the CGEventTap, install the IPC observer, wait
//      for strokes until killed.
//
//   2. **Client mode** (`--reload` / `--quit`): post a Distributed
//      Notification to the running server, exit. Refuses if no
//      server is running (exit 3) so silent broadcasts to nobody
//      don't leave the user wondering why nothing happened.
//
//   3. **Standalone mode** (`--validate` / `--record` / `--help`):
//      self-contained; no IPC, no running server expected.
//      `--record` does install its own event tap and refuses if a
//      server is already running (would conflict on the tap).
//
// `@main enum StrokeApp` (NOT top-level code in main.swift) so
// XCTest can `@testable import StrokeApp` later without launching
// the daemon. Same trap as facet — don't reintroduce main.swift.

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
                                       without restarting (rules + excludes
                                       only; trigger/minStrokePx need a
                                       full restart)
          stroke --quit                terminate the running daemon

        STANDALONE COMMANDS
          stroke --validate            parse config.toml; exit 0 if valid
          stroke --record              interactive recorder: draw a
                                       gesture, see the direction
                                       sequence printed to stdout.
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

        // Standalone modes —  no running daemon required.
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
        if argv.contains("--reload") { runClient(cmd: "reload") }
        if argv.contains("--quit")   { runClient(cmd: "quit") }

        // Reject unknown flags loudly (facet policy: silent fallback
        // is a misfeature).
        let recognised: Set<String> = [
            "--help", "--debug", "--validate", "--record",
            "--reload", "--quit",
        ]
        for a in argv where !recognised.contains(a) {
            let msg = "stroke: unknown flag \"\(a)\" — see "
                + "`stroke --help`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }

        // ----- Server mode -----
        runServer()
    }

    // MARK: - Server mode

    @MainActor
    private static func runServer() -> Never {
        let cfg = StrokeConfig.load()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)            // LSUIElement: no Dock icon
        AXTarget.ensureTrusted()

        let source = MacOSMouseSource(
            trigger: cfg.trigger,
            minStrokePx: cfg.minStrokePx
        )
        let controller = Controller(source: source, config: cfg)
        controller.start()

        app.run()
        exit(0)
    }

    // MARK: - Client mode (IPC)

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

    // MARK: - Record mode

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
            let pattern = dirs.isEmpty ? "(too short)" : dirs.patternString
            let (dx, dy) = event.samples.span
            let line = "pattern=\(pattern)  samples=\(event.samples.count)"
                + "  max|dx|=\(Int(dx)) max|dy|=\(Int(dy))"
                + "  target=\(event.target.bundleID)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
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
