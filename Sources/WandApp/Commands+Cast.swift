// `cast --test` / `cast --record`, plus the assist-hint formatting
// the daemon's overlay shares with them.

import AppKit
import Foundation
import CLIKit
import ConfigSchema
import WandCore
import WandAdapterMacOS

extension WandApp {

    /// `cast --test PATTERN [bundle-id]`: resolve which rule a pattern would
    /// fire. With a bundle id, report the single firing rule (honouring
    /// app filters + excludes); without one, list every rule that uses
    /// the pattern. Reads config; touches no event tap.
    static func runTest(pattern: String, bundleID: String?) -> Never {
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
    static func arrows(_ pattern: String) -> String {
        pattern.compactMap { Direction(rawValue: $0)?.arrow }.joined()
    }

    /// Build the overlay hint: the shape so far, plus a row per rule
    /// reachable from here. Each row shows only the *remaining* arrows
    /// (the already-drawn prefix is stripped), and `fires` marks the
    /// rule the current shape triggers now. Capped so a permissive
    /// prefix can't grow a wall.
    static func assistHint(pattern: String, candidates: [Rule]) -> CastHint {
        let rows = candidates.prefix(6).map { r in
            CastHint.Row(
                suffix: arrows(String(r.pattern.dropFirst(pattern.count))),
                name: r.name,
                icon: r.icon,
                fires: r.pattern == pattern)
        }
        return CastHint(shape: arrows(pattern), rows: Array(rows))
    }

    /// Interactive recorder. Installs an event tap in "recording"
    /// mode (no actions fire, every stroke including too-short ones
    /// is delivered to the print handler), refuses if the daemon
    /// is already running (would fight over the tap). Ctrl-C to
    /// exit.
    @MainActor
    static func runRecord() -> Never {
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
