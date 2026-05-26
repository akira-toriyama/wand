// Hand-rolled TOML subset parser primitives — comments, types, and
// array-of-tables boundary behaviour. WandConfig.parse layers on
// top of these and has its own tests (ConfigTests.swift).
//
// Reads the `TOMLValue` enum directly because the per-table dict
// accessors are private to Config.swift.

import XCTest
@testable import WandCore

final class TOMLTests: XCTestCase {

    func testTOMLInlineCommentAfterString() {
        let doc = parseTOMLSubset("""
        [gesture]
        button = "right" # this is a comment with # inside
        """)
        // The inline-strip branch must keep the quoted `#` and only
        // drop the trailing comment. Without it the value picks up
        // " # this is a comment …".
        XCTAssertEqual(doc.tables["trigger"]?["button"], .string("right"))
    }

    func testTOMLInlineCommentAfterArray() {
        let doc = parseTOMLSubset("""
        [gesture]
        modifiers = ["cmd", "opt"] # mods
        """)
        XCTAssertEqual(doc.tables["trigger"]?["modifiers"],
                       .stringArray(["cmd", "opt"]))
    }

    func testTOMLUnknownLinesSkipped() {
        // The "config typos never break the daemon" promise: lines
        // without `=`, lines under no header, garbage — all dropped
        // and the rest still loads.
        let doc = parseTOMLSubset("""
        garbage line with no equals
        [gesture]
        button = "right"
        more garbage
        """)
        XCTAssertEqual(doc.tables["trigger"]?["button"], .string("right"))
    }

    func testTOMLBoolAndIntParsing() {
        let doc = parseTOMLSubset("""
        [gesture.overlay]
        enabled = true
        width = 7
        """)
        XCTAssertEqual(doc.tables["overlay"]?["enabled"], .bool(true))
        XCTAssertEqual(doc.tables["overlay"]?["width"], .int(7))
    }

    func testTOMLMultipleArrayOfTables() {
        // Three `[[gesture.rule]]` rows in order, no key bleed between rows
        // (each row is a fresh dictionary).
        let doc = parseTOMLSubset("""
        [[gesture.rule]]
        pattern = "A"
        action-keys = "cmd+1"

        [[gesture.rule]]
        pattern = "B"
        action-keys = "cmd+2"

        [[gesture.rule]]
        pattern = "C"
        action-keys = "cmd+3"
        """)
        let rows = doc.arrays["rules"] ?? []
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0]["pattern"], .string("A"))
        XCTAssertEqual(rows[0]["action-keys"], .string("cmd+1"))
        XCTAssertEqual(rows[1]["pattern"], .string("B"))
        XCTAssertEqual(rows[2]["pattern"], .string("C"))
    }
}
