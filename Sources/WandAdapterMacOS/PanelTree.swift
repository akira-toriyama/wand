// `[TomeItem]` → panel tree. Pure data shaping for the tome panel:
// no views, no AppKit beyond `NSImage` in `HeaderSpec`.

import AppKit
import WandCore

/// App-header data flowed into the root panel.
struct HeaderSpec {
    let name: String
    let icon: NSImage?
}

/// `[TomeItem]` → `[PanelNode]`. Folder order follows first
/// mention in config, not alphabetical — the user orders rows by
/// writing them, so the tree must not resort.
enum PanelTree {
    static func build(from items: [TomeItem]) -> [PanelNode] {
        let root = FolderBuilder(name: "")
        for item in items {
            var current = root
            for segment in item.group {
                if let existing = current.subs[segment] {
                    current = existing
                } else {
                    let f = FolderBuilder(name: segment)
                    current.subs[segment] = f
                    current.children.append(.folder(f))
                    current = f
                }
            }
            current.children.append(.leaf(item))
        }
        return root.toNodes()
    }

    /// Separator for panel-path override keys. U+001F (unit
    /// separator) instead of "/" because folder names are free-form
    /// user strings — `group = ["a/b"]` and `group = ["a", "b"]`
    /// must not collapse to the same key.
    static let pathSep = "\u{1F}"

    /// Override key for the child panel of folder `name` inside
    /// `parent`. Always prefixes the separator so even an empty
    /// folder name can't collide with the root key `""`.
    static func childPath(_ parent: String, _ name: String) -> String {
        parent + pathSep + name
    }

    /// Human-readable form of a panel path for log lines.
    static func displayPath(_ path: String) -> String {
        path.isEmpty
            ? "(root)"
            : path.split(separator: Character(pathSep), omittingEmptySubsequences: false)
                  .dropFirst()  // leading separator from the always-prefix shape
                  .joined(separator: "/")
    }

    /// Re-apply the session's DnD sort override (wand#127) to every
    /// level of the tree. `override` maps a panel path ("" = root,
    /// folder names joined via `pathSep` when nested) to the row
    /// order the user last dragged that level into;
    /// `TomeOrder.apply` does the slot-merge so rows the
    /// override doesn't know about keep their config positions.
    static func applyOrder(_ nodes: [PanelNode], path: String,
                           override: [String: [String]]) -> [PanelNode] {
        let level = override[path].map { order in
            TomeOrder.apply(nodes, id: { $0.orderID }, override: order)
        } ?? nodes
        guard !override.isEmpty else { return level }
        return level.map { node in
            guard case .folder(let name, let children) = node else {
                return node
            }
            return .folder(name: name,
                           children: applyOrder(children,
                                                 path: childPath(path, name),
                                                 override: override))
        }
    }

    /// Apply the session's context-menu deletes (wand#128) to every
    /// level of the tree, BEFORE `applyOrder`. `hidden` maps a panel
    /// path to the node ids the user deleted at that level. Folders
    /// whose children all end up hidden are pruned — an empty child
    /// panel must never appear.
    static func applyHidden(_ nodes: [PanelNode], path: String,
                             hidden: [String: Set<String>]) -> [PanelNode] {
        guard !hidden.isEmpty else { return nodes }
        let level = TomeHidden.apply(nodes, id: { $0.orderID },
                                     hidden: hidden[path] ?? [])
        return level.compactMap { node in
            guard case .folder(let name, let children) = node else {
                return node
            }
            let kids = applyHidden(children,
                                    path: childPath(path, name),
                                    hidden: hidden)
            return kids.isEmpty ? nil : .folder(name: name, children: kids)
        }
    }

    /// Mutable intermediate. Class so siblings share folder references.
    private final class FolderBuilder {
        let name: String
        var children: [Child] = []
        var subs: [String: FolderBuilder] = [:]
        init(name: String) { self.name = name }
        enum Child {
            case folder(FolderBuilder)
            case leaf(TomeItem)
        }
        func toNodes() -> [PanelNode] {
            children.map { c in
                switch c {
                case .folder(let f):
                    return .folder(name: f.name, children: f.toNodes())
                case .leaf(let item):
                    return .item(item)
                }
            }
        }
    }
}
