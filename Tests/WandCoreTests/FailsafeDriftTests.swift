import XCTest
@testable import WandCore

/// `[failsafe]`'s bounds + defaults live in ONE place — `FailsafeConfig`'s
/// static constants — which the schema descriptor (`Config+Spec.swift`) and
/// the lenient runtime clamp (`WandConfig.parse`) both cite. These guard that
/// nobody re-hardcodes a literal that silently diverges from that source, so
/// "what completion shows" stays equal to "what the loader enforces".
/// (A3 DRY — projects t-5qxd; sibling of `ConfigSchemaDriftTests`.)
final class FailsafeDriftTests: XCTestCase {

    private func obj(_ any: Any?) -> [String: Any]? { any as? [String: Any] }

    // MARK: - descriptor side: the emitted schema == the constants

    func testEmittedSchemaMatchesFailsafeConstants() throws {
        let root = try XCTUnwrap(obj(try JSONSerialization.jsonObject(
            with: Data(WandConfig.jsonSchema.utf8))))
        let props = try XCTUnwrap(
            obj(obj(obj(root["properties"])?["failsafe"])?["properties"]),
            "schema missing failsafe.properties")

        let timeout = try XCTUnwrap(obj(props["mouse-hold-timeout-seconds"]))
        XCTAssertEqual(timeout["minimum"] as? Int,
                       FailsafeConfig.mouseHoldTimeoutRange.lowerBound,
                       "schema minimum drifted from FailsafeConfig constant")
        XCTAssertEqual(timeout["maximum"] as? Int,
                       FailsafeConfig.mouseHoldTimeoutRange.upperBound,
                       "schema maximum drifted from FailsafeConfig constant")
        XCTAssertEqual(timeout["default"] as? Int,
                       FailsafeConfig.mouseHoldTimeoutDefault,
                       "schema default drifted from FailsafeConfig constant")

        let key = try XCTUnwrap(obj(props["emergency-release-key"]))
        XCTAssertEqual(key["default"] as? String,
                       FailsafeConfig.emergencyReleaseKeyDefault,
                       "schema default key drifted from FailsafeConfig constant")
    }

    // MARK: - clamp side: parse() enforces exactly the constants

    func testParseClampsToFailsafeConstants() {
        let lo = FailsafeConfig.mouseHoldTimeoutRange.lowerBound
        let hi = FailsafeConfig.mouseHoldTimeoutRange.upperBound

        // below the floor → clamped up to lo
        XCTAssertEqual(
            WandConfig.parse("[failsafe]\nmouse-hold-timeout-seconds = \(lo - 1)")
                .failsafe.mouseHoldTimeoutSec, lo)
        // above the ceiling → clamped down to hi
        XCTAssertEqual(
            WandConfig.parse("[failsafe]\nmouse-hold-timeout-seconds = \(hi + 1)")
                .failsafe.mouseHoldTimeoutSec, hi)
        // in range → unchanged
        let mid = (lo + hi) / 2
        XCTAssertEqual(
            WandConfig.parse("[failsafe]\nmouse-hold-timeout-seconds = \(mid)")
                .failsafe.mouseHoldTimeoutSec, mid)
    }

    // MARK: - default side: parse() falls back to the constants

    func testParseDefaultsToFailsafeConstants() {
        // absent block → struct defaults, which are the constants
        let def = WandConfig.parse("").failsafe
        XCTAssertEqual(def.mouseHoldTimeoutSec,
                       FailsafeConfig.mouseHoldTimeoutDefault)
        XCTAssertEqual(def.emergencyReleaseKey,
                       FailsafeConfig.emergencyReleaseKeyDefault)

        // present block, empty key → the esc sentinel constant
        XCTAssertEqual(
            WandConfig.parse("[failsafe]\nemergency-release-key = \"\"")
                .failsafe.emergencyReleaseKey,
            FailsafeConfig.emergencyReleaseKeyDefault)

        // present block, timeout key absent → default constant
        XCTAssertEqual(
            WandConfig.parse("[failsafe]\nemergency-release-key = \"esc\"")
                .failsafe.mouseHoldTimeoutSec,
            FailsafeConfig.mouseHoldTimeoutDefault)
    }

    // MARK: - the struct's own `.default` reflects the constants

    func testFailsafeConfigDefaultUsesConstants() {
        XCTAssertEqual(FailsafeConfig.default.mouseHoldTimeoutSec,
                       FailsafeConfig.mouseHoldTimeoutDefault)
        XCTAssertEqual(FailsafeConfig.default.emergencyReleaseKey,
                       FailsafeConfig.emergencyReleaseKeyDefault)
    }
}
