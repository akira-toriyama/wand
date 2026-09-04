// Theme bridge — the sill seam (atelier block-6). Validates that
// `[cast].theme` / `[tome].theme` names resolve against sill's catalog
// (+ wand's local engine themes), that cut names clamp to the native
// `system` default, and that the cast/tome palettes derive the expected
// String tokens from sill's `ThemeSpec` roles. wand has no Xcode locally
// (XCTest is CI-only), so these are written defensively and only
// compile-checked on the dev box.

import XCTest
import Palette
@testable import WandCore

final class ThemeTests: XCTestCase {

    func testCanonicalAcceptsSillCatalog() {
        // Derived from sill, NOT copied. A hardcoded list is exactly how
        // `catppuccin-latte`'s removal reached wand as a surprise: sill cut
        // the theme under a non-major gitmoji, this test kept asserting a
        // name that no longer existed, and the break surfaced at the next pin
        // bump instead of at the removal (t-n158). Reading the live catalog
        // means a sill addition is covered for free and a sill removal can
        // only fail where wand actually depends on the name.
        //
        // `random` is excluded because wand resolves it to a CONCRETE name by
        // design (asserted in testRandomResolvesToConcreteName below), so it
        // is the one catalog entry that must not round-trip.
        let catalog = canonicalThemeNames.filter { $0 != "random" }
        XCTAssertFalse(catalog.isEmpty, "sill's canonicalThemeNames is empty")
        for name in catalog {
            XCTAssertEqual(wandCanonicalThemeName(name), name, name)
        }
    }

    func testCanonicalAcceptsWandEngineThemes() {
        XCTAssertEqual(wandCanonicalThemeName("neon"), "neon")
        XCTAssertEqual(wandCanonicalThemeName("splatoon"), "splatoon")
    }

    func testCanonicalCaseInsensitiveAndTrimmed() {
        XCTAssertEqual(wandCanonicalThemeName("DRACULA"), "dracula")
        XCTAssertEqual(wandCanonicalThemeName("  github-dark "), "github-dark")
    }

    func testCanonicalRejectsCutAndUnknownNames() {
        // Cut in Phase V / never in sill — must NOT resolve.
        for cut in ["nord", "onedark", "rosepine", "vapor", "aurora",
                    "mono", "catppuccin", "default", "nonsense", ""] {
            XCTAssertNil(wandCanonicalThemeName(cut), cut)
        }
    }

    func testRetiredNameRejectsWithTombstoneHint() {
        // Derived from sill's tombstone list, NOT a copied name: whatever
        // the catalog has retired must reject, and the did-you-mean hint
        // must be the tombstone's `tryInstead` (sill's `suggest` short-
        // circuits retired names there), not a Levenshtein guess.
        XCTAssertFalse(retiredThemeNames.isEmpty, "sill's tombstone list is empty")
        for tomb in retiredThemeNames {
            XCTAssertNil(wandCanonicalThemeName(tomb.name), tomb.name)
            XCTAssertEqual(wandThemeNameSuggestion(tomb.name), tomb.tryInstead, tomb.name)
        }
    }

    func testRandomResolvesToConcreteName() {
        guard let r = wandCanonicalThemeName("random") else {
            return XCTFail("random should resolve to a concrete name")
        }
        XCTAssertNotEqual(r, "random")
        XCTAssertNotEqual(r, "system")           // pool excludes system
        XCTAssertNotNil(wandCanonicalThemeName(r))  // the pick is itself valid
    }

    // Config clamps theme to the native default.

    func testConfigClampsCutThemeToSystem() {
        XCTAssertEqual(WandConfig.parse("[cast]\ntheme = \"nord\"").theme, "system")
        XCTAssertEqual(WandConfig.parse("[tome]\ntheme = \"aurora\"").launcher.theme, "system")
    }

    func testConfigDefaultThemeIsSystem() {
        XCTAssertEqual(WandConfig.parse("").theme, "system")
        XCTAssertEqual(WandConfig.parse("").launcher.theme, "system")
    }

    func testConfigKeepsValidTheme() {
        XCTAssertEqual(WandConfig.parse("[cast]\ntheme = \"dracula\"").theme, "dracula")
        XCTAssertEqual(WandConfig.parse("[tome]\ntheme = \"gruvbox\"").launcher.theme, "gruvbox")
    }

    // Cast palette derives from sill roles (Q5 maximal map).

    func testCastTerminalDerivesGreenFromSill() {
        // sill terminal: primary 0x33FF66, error 0xFF3B3B,
        // foreground 0x9BFEDA, background 0x050805.
        let p = wandCastPalette("terminal")
        XCTAssertEqual(p.trailColor, "#33FF66")          // ← primary
        XCTAssertEqual(p.trailColorNoMatch, "#FF3B3B")   // ← error
        XCTAssertEqual(p.cardsBorderColor, "#33FF66")    // ← primary
        XCTAssertEqual(p.cardsBodyColor, "#050805")      // ← background
        XCTAssertEqual(p.cardsTextColor, "#9BFEDA")      // ← foreground
        XCTAssertEqual(p.trailColorOutline, "#050805")   // ← background
        XCTAssertEqual(p.badgeBackgroundColor, "#050805")
    }

    func testCastDraculaDerivesFromSill() {
        let p = wandCastPalette("dracula")
        XCTAssertEqual(p.trailColor, "#BD93F9")          // sill dracula primary
        XCTAssertEqual(p.trailColorNoMatch, "#FF5555")   // sill dracula error
    }

    // Tome palette derives from sill roles.

    func testTomeTerminalDerivesFromSill() {
        let p = wandTomePalette("terminal")
        XCTAssertEqual(p.accentColor, "#33FF66")          // hover ← primary
        XCTAssertEqual(p.accentTextColor, "#000000")      // ← primary.bestForeground (vivid green → black)
        XCTAssertEqual(p.textColor, "#9BFEDA")            // rows ← foreground
        XCTAssertEqual(p.backgroundColor, "#050805")      // panel ← background
    }

    // chomp: sill-derived constants, wand arcade arrangement.

    func testChompConstantsMatchSill() {
        // Byte-match to sill chomp (primary 0xFFEA00, error 0xFF0000,
        // secondary 0x2121FF, background 0x000000) — derived, not literal.
        XCTAssertEqual(Chomp.pellet, "#FFEA00")
        XCTAssertEqual(Chomp.ghost, "#FF0000")
        XCTAssertEqual(Chomp.wall, "#2121FF")
        XCTAssertEqual(Chomp.backdrop, "#000000")
    }

    func testChompCastKeepsArcadeArrangement() {
        let p = wandCastPalette("chomp")
        XCTAssertEqual(p.trailColor, "#FFEA00")           // pellet
        XCTAssertEqual(p.trailColorNoMatch, "#FF0000")    // ghost
        XCTAssertEqual(p.trailColorOutline, "#2121FF")    // wall (NOT background)
        XCTAssertEqual(p.cardsBorderColor, "#2121FF")     // wall (NOT primary)
        XCTAssertEqual(p.cardsFiresBorderColor, "rainbow")// animated firing border (wand motion)
    }

    // Engine + system exceptions keep their tokens.

    func testEngineThemesKeepDynamicTokens() {
        XCTAssertEqual(wandCastPalette("neon").trailColor, "neon")
        XCTAssertEqual(wandCastPalette("splatoon").trailColor, "splatoon")
        XCTAssertEqual(wandTomePalette("splatoon").accentColor, "splatoon")
    }

    func testSystemThemeIsNativeLook() {
        let cast = wandCastPalette("system")
        XCTAssertEqual(cast.trailColor, "accent")         // OS control-accent
        XCTAssertEqual(cast.cardsBodyColor, "")           // frosted blur kept
        let tome = wandTomePalette("system")
        XCTAssertEqual(tome.accentColor, "")              // OS control-accent
        XCTAssertEqual(tome.backgroundColor, "")          // frosted blur kept
    }
}
