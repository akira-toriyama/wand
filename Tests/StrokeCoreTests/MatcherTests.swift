// Matcher / glob / candidates / resolve / exclude.

import XCTest
@testable import StrokeCore

final class MatcherTests: XCTestCase {

    func testMatcherFirstWins() {
        let rules = [
            Rule(name: "A", pattern: "D", apps: ["*"], action: .key("cmd+1")),
            Rule(name: "B", pattern: "D", apps: ["*"], action: .key("cmd+2")),
        ]
        XCTAssertEqual(Matcher.match(pattern: "D",
                                     bundleID: "com.apple.Finder",
                                     rules: rules)?.name, "A")
    }

    func testMatcherAppExclusion() {
        let rules = [
            Rule(name: "X", pattern: "D",
                 apps: ["*", "!com.apple.dt.Xcode"],
                 action: .key("cmd+w"))
        ]
        XCTAssertNil(Matcher.match(pattern: "D",
                                   bundleID: "com.apple.dt.Xcode",
                                   rules: rules))
        XCTAssertNotNil(Matcher.match(pattern: "D",
                                      bundleID: "com.apple.Finder",
                                      rules: rules))
    }

    func testMatcherEmptyAppsAllowsAll() {
        // `apps: []` is permissive — without this branch every
        // default-apps rule would silently break.
        let rules = [
            Rule(name: "any", pattern: "D", apps: [], action: .key("cmd+w"))
        ]
        XCTAssertNotNil(Matcher.match(pattern: "D",
                                      bundleID: "com.anything.here",
                                      rules: rules))
    }

    func testMatcherAllExclusionsNoPositive() {
        // No positive filter, just `!…` — must still apply to
        // non-excluded apps. Easy to invert this guard.
        let rules = [
            Rule(name: "anywhere-but-xcode", pattern: "D",
                 apps: ["!com.apple.dt.Xcode"], action: .key("cmd+w"))
        ]
        XCTAssertNil(Matcher.match(pattern: "D",
                                   bundleID: "com.apple.dt.Xcode",
                                   rules: rules))
        XCTAssertNotNil(Matcher.match(pattern: "D",
                                      bundleID: "com.apple.Finder",
                                      rules: rules))
    }

    func testMatcherCaseInsensitiveBundleID() {
        // Caller may hand us mixed case (Chrome's bundleID is
        // `com.google.Chrome`); rule strings are lowercased on parse.
        let rules = [
            Rule(name: "safari", pattern: "D",
                 apps: ["com.apple.safari"], action: .key("cmd+w"))
        ]
        XCTAssertNotNil(Matcher.match(pattern: "D",
                                      bundleID: "COM.APPLE.SAFARI",
                                      rules: rules))
    }

    func testCandidatesByPrefixAndApp() {
        let rules = [
            Rule(name: "close tab", pattern: "DL", apps: ["*chrome*"], action: .key("cmd+w")),
            Rule(name: "close window", pattern: "DRU", apps: ["*"], action: .ax("close")),
            Rule(name: "minimize", pattern: "L", apps: ["*"], action: .ax("minimize")),
        ]
        // "D" reaches both DL (chrome-only) and DRU on Chrome…
        XCTAssertEqual(
            Set(Matcher.candidates(prefix: "D", bundleID: "com.google.Chrome",
                                   rules: rules).map(\.name)),
            ["close tab", "close window"])
        // …but only DRU on a non-chrome app (app filter applies).
        XCTAssertEqual(
            Matcher.candidates(prefix: "D", bundleID: "com.apple.finder",
                               rules: rules).map(\.name),
            ["close window"])
        // Exact pattern is a prefix of itself.
        XCTAssertEqual(
            Matcher.candidates(prefix: "DL", bundleID: "com.google.Chrome",
                               rules: rules).map(\.name),
            ["close tab"])
        // Dead end → nothing.
        XCTAssertTrue(
            Matcher.candidates(prefix: "X", bundleID: "com.google.Chrome",
                               rules: rules).isEmpty)
    }

    func testCandidatesEmptyPrefixReturnsEmpty() {
        // Before any motion the assist must show nothing — otherwise
        // every rule surfaces as a hint at button-down.
        let rules = [
            Rule(name: "any", pattern: "D", apps: ["*"], action: .key("cmd+w"))
        ]
        XCTAssertTrue(
            Matcher.candidates(prefix: "", bundleID: "com.x",
                               rules: rules).isEmpty)
    }

    func testCandidatesPreservesRuleOrder() {
        let rules = [
            Rule(name: "first", pattern: "DA", apps: ["*"], action: .key("cmd+1")),
            Rule(name: "second", pattern: "DB", apps: ["*"], action: .key("cmd+2")),
            Rule(name: "third", pattern: "DC", apps: ["*"], action: .key("cmd+3")),
        ]
        XCTAssertEqual(
            Matcher.candidates(prefix: "D", bundleID: "com.x",
                               rules: rules).map(\.name),
            ["first", "second", "third"])
    }

    func testResolveHonorsExcludes() {
        // The global `excludes` list trumps even matching rules.
        let rules = [
            Rule(name: "any", pattern: "D", apps: ["*"], action: .key("cmd+w"))
        ]
        XCTAssertNotNil(
            Matcher.resolve(pattern: "D", bundleID: "com.apple.finder",
                            rules: rules, excludes: []))
        XCTAssertNil(
            Matcher.resolve(pattern: "D", bundleID: "com.apple.finder",
                            rules: rules, excludes: ["com.apple.finder"]))
    }

    // MARK: - glob

    func testGlobWildcards() {
        XCTAssertTrue(Matcher.glob("*chrome*", "com.google.chrome"))
        XCTAssertTrue(Matcher.glob("com.apple.?afari", "com.apple.safari"))
        XCTAssertFalse(Matcher.glob("com.apple.safari", "com.google.chrome"))
    }

    func testGlobLeadingTrailingStarsAndQuestion() {
        XCTAssertTrue(Matcher.glob("*", "anything"))
        XCTAssertTrue(Matcher.glob("", ""))             // both empty → match
        XCTAssertFalse(Matcher.glob("?", ""))           // ? needs one char
        XCTAssertTrue(Matcher.glob("a*b", "axxxb"))
        XCTAssertTrue(Matcher.glob("a*b", "ab"))        // * can match zero
        XCTAssertFalse(Matcher.glob("a*b", "axx"))      // tail must match
    }
}
