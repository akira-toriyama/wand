// wand is config.toml-driven, read-only from the daemon's
// perspective: the file is the source of truth, the CLI never writes
// it. Unknown / out-of-range values clamp to defaults — a typo can
// never break recognition.

import ConfigSchema
import Foundation
import Palette
import Toml

// wand's four-case TOML model + flat document folded into sill's shared
// `Toml` module in atelier Phase 1.6. `Toml.Document` has the exact
// `{tables, arrays}` shape wand's old `TOMLDocument` had, and `Toml.Value`
// is a superset of the old `TOMLValue` (adds .double/.array/.table/AoT),
// so these aliases keep every signature and `if case .string(...)` read
// site unchanged. Values are read through the accessor extension below.
typealias TOMLValue = Toml.Value
typealias TOMLDocument = Toml.Document

public struct WandConfig: Sendable {
    /// `[cast]` — the gesture trigger (button + modifiers). Other
    /// gesture-family knobs live in dedicated sub-blocks
    /// (`recognition` / `overlay` / `fire`).
    public var trigger: Trigger
    /// `[cast].intensity` — gesture-wide effect multiplier. Scope
    /// spans `[cast.overlay.cards]` (HUD card particle effects)
    /// AND `[cast.fire.burst]` (cursor-anchored explosion). Decal
    /// has its own size / duration knobs and is not scaled. Kept
    /// inline at the gesture level (next to button / modifiers)
    /// because moving it into either sub-block would mislead about
    /// the scope.
    public var intensity: EffectIntensity
    /// `[cast].theme` — the canonical theme name (sill's catalog +
    /// wand's `neon` / `splatoon` engine themes). The cast HUD palette
    /// is derived from it via `wandCastPalette`; individual colour keys
    /// still win when explicitly set in the TOML (non-empty string).
    public var theme: String
    /// `[cast.chomp]` — only populated when `theme == "chomp"` (the
    /// chomp "special theme"). `nil` under every other theme. The
    /// adapter reads this single field to decide whether to route the
    /// trail through `ChompRenderer` and what scale to use; the rest of
    /// the codebase doesn't need to know `chomp` is a special case.
    public var chomp: ChompSpec?
    /// `[cast.recognition]` — sample → direction tuning.
    public var recognition: CastRecognitionSpec
    /// `[exclude].apps` — global bundle-id exclusion list. Applies
    /// to both gesture rules and tome items.
    public var excludeApps: [String]
    /// `[[cast.cursor.rule]]` + `[[cast.focused.rule]]` — gesture
    /// pattern → action mappings, tagged with their activation
    /// context (`RuleContext.cursor` / `.focused`).
    public var rules: [Rule]
    /// `[cast.overlay]` and sub-blocks — trail + badge + cards.
    public var overlay: CastOverlaySpec
    /// `[cast.fire]` and sub-blocks — burst + decal.
    public var fire: CastFireSpec
    /// `[tome]` and sub-blocks — trigger + items + row /
    /// animation / decoration cosmetics.
    public var tome: TomeSpec
    /// `[failsafe]` — mandatory safety-net block. See CLAUDE.md
    /// "Safety invariants" for the WHY of the missing-block policy.
    public var failsafe: FailsafeConfig
    /// `false` when the `[failsafe]` block was absent in the parsed
    /// TOML. The App layer refuses to start in that case.
    public var failsafeBlockPresent: Bool

    public static let `default` = WandConfig(
        trigger: Trigger(button: .right, modifiers: []),
        intensity: .normal,
        theme: wandDefaultThemeName,
        chomp: nil,
        recognition: .default,
        excludeApps: [],
        rules: [],
        overlay: .default,
        fire: .default,
        tome: .default,
        failsafe: .default,
        failsafeBlockPresent: true
    )

    /// The single source-of-truth path. Shared by `load()` and the
    /// app's file watcher so both point at the same file.
    public static let path = NSString(string: "~/.config/wand/config.toml")
        .expandingTildeInPath

    /// Read ~/.config/wand/config.toml. Missing file → defaults,
    /// no error (same agent-friendly behaviour as facet).
    public static func load() -> WandConfig {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            Log.line("config: no file at \(path) — using built-in defaults")
            return .default
        }
        return parse(text)
    }

    /// Structural validation against the SAME `configSpec` that drives decode
    /// + `--emit-schema` (sill 1.29.0's `Spec.validate` bridge, t-0029). The
    /// STRICT counterpart to the lenient `load()` / `parse()` (which clamp
    /// out-of-range values and drop typo'd keys): it surfaces the type / enum /
    /// range / unknown-key mismatches the loader silently accepts — the
    /// "editor-green-but-load-accepts" gap. Returns every violation (empty =
    /// structurally valid). Throws only if `text` is not parseable TOML at all
    /// (a genuine syntax error, distinct from a schema violation). One source
    /// for decode + emit + validate ⇒ they can't drift.
    public static func validate(_ text: String) throws -> [ValidationError] {
        let root = try Toml.parse(text)
        return configSpec.validate(root)
    }

    /// A1 (load-path validate): run the strict `validate` on the daemon's
    /// load path and surface each violation as a WARNING via `Log.line` — it
    /// does NOT reject. The lenient `load()`/`parse()` already clamped
    /// out-of-range values and dropped typo'd keys; this only makes those
    /// mismatches visible in the log (matching facet/perch). A non-parseable
    /// source yields zero warnings (the lenient loader still continues).
    /// Returns the violation count (0 = clean).
    @discardableResult
    public static func warnSchemaViolations(_ text: String) -> Int {
        let errors = (try? validate(text)) ?? []
        for e in errors {
            Log.line("config: \(e.message)")
        }
        return errors.count
    }

    public static func parse(_ text: String) -> WandConfig {
        let doc = Toml.parseFlat(text)

        // Uniform half: the plain scalar/table keys are driven by the
        // single declarative `configSpec` (which ALSO emits the JSON
        // Schema — see `Config+Spec.swift`). `decode` runs the SAME
        // clamp / enum-parse / theme-resolve the hand-written reads did,
        // writing into a scratch `Decoded` seeded with the parse
        // defaults — so the resolved values below are byte-identical to
        // the old inline reads (proven by `wandparityharness`). The
        // NON-uniform bits (palette inheritance on the `""` colour
        // sentinel, the chomp theme-conditional masking, `[failsafe]`
        // block-present + empty→esc, the arrays-of-tables, the trigger
        // collision) stay bespoke below; the spec still DESCRIBES them.
        var d = Decoded()
        configSpec.decode(doc.tables, into: &d)

        // [exclude]
        let excludes = d.excludeApps

        let cast = parseCast(doc, d)
        let tome = parseTome(doc, d, castTrigger: cast.trigger)
        let rules = parseRules(doc)
        let (failsafe, failsafeBlockPresent) = parseFailsafe(doc)

        return WandConfig(
            trigger: cast.trigger,
            intensity: cast.intensity,
            theme: cast.theme,
            chomp: cast.chomp,
            recognition: cast.recognition,
            excludeApps: excludes,
            rules: rules,
            overlay: cast.overlay,
            fire: cast.fire,
            tome: tome,
            failsafe: failsafe,
            failsafeBlockPresent: failsafeBlockPresent
        )
    }

    // Per-row action shape, decomposed across dotted-style keys:
    //
    //     action-type = "key"           # key | ax | shell | url
    //     action-keys = "cmd+w"         # for type=key
    //     action-verb = "close"         # for type=ax
    //     action-cmd  = "open ..."      # for type=shell
    //     action-url  = "https://..."   # for type=url
    //
    // Convention, not a parser limit: swift-toml-edit is full TOML
    // 1.0, so inline tables would parse — the flat form predates it
    // and every row / doc / bundled config.toml is written this way.

    static func parseAction(_ row: [String: TOMLValue]) -> Action? {
        guard case .string(let type) = row["action-type"] ?? .string("")
        else { return nil }
        switch type.lowercased() {
        case "key":
            if case .string(let k) = row["action-keys"] ?? .string(""),
               !k.isEmpty { return .key(k) }
        case "ax":
            if case .string(let v) = row["action-verb"] ?? .string("") {
                let verb = v.lowercased()
                if Action.axVerbs.contains(verb) { return .ax(verb) }
            }
        case "shell":
            if case .string(let c) = row["action-cmd"] ?? .string(""),
               !c.isEmpty { return .shell(c) }
        case "url":
            if case .string(let u) = row["action-url"] ?? .string(""),
               !u.isEmpty { return .url(u) }
        default: break
        }
        return nil
    }

    /// Parse a string-keyed enum from a TOML table. Empty / missing
    /// → silent default; unknown name → loud log + default with the
    /// full vocabulary listed (so a typo is fixable from the log
    /// alone). `CaseIterable` powers the valid-set; `RawRepresentable
    /// where RawValue == String` powers the lookup. The uniform
    /// `[block]` enums run through `configSpec` now; this stays for the
    /// bespoke `[cast.chomp].size` (read conditionally on the theme) and
    /// the `[tome].layout` of a standalone `--items` file (`parseItems`).
    static func parseEnum<E>(
        _ table: [String: TOMLValue], key: String, section: String,
        default def: E
    ) -> E where E: RawRepresentable & CaseIterable, E.RawValue == String {
        let raw = table.string(key).lowercased()
        if raw.isEmpty { return def }
        if let v = E(rawValue: raw) { return v }
        let valid = E.allCases.map(\.rawValue).sorted().joined(separator: ", ")
        Log.line("config: [\(section)].\(key) = \"\(raw)\" not recognised "
                 + "— falling back to \"\(def.rawValue)\" (valid: \(valid))")
        return def
    }
}

extension [String: TOMLValue] {
    func string(_ key: String, _ fallback: String = "") -> String {
        self[key]?.asString ?? fallback
    }
    func int(_ key: String, _ fallback: Int) -> Int {
        // sill stores ints as Int64; `asInt` narrows to wand's field
        // width and (deliberately) does NOT coerce a `.double`, so a
        // fractional value falls back exactly like the old skip-on-typo.
        self[key]?.asInt ?? fallback
    }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
        self[key]?.asBool ?? fallback
    }
    func strings(_ key: String, _ fallback: [String] = []) -> [String] {
        // Old wand had a dedicated `.stringArray` case; sill stores a
        // generic `.array` and projects to strings on read (non-strings
        // dropped — same net result as the old string-only array parse).
        self[key]?.asStringArray ?? fallback
    }
}
