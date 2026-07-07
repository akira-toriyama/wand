import XCTest
@testable import WandCore

/// `WandConfig.validate` — structural validation against the SAME `configSpec`
/// that drives decode + `--emit-schema` (sill 1.29.0's `Spec.validate` bridge,
/// t-0029). The strict counterpart to the lenient `parse()`/`load()`: it
/// surfaces the type / enum / range / unknown-key mismatches the loader
/// silently clamps or drops.
final class ConfigValidateTests: XCTestCase {

    // MARK: - no regression: the shipped template validates clean

    /// The committed `config.toml` template MUST validate with zero errors —
    /// the keys it uses are exactly the keys the spec declares. Guards against
    /// the spec drifting from the template (a key renamed in one, not the other).
    func testCommittedTemplateValidatesClean() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/WandCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let url = repoRoot.appendingPathComponent("config.toml")
        let source = try String(contentsOf: url, encoding: .utf8)
        let errors = try WandConfig.validate(source)
        XCTAssertEqual(errors, [],
                       "shipped config.toml should validate clean; got: "
                           + errors.map(\.message).joined(separator: "; "))
    }

    func testEmptyDocumentIsValid() throws {
        XCTAssertEqual(try WandConfig.validate(""), [])
    }

    // MARK: - it catches what load() silently accepts

    func testUnknownKeyIsReported() throws {
        let errors = try WandConfig.validate("""
        [cast.overlay]
        enabled = true
        bogus-key = 1
        """)
        XCTAssertTrue(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "bogus-key" }
            return false
        }, "unknown key should be reported; got \(errors.map(\.rule))")
    }

    func testWrongTypeIsReported() throws {
        // `[cast.overlay] enabled` is a boolean; a string is a type mismatch.
        let errors = try WandConfig.validate("""
        [cast.overlay]
        enabled = "yes"
        """)
        XCTAssertTrue(errors.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "enabled" }
            return false
        }, "type mismatch should be reported; got \(errors.map(\.rule))")
    }

    /// A genuine TOML syntax error throws (distinct from a schema violation) —
    /// the caller maps it to exit 2.
    func testUnparseableSourceThrows() {
        XCTAssertThrowsError(try WandConfig.validate("[cast.overlay\nbad"))
    }

    // MARK: - A1: the daemon LOAD path warns on a schema violation (no reject)

    func testLoadPathWarnsOnSchemaViolation() throws {
        Log.resetLineCount()
        // `bogus-key` is an unknown key the lenient load()/parse() silently
        // drops; the load-path validate must surface it as a WARNING.
        let count = WandConfig.warnSchemaViolations("""
        [cast.overlay]
        enabled = true
        bogus-key = 1
        """)
        XCTAssertGreaterThanOrEqual(count, 1,
            "a schema violation on the load path must produce a warning")
        XCTAssertGreaterThanOrEqual(Log.lineCount, 1,
            "the violation must reach Log.line (the daemon warning channel)")
    }

    func testLoadPathIsSilentOnCleanConfig() throws {
        Log.resetLineCount()
        let count = WandConfig.warnSchemaViolations("""
        [cast.overlay]
        enabled = true
        """)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(Log.lineCount, 0)
    }

    func testLoadPathDoesNotRejectUnparseableSource() {
        // Unparseable TOML must NOT throw on the daemon path (load stays
        // lenient / keeps starting) — helper swallows it via try?.
        XCTAssertEqual(WandConfig.warnSchemaViolations("[cast.overlay\nbad"), 0)
    }
}
