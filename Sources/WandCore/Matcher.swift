import Foundation

public enum Matcher {

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

    /// Rules whose pattern **starts with** `prefix` — drives the
    /// overlay's gesture-assist (what's reachable from here). An exact
    /// match (`pattern == prefix`) is included since that's a prefix
    /// of itself.
    public static func candidates(prefix: String, bundleID: String,
                                  rules: [Rule]) -> [Rule] {
        guard !prefix.isEmpty else { return [] }
        let bid = bundleID.lowercased()
        return rules.filter {
            $0.pattern.hasPrefix(prefix) && appsAllow($0.apps, bundleID: bid)
        }
    }

    /// Single source of truth for "this gesture acts." Controller and
    /// overlay both call it so the dispatch decision and the trail
    /// color can't drift apart.
    public static func resolve(pattern: String, bundleID: String,
                               rules: [Rule], excludes: [String]) -> Rule? {
        if isExcluded(bundleID: bundleID, by: excludes) { return nil }
        return match(pattern: pattern, bundleID: bundleID, rules: rules)
    }

    public static func isExcluded(bundleID: String, by excludes: [String]) -> Bool {
        let bid = bundleID.lowercased()
        return excludes.contains { glob($0.lowercased(), bid) }
    }

    /// Launcher counterpart of `match` — filters items by both the
    /// global `excludeApps` and each item's own `apps` glob, keeping
    /// document order so the menu builder can place items as written.
    /// Returns empty if the target is excluded entirely.
    public static func itemsFor(target: Target,
                                items: [LauncherItem],
                                excludes: [String]) -> [LauncherItem] {
        if isExcluded(bundleID: target.bundleID, by: excludes) { return [] }
        let bid = target.bundleID.lowercased()
        return items.filter { appsAllow($0.apps, bundleID: bid) }
    }

    /// Per-rule `apps` filter:
    ///   `"*"`                — matches every bundle id
    ///   `"com.apple.Safari"` — exact (case-insensitive)
    ///   `"*chrome*"`         — `*` / `?` glob
    ///   `"!com.apple.dt.X"`  — exclusion; any matching `!` wins
    /// Empty filter is permissive.
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

    /// Case sensitivity: caller lowercases both sides before calling.
    static func glob(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern), t = Array(s)
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
