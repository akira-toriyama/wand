// Tome model + `[[tome.cursor.item]]` row parse. Pins what the adapter
// relies on without re-deriving it: item defaults, the group path
// arriving as an ordered array, `{line}` surviving the parse verbatim
// (substitution is the adapter's job, `PanelLayout.expandDynamic`),
// and the per-row drop rules. Layout / DnD order have their own files.

import XCTest
@testable import WandCore

final class TomeTests: XCTestCase {

    // MARK: model defaults

    func testItemInitDefaultsMatchAnOmittedRow() {
        // The memberwise defaults are what a minimal TOML row resolves
        // to; a drift here would silently change every parsed item.
        let item = TomeItem(name: "X", action: .key("cmd+x"))
        XCTAssertEqual(item.group, [])
        XCTAssertFalse(item.separatorBefore)
        XCTAssertEqual(item.apps, ["*"])
        XCTAssertEqual(item.header, "")
        XCTAssertEqual(item.subtitle, "")
        XCTAssertEqual(item.icon, "")
        XCTAssertEqual(item.tint, "")
        XCTAssertEqual(item.tintColors, [])
        XCTAssertEqual(item.iconAnim, "")
        XCTAssertEqual(item.filterTitle, "")
        XCTAssertEqual(item.filterShell, "")
        XCTAssertEqual(item.state, "")
        XCTAssertEqual(item.dynamic, "")
        XCTAssertNil(item.template)
    }

    func testSpecDefaultIsDisabledMiddleClickList() {
        let spec = TomeSpec.default
        XCTAssertFalse(spec.enabled)
        XCTAssertEqual(spec.trigger, Trigger(button: .middle, modifiers: []))
        XCTAssertEqual(spec.layout, .list)
        XCTAssertEqual(spec.items, [])
        XCTAssertEqual(spec.row, .default)
        XCTAssertEqual(spec.animation, .default)
        XCTAssertEqual(spec.decoration, .default)
        XCTAssertEqual(spec.theme, wandDefaultThemeName)
    }

    func testLayoutOrientationAndRawValues() {
        // `isHorizontal` decides where child panels open (right for
        // list, below for both toolbars); the raw value of the
        // hyphenated case is the TOML spelling.
        XCTAssertFalse(TomeLayout.list.isHorizontal)
        XCTAssertTrue(TomeLayout.toolbar.isHorizontal)
        XCTAssertTrue(TomeLayout.labeledToolbar.isHorizontal)
        XCTAssertEqual(TomeLayout(rawValue: "labeled-toolbar"), .labeledToolbar)
        XCTAssertEqual(TomeLayout.allCases.count, 3)
    }

    // MARK: row parse — shape

    func testGroupPathIsPreservedInOrder() {
        // The adapter builds folders by walking `group` top-down; a
        // resort or flatten here would move rows between submenus.
        let file = WandConfig.parseItems("""
        [[tome.cursor.item]]
        name = "Deep"
        group = ["Edit", "Advanced", "More"]
        action-type = "key"
        action-keys = "cmd+d"

        [[tome.cursor.item]]
        name = "Top"
        action-type = "key"
        action-keys = "cmd+t"
        """)
        XCTAssertEqual(file.items.map(\.group),
                       [["Edit", "Advanced", "More"], []])
    }

    func testPresentationFieldsRoundTrip() {
        let file = WandConfig.parseItems("""
        [[tome.cursor.item]]
        name = "Full"
        separator-before = true
        apps = ["com.apple.Safari", "com.google.Chrome"]
        header = "Web"
        subtitle = "opens the page"
        icon = "SF:globe"
        tint = "accent"
        tint-colors = ["#ff0000", "systemBlue"]
        icon-anim = "bounce"
        filter-title = "*GitHub*"
        filter-shell = "test -d ~/src"
        state = "shell:true"
        action-type = "url"
        action-url = "https://example.com"
        """)
        XCTAssertEqual(file.items, [TomeItem(
            name: "Full", separatorBefore: true,
            apps: ["com.apple.Safari", "com.google.Chrome"],
            header: "Web", subtitle: "opens the page",
            icon: "SF:globe", tint: "accent",
            tintColors: ["#ff0000", "systemBlue"], iconAnim: "bounce",
            filterTitle: "*GitHub*", filterShell: "test -d ~/src",
            state: "shell:true",
            action: .url("https://example.com"))])
    }

    func testEmptyAppsBecomesMatchAll() {
        // `apps = []` and an omitted key both mean "any app" — the
        // matcher never sees an empty glob list.
        let file = WandConfig.parseItems("""
        [[tome.cursor.item]]
        name = "A"
        apps = []
        action-type = "key"
        action-keys = "cmd+a"

        [[tome.cursor.item]]
        name = "B"
        action-type = "key"
        action-keys = "cmd+b"
        """)
        XCTAssertEqual(file.items.map(\.apps), [["*"], ["*"]])
    }

    func testItemsFileLayoutDefaultsToListOnMissingOrUnknown() {
        let missing = WandConfig.parseItems("""
        [[tome.cursor.item]]
        name = "A"
        action-type = "key"
        action-keys = "cmd+a"
        """)
        XCTAssertEqual(missing.layout, .list)
        let unknown = WandConfig.parseItems("""
        [tome]
        layout = "carousel"
        """)
        XCTAssertEqual(unknown.layout, .list)
        XCTAssertEqual(unknown.items, [])
        let toolbar = WandConfig.parseItems("""
        [tome]
        layout = "labeled-toolbar"
        """)
        XCTAssertEqual(toolbar.layout, .labeledToolbar)
    }

    // MARK: row parse — drop rules

    func testRowsWithoutNameOrActionDropButNeighboursSurvive() {
        let file = WandConfig.parseItems("""
        [[tome.cursor.item]]
        action-type = "key"
        action-keys = "cmd+1"

        [[tome.cursor.item]]
        name = "No action"

        [[tome.cursor.item]]
        name = "Bad verb"
        action-type = "ax"
        action-verb = "explode"

        [[tome.cursor.item]]
        name = "Keeper"
        action-type = "ax"
        action-verb = "close"
        """)
        XCTAssertEqual(file.items.map(\.name), ["Keeper"])
        XCTAssertEqual(file.items.first?.action, .ax("close"))
    }

    // MARK: dynamic items + templates

    func testDynamicItemKeepsTemplateRawAndUsesSentinelAction() {
        // `{line}` must reach the adapter untouched — it is the
        // substitution key — and the parent's action is the `.shell("")`
        // sentinel that expansion never runs.
        let file = WandConfig.parseItems("""
        [[tome.cursor.item]]
        name = "Recent"
        dynamic = "ls -t ~/Documents | head -5"
        template-action-type = "shell"
        template-action-cmd = "open \\"{line}\\""
        template-name = "Open {line}"
        template-icon = "SF:doc"
        """)
        XCTAssertEqual(file.items.count, 1)
        let item = file.items[0]
        XCTAssertEqual(item.dynamic, "ls -t ~/Documents | head -5")
        XCTAssertEqual(item.action, .shell(""))
        XCTAssertEqual(item.template, TomeTemplate(
            kind: .shell, payload: "open \"{line}\"",
            name: "Open {line}", icon: "SF:doc"))
    }

    func testTemplateNameDefaultsToLinePlaceholder() {
        let file = WandConfig.parseItems("""
        [[tome.cursor.item]]
        name = "Tabs"
        dynamic = "echo a; echo b"
        template-action-type = "key"
        template-action-keys = "cmd+{line}"
        """)
        XCTAssertEqual(file.items.first?.template?.name, "{line}")
        XCTAssertEqual(file.items.first?.template?.icon, "")
        XCTAssertEqual(file.items.first?.template?.payload, "cmd+{line}")
    }

    func testTemplateAxVerbMustBeKnownOrCarryLine() {
        // A literal verb is checked against `Action.axVerbs` at parse
        // time; a `{line}`-bearing verb is deferred to expansion.
        let file = WandConfig.parseItems("""
        [[tome.cursor.item]]
        name = "Literal"
        dynamic = "echo x"
        template-action-type = "ax"
        template-action-verb = "close"

        [[tome.cursor.item]]
        name = "Deferred"
        dynamic = "echo x"
        template-action-type = "ax"
        template-action-verb = "{line}"

        [[tome.cursor.item]]
        name = "Bogus"
        dynamic = "echo x"
        template-action-type = "ax"
        template-action-verb = "explode"
        """)
        XCTAssertEqual(file.items.map(\.name), ["Literal", "Deferred"])
        XCTAssertEqual(file.items.map { $0.template?.payload },
                       ["close", "{line}"])
    }

    func testDynamicItemWithoutUsableTemplateDrops() {
        let file = WandConfig.parseItems("""
        [[tome.cursor.item]]
        name = "No template"
        dynamic = "echo x"

        [[tome.cursor.item]]
        name = "Unknown kind"
        dynamic = "echo x"
        template-action-type = "applescript"
        template-action-cmd = "{line}"

        [[tome.cursor.item]]
        name = "Empty payload"
        dynamic = "echo x"
        template-action-type = "url"
        template-action-url = ""

        [[tome.cursor.item]]
        name = "Static neighbour"
        action-type = "key"
        action-keys = "cmd+s"
        """)
        XCTAssertEqual(file.items.map(\.name), ["Static neighbour"])
    }

    func testDynamicParentIgnoresItsOwnActionFieldsButStillParses() {
        // Stray `action-*` on a dynamic parent only warns; the row
        // stays and still carries the sentinel, not the stray action.
        let file = WandConfig.parseItems("""
        [[tome.cursor.item]]
        name = "Folder"
        dynamic = "echo x"
        action-type = "key"
        action-keys = "cmd+z"
        template-action-type = "url"
        template-action-url = "https://example.com/{line}"
        """)
        XCTAssertEqual(file.items.count, 1)
        XCTAssertEqual(file.items[0].action, .shell(""))
        XCTAssertEqual(file.items[0].template?.kind, .url)
    }
}
