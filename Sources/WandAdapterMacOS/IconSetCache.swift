// External icon-set resolver for the `icon = "<set>:<name>"` syntax.
// Sibling of `FaviconCache` — same memory + disk + in-flight coalesce
// shape, swapped over to per-icon SVG payloads downloaded from
// jsDelivr's npm CDN.
//
// Supported sets (each maps to a single default variant; weight /
// solid / outline variants are a future addition once the v1 syntax
// lands):
//
//   - lucide:<name>      — Lucide (outline, strokeWidth=2)
//   - phosphor:<name>    — Phosphor Icons (regular weight)
//   - tabler:<name>      — Tabler Icons (outline)
//   - heroicons:<name>   — Heroicons (24 px outline)
//
// On miss, the SVG is fetched once over the network, written to disk
// under `~/.cache/wand/icon-sets/<set>/<name>.svg`, and held in
// memory as an `NSImage` (template-flagged so AppKit auto-tints it
// with the active label colour — light/dark adaptive without
// per-call recolouring).

import AppKit
import WandCore

@MainActor
public final class IconSetCache {

    public static let shared = IconSetCache()

    /// Memory cache keyed by the full spec (e.g., `lucide:trash`).
    /// Holds the resolved NSImage; sizing is applied at render time
    /// by the caller via `image.size = ...`.
    private var memCache: [String: NSImage] = [:]

    /// In-flight fetches keyed by spec, so concurrent rows pointing
    /// at the same icon coalesce onto a single download.
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]

    /// One log per dead spec per session — same approach as
    /// `FaviconCache` so a typo'd `lucide:tasrh` doesn't flood the
    /// log every panel open.
    private var loggedFailures: Set<String> = []

    /// Same 24 h TTL as `FaviconCache`. Long enough that a normal
    /// week of use never re-fetches, short enough that an icon set
    /// publishing an updated SVG eventually catches up.
    private static let ttl: TimeInterval = 24 * 60 * 60

    /// URLSession timeout — favicon-equivalent. SVGs are small
    /// (typically 1-4 KB) so this is generous.
    private static let timeout: TimeInterval = 5

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

    /// Names recognised as icon-set prefixes (`lucide:`, `phosphor:`,
    /// `tabler:`, `heroicons:`). Used by `IconResolver` to decide
    /// whether a spec belongs to this cache vs. the existing
    /// `app:` / `favicon:` / `SF:` branches.
    public static let recognisedPrefixes: [String] =
        Array(sources.keys)

    /// True iff `spec` starts with one of the recognised set
    /// prefixes followed by an icon name (no empty-name acceptance
    /// — `"lucide:"` alone is treated as malformed and falls
    /// through to the text-glyph path in `IconResolver`).
    public static func matches(_ spec: String) -> Bool {
        return parse(spec) != nil
    }

    /// Split a spec into `(set, name)`. Returns `nil` for unknown
    /// prefixes or empty names so the caller can decide whether to
    /// fall back.
    public static func parse(_ spec: String)
        -> (set: String, name: String)? {
        guard let colon = spec.firstIndex(of: ":") else { return nil }
        let set = String(spec[..<colon]).lowercased()
        let name = String(spec[spec.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, sources[set] != nil else { return nil }
        return (set, name)
    }

    /// Synchronous cache lookup — instant hits for memory + disk,
    /// `nil` for misses so the caller can show a placeholder while
    /// the network round-trip lands.
    public func cached(spec: String) -> NSImage? {
        if let img = memCache[spec] { return img }
        guard let (set, name) = Self.parse(spec) else { return nil }
        guard let img = loadFromDisk(set: set, name: name)
        else { return nil }
        memCache[spec] = img
        return img
    }

    /// Cached lookup with async fallback. Cache hits fire `completion`
    /// synchronously; misses kick a URLSession download and call
    /// `completion` on the main actor when it finishes. Concurrent
    /// calls for the same spec coalesce.
    public func loadOrFetch(spec: String,
                             completion: @escaping @MainActor (NSImage?) -> Void) {
        if let img = cached(spec: spec) {
            completion(img)
            return
        }
        guard let (set, name) = Self.parse(spec),
              let url = Self.sources[set]?(name) else {
            completion(nil)
            return
        }
        if inFlight[spec] != nil {
            inFlight[spec]?.append(completion)
            return
        }
        inFlight[spec] = [completion]
        Task { [weak self] in
            let img = await Self.fetch(url: url)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if let img = img {
                    img.isTemplate = true
                    self.memCache[spec] = img
                    self.writeToDisk(set: set, name: name, image: img)
                } else if !self.loggedFailures.contains(spec) {
                    self.loggedFailures.insert(spec)
                    Log.line("icon-set-cache: fetch failed for "
                             + "\"\(spec)\" — falling back to "
                             + "placeholder for the rest of this "
                             + "session")
                }
                let waiters = self.inFlight.removeValue(forKey: spec)
                    ?? []
                for cb in waiters { cb(img) }
            }
        }
    }

    /// Walk every icon spec in `config` and prewarm the cache for
    /// each unique icon-set reference. Same shape as
    /// `FaviconCache.prewarm` — no-op completion, in-flight
    /// coalesce, safe to call on boot and on every config reload.
    public static func prewarm(from config: WandConfig) {
        var specs: Set<String> = []
        for item in config.launcher.items {
            if matches(item.icon) { specs.insert(item.icon) }
        }
        for rule in config.rules {
            if matches(rule.icon) { specs.insert(rule.icon) }
        }
        for s in specs {
            shared.loadOrFetch(spec: s) { _ in }
        }
    }

    // MARK: - Disk persistence

    private static var rootDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            ".cache/wand/icon-sets", isDirectory: true)
    }

    /// File path for the cached SVG. The name is sanitised so
    /// arbitrary `/` / `:` characters can't escape the cache root.
    private static func diskPath(set: String, name: String) -> URL {
        let safeName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return rootDirectory
            .appendingPathComponent(set, isDirectory: true)
            .appendingPathComponent("\(safeName).svg")
    }

    private func loadFromDisk(set: String, name: String) -> NSImage? {
        let url = Self.diskPath(set: set, name: name)
        guard FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        if let attrs = try? FileManager.default
            .attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) > Self.ttl {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }

    private func writeToDisk(set: String, name: String, image: NSImage) {
        let path = Self.diskPath(set: set, name: name)
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        // The fetched payload was already an SVG — but we round-trip
        // through the NSImage's `tiffRepresentation` only as a
        // fallback path. The actual SVG bytes are written by the
        // fetch code path via `writeRawSVG`. This method is kept for
        // any code path that has only the rendered NSImage.
        guard let tiff = image.tiffRepresentation else { return }
        try? tiff.write(to: path.deletingPathExtension()
                            .appendingPathExtension("tiff"))
    }

    /// Write the original SVG bytes to disk so `NSImage(contentsOf:)`
    /// can re-render them on subsequent launches (and the system
    /// SVG decoder handles the layout, rather than us holding a
    /// fixed-size bitmap). Called from the fetch path with the raw
    /// HTTP body before we hand the NSImage off to the caller.
    private func writeRawSVG(set: String, name: String, data: Data) {
        let path = Self.diskPath(set: set, name: name)
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try? data.write(to: path)
    }

    // MARK: - Fetch

    /// Detached download. Returns `nil` on transport error, non-2xx,
    /// or empty body / invalid SVG. The caller (on the main actor)
    /// caches both the raw SVG bytes (for disk re-render on relaunch)
    /// and the resolved NSImage.
    private static func fetch(url: URL) async -> NSImage? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared
                .data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty
            else { return nil }
            // Write the raw SVG to disk first via a hop back to the
            // main actor — the cache writer is @MainActor-isolated to
            // share the same disk-path machinery as the synchronous
            // path.
            await MainActor.run {
                if let (set, name) = pathParts(for: url) {
                    shared.writeRawSVG(set: set, name: name, data: data)
                }
            }
            // Reload through the disk path so the NSImage carries
            // the same loader behaviour subsequent sessions will see
            // (avoids "first render goes through NSImage(data:) which
            // may behave differently from NSImage(contentsOf:)").
            if let (set, name) = pathParts(for: url) {
                let diskURL = await MainActor.run {
                    Self.diskPath(set: set, name: name)
                }
                return NSImage(contentsOf: diskURL)
            }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    /// Recover the (set, name) pair from a jsDelivr URL — works by
    /// inspecting the last two/three path components against each
    /// known builder. Avoids carrying (set, name) through the
    /// `fetch` API itself, which keeps the network call signature
    /// minimal.
    private static func pathParts(for url: URL)
        -> (set: String, name: String)? {
        let comps = url.pathComponents
        guard let svgComp = comps.last,
              svgComp.hasSuffix(".svg") else { return nil }
        let name = String(svgComp.dropLast(".svg".count))
        // Heuristic — match by recognised set name appearing in the
        // path. Cheap and the path conventions diverge enough that
        // collisions don't happen.
        for set in sources.keys {
            if comps.contains(where: { $0.lowercased() == set })
                || comps.contains(where: {
                    $0.lowercased().contains(set)
                }) {
                return (set, name)
            }
        }
        return nil
    }
}
