// The tome UI surface. A non-activating NSPanel that does NOT
// take keyboard focus from the underlying app — the user keeps typing
// in their editor while picking an item with the mouse. Used for
// both the native middle-click trigger and the
// `wand tome --open` external trigger.
//
// Behaviour notes:
//   - No keyboard navigation (panel cannot become key by design);
//     Esc dismisses the whole tree.
//   - Submenus open as adjacent child panels on hover. The gap
//     between panels is zero so moving the cursor straight right
//     from the folder row into the child works reliably; the native
//     NSMenu diagonal-cursor tolerance is NOT reproduced — hovering
//     a non-folder row inside the parent closes the child.
//   - State markers (✓ / –) prefix the row title.
//
// Spec contract:
//   - `present(...)` returns **immediately** (unlike `NSMenu.popUp`,
//     which blocks). Callers must not assume synchronous selection.
//   - `onSelect` fires asynchronously on click and is followed by
//     the whole panel tree closing.
//   - Only one panel tree is visible at a time. A second
//     `present(...)` dismisses the first.

import AppKit
import Effects   // drawLinePets (shared line-pet drawing; re-exports Palette)
import Foundation
import WandCore

@MainActor
public enum TomePanel {

    /// Strong reference holder for the currently-visible root panel —
    /// nothing else retains the tree once `present` returns.
    private static var current: PanelController?

    public static func present(filteredItems items: [TomeItem],
                                target: Target,
                                cocoaPoint: NSPoint,
                                layout: TomeLayout = .list,
                                shortcutBadge: Bool = true,
                                iconChip: Bool = true,
                                fontSize: Int = 13,
                                openAnim: TomeOpenAnim = .off,
                                closeAnim: TomeCloseAnim = .off,
                                border: TomeBorder = .off,
                                borderCycleMs: Int = 4000,
                                borderWidth: Int = 2,
                                shadow: Bool = false,
                                linePets: [LinePet] = [],
                                palette: TomeThemePalette = TomeThemePalette(),
                                orderOverride: [String: [String]] = [:],
                                onReorder: ((String, [String]) -> Void)? = nil,
                                onSelect: @escaping (TomeItem, Target) -> Void) {
        current?.dismiss()
        guard !items.isEmpty else {
            Log.line("tome-panel: no items for \(target.bundleID) — "
                     + "panel suppressed")
            return
        }
        let nodes = PanelTree.applyOrder(PanelTree.build(from: items),
                                          path: "", override: orderOverride)
        let colors = TomeColors.resolve(palette)
        // Header (app icon + name) only makes sense on the vertical
        // list — in toolbar mode the panel is a single horizontal row
        // and a header banner doesn't fit visually.
        let header = layout == .list
            ? PanelLayout.makeHeaderSpec(for: target)
            : nil
        // Outer margin around bg — needed by any decoration that sits
        // OUTSIDE the panel content rather than inside it. Two sources
        // contribute. `line-pets` ride the rim and need ~14 pt
        // (scaled by `fontSize`) so the panel window doesn't clip
        // their outer half.
        let petScale = max(1.0, CGFloat(fontSize) / 13.0)
        let outerMargin: CGFloat = linePets.isEmpty
            ? 0 : round(14 * petScale)
        let (content, rows) = PanelLayout.buildContent(
            nodes: nodes, header: header, layout: layout,
            shortcutBadge: shortcutBadge, iconChip: iconChip,
            fontSize: fontSize,
            colors: colors, outerMargin: outerMargin)
        let frame = PanelLayout.placeRoot(
            atCursor: cocoaPoint, contentSize: content.fittingSize)
        let controller = PanelController(
            content: content, rows: rows, frame: frame,
            layout: layout,
            target: target, onSelect: onSelect,
            isRoot: true,
            panelPath: "",
            onReorder: onReorder,
            openAnim: openAnim,
            closeAnim: closeAnim,
            border: border,
            borderCycleMs: borderCycleMs,
            borderWidth: borderWidth,
            shadow: shadow,
            linePets: linePets,
            fontSize: fontSize,
            colors: colors,
            onDismissRoot: { current = nil })
        current = controller
        controller.show()
    }
}

/// One node in the panel tree. Built from the flat `[TomeItem]`
/// list by `PanelTree.build`. `separatorBefore` is carried on
/// `.item` only — folder nodes don't need it because each item that
/// opens a new section keeps its own flag.
///
/// `.placeholder` is used for synthesized disabled rows (e.g. "(no
/// items)" when a dynamic-item expansion's shell command returned
/// nothing). It's NOT in the tree at build time; only injected into
/// expansion results at hover time.
indirect enum PanelNode {
    case item(TomeItem)
    case folder(name: String, children: [PanelNode])
    case placeholder(label: String)

    /// Stable-within-a-session identity for the DnD sort override
    /// (wand#127). Keyed on the display name — two same-named items
    /// at one level share an id and keep their relative order (see
    /// `TomeOrder.apply`). `nil` = the node never participates
    /// in reordering. The id is threaded into each `ItemRow` at
    /// build time so rows and nodes can't drift apart.
    var orderID: String? {
        switch self {
        case .item(let i):             return "item:\(i.name)"
        case .folder(let name, _):     return "folder:\(name)"
        case .placeholder:             return nil
        }
    }
}
