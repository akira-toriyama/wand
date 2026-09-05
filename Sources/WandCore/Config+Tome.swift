// The `[tome]` half of the config surface: `parseTome` (panel knobs,
// items, dead-config + trigger-collision warnings), the standalone
// `--items` file parser, the per-row item / template parse, and the
// `configSpec` sections that describe them.

import ConfigSchema
import Foundation
import Palette
import Toml

extension WandConfig {
    /// Parse a TOML document containing `[[tome.cursor.item]]` entries
    /// (and optionally `[tome].layout`) — the schema `wand
    /// tome --open --items <PATH>` expects. Same row-level
    /// validation as `[tome]` items in the main config (drop on
    /// missing name / invalid action, with a loud log line), so a
    /// client that screws up the file gets a diagnostic.
    ///
    /// The items file's `[tome].layout` declaration is what
    /// controls the visual orientation for this particular show-menu
    /// call — independent of `~/.config/wand/config.toml`'s
    /// `[tome].layout` (which only applies to the native middle-
    /// click trigger). Default `.list` when missing or unknown.
    ///
    /// The legacy `[[tome.item]]` header logs + drops; the user must
    /// rename to `[[tome.cursor.item]]` (the namespace explicit form
    /// that pairs symmetrically with `[[cast.cursor.rule]]`).
    public static func parseItems(_ text: String) -> TomeItemsFile {
        let doc = Toml.parseFlat(text)
        let lr = doc.tables["tome"] ?? [:]
        let layout: TomeLayout = parseEnum(
            lr, key: "layout", section: "tome", default: .list)
        warnLegacyTomeItem(doc, scope: "--items file")
        let items: [TomeItem] = (doc.arrays["tome.cursor.item"] ?? []).enumerated()
            .compactMap { idx, row in parseItem(row, idx: idx) }
        warnToolbarOnlyFields(items: items, layout: layout)
        return TomeItemsFile(layout: layout, items: items)
    }

    /// `[tome]` and its sub-blocks + `[[tome.cursor.item]]`, ending in
    /// the trigger-collision check against `castTrigger` (declaration
    /// order wins: cast keeps the button, tome is demoted).
    static func parseTome(_ doc: TOMLDocument, _ d: Decoded,
                          castTrigger: Trigger) -> TomeSpec {
        // [tome.*] — middle-click (or other configured button) menu.
        // Tap not installed when `enabled = false` (default). The plain
        // scalar/table keys come from the spec decode; the items
        // array-of-tables + trigger collision stay bespoke below.
        let tomeEnabled = d.tomeEnabled
        let tomeButton = d.tomeButton
        let tomeMods = d.tomeModifiers
        let tomeLayout = d.tomeLayout
        let tomeTheme = d.tomeTheme

        // [tome.row] — per-row visual cosmetics.
        let tomeRow = TomeRowSpec(
            shortcutBadge: d.rowShortcutBadge,
            iconChip: d.rowIconChip,
            fontSize: d.rowFontSize)

        // [tome.animation]
        let tomeAnimOpen = d.animOpen
        let tomeAnimClose = d.animClose
        let tomeAnimation = TomeAnimationSpec(
            open: tomeAnimOpen, close: tomeAnimClose)

        // [tome.decoration] + [tome.decoration.border] — panel statics +
        // the border rim (the family block shape shared with facet/halo
        // [border] and perch [overlay.border]).
        let tomeDecorBorder = d.decorBorder
        let tomeDecoration = TomeDecorationSpec(
            border: tomeDecorBorder,
            cycleMs: d.decorCycleMs,
            borderWidth: d.decorBorderWidth,
            shadow: d.decorShadow,
            linePets: d.decorLinePets)

        // Warn when the user opted out of tome but still
        // configured non-default panel cosmetics — those only fire
        // when a panel actually opens, so they're dead config until
        // `[tome].enabled = true`. Default values stay silent;
        // the log lists exactly what's dead. Skipped when tome
        // is enabled — the collision check below handles demotion.
        if !tomeEnabled {
            var nonDefault: [String] = []
            if tomeAnimOpen != .off {
                nonDefault.append("[tome.animation].open = \"\(tomeAnimOpen.rawValue)\"")
            }
            if tomeAnimClose != .off {
                nonDefault.append("[tome.animation].close = \"\(tomeAnimClose.rawValue)\"")
            }
            if tomeDecorBorder != .off {
                nonDefault.append("[tome.decoration.border].effect = \"\(tomeDecorBorder.rawValue)\"")
            }
            if !nonDefault.isEmpty {
                Log.line("config: \(nonDefault.joined(separator: ", "))"
                    + " is set but [tome].enabled = false — these"
                    + " knobs only fire when a tome panel actually"
                    + " opens. Either set [tome].enabled = true,"
                    + " or remove the offending lines.")
            }
        }

        // [[tome.cursor.item]] — tome rows. Same drop-on-typo
        // policy as [[cast.cursor.rule]]: bad rows surface in the log
        // with their position. Legacy `[[tome.item]]` header is
        // detected and warned out via `warnLegacyTomeItem` so users
        // notice the breaking rename instead of silently losing every
        // menu row.
        warnLegacyTomeItem(doc, scope: "config")
        let items: [TomeItem] = (doc.arrays["tome.cursor.item"] ?? []).enumerated()
            .compactMap { idx, row in parseItem(row, idx: idx) }
        warnToolbarOnlyFields(items: items, layout: tomeLayout)

        // Trigger collision detection.
        // Two trigger families sharing the same (button, modifiers)
        // would have their CGEventTaps fight over the same down
        // event. Declaration-order wins (gesture > tome > future
        // families); the loser is forced enabled = false. A different
        // button OR a non-empty modifier difference resolves it.
        let tomeTrigger = Trigger(button: tomeButton,
                                       modifiers: tomeMods)
        var effectiveTomeEnabled = tomeEnabled
        if tomeEnabled && tomeTrigger == castTrigger {
            Log.line("config: [tome].button = \"\(tomeButton.rawValue)\""
                + " + modifiers=\(modifierList(tomeMods)) collides"
                + " with [cast] — [tome] disabled for this"
                + " session. Pick a distinct button, or add a"
                + " modifier (e.g. `modifiers = [\"ctrl\"]`) to one"
                + " side. (Declaration-order policy: gesture wins,"
                + " later families lose.)")
            effectiveTomeEnabled = false
        }

        let tome = TomeSpec(
            enabled: effectiveTomeEnabled,
            trigger: tomeTrigger,
            layout: tomeLayout,
            items: items,
            row: tomeRow,
            animation: tomeAnimation,
            decoration: tomeDecoration,
            theme: tomeTheme)
        return tome
    }

    /// Detect the legacy `[[tome.item]]` header and emit a loud
    /// warning per row — every row is dropped. Users must rename to
    /// `[[tome.cursor.item]]`. `scope` is "config" for the main
    /// daemon config and "--items file" for `tome --open --items`.
    private static func warnLegacyTomeItem(_ doc: TOMLDocument,
                                            scope: String) {
        guard let rows = doc.arrays["tome.item"], !rows.isEmpty
        else { return }
        Log.line("config: [[tome.item]] is no longer supported "
                 + "in the \(scope) (\(rows.count) row(s) dropped). "
                 + "Rename each row to `[[tome.cursor.item]]` — the "
                 + "namespace-explicit form that pairs symmetrically "
                 + "with `[[cast.cursor.rule]]` and leaves room for "
                 + "future `[[tome.<modifier>.item]]` namespaces.")
    }

    /// Warn once per row when an item carries fields that only render
    /// in `[tome].layout = "list"`. Toolbar variants are short
    /// horizontal strips with no room for a section header, a 2nd-line
    /// subtitle, or a row separator — those fields parse cleanly but
    /// never appear, leaving dead config in the file.
    ///
    /// `shortcut-badge` at `[tome]` level is intentionally not
    /// surfaced here: it's a global default with a true/false value
    /// that doesn't change toolbar's behaviour either way, so warning
    /// about it would just add noise.
    private static func warnToolbarOnlyFields(items: [TomeItem],
                                               layout: TomeLayout) {
        guard layout != .list else { return }
        for (idx, item) in items.enumerated() {
            var ignored: [String] = []
            if !item.header.isEmpty {
                ignored.append("`header = \"\(item.header)\"`")
            }
            if !item.subtitle.isEmpty {
                ignored.append("`subtitle = \"\(item.subtitle)\"`")
            }
            if item.separatorBefore {
                ignored.append("`separator-before = true`")
            }
            guard !ignored.isEmpty else { continue }
            let label = "[[item]][\(idx)]"
                + (item.name.isEmpty ? "" : " \(item.name)")
            Log.line("config: \(label) — "
                + "\(ignored.joined(separator: ", ")) only apply to"
                + " `[tome].layout = \"list\"`. Current layout is"
                + " \"\(layout.rawValue)\", so these fields are"
                + " ignored.")
        }
    }

    /// Render a Modifier set as a stable, sorted, bracketed string
    /// for log lines — `[]` for empty, `["cmd", "shift"]` for two.
    /// Sort by rawValue so the same set always renders the same way
    /// (Swift's Set has no inherent order, and log diffability beats
    /// the natural-language order).
    private static func modifierList(_ mods: Set<Modifier>) -> String {
        if mods.isEmpty { return "[]" }
        let names = mods.map(\.rawValue).sorted()
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        return "[\(names)]"
    }

    /// Row-level parse for a single `[[item]]`. Shared by the
    /// `[tome]` items inside the main config and by
    /// `parseItems(_:)` for the `tome --open --items <PATH>` path.
    private static func parseItem(_ row: [String: TOMLValue], idx: Int)
        -> TomeItem? {
        let label = "[[item]][\(idx)]"
            + (row.string("name").isEmpty ? "" : " \(row.string("name"))")
        let name = row.string("name")
        guard !name.isEmpty else {
            Log.line("config: dropped \(label) — `name` is required "
                     + "(it's the menu label)")
            return nil
        }
        let dynamic = row.string("dynamic")
        let action: Action
        let template: TomeTemplate?
        if dynamic.isEmpty {
            // Static item — need a regular action.
            template = nil
            guard let parsed = parseAction(row) else {
                Log.line("config: dropped \(label) — invalid or missing "
                         + "action (need action-type + matching "
                         + "action-keys / action-verb / action-cmd / "
                         + "action-url)")
                return nil
            }
            action = parsed
        } else {
            // Dynamic producer — needs a template for children. The
            // parent's own `action` is unused (a sentinel keeps the
            // type total — `.shell("")` doubles as a no-op marker;
            // expansion paths never call it).
            //
            // Warn if the user also set action-* / state fields on
            // the parent: those rows parse cleanly but are silently
            // dropped because the dynamic branch renders the parent
            // as a folder (no action, no selectability), and the
            // dynamic-folder render path bypasses `renderItemLabel`
            // entirely (so `state = "on"` / `state = "shell:..."`
            // never produces a checkmark or runs the shell).
            //
            // `[[cast.cursor.rule]]` drops + logs on bad action; the
            // dynamic-tome parent keeps working but tells the
            // user exactly which lines are dead.
            var strayDynamicFields: [String] = [
                "action-type", "action-keys", "action-verb",
                "action-cmd", "action-url",
            ].filter { !row.string($0).isEmpty }
            if !row.string("state").isEmpty {
                strayDynamicFields.append("state")
            }
            if !strayDynamicFields.isEmpty {
                Log.line("config: \(label) — `dynamic` is set, so the"
                    + " parent's own "
                    + "\(strayDynamicFields.joined(separator: " / "))"
                    + " is ignored (the row renders as a folder for"
                    + " the dynamic children, not as a selectable"
                    + " leaf). Remove these lines from this row to"
                    + " silence this warning.")
            }
            guard let t = parseTemplate(row) else {
                Log.line("config: dropped \(label) — `dynamic` is set "
                         + "but no valid template-* fields found "
                         + "(need template-action-type + matching "
                         + "template-action-keys / template-action-verb / "
                         + "template-action-cmd / template-action-url)")
                return nil
            }
            template = t
            action = .shell("")  // unused for dynamic items
        }
        let apps = row.strings("apps")
        let group = row.strings("group")
        let sep = row.bool("separator-before", false)
        let header = row.string("header")
        let subtitle = row.string("subtitle")
        let icon = row.string("icon")
        let tint = row.string("tint")
        let tintColors = row.strings("tint-colors")
        let iconAnim = row.string("icon-anim")
        let filterTitle = row.string("filter-title")
        let filterShell = row.string("filter-shell")
        let state = row.string("state")

        // `icon-anim` / `tint` / `tint-colors` only apply to SF
        // Symbol icons — the adapter's symbol-effect and palette
        // paths gate on the `SF:` prefix, so an emoji / file path /
        // `app:` icon (or no icon at all) silently ignores them.
        // Warn once per offending row so the dead config is visible
        // in the log. Default-empty fields stay silent.
        if !icon.hasPrefix("SF:") {
            var ignored: [String] = []
            if !iconAnim.isEmpty {
                ignored.append("icon-anim = \"\(iconAnim)\"")
            }
            if !tint.isEmpty {
                ignored.append("tint = \"\(tint)\"")
            }
            if !tintColors.isEmpty {
                ignored.append("tint-colors = "
                    + "[\(tintColors.map { "\"\($0)\"" }.joined(separator: ", "))]")
            }
            if !ignored.isEmpty {
                let iconDescription = icon.isEmpty
                    ? "no icon set"
                    : "a non-SF-Symbol icon (\"\(icon)\")"
                Log.line("config: \(label) — "
                    + "\(ignored.joined(separator: ", ")) only apply"
                    + " to SF Symbol icons (icon = \"SF:...\")."
                    + " Current item has \(iconDescription), so"
                    + " these fields are ignored.")
            }
        }
        return TomeItem(
            name: name, group: group, separatorBefore: sep,
            apps: apps.isEmpty ? ["*"] : apps,
            header: header,
            subtitle: subtitle,
            icon: icon,
            tint: tint,
            tintColors: tintColors,
            iconAnim: iconAnim,
            filterTitle: filterTitle, filterShell: filterShell,
            state: state,
            dynamic: dynamic, template: template,
            action: action)
    }

    /// Parse the `template-*` block — sibling of `parseAction` but
    /// reads from `template-action-type` etc., and keeps the body as
    /// a raw string (it may contain `{line}` placeholders that the
    /// adapter substitutes at expansion time).
    private static func parseTemplate(_ row: [String: TOMLValue])
        -> TomeTemplate? {
        let kindRaw = row.string("template-action-type").lowercased()
        guard let kind = TomeTemplate.Kind(rawValue: kindRaw)
        else { return nil }
        let payload: String
        switch kind {
        case .key:   payload = row.string("template-action-keys")
        case .ax:
            let verb = row.string("template-action-verb").lowercased()
            guard Action.axVerbs.contains(verb) || verb.contains("{line}")
            else { return nil }
            payload = verb
        case .shell: payload = row.string("template-action-cmd")
        case .url:   payload = row.string("template-action-url")
        }
        guard !payload.isEmpty else { return nil }
        let name = row.string("template-name")
        return TomeTemplate(
            kind: kind,
            payload: payload,
            name: name.isEmpty ? "{line}" : name,
            icon: row.string("template-icon"))
    }

    /// `[tome]` … `[tome.decoration.border]` — the order `configSpec` emits them.
    static var tomeSpecSections: [ConfigSchema.Section<Decoded>] {
        [
            .init("tome",
                  doc: "Tome trigger (a button-press pops a contextual "
                     + "menu) + layout + theme.",
                  fields: [
                .bool("enabled", \.tomeEnabled, default: false,
                      doc: "Install the tome tap. `false` = no menu "
                         + "(restart to flip)."),
                .button("button", \.tomeButton, default: .middle,
                        doc: "Mouse button that pops the menu."),
                .modifiers("modifiers", \.tomeModifiers,
                           doc: "Modifiers held with the button; `[]` = none. "
                              + "Must differ from `[cast]` or the tome is "
                              + "demoted (collision)."),
                .enumField("layout", \.tomeLayout, section: "tome",
                           domain: TomeLayout.allCases.map(\.rawValue),
                           default: .list,
                           doc: "Panel orientation for the native trigger."),
                .theme("theme", \.tomeTheme,
                       doc: "Tome panel theme (independent of `[cast].theme`); "
                          + "`\"\"` = native `system`."),
            ]),

            .init("tome.row",
                  doc: "Per-row visual conventions applied to every item.",
                  fields: [
                .bool("shortcut-badge", \.rowShortcutBadge, default: true,
                      doc: "Auto `⌘W`-style glyph badge on `.list` key rows."),
                .bool("icon-chip", \.rowIconChip, default: true,
                      doc: "Rounded chip behind emoji / text-glyph icons."),
                .clampInt("font-size", \.rowFontSize, min: 11, max: 32,
                          default: 13,
                          doc: "Title font size (px); drives row height. "
                             + "Clamped 11..32."),
            ]),

            .init("tome.animation",
                  doc: "Panel open / close transitions.",
                  fields: [
                .enumField("open", \.animOpen, section: "tome.animation",
                           domain: TomeOpenAnim.allCases.map(\.rawValue),
                           default: .off, doc: "Open animation; `off` = instant."),
                .enumField("close", \.animClose, section: "tome.animation",
                           domain: TomeCloseAnim.allCases.map(\.rawValue),
                           default: .off, doc: "Close animation; `off` = instant."),
            ]),

            .init("tome.decoration",
                  doc: "Static panel decoration (shadow + line-pets); the "
                     + "border rim is its own sub-block.",
                  fields: [
                .bool("shadow", \.decorShadow, default: false,
                      doc: "macOS window drop shadow under the panel."),
                .linePets("line-pets", \.decorLinePets,
                          doc: "Arcade pets walking the panel outline; "
                             + "`[]` = none."),
            ]),

            .init("tome.decoration.border",
                  doc: "Decorative border rim (effect / width / cycle).",
                  fields: [
                .enumField("effect", \.decorBorder,
                           section: "tome.decoration.border",
                           domain: TomeBorder.allCases.map(\.rawValue),
                           default: .off,
                           doc: "Border decoration; `off` = no rim."),
                .clampInt("color-cycle-ms", \.decorCycleMs, min: 500, max: 10000,
                          default: 4000,
                          doc: "Cycle period (ms) for the `rainbow` outline. "
                             + "Clamped 500..10000."),
                .clampInt("width", \.decorBorderWidth, min: 1, max: 10,
                          default: 2,
                          doc: "Border stroke width (px). Clamped 1..10."),
            ]),

            // Schema-only below — wand decodes these bespoke.
        ]
    }

    /// `[[tome.cursor.item]]` (schema-only rows).
    static var tomeItemSpecSections: [ConfigSchema.Section<Decoded>] {
        [
            .init("tome.cursor.item", kind: .arrayOfTables,
                  doc: "One tome menu row.",
                  fields: tomeItemFields),
        ]
    }

    /// `[[tome.cursor.item]]` row shape — schema-only (wand parses these
    /// from the raw array-of-tables with per-row drop-on-typo). Covers
    /// the static-action, dynamic-producer, and presentation fields.
    private static var tomeItemFields: [ConfigSchema.Field<Decoded>] {
        [
            .descOnly("name", doc: "Menu label (required)."),
            .descArray("group", doc: "Parent submenu path; empty = top level."),
            .descOnly("separator-before", .boolean,
                      doc: "Draw a separator above this row."),
            .descArray("apps", doc: "Bundle-id globs; empty = `[\"*\"]`."),
            .descOnly("header",
                      doc: "Section header (`.list` layout only)."),
            .descOnly("subtitle",
                      doc: "Second line under the name (`.list` layout only)."),
            .descOnly("icon", doc: "Icon spec (SF: / emoji / path / app:)."),
            .descOnly("tint", doc: "SF Symbol tint colour (named / hex)."),
            .descArray("tint-colors",
                       doc: "SF Symbol multi-colour palette."),
            .descOnly("icon-anim",
                      doc: "SF Symbol hover animation (`bounce` / `pulse`)."),
            .descOnly("filter-title", doc: "Title-glob filter."),
            .descOnly("filter-shell", doc: "Shell predicate (exit 0 keeps)."),
            .descOnly("state",
                      doc: "Checkmark spec (`on` / `off` / `mixed` / "
                         + "`shell:<cmd>`)."),
            .descOnly("dynamic",
                      doc: "Shell command whose stdout lines become child "
                         + "rows (folder producer)."),
            .descOnly("action-type",
                      domain: ["key", "ax", "shell", "url"],
                      doc: "Static-row action kind."),
            .descOnly("action-keys"),
            .descOnly("action-verb", domain: Array(Action.axVerbs).sorted()),
            .descOnly("action-cmd"),
            .descOnly("action-url"),
            .descOnly("template-action-type",
                      domain: ["key", "ax", "shell", "url"],
                      doc: "Child-row action kind for a `dynamic` item."),
            .descOnly("template-action-keys"),
            .descOnly("template-action-verb"),
            .descOnly("template-action-cmd"),
            .descOnly("template-action-url"),
            .descOnly("template-name", doc: "Child label template ({line})."),
            .descOnly("template-icon", doc: "Child icon template ({line})."),
        ]
    }
}
