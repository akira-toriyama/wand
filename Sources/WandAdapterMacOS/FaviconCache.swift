// Favicon resolver for the `icon = "favicon:<host>"` syntax. Looks up
// per-host site icons via Google's s2 favicon endpoint, caches them on
// disk (`~/.cache/wand/favicons/<host>.png`, 24 h TTL) + in memory,
// and surfaces them through the shared `IconResolver` so both the
// tome panel rows and the cast assist cards can use them.
//
// Two-stage lookup:
//   1. Memory cache (NSImage by host) — instant; populated on disk
//      load and on successful fetch.
//   2. Disk cache (PNG file by host) — checked on demand; loads into
//      memory cache and returns synchronously when fresh.
//
// Cache miss falls through to async fetch. The caller (the row in
// `LauncherPanel`) gets a placeholder image up front, then a
// completion callback once the network round-trip lands so the row
// can update its `iconView.image`.

import AppKit
import WandCore

@MainActor
public final class FaviconCache {

    public static let shared = FaviconCache()

    /// Memory cache keyed by host. Populated on disk-cache load and
    /// on successful fetch. Reads are O(1) so this is the path
    /// `IconResolver.resolve` takes on every panel open after the
    /// first sight of a given host.
    private var memCache: [String: NSImage] = [:]

    /// Hosts whose fetch is currently in flight. Subsequent
    /// `loadOrFetch` calls for the same host pile their completion
    /// closures onto the existing in-flight entry instead of starting
    /// a duplicate download.
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]

    /// Hosts we've already logged a fetch failure for this session.
    /// Stops the same dead host from spamming `/tmp/wand.log` once per
    /// row that references it.
    private var loggedFailures: Set<String> = []

    /// On-disk TTL — same 24 h the issue describes. Old enough to
    /// survive a normal week of panel opens without re-fetching, fresh
    /// enough that a site that changed its favicon eventually catches
    /// up.
    private static let ttl: TimeInterval = 24 * 60 * 60

    /// URLSession timeout. The bonus pellet beat is sub-second; a
    /// favicon that takes longer than this is better off shown as a
    /// `SF:globe` placeholder and re-tried on the next session.
    private static let timeout: TimeInterval = 5

    /// Source pixel dimension. Google's s2 endpoint serves multiples
    /// of 16; 64 gives crisp icons at every supported font-size
    /// without the bandwidth of a 128 px request.
    private static let sourceSizePx: Int = 64

    /// Look the cache up synchronously. Hits return the NSImage (with
    /// the caller responsible for sizing it via `image.size = ...`);
    /// misses return `nil` so the caller can show a placeholder while
    /// the async fetch lands.
    public func cached(host: String) -> NSImage? {
        if let img = memCache[host] { return img }
        guard let img = loadFromDisk(host: host) else { return nil }
        memCache[host] = img
        return img
    }

    /// Cached lookup with async fallback. If `host` is in memory or
    /// fresh on disk, `completion` fires synchronously with the
    /// image. Otherwise spawns a URLSession download and calls
    /// `completion` on the main actor once it finishes (or fails).
    /// Concurrent calls for the same host coalesce — only one
    /// network round-trip per host per "burst".
    public func loadOrFetch(host: String,
                      completion: @escaping @MainActor (NSImage?) -> Void) {
        if let img = cached(host: host) {
            completion(img)
            return
        }
        // Coalesce concurrent requests: stack the closure onto an
        // existing in-flight entry rather than starting a duplicate
        // fetch. The first call to `loadOrFetch` for a host kicks the
        // download; everyone else waits for the same completion.
        if inFlight[host] != nil {
            inFlight[host]?.append(completion)
            return
        }
        inFlight[host] = [completion]
        Task { [weak self] in
            let img = await Self.fetch(host: host)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if let img = img {
                    self.memCache[host] = img
                    self.writeToDisk(host: host, image: img)
                } else if !self.loggedFailures.contains(host) {
                    self.loggedFailures.insert(host)
                    Log.line("favicon-cache: fetch failed for \"\(host)\""
                             + " — using SF:globe placeholder for the"
                             + " rest of this session")
                }
                let waiters = self.inFlight.removeValue(forKey: host) ?? []
                for cb in waiters { cb(img) }
            }
        }
    }

    /// Walk every icon spec in `config` and kick off a background
    /// fetch for each unique `favicon:<host>`. Completion is a no-op
    /// — the network response lands in `memCache` + disk-cache
    /// passively, so subsequent `IconResolver.resolve(...)` calls
    /// (when a tome panel opens or a cast assist card lays out) see
    /// the favicon immediately rather than the `SF:globe`
    /// placeholder. Safe to call at startup AND on every config
    /// reload; the per-host `inFlight` coalesce ensures repeated
    /// calls for the same host don't trigger duplicate network
    /// requests, and disk-cached hits skip the network entirely.
    public static func prewarm(from config: WandConfig) {
        var hosts: Set<String> = []
        for item in config.launcher.items {
            if let h = host(from: item.icon) { hosts.insert(h) }
        }
        for rule in config.rules {
            if let h = host(from: rule.icon) { hosts.insert(h) }
        }
        for h in hosts {
            shared.loadOrFetch(host: h) { _ in }
        }
    }

    /// Normalise a `favicon:` spec to a bare host. Accepts:
    ///   - `favicon:github.com`
    ///   - `favicon:https://github.com/whatever?x=1` → `github.com`
    ///   - `favicon:gist.github.com` (subdomain kept distinct)
    /// Returns `nil` for malformed specs (empty host, scheme-only)
    /// so the caller can fall through to no icon.
    public static func host(from spec: String) -> String? {
        guard spec.hasPrefix("favicon:") else { return nil }
        var raw = String(spec.dropFirst("favicon:".count))
        // Strip `//` after the scheme if a full URL was passed.
        if let schemeEnd = raw.range(of: "://") {
            raw = String(raw[schemeEnd.upperBound...])
        }
        // Drop the path / query — host only.
        if let pathStart = raw.firstIndex(where: { $0 == "/" || $0 == "?" }) {
            raw = String(raw[..<pathStart])
        }
        // Drop a leading user:password@ prefix if any (rare for sites
        // a user would TOML in, but cheap to handle).
        if let at = raw.lastIndex(of: "@") {
            raw = String(raw[raw.index(after: at)...])
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    // MARK: - Disk persistence

    private static var directory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cache/wand/favicons",
                                            isDirectory: true)
    }

    /// PNG file path for `host`. The host is sanitised so an
    /// internal-DNS entry with `:` or `?` can't escape the cache dir.
    private static func diskPath(for host: String) -> URL {
        let safe = host.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(safe).png")
    }

    private func loadFromDisk(host: String) -> NSImage? {
        let url = Self.diskPath(for: host)
        guard FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        if let attrs = try? FileManager.default
            .attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date {
            let age = Date().timeIntervalSince(mtime)
            if age > Self.ttl {
                // Stale — drop the file so the next call re-fetches.
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        return NSImage(contentsOf: url)
    }

    private func writeToDisk(host: String, image: NSImage) {
        let dir = Self.directory
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        // Re-encode through NSBitmapImageRep so a non-PNG payload
        // (Google occasionally serves ICO under the same URL) is
        // normalised to PNG on disk — the on-disk extension is `.png`
        // by contract and NSImage(contentsOf:) reads back cleanly.
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: Self.diskPath(for: host))
    }

    // MARK: - Fetch

    /// Build the Google s2 endpoint for `host`. Lives here rather
    /// than at the call site so an eventual `direct` source can swap
    /// implementations behind the same `fetch(host:)` API.
    private static func endpoint(for host: String) -> URL? {
        guard var c = URLComponents(
            string: "https://www.google.com/s2/favicons") else { return nil }
        c.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: String(sourceSizePx)),
        ]
        return c.url
    }

    /// Single URLSession request with the configured timeout. Returns
    /// `nil` on transport error, non-2xx response, or empty body.
    /// Detached from the main actor so the network wait doesn't tie
    /// up the UI thread.
    private static func fetch(host: String) async -> NSImage? {
        guard let url = endpoint(for: host) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty,
                  let img = NSImage(data: data)
            else { return nil }
            return img
        } catch {
            return nil
        }
    }
}
