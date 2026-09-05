// Favicon family for the `icon = "favicon:<host>"` syntax: per-host
// site icons from Google's s2 endpoint, kept under
// `~/.cache/wand/favicons/<host>.png` by `DiskImageCache`. Google
// occasionally serves ICO under the same URL, so the payload is
// re-encoded to PNG before it is persisted — the `.png` extension is
// the on-disk contract.

import AppKit
import WandCore

@MainActor
public enum FaviconCache {

    static let shared = DiskImageCache(DiskImageCache.Family(
        label: "favicon-cache",
        file: { host in
            directory.appendingPathComponent(
                "\(DiskImageCache.safeFileName(host)).png")
        },
        url: endpoint(for:),
        persist: pngBytes(from:),
        decorate: { _ in },
        failureNote: "using SF:globe placeholder for the rest of this session"))

    /// Source pixel dimension. Google's s2 endpoint serves multiples
    /// of 16; 64 gives crisp icons at every supported font-size
    /// without the bandwidth of a 128 px request.
    private static let sourceSizePx: Int = 64

    private static var directory: URL {
        DiskImageCache.root.appendingPathComponent("favicons", isDirectory: true)
    }

    /// Fetch every unique `favicon:<host>` in `config` in the
    /// background so the first panel open / assist card already has it.
    public static func prewarm(from config: WandConfig) {
        shared.prewarm(keys: DiskImageCache.iconSpecs(in: config)
            .compactMap(host(from:)))
    }

    /// Normalise a `favicon:` spec to a bare host. Accepts:
    ///   - `favicon:github.com`
    ///   - `favicon:https://github.com/whatever?x=1` → `github.com`
    ///   - `favicon:gist.github.com` (subdomain kept distinct)
    /// Returns `nil` for malformed specs (empty host, scheme-only)
    /// so the caller can fall through to no icon.
    static func host(from spec: String) -> String? {
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

    /// Google s2 endpoint for `host`. Lives here rather than at the
    /// call site so an eventual `direct` source can swap
    /// implementations behind the same family.
    private static func endpoint(for host: String) -> URL? {
        guard var c = URLComponents(
            string: "https://www.google.com/s2/favicons") else { return nil }
        c.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: String(sourceSizePx)),
        ]
        return c.url
    }

    /// Re-encode through NSBitmapImageRep so a non-PNG payload is
    /// normalised to PNG on disk and `NSImage(contentsOf:)` reads
    /// it back cleanly.
    private static func pngBytes(from data: Data) -> Data? {
        guard let img = NSImage(data: data),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
