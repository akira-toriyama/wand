// Minimal TOML subset — kept in-tree to avoid pulling a SwiftPM
// dependency. Strict subset of toml.io v1.0:
//
//   ✓ `[section]` and `[[array-of-tables]]` headers
//   ✓ int / "string" / 'literal string' / bool / `[ "a", "b" ]`
//     literal arrays. Single-quoted strings preserve their body
//     verbatim (no escapes processed) — handy for shell action
//     bodies that embed double quotes around URLs / env vars.
//   ✓ `#` line + inline comments (outside quoted strings)
//   ✗ inline tables `{ a = 1 }` — `[[rules]]` uses dotted-key style
//     (action-type / action-keys / action-verb / action-cmd) instead
//
// Anything we can't parse is silently skipped: a typo only loses the
// one line, the rest still loads. That promise is what lets the
// daemon survive any config edit.

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
        // Strip inline `# …` comment outside any quoted body. Same
        // logic for `"..."` and `'...'` — find the matching close,
        // truncate at any `#` that follows.
        if val.hasPrefix("\"") || val.hasPrefix("'") {
            let quote = val.first!
            let afterOpen = val.index(after: val.startIndex)
            if let closeIdx = val[afterOpen...].firstIndex(of: quote) {
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
        } else if val.hasPrefix("'"), val.hasSuffix("'"), val.count >= 2 {
            // TOML literal string — body is verbatim, no escapes.
            parsed = .string(String(val.dropFirst().dropLast()))
        } else if val.hasPrefix("["), val.hasSuffix("]") {
            let inner = String(val.dropFirst().dropLast())
            let items = inner.split(separator: ",").compactMap {
                (chunk: Substring) -> String? in
                let s = chunk.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
                    return String(s.dropFirst().dropLast())
                }
                if s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 {
                    return String(s.dropFirst().dropLast())
                }
                return nil
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
