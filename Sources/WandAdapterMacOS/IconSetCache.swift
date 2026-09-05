// External icon-set family for the `icon = "<set>:<name>"` syntax:
// per-icon SVGs from jsDelivr's npm CDN, kept under
// `~/.cache/wand/icon-sets/<set>/<name>.svg` by `DiskImageCache`.
// The raw SVG bytes are what is persisted, so the system SVG decoder
// re-renders them at whatever size a later caller asks for. Every
// image is template-flagged so AppKit auto-tints it with the active
// label colour — light/dark adaptive without per-call recolouring.
//
// Supported sets (each maps to a single default variant; weight /
// solid / outline variants are a future addition once the v1 syntax
// lands):
//
//   - lucide:<name>      — Lucide (outline, strokeWidth=2)
//   - phosphor:<name>    — Phosphor Icons (regular weight)
//   - tabler:<name>      — Tabler Icons (outline)
//   - heroicons:<name>   — Heroicons (24 px outline)

import AppKit
import WandCore

@MainActor
public enum IconSetCache {

    static let shared = DiskImageCache(DiskImageCache.Family(
        label: "icon-set-cache",
        file: { spec in
            guard let (set, name) = parse(spec) else { return nil }
            return rootDirectory
                .appendingPathComponent(set, isDirectory: true)
                .appendingPathComponent(
                    "\(DiskImageCache.safeFileName(name)).svg")
        },
        url: { spec in
            guard let (set, name) = parse(spec) else { return nil }
            return sources[set]?(name)
        },
        persist: { $0 },
        decorate: { $0.isTemplate = true },
        failureNote: "falling back to placeholder for the rest of this session"))

    /// Recognised prefix → jsDelivr URL builder. Keeping this as a
    /// single table makes adding a new set a one-line change.
    /// Each builder gets the bare icon name (e.g., `"trash"`) and
    /// returns the full HTTPS URL. `nil` means "unsupported set".
    private static let sources: [String: (String) -> URL?] = [
        "lucide": { name in
            URL(string: "https://cdn.jsdelivr.net/npm/"
                + "lucide-static/icons/\(name).svg")
        },
        "phosphor": { name in
            URL(string: "https://cdn.jsdelivr.net/npm/"
                + "@phosphor-icons/core/assets/regular/\(name).svg")
        },
        "tabler": { name in
            URL(string: "https://cdn.jsdelivr.net/npm/"
                + "@tabler/icons/icons/outline/\(name).svg")
        },
        "heroicons": { name in
            URL(string: "https://cdn.jsdelivr.net/npm/"
                + "heroicons/24/outline/\(name).svg")
        },
    ]

    private static var rootDirectory: URL {
        DiskImageCache.root.appendingPathComponent("icon-sets", isDirectory: true)
    }

    /// True iff `spec` starts with one of the recognised set
    /// prefixes followed by an icon name (no empty-name acceptance
    /// — `"lucide:"` alone is treated as malformed and falls
    /// through to the text-glyph path in `IconResolver`).
    static func matches(_ spec: String) -> Bool {
        parse(spec) != nil
    }

    /// Split a spec into `(set, name)`. Returns `nil` for unknown
    /// prefixes or empty names so the caller can decide whether to
    /// fall back.
    static func parse(_ spec: String) -> (set: String, name: String)? {
        guard let colon = spec.firstIndex(of: ":") else { return nil }
        let set = String(spec[..<colon]).lowercased()
        let name = String(spec[spec.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, sources[set] != nil else { return nil }
        return (set, name)
    }

    /// Fetch every unique icon-set reference in `config` in the
    /// background so the first panel open / assist card already has it.
    public static func prewarm(from config: WandConfig) {
        shared.prewarm(keys: DiskImageCache.iconSpecs(in: config).filter(matches))
    }
}
