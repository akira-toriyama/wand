import Foundation

/// Predicate evaluator for `filter-shell` rows. Returns `true` when
/// the shell command exits 0 inside the adapter's bounded budget.
/// Core can't shell out, so this is an injection point — the App
/// layer wires `BoundedShell.run` in. The default ("always true")
/// keeps callsites that don't care (overlay prefix-candidates, the
/// `--test` CLI dry-run) unchanged.
public typealias ShellFilterEval = @Sendable (String) -> Bool
public let defaultShellFilterEval: ShellFilterEval = { _ in true }

public enum Matcher {

    public static func match(pattern: String,
                             target: Target,
                             rules: [Rule],
                             evalShell: ShellFilterEval = defaultShellFilterEval)
        -> Rule? {
        // Strict partition by activation context: a synthetic target
        // from `NSWorkspace.frontmostApplication` (cursor over
        // Desktop / Dock / menu bar) only fires `[[cast.focused.rule]]`
        // rows; a resolved cursor-anchored target only fires
        // `[[cast.cursor.rule]]` rows. The previous "focused-fallback
        // is a superset" semantic is gone — a rule that should fire
        // in both regimes must be declared in both namespaces.
        let want: RuleContext = target.isFocusedFallback ? .focused : .cursor
        for r in rules {
            guard r.pattern == pattern, r.context == want else { continue }
            if passesFilter(apps: r.apps,
                            filterTitle: r.filterTitle,
                            filterShell: r.filterShell,
                            target: target,
                            evalShell: evalShell) { return r }
        }
        return nil
    }

    /// Rules whose pattern **starts with** `prefix` — drives the
    /// overlay's gesture-assist (what's reachable from here). An
    /// exact match (`pattern == prefix`) is included since that's a
    /// prefix of itself. **Apps-only filter** on this path: the
    /// assist tooltips redraw on every sample, and re-running
    /// title-glob / shell predicates per sample is too costly. The
    /// overlay's hint is permissive — it shows what *might* fire;
    /// the actual decision at button-up runs the full filter chain.
    ///
    /// `isFocusedFallback` mirrors the `Target.isFocusedFallback`
    /// gate on `match` — when the live target was synthesised from
    /// the frontmost-app fallback, the assist HUD only hints
    /// `[[cast.focused.rule]]` rows; on a resolved cursor target it
    /// only hints `[[cast.cursor.rule]]` rows. Strict partition,
    /// matching the `match` regime so the tooltip can't promise a
    /// stroke the gate will reject at button-up.
    public static func candidates(prefix: String, bundleID: String,
                                  rules: [Rule],
                                  isFocusedFallback: Bool = false) -> [Rule] {
        guard !prefix.isEmpty else { return [] }
        let bid = bundleID.lowercased()
        let want: RuleContext = isFocusedFallback ? .focused : .cursor
        return rules.filter {
            $0.pattern.hasPrefix(prefix)
                && $0.context == want
                && appsAllow($0.apps, bundleID: bid)
        }
    }

    /// Single source of truth for "this gesture acts." Controller and
    /// overlay both call it so the dispatch decision and the trail
    /// color can't drift apart.
    public static func resolve(pattern: String, target: Target,
                               rules: [Rule], excludes: [String],
                               evalShell: ShellFilterEval = defaultShellFilterEval)
        -> Rule? {
        if isExcluded(bundleID: target.bundleID, by: excludes) { return nil }
        return match(pattern: pattern, target: target, rules: rules,
                     evalShell: evalShell)
    }

    public static func isExcluded(bundleID: String, by excludes: [String]) -> Bool {
        let bid = bundleID.lowercased()
        return excludes.contains { glob($0.lowercased(), bid) }
    }

    /// Launcher counterpart of `match` — filters items by both the
    /// global `excludeApps` and each item's own `apps` + filter-title
    /// + filter-shell, keeping document order so the menu builder
    /// can place items as written. Returns empty if the target is
    /// excluded entirely.
    public static func itemsFor(target: Target,
                                items: [LauncherItem],
                                excludes: [String],
                                evalShell: ShellFilterEval = defaultShellFilterEval)
        -> [LauncherItem] {
        if isExcluded(bundleID: target.bundleID, by: excludes) { return [] }
        return items.filter {
            passesFilter(apps: $0.apps,
                         filterTitle: $0.filterTitle,
                         filterShell: $0.filterShell,
                         target: target,
                         evalShell: evalShell)
        }
    }

    /// Apps glob + optional title glob + optional shell predicate —
    /// the three conditions all rules / items use, in increasing
    /// cost order so an early-fail skips the more expensive check.
    /// Filter-title and filter-shell default to empty (no filter),
    /// so an item with neither set behaves exactly like before this
    /// feature landed.
    public static func passesFilter(apps: [String],
                                     filterTitle: String,
                                     filterShell: String,
                                     target: Target,
                                     evalShell: ShellFilterEval)
        -> Bool {
        let bid = target.bundleID.lowercased()
        if !appsAllow(apps, bundleID: bid) { return false }
        if !filterTitle.isEmpty {
            let title = target.title.lowercased()
            if !glob(filterTitle.lowercased(), title) { return false }
        }
        if !filterShell.isEmpty {
            if !evalShell(filterShell) { return false }
        }
        return true
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
