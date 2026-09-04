// Client side of the DNC channel: `tome --open`, `daemon --reload` /
// `--quit` (`runClient`), and the liveness probe every client verb
// and `cast --record` consult.

import AppKit
import Foundation
import CLIKit
import ConfigSchema
import WandCore
import WandAdapterMacOS

extension WandApp {

    /// `wand tome --open --items <PATH> --at <X> <Y> [--selection <TEXT>]
    /// [--title <TEXT>]` — external trigger entry to the launcher menu.
    /// Values are already tokenized by CLIKit (so `--at` accepts negative
    /// Cocoa coords). Validates locally (exit 2 on bad input), checks
    /// daemon liveness (exit 3), then posts a DNC notification with the
    /// parameters and exits 0. The daemon does the rest async — resolves
    /// the frontmost app as the target, builds the menu, pops it up.
    static func runTomeOpen(_ inv: CLIKit.Invocation) -> Never {
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
    static func runClient(cmd: String) -> Never {
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
    static func isServerRunning() -> Bool {
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
}
