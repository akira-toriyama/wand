// stroke configuration. Single source of truth lives at
// ~/.config/stroke/config.toml — never written, never auto-generated,
// never persisted from the CLI (same policy as facet). To make a
// change stick, the user edits the file and restarts (or
// `stroke --reload`).
//
// Unknown / out-of-range values clamp to defaults — a typo can
// never break the daemon.

import Foundation

public struct StrokeConfig: Sendable {
    public var trigger: Trigger
    public var minStrokePx: Int
    public var sampleHz: Int
    public var excludeApps: [String]
    public var rules: [Rule]

    public static let `default` = StrokeConfig(
        trigger: Trigger(button: .right, modifiers: []),
        minStrokePx: 16,
        sampleHz: 120,
        excludeApps: [],
        rules: []
    )

    /// Read ~/.config/stroke/config.toml. Missing file → defaults,
    /// no error (same agent-friendly behaviour as facet).
    public static func load() -> StrokeConfig {
        let path = NSString(string: "~/.config/stroke/config.toml")
            .expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            Log.line("config: no file at \(path) — using built-in defaults")
            return .default
        }
        return parse(text)
    }

    static func parse(_ text: String) -> StrokeConfig {
        let doc = parseTOMLSubset(text)

        // [trigger]
        let trig = doc.tables["trigger"] ?? [:]
        let button: Trigger.Button = {
            if case .string(let s) = trig["button"] ?? .string(""),
               let b = Trigger.Button(rawValue: s.lowercased()) {
                return b
            }
            return .right
        }()
        let mods: Set<Modifier> = {
            guard case .stringArray(let arr) = trig["modifiers"]
                ?? .stringArray([]) else { return [] }
            return Set(arr.compactMap { Modifier(rawValue: $0.lowercased()) })
        }()

        // [recognition]
        let reco = doc.tables["recognition"] ?? [:]
        let minPx: Int = {
            if case .int(let i) = reco["min-stroke-px"] ?? .int(16) {
                return max(4, min(200, i))
            }
            return 16
        }()
        let hz: Int = {
            if case .int(let i) = reco["sample-hz"] ?? .int(120) {
                return max(30, min(240, i))
            }
            return 120
        }()
        let excludes: [String] = {
            if case .stringArray(let arr) = reco["exclude-apps"]
                ?? .stringArray([]) { return arr }
            return []
        }()

        // [[rules]]
        let rules: [Rule] = (doc.arrays["rules"] ?? []).compactMap { row in
            guard case .string(let pattern) = row["pattern"] ?? .string(""),
                  !pattern.isEmpty
            else { return nil }
            let name: String = {
                if case .string(let s) = row["name"] ?? .string("") { return s }
                return pattern
            }()
            let apps: [String] = {
                if case .stringArray(let arr) = row["apps"]
                    ?? .stringArray([]) { return arr }
                return ["*"]
            }()
            guard let action = parseAction(row) else { return nil }
            return Rule(name: name, pattern: pattern, apps: apps, action: action)
        }

        return StrokeConfig(
            trigger: Trigger(button: button, modifiers: mods),
            minStrokePx: minPx,
            sampleHz: hz,
            excludeApps: excludes,
            rules: rules
        )
    }

    /// Per-row action shape, decomposed across dotted-style keys so
    /// the minimal TOML parser can read it without inline-table
    /// support:
    ///
    ///     action-type = "key"           # key | ax | shell
    ///     action-keys = "cmd+w"         # for type=key
    ///     action-verb = "close"         # for type=ax
    ///     action-cmd  = "open ..."      # for type=shell
    private static func parseAction(_ row: [String: TOMLValue]) -> Action? {
        guard case .string(let type) = row["action-type"] ?? .string("")
        else { return nil }
        switch type.lowercased() {
        case "key":
            if case .string(let k) = row["action-keys"] ?? .string(""),
               !k.isEmpty { return .key(k) }
        case "ax":
            if case .string(let v) = row["action-verb"] ?? .string(""),
               !v.isEmpty { return .ax(v) }
        case "shell":
            if case .string(let c) = row["action-cmd"] ?? .string(""),
               !c.isEmpty { return .shell(c) }
        default: break
        }
        return nil
    }
}
