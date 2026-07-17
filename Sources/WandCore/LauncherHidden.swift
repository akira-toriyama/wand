// Session-only context-menu delete (t-k4hf / wand#128) — the pure
// half of the feature. The adapter's panel records "the user deleted
// this row" as a node-id set per panel level; this filter drops those
// rows the next time the same level is built. The recursive walk and
// the empty-folder pruning live adapter-side (`PanelTree.applyHidden`)
// because the tree type does; this level filter is the testable core.

public enum LauncherHidden {

    /// Filter one panel level's `elements` per the level's `hidden`
    /// id set. Elements whose `id` is `nil` (headers / placeholders)
    /// always survive; hidden ids not present in `elements` are
    /// ignored.
    public static func apply<T>(_ elements: [T],
                                 id: (T) -> String?,
                                 hidden: Set<String>) -> [T] {
        guard !hidden.isEmpty else { return elements }
        return elements.filter { el in
            guard let eid = id(el) else { return true }
            return !hidden.contains(eid)
        }
    }
}
