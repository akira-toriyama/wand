// Minimal TOML parser, ported from facet's FacetCore/TOML.swift.
// Keeps stroke zero-dep (no SwiftPM TOML library pulled in).
//
// Supported:
//   - `[section]` headers
//   - `key = value` lines, where value is int / "string" / bool /
//     array literal `[ "a", "b" ]`
//   - `[[array-of-tables]]` headers (each occurrence appends a new
//     table — used by `[[rules]]`)
//   - `#` line comments and inline `# …` comments outside quoted
//     strings
//   - Anything else is silently skipped (a typo only loses that one
//     line — the rest of the file still loads, per facet's policy)
//
// Empty section name `""` is used for top-level keys. Inline tables
// (`{ a = 1, b = 2 }`) are NOT yet supported — `[[rules]]` actions
// are decomposed via dotted-key TOML (action-type / action-keys /
// action-verb / action-cmd) instead. See config.toml for the
// canonical schema.

import Foundation

public enum TOMLValue: Sendable, Equatable {
    case int(Int)
    case string(String)
    case bool(Bool)
    case stringArray([String])
}

/// Output of the parser. `tables[""]` is the top-level scope.
/// `arrays["rules"]` holds the per-`[[rules]]` table list, in source
/// order.
public struct TOMLDocument: Sendable {
    public var tables: [String: [String: TOMLValue]] = [:]
    public var arrays: [String: [[String: TOMLValue]]] = [:]
}

public func parseTOMLSubset(_ text: String) -> TOMLDocument {
    var out = TOMLDocument()
    var section = ""
    var arrayKey: String? = nil          // non-nil → currently inside [[arrayKey]]

    func writeKV(_ key: String, _ val: TOMLValue) {
        if let k = arrayKey {
            // append into the *last* table of the array
            var rows = out.arrays[k] ?? []
            if rows.isEmpty { rows.append([:]) }
            rows[rows.count - 1][key] = val
            out.arrays[k] = rows
        } else {
            out.tables[section, default: [:]][key] = val
        }
    }

    for raw in text.split(separator: "\n",
                          omittingEmptySubsequences: false) {
        // `.whitespacesAndNewlines` (not just `.whitespaces`) so a
        // CRLF file's trailing `\r` is stripped — otherwise a value
        // like `action-keys = "cmd+w"` parses as `cmd+w\r` and
        // `KeyCombo.parse` silently fails to look up the keycode.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        // [[array-of-tables]]
        if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") {
            let name = String(trimmed.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespaces)
            arrayKey = name
            out.arrays[name, default: []].append([:])
            continue
        }
        // [section]
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            section = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            if out.tables[section] == nil { out.tables[section] = [:] }
            arrayKey = nil
            continue
        }
        // key = value
        guard let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq])
            .trimmingCharacters(in: .whitespaces)
        var val = String(trimmed[trimmed.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        // Strip inline `# …` comment outside any quoted body.
        if val.hasPrefix("\"") {
            let afterOpen = val.index(after: val.startIndex)
            if let closeIdx = val[afterOpen...].firstIndex(of: "\"") {
                let afterClose = val.index(after: closeIdx)
                if afterClose < val.endIndex,
                   let h = val[afterClose...].firstIndex(of: "#") {
                    val = String(val[..<h])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        } else if val.hasPrefix("[") {
            // Array literal — comments after the closing `]` are stripped.
            if let closeIdx = val.firstIndex(of: "]") {
                let afterClose = val.index(after: closeIdx)
                if afterClose < val.endIndex,
                   let h = val[afterClose...].firstIndex(of: "#") {
                    val = String(val[..<h])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        } else if let h = val.firstIndex(of: "#") {
            val = String(val[..<h]).trimmingCharacters(in: .whitespaces)
        }
        guard !key.isEmpty, !val.isEmpty else { continue }
        let parsed: TOMLValue
        if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
            parsed = .string(String(val.dropFirst().dropLast()))
        } else if val.hasPrefix("["), val.hasSuffix("]") {
            let inner = String(val.dropFirst().dropLast())
            let items = inner.split(separator: ",").compactMap {
                (chunk: Substring) -> String? in
                let s = chunk.trimmingCharacters(in: .whitespaces)
                guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2
                else { return nil }
                return String(s.dropFirst().dropLast())
            }
            parsed = .stringArray(items)
        } else if val == "true"  { parsed = .bool(true) }
        else  if val == "false" { parsed = .bool(false) }
        else  if let i = Int(val) { parsed = .int(i) }
        else  { continue }
        writeKV(key, parsed)
    }
    return out
}
