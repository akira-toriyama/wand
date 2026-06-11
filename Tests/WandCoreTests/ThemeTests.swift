// Theme bridge — the sill seam (atelier block-6). Validates that
// `[cast].theme` / `[tome].theme` names resolve against sill's catalog
// (+ wand's local engine themes), that cut names clamp to the native
// `system` default, and that the cast/tome palettes derive the expected
// String tokens from sill's `ThemeSpec` roles. wand has no Xcode locally
// (XCTest is CI-only), so these are written defensively and only
// compile-checked on the dev box.

import XCTest
@testable import WandCore

final class ThemeTests: XCTestCase {

    // MARK: - Name validation (sill catalog + wand engine themes)

    func testCanonicalAcceptsSillCatalog() {
        for name in ["terminal", "chomp", "rainbow", "cobalt2",
                     "shades-of-purple", "tokyo-hack", "github-dark",
                     "dracula", "catppuccin-mocha", "gruvbox",
                     "github-light", "catppuccin-latte", "system"] {
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

    func testRandomResolvesToConcreteName() {
        guard let r = wandCanonicalThemeName("random") else {
            return XCTFail("random should resolve to a concrete name")
        }
        XCTAssertNotEqual(r, "random")
        XCTAssertNotEqual(r, "system")           // pool excludes system
        XCTAssertNotNil(wandCanonicalThemeName(r))  // the pick is itself valid
    }

    // MARK: - Config clamps theme to the native default

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

    // MARK: - Cast palette derives from sill roles (Q5 maximal map)

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

    // MARK: - Tome palette derives from sill roles

    func testTomeTerminalDerivesFromSill() {
        let p = wandTomePalette("terminal")
        XCTAssertEqual(p.accentColor, "#33FF66")          // hover ← primary
        XCTAssertEqual(p.accentTextColor, "#000000")      // ← primary.bestForeground (vivid green → black)
        XCTAssertEqual(p.textColor, "#9BFEDA")            // rows ← foreground
        XCTAssertEqual(p.backgroundColor, "#050805")      // panel ← background
    }

    // MARK: - chomp: sill-derived constants, wand arcade arrangement

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

    // MARK: - Engine + system exceptions keep their tokens

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
