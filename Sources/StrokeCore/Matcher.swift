// Rule matching: (pattern, target bundle id) → first matching Rule.
//
// Pure logic, used by the Controller. The "first match wins" semantic
// matches MacGesture so existing rule files port without surprise.
//
// App filter syntax:
//   "*"                — matches every bundle id
//   "com.apple.Safari" — exact
//   "*chrome*"         — `*` / `?` glob (case-insensitive)
//   "!com.apple.dt.Xcode" — exclusion; if any entry matches as
//                          exclusion, the rule is rejected even if
//                          a positive entry matched

import Foundation

public enum Matcher {

    /// First rule whose pattern equals `pattern` AND whose `apps`
    /// filter allows `bundleID`. Returns `nil` if nothing matches.
    public static func match(pattern: String,
                             bundleID: String,
                             rules: [Rule]) -> Rule? {
        let bid = bundleID.lowercased()
        for r in rules {
            guard r.pattern == pattern else { continue }
            if appsAllow(r.apps, bundleID: bid) { return r }
        }
        return nil
    }

    /// `true` when `bundleID` matches any glob in `excludes`. Used
    /// by the Controller to honour `[recognition] exclude-apps`
    /// before any rule is even considered.
    public static func isExcluded(bundleID: String, by excludes: [String]) -> Bool {
        let bid = bundleID.lowercased()
        return excludes.contains { glob($0.lowercased(), bid) }
    }

    /// Whether the per-rule `apps` filter permits `bundleID`.
    /// Empty filter is permissive. Exclusions (`!…`) always win.
    static func appsAllow(_ filters: [String], bundleID: String) -> Bool {
        if filters.isEmpty { return true }
        var anyPositive = false
        var anyMatch = false
        for f in filters {
            if f.hasPrefix("!") {
                let pat = String(f.dropFirst())
                if glob(pat.lowercased(), bundleID) { return false }
            } else {
                anyPositive = true
                if glob(f.lowercased(), bundleID) { anyMatch = true }
            }
        }
        return anyPositive ? anyMatch : true
    }

    /// `*` and `?` glob, case-insensitive (caller lowercases inputs).
    static func glob(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern), t = Array(s)
        // Iterative algorithm with `*` backtracking.
        var pi = 0, ti = 0
        var starPi = -1, starTi = 0
        while ti < t.count {
            if pi < p.count, (p[pi] == "?" || p[pi] == t[ti]) {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi; starTi = ti; pi += 1
            } else if starPi != -1 {
                pi = starPi + 1; starTi += 1; ti = starTi
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
