// Row views of the tome panel: `ItemRow` (hover / click / DnD sort
// per `RowKind`) and `TomePetsView` (line-pets on the panel rim).
// `NSTrackingArea` MUST stay `.activeAlways` — wand is LSUIElement
// and the panel never activates, so `.activeInActiveApp` never fires.

import AppKit
import Effects   // LinePet / drawLinePets (shared line-pet drawing; re-exports Palette)
import WandCore

/// Click-through view that paints one or more chomp "pets"
/// (`chomp`, `ghost`) walking the panel's rounded outline. Pets
/// share a single 60 fps timer so the rim doesn't accumulate
/// independent animation loops. Each pet's centre traces `bgFrame`
/// directly; the configured outer margin gives them room to spill
/// past the border. The leader is at the live time `t`; subsequent
/// pets trail by a fixed gap (28 pt) so they read as a chase rather
/// than evenly spaced.
@MainActor
final class TomePetsView: NSView {
    private let startedAt: CFTimeInterval = CACurrentMediaTime()
    private let bgFrameInView: CGRect
    private let cornerRadius: CGFloat
    private let pets: [LinePet]
    /// Scale factor multiplied into every pet's geometry (pellet
    /// radius / ghost dimensions) and the chase gap. Derived from
    /// `[tome.row].font-size` so a larger panel gets proportionally
    /// larger pets — without this, the ghost shrinks visually as the
    /// panel grows.
    private let petScale: CGFloat
    private var timer: Timer?

    /// Travel speed of the chase along the rim. A typical panel
    /// (~250 × 200 pt → perimeter ~900 pt) completes a lap in 5-6 s
    /// at 160 pt/s. Speed stays constant across `petScale` — a
    /// larger pet at the same pt/s reads as "the same pet, just
    /// bigger", not as a slower one.
    private static let petSpeedPtPerSec: CGFloat = 160

    init(frame: NSRect, bgFrameInView: CGRect,
         cornerRadius: CGFloat, pets: [LinePet],
         petScale: CGFloat) {
        self.bgFrameInView = bgFrameInView
        self.cornerRadius = cornerRadius
        self.pets = pets
        self.petScale = petScale
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        translatesAutoresizingMaskIntoConstraints = true
        // 60 fps. Timer holds the block, block captures self weakly
        // — no retain cycle.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60,
                                      repeats: true) { [weak self] _ in
            Task { @MainActor in self?.needsDisplay = true }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Stop the redraw timer when the view leaves its window — covers
    /// panel dismissal cleanly. (`deinit` would have crossed the
    /// main-actor isolation boundary.)
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime() - startedAt
        // Shared sill drawing. The tome rim runs a brisker 160 pt/s and a
        // looser 28*petScale chase than the cast card's defaults; both are
        // passed explicitly so the dedup preserves the prior look exactly.
        drawLinePets(pets, on: bgFrameInView, now: now, scale: petScale,
                     speed: Self.petSpeedPtPerSec, chaseGap: 28 * petScale)
    }

}

/// One row's visual + behavioural kind. `header` is the app-icon
/// banner at top of the root panel; `placeholder` is a disabled row
/// (e.g. "(no items)" inside a dynamic expansion's error path);
/// `leaf` fires onSelect; `folder` opens a child panel on hover with
/// the precomputed children; `dynamic` opens a child panel on hover
/// with children produced by `PanelLayout.expandDynamic` at hover
/// time (i.e. the shell runs only when the user actually opens the
/// submenu).
enum RowKind {
    case header
    /// Inline section header — a labelled band drawn above a run of
    /// items whose `TomeItem.header` shares a value. Distinct from
    /// `.header` (which is the app-icon banner pinned at the top of
    /// the root panel). Non-interactive, smaller height, only used in
    /// `.list` layout.
    case sectionHeader(String)
    case placeholder
    case leaf(TomeItem)
    case folder(name: String, children: [PanelNode])
    case dynamic(TomeItem)
}

/// One clickable tome row. Custom NSView whose layout depends on
/// `layout`:
///
/// - `.list` — fixed-height horizontal strip: icon left, label
///   filling the rest, optional chevron right (for folder/dynamic).
///   Width is set by the panel (constraint to `contentWidth`); hover
///   highlight fills the row corner-to-corner.
/// - `.toolbar` — square icon-only button. Label rendered as a
///   `toolTip` (system shows on hover after a short delay). No
///   chevron in `.toolbar` even for folder/dynamic — the hover
///   behaviour itself signals expandability, and a chevron in a
///   tiny button reads as noise.
///
/// Either way, hover state machine + click handler are identical:
/// `onHover` fires on mouseEntered, `onClick` on mouseUp. The
/// controller decides what the events mean based on `kind`.
@MainActor
final class ItemRow: NSView {

    let kind: RowKind
    let layout: TomeLayout
    /// Session DnD sort identity (`PanelNode.orderID`, threaded in at
    /// build time so rows and nodes can't drift apart). `nil` for
    /// header / section-header / placeholder rows — they never drag.
    let nodeID: String?
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    /// Theme-resolved colours. Defaults to `.none` (every field nil →
    /// system colours). The panel re-applies these after building the
    /// row tree via `applyTheme(_:)`, which kicks `applyIdleStyle` so
    /// theme-tinted idle text takes effect before first paint.
    private var themeColors: TomeColors = .none

    /// Per-row random splatoon ink rolled once when the theme is
    /// applied. Non-nil only under `[tome].theme = "splatoon"` —
    /// every row picks its own colour, and that colour stays put
    /// across every hover until the panel is dismissed (new rows
    /// = new rolls on the next panel-open). When `nil`, the
    /// hover style falls back to `themeColors.accent`.
    private var rowAccent: NSColor?

    func applyTheme(_ colors: TomeColors) {
        themeColors = colors
        rowAccent = colors.accentRandomSplatoon
            ? NSColorParse.randomSplatoonInk()
            : nil
        applyIdleStyle()
    }

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var chevronView: NSImageView?
    /// Right-edge "⌘W"-style display string, derived from the item's
    /// `action-keys` by `KeyCombo.format` when this row was built.
    /// Empty for non-`.key` actions, toolbar layouts, or when the
    /// global `[tome.row].shortcut-badge = false`. Rendered as a
    /// muted-grey label inside `installListLayout` only.
    private let shortcutText: String
    private var shortcutField: NSTextField?
    /// Optional second line under the title. Empty = single-line row
    /// (the existing `listRowHeight`); non-empty bumps the row to
    /// `listRowHeightWithSubtitle` and shows a muted-grey caption.
    /// Toolbar variants ignore this — the `makeItemRow` factory only
    /// passes a non-empty value when `layout == .list`.
    private let subtitleText: String
    private var subtitleField: NSTextField?
    /// SF Symbol animation kind ("bounce" / "pulse" / empty), fired on
    /// `mouseEntered`. macOS 14+ only; older OS silently ignores.
    /// Empty (default) means static icon.
    private let iconAnim: String
    /// Title font size (points). Scales the row's icon size and
    /// height proportionally — the row reads at the user's preferred
    /// text scale rather than truncating. Default 13 matches macOS'
    /// menu baseline; `[tome.row].font-size` overrides it.
    private let fontSize: CGFloat
    /// Per-instance scale factor against the baseline (13 pt). Used
    /// to derive icon box, row height, and `iconRenderPt` so the
    /// whole row grows or shrinks coherently.
    private var fontScale: CGFloat { fontSize / 13.0 }
    /// Bounding box in points for the icon view. The actual rendered
    /// SF Symbol is sized to `iconRenderPt` and scaled `.large`, so it
    /// fills the box optically.
    private var iconSize: CGFloat { round(17 * fontScale) }
    /// Baseline icon render size in points (font-size 13). Non-row
    /// icon callers like the panel header use this directly.
    static let iconRenderPt: CGFloat = IconResolver.baselinePt
    /// Per-row scaled equivalent. Callers with a live row's
    /// `fontSize` in hand pass it here so the icon column scales
    /// with the rest of the row.
    static func iconRenderPt(forFontSize pt: Int) -> CGFloat {
        IconResolver.pt(forFontSize: pt)
    }
    private var listRowHeight: CGFloat { round(26 * fontScale) }
    /// Taller row variant for items that supply a non-empty subtitle.
    /// Scales with `fontSize` like the single-line variant so a tall
    /// `font-size` panel keeps captioned rows proportional to plain
    /// rows.
    private var listRowHeightWithSubtitle: CGFloat {
        round(38 * fontScale)
    }
    /// Section-header band height. Just enough to breathe a small-caps
    /// 10pt label without the band dominating the panel.
    private static let sectionHeaderHeight: CGFloat = 22
    private static let toolbarButtonSide: CGFloat = 34
    /// Height of the labeled-toolbar "pill" button. Tall enough to
    /// breathe with the 17pt icon + menu font, short enough to read
    /// as a chip rather than a row.
    private static let labeledPillHeight: CGFloat = 28
    private static let idleCornerRadius: CGFloat = 4
    private static let hoverCornerRadius: CGFloat = 5

    private let rawLabel: String

    /// Friendly name for `/tmp/wand.log`. In toolbar mode the label
    /// isn't rendered, so we keep the raw string around for logs.
    var titleForLog: String { rawLabel }

    init(kind: RowKind, label: String, icon: NSImage?,
         layout: TomeLayout, shortcut: String = "",
         subtitle: String = "", iconAnim: String = "",
         iconSpec: String = "",
         fontSize: Int = 13,
         nodeID: String? = nil) {
        self.kind = kind
        self.layout = layout
        self.nodeID = nodeID
        self.rawLabel = label
        self.shortcutText = shortcut
        self.subtitleText = subtitle
        self.iconAnim = iconAnim
        self.fontSize = CGFloat(fontSize)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.idleCornerRadius

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = icon
        addSubview(iconView)

        // Remote-icon async swap — when the row was constructed with
        // a spec that resolved to a placeholder pending a network
        // fetch (`favicon:<host>` → SF:globe, or `lucide:<name>` /
        // `phosphor:` / `tabler:` / `heroicons:` → SF:square.dashed),
        // kick off the download and update `iconView.image` in
        // place once it lands. Cache hits are already handled
        // synchronously by `IconResolver`, so this path only fires
        // on the very first sight (or after a 24 h disk-cache
        // expiry). Resize on swap matches the resize the
        // synchronous path applies.
        let pt = IconResolver.pt(forFontSize: Int(self.fontSize))
        if iconSpec.hasPrefix("favicon:"),
           let host = FaviconCache.host(from: iconSpec) {
            FaviconCache.shared.loadOrFetch(host) { [weak self] img in
                guard let self = self, let img = img else { return }
                img.size = NSSize(width: pt, height: pt)
                self.iconView.image = img
            }
        } else if IconSetCache.matches(iconSpec) {
            IconSetCache.shared.loadOrFetch(iconSpec) { [weak self] img in
                guard let self = self, let img = img else { return }
                img.size = NSSize(width: pt, height: pt)
                self.iconView.image = img
            }
        }

        if case .sectionHeader = kind {
            iconView.isHidden = true
            installSectionHeaderLayout(label: label)
        } else {
            switch layout {
            case .list:           installListLayout(label: label)
            case .toolbar:        installToolbarLayout(label: label)
            case .labeledToolbar: installLabeledToolbarLayout(label: label)
            }
        }

        applyIdleStyle()
    }

    /// Splits a long `.list` panel into labelled groups without
    /// stealing space from the items themselves — hence the compact
    /// band rather than a full-height row.
    private func installSectionHeaderLayout(label: String) {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        // Uppercase + small-cap weight reads as a band rather than a
        // row title. Falls back gracefully on locales where uppercase
        // is a no-op (Japanese / CJK section names still render as
        // their original glyphs).
        titleField.stringValue = label.uppercased()
        titleField.font = .systemFont(ofSize: 10, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.sectionHeaderHeight),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                  constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                  constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func installListLayout(label: String) {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = label
        titleField.font = .menuFont(ofSize: fontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        var titleTrailingAnchor = trailingAnchor
        var titleTrailingConst: CGFloat = -10

        let needsChevron: Bool = {
            switch kind {
            case .folder, .dynamic: return true
            case .header, .sectionHeader, .placeholder, .leaf: return false
            }
        }()

        if needsChevron {
            let cv = NSImageView()
            cv.translatesAutoresizingMaskIntoConstraints = false
            cv.image = NSImage(systemSymbolName: "chevron.right",
                                accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(pointSize: 9, weight: .semibold))
            cv.contentTintColor = .secondaryLabelColor
            cv.imageScaling = .scaleProportionallyDown
            addSubview(cv)
            NSLayoutConstraint.activate([
                cv.trailingAnchor.constraint(equalTo: trailingAnchor,
                                              constant: -8),
                cv.centerYAnchor.constraint(equalTo: centerYAnchor),
                cv.widthAnchor.constraint(equalToConstant: 10),
                cv.heightAnchor.constraint(equalToConstant: 10),
            ])
            chevronView = cv
            titleTrailingAnchor = cv.leadingAnchor
            titleTrailingConst = -6
        } else if !shortcutText.isEmpty {
            // Shortcut glyph badge — purely cosmetic, mirrors native
            // NSMenu's right-aligned ⌘W next to a row. Sits where the
            // chevron would, with a muted colour so the row title
            // still reads as the primary content.
            let sf = NSTextField(labelWithString: shortcutText)
            sf.translatesAutoresizingMaskIntoConstraints = false
            sf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            sf.textColor = .tertiaryLabelColor
            sf.alignment = .right
            sf.lineBreakMode = .byTruncatingTail
            sf.maximumNumberOfLines = 1
            sf.cell?.usesSingleLineMode = true
            addSubview(sf)
            NSLayoutConstraint.activate([
                sf.trailingAnchor.constraint(equalTo: trailingAnchor,
                                              constant: -10),
                sf.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            shortcutField = sf
            titleTrailingAnchor = sf.leadingAnchor
            titleTrailingConst = -8
        }

        // With a subtitle the title hangs from the top, but the icon
        // stays centred — otherwise a captioned row's icon baseline
        // drifts away from the plain rows above and below it.
        let hasSubtitle = !subtitleText.isEmpty
        let rowHeight: CGFloat = hasSubtitle
            ? listRowHeightWithSubtitle : listRowHeight

        var verticalConstraints: [NSLayoutConstraint] = []
        if hasSubtitle {
            let sub = NSTextField(labelWithString: subtitleText)
            sub.translatesAutoresizingMaskIntoConstraints = false
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            sub.maximumNumberOfLines = 1
            sub.cell?.usesSingleLineMode = true
            addSubview(sub)
            subtitleField = sub
            verticalConstraints = [
                titleField.topAnchor.constraint(equalTo: topAnchor,
                                                  constant: 4),
                sub.topAnchor.constraint(equalTo: titleField.bottomAnchor,
                                          constant: 1),
                sub.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            ]
        } else {
            verticalConstraints = [
                titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: rowHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                constant: 8),
            titleField.trailingAnchor.constraint(equalTo: titleTrailingAnchor,
                                                  constant: titleTrailingConst),
        ] + verticalConstraints)
    }

    private func installToolbarLayout(label: String) {
        // Tooltip: system shows on hover after a built-in delay. No
        // on-screen label, no chevron — the button is purely the
        // icon's bounding box.
        toolTip = label
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.toolbarButtonSide),
            heightAnchor.constraint(equalToConstant: Self.toolbarButtonSide),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize + 2),
            iconView.heightAnchor.constraint(equalToConstant: iconSize + 2),
        ])
    }

    private func installLabeledToolbarLayout(label: String) {
        // Horizontal "pill" button: icon left, label right. Same
        // tooltip as icon-only toolbar so a user hovering still gets
        // the full name on accessibility readers. Width is intrinsic
        // — the stack lets each pill size to its label.
        toolTip = label

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = label
        titleField.font = .menuFont(ofSize: fontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.labeledPillHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            titleField.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var isInteractive: Bool {
        switch kind {
        case .leaf, .folder, .dynamic: return true
        case .header, .sectionHeader, .placeholder: return false
        }
    }

    private func applyIdleStyle() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Self.idleCornerRadius
        // Theme idle text overrides only the regular interactive row
        // text — headers / section bands / placeholders keep their
        // quieter system semantics so the visual hierarchy survives.
        let themedText = themeColors.text
        switch kind {
        case .header:
            titleField.textColor = .secondaryLabelColor
        case .sectionHeader:
            titleField.textColor = .tertiaryLabelColor
        case .placeholder:
            titleField.textColor = .tertiaryLabelColor
        case .leaf, .folder, .dynamic:
            titleField.textColor = themedText ?? .labelColor
        }
        subtitleField?.textColor = .secondaryLabelColor
        shortcutField?.textColor = .tertiaryLabelColor
        chevronView?.contentTintColor = .secondaryLabelColor
        // Toolbar variants: tint SF Symbol icons in `.labelColor`
        // so they read as text-level contrast rather than the
        // default grey. No effect on .icns / emoji rendered icons.
        if layout != .list {
            iconView.contentTintColor = isInteractive
                ? (themedText ?? .labelColor) : .tertiaryLabelColor
        }
    }

    private func applyHoverStyle() {
        // Fully-opaque accent so the hovered row reads as THE
        // selection target, with no risk of being washed out by the
        // vibrancy underneath. Under the splatoon theme each row
        // carries its own ink (`rowAccent`) rolled in `applyTheme`,
        // and that ink stays stable until the panel closes — only
        // the next panel-open rerolls. Text colour adapts to the
        // row's ink luma when the palette didn't pin a value.
        let accent = rowAccent ?? themeColors.accent ?? .controlAccentColor
        let accentText: NSColor
        if let ink = rowAccent {
            accentText = themeColors.accentText ?? TomeColors.legibleText(on: ink)
        } else {
            accentText = themeColors.accentText ?? .white
        }
        layer?.backgroundColor = accent.cgColor
        layer?.cornerRadius = Self.hoverCornerRadius
        titleField.textColor = accentText
        chevronView?.contentTintColor = accentText
        // Subtitle / shortcut badges share the row with the title, so
        // they flip alongside it — otherwise muted greys read as
        // smudged on the accent fill. Use 85% alpha for the same
        // visual hierarchy idle had with `secondary` / `tertiary`.
        subtitleField?.textColor = accentText.withAlphaComponent(0.85)
        shortcutField?.textColor = accentText.withAlphaComponent(0.85)
        if layout != .list {
            iconView.contentTintColor = accentText
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        // `.activeAlways` is mandatory here — wand is LSUIElement +
        // the panel is non-activating, so `.activeInActiveApp` would
        // resolve to "never" and mouseEntered would never fire (which
        // is why hover-to-expand silently failed in the first cut).
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways,
                      .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive else { return }
        applyHoverStyle()
        playIconAnim()
        onHover?()
    }

    /// Fire the configured SF Symbol effect on the icon. Unknown effect
    /// strings log + skip.
    private func playIconAnim() {
        guard !iconAnim.isEmpty, iconView.image != nil else { return }
        switch iconAnim.lowercased() {
        case "bounce":
            iconView.addSymbolEffect(.bounce, options: .nonRepeating,
                                      animated: true)
        case "pulse":
            iconView.addSymbolEffect(.pulse, options: .nonRepeating,
                                      animated: true)
        default:
            Log.line("tome-panel: unknown icon-anim \"\(iconAnim)\" "
                     + "(supported: bounce, pulse) — skipped")
        }
    }

    override func mouseExited(with event: NSEvent) {
        applyIdleStyle()
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        guard isInteractive else { return }
        onClick?()
    }

    /// Private in-app pasteboard type marking a tome-row drag. The
    /// payload (the row's `nodeID`) is informational — drop handling
    /// resolves the source row via `draggingSource` identity so
    /// duplicate-named rows can't cross wires.
    static let reorderType =
        NSPasteboard.PasteboardType("com.wand.wand.tome-row")

    /// Set by `PanelController` on reorderable rows only (`.list`
    /// layout + a live `onReorder` sink + non-nil `nodeID`). Fires
    /// with (source row, target row = self, insert-after) when a
    /// drop lands on this row.
    private var reorderDrop: ((ItemRow, ItemRow, Bool) -> Void)?
    /// Button-down point (window coords) armed in `mouseDown`; a
    /// drag past a small hysteresis starts the dragging session.
    /// Cleared on mouseUp so a plain click stays a click.
    private var dragOrigin: NSPoint?
    /// 2 pt accent insertion line shown while a compatible drag
    /// hovers this row — top edge = "insert above", bottom edge =
    /// "insert below". Lazily created, hidden between drags.
    private var dropIndicator: CALayer?

    func enableReorder(
        _ onDrop: @escaping (ItemRow, ItemRow, Bool) -> Void) {
        reorderDrop = onDrop
        registerForDraggedTypes([Self.reorderType])
    }

    override func mouseDown(with event: NSEvent) {
        guard reorderDrop != nil else {
            // Non-reorderable rows keep NSView's default next-
            // responder propagation — only drag-source rows hold the
            // event back to arm the hysteresis check.
            super.mouseDown(with: event)
            return
        }
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let nodeID else { return }
        let dx = event.locationInWindow.x - origin.x
        let dy = event.locationInWindow.y - origin.y
        guard dx * dx + dy * dy > 16 else { return }  // 4 pt hysteresis
        dragOrigin = nil
        let pb = NSPasteboardItem()
        pb.setString(nodeID, forType: Self.reorderType)
        let item = NSDraggingItem(pasteboardWriter: pb)
        item.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// Row snapshot used as the drag image, so the user drags a
    /// faithful copy of the row instead of a generic ghost.
    private func snapshotImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }

    // Destination side — every reorderable row is also a drop target.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideDropIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropIndicator()
        guard let drop = reorderDrop,
              let source = sender.draggingSource as? ItemRow,
              source !== self else { return false }
        drop(source, self, isLowerHalf(sender))
        return true
    }

    private func updateDropIndicator(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard reorderDrop != nil,
              let source = sender.draggingSource as? ItemRow,
              source !== self else {
            hideDropIndicator()
            return []
        }
        showDropIndicator(below: isLowerHalf(sender))
        return .move
    }

    private func hideDropIndicator() {
        dropIndicator?.isHidden = true
    }

    /// Non-flipped view: smaller y = visually lower. Lower half →
    /// insert AFTER (below) this row.
    private func isLowerHalf(_ sender: NSDraggingInfo) -> Bool {
        convert(sender.draggingLocation, from: nil).y < bounds.midY
    }

    private func showDropIndicator(below: Bool) {
        let line: CALayer
        if let existing = dropIndicator {
            line = existing
        } else {
            line = CALayer()
            line.cornerRadius = 1
            line.zPosition = 10
            // Standalone CALayer: kill the implicit ~0.25 s
            // animations, or the line eases behind every drag-move
            // event instead of tracking the cursor.
            line.actions = ["frame": NSNull(), "position": NSNull(),
                            "bounds": NSNull(), "hidden": NSNull(),
                            "backgroundColor": NSNull()]
            layer?.addSublayer(line)
            dropIndicator = line
        }
        // Same accent resolution as the hover highlight so the two
        // drag affordances agree under a `[tome].theme`.
        let accent = rowAccent ?? themeColors.accent ?? .controlAccentColor
        line.backgroundColor = accent.cgColor
        line.frame = CGRect(x: 4, y: below ? 0 : bounds.height - 2,
                            width: bounds.width - 8, height: 2)
        line.isHidden = false
    }
}

// NSDraggingSource — nonisolated to satisfy the protocol regardless
// of the SDK's isolation annotations; AppKit calls these on the main
// thread, so `assumeIsolated` is safe where row state is touched.
extension ItemRow: NSDraggingSource {
    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     willBeginAt screenPoint: NSPoint) {
        MainActor.assumeIsolated { alphaValue = 0.5 }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        // Restore idle style too: the drag session swallows mouse
        // events, so the tracking area's mouseExited never fires and
        // the source row would otherwise keep its hover accent.
        MainActor.assumeIsolated {
            alphaValue = 1
            applyIdleStyle()
        }
    }
}
