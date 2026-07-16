// Session-only DnD sort (wand#127) — the pure half of the feature.
// The adapter's panel records "the user dragged these rows into this
// order" as an ordered id list per panel level; this slot-merge
// re-applies that order the next time the same level is built.
//
// Slot-merge, not wholesale replacement: only elements whose id
// appears in the override move, and they move only within the slots
// they already occupy. Items filtered out when the override was
// saved (per-app `apps` globs, filter-title, filter-shell) keep
// their config positions, so reordering the panel over one app never
// scrambles the panel another app sees.

public enum LauncherOrder {

    /// Reorder one panel level's `elements` per a saved `override`
    /// (desired ids, first = topmost). Elements whose `id` is `nil`
    /// (separator-ish rows) or absent from `override` keep their
    /// positions; override ids not present in `elements` are
    /// ignored. Duplicate ids keep their relative order among
    /// themselves (stable).
    public static func apply<T>(_ elements: [T],
                                 id: (T) -> String?,
                                 override: [String]) -> [T] {
        guard !override.isEmpty else { return elements }
        var rank: [String: Int] = [:]
        for (i, oid) in override.enumerated() where rank[oid] == nil {
            rank[oid] = i
        }
        // Slots = positions currently occupied by overridden elements.
        var slots: [Int] = []
        for (i, el) in elements.enumerated() {
            if let eid = id(el), rank[eid] != nil { slots.append(i) }
        }
        guard slots.count > 1 else { return elements }
        // Occupants sorted by override rank; offset tie-break keeps
        // duplicate ids stable.
        let sorted = slots
            .enumerated()
            .sorted { a, b in
                let ra = rank[id(elements[a.element])!]!
                let rb = rank[id(elements[b.element])!]!
                return (ra, a.offset) < (rb, b.offset)
            }
            .map { elements[$0.element] }
        var out = elements
        for (slot, el) in zip(slots, sorted) { out[slot] = el }
        return out
    }
}
