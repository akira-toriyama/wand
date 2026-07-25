import XCTest
@testable import WandCore

/// The committed `config.schema.json` (shipped next to `config.toml`,
/// pointed at by its `#:schema` directive) MUST equal what the live spec
/// emits — otherwise editor completion drifts from the actual parser.
/// Regenerate with: `wand config --emit-schema > config.schema.json`.
final class ConfigSchemaDriftTests: XCTestCase {

    func testCommittedSchemaMatchesSpec() throws {
        // Locate the repo-root schema relative to THIS source file, so the
        // check is independent of the test runner's working directory.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/WandCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let url = repoRoot.appendingPathComponent("config.schema.json")
        let committed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            committed, WandConfig.jsonSchema,
            "config.schema.json is stale — run "
                + "`wand config --emit-schema > config.schema.json` and commit.")
    }
}
