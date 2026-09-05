// One memory + disk + in-flight-coalesce cache for images fetched
// over HTTP, shared by the `favicon:<host>` and `<set>:<name>` icon
// specs. The two facades (`FaviconCache`, `IconSetCache`) own only
// what differs between them — key parsing, the request URL, the
// on-disk file, the bytes to persist, the post-load decoration —
// and everything about WHEN the network is hit lives here, once:
//
//   - memory hit               → synchronous
//   - fresh disk file (< ttl)  → synchronous, populates memory
//   - stale disk file          → deleted, treated as a miss
//   - miss                     → one URLSession request per key per
//                                burst; concurrent callers queue on
//                                the in-flight entry
//
// Exactly one file is written per successful fetch. The file IS the
// cache: the image handed to callers is re-read from it, so the
// first session sees the same loader behaviour every later session
// will. (The icon-set cache used to write a second, never-read
// `.tiff` beside every `.svg` — the reason this file exists.)

import AppKit
import WandCore

@MainActor
final class DiskImageCache {

    /// What one icon family contributes. Every closure runs on the
    /// main actor, so a family may reach its own isolated statics.
    struct Family {
        /// Log prefix (`favicon-cache`, `icon-set-cache`).
        let label: String
        /// On-disk file for `key`, or `nil` when the key is malformed
        /// for this family (then it is neither read nor fetched).
        let file: @MainActor (String) -> URL?
        /// Request URL for `key`, or `nil` when nothing can be fetched.
        let url: @MainActor (String) -> URL?
        /// Bytes to keep on disk for a 2xx body. `nil` rejects the
        /// payload as unusable (counts as a failed fetch).
        let persist: @MainActor (Data) -> Data?
        /// Applied to every image handed out — memory, disk, and
        /// fresh fetch alike — so callers never see an undecorated one.
        let decorate: @MainActor (NSImage) -> Void
        /// Tail of the one-per-key-per-session failure log line, after
        /// `<label>: fetch failed for "<key>" — `.
        let failureNote: String
    }

    /// On-disk TTL. Old enough to survive a normal week of panel
    /// opens without re-fetching, fresh enough that a site or icon
    /// set that changed its artwork eventually catches up.
    static let ttl: TimeInterval = 24 * 60 * 60

    /// URLSession timeout. The UI shows a placeholder meanwhile; an
    /// icon slower than this is better retried next session.
    static let timeout: TimeInterval = 5

    /// `~/.cache/wand` — every family's files sit below it.
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/wand", isDirectory: true)
    }

    /// File-name-safe form of a key segment, so an internal-DNS host
    /// or an icon name carrying `/` or `:` cannot escape the cache dir.
    nonisolated static func safeFileName(_ segment: String) -> String {
        segment.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Every `icon` spec in `config` — tome entries and cast rules —
    /// for the facades' `prewarm`. Filtering to a family is theirs.
    nonisolated static func iconSpecs(in config: WandConfig) -> [String] {
        config.launcher.items.map(\.icon) + config.rules.map(\.icon)
    }

    private let family: Family
    private var memCache: [String: NSImage] = [:]
    private var inFlight: [String: [@MainActor (NSImage?) -> Void]] = [:]
    private var loggedFailures: Set<String> = []

    init(_ family: Family) {
        self.family = family
    }

    /// Synchronous lookup: memory, then a fresh disk file. `nil` is a
    /// miss the caller covers with a placeholder while `loadOrFetch`
    /// lands.
    func cached(_ key: String) -> NSImage? {
        if let img = memCache[key] { return img }
        guard let file = family.file(key),
              let img = Self.loadFresh(file) else { return nil }
        family.decorate(img)
        memCache[key] = img
        return img
    }

    /// `cached` with an async fallback. Hits fire `completion`
    /// synchronously; a miss starts one download per key and fires
    /// every queued completion when it lands (with `nil` on failure).
    func loadOrFetch(_ key: String,
                     completion: @escaping @MainActor (NSImage?) -> Void) {
        if let img = cached(key) {
            completion(img)
            return
        }
        guard let url = family.url(key), let file = family.file(key) else {
            completion(nil)
            return
        }
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            return
        }
        inFlight[key] = [completion]
        Task { [weak self] in
            let data = await Self.fetch(url)
            guard let self else { return }
            let img = data.flatMap { self.store($0, at: file) }
            if let img {
                self.memCache[key] = img
            } else if !self.loggedFailures.contains(key) {
                self.loggedFailures.insert(key)
                Log.line("\(self.family.label): fetch failed for \"\(key)\""
                         + " — \(self.family.failureNote)")
            }
            for cb in self.inFlight.removeValue(forKey: key) ?? [] { cb(img) }
        }
    }

    /// Background fetch for every key, completion discarded — the
    /// result lands in memory + disk so the next `cached` call hits.
    /// Safe on boot and on every config reload: in-flight coalescing
    /// and disk hits make repeats free.
    func prewarm(keys: some Sequence<String>) {
        for key in Set(keys) { loadOrFetch(key) { _ in } }
    }

    /// Persist the payload and hand back the image as read from disk.
    /// Falls back to decoding the bytes in memory when the write
    /// failed, so a read-only home still yields an icon this session.
    private func store(_ data: Data, at file: URL) -> NSImage? {
        guard let bytes = family.persist(data) else { return nil }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? bytes.write(to: file)
        guard let img = NSImage(contentsOf: file) ?? NSImage(data: bytes)
        else { return nil }
        family.decorate(img)
        return img
    }

    private static func loadFresh(_ file: URL) -> NSImage? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return nil }
        if let mtime = (try? fm.attributesOfItem(atPath: file.path))?[
            .modificationDate] as? Date,
           Date().timeIntervalSince(mtime) > ttl {
            try? fm.removeItem(at: file)
            return nil
        }
        return NSImage(contentsOf: file)
    }

    /// `nil` on transport error, non-2xx, or an empty body.
    private static func fetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }
}
