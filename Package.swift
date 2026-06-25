// swift-tools-version:6.0
//
// wand — macOS daemon for cursor-anchored mouse automation.
// Ships two trigger families on one daemon:
//   - gesture (mouse button + drag — the original `stroke` project's
//     feature; "stroke" remains the domain term for a drawn gesture)
//   - launcher (middle-click + contextual NSMenu)
// Both dispatch actions against the cursor-anchored window.
//
// Architecture is hexagonal (Ports & Adapters), mirroring facet's
// three-layer split. See docs/architecture.md for the diagram.
//
//   WandCore             pure logic: stroke recognition, rule
//                        matching, TOML config. No AppKit, no AX,
//                        no CG event handling. Fully testable.
//
//   WandAdapterMacOS     real-world glue: CGEventTap mouse capture,
//                        AXUIElementCopyElementAtPosition window
//                        targeting (the heart of the cursor-anchored
//                        spine), action dispatch via AX + CGEvent.
//
//   WandAdapterTest      synthetic MouseSource for end-to-end tests
//                        of the recognition + matching pipeline
//                        without real mouse hardware.
//
//   WandApp              executable target: @main, CLI argv,
//                        Controller orchestration.
//
// Tests live under Tests/<Module>Tests. GUI is deliberately absent
// — the app is config.toml-driven (no settings window).

import PackageDescription

let package = Package(
    name: "wand",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wand", targets: ["WandApp"]),
        .library(name: "WandCore", targets: ["WandCore"]),
    ],
    dependencies: [
        // sill — the shared theme foundation (atelier). WandCore takes
        // the pure `Palette` module (ThemeSpec → wand's String-token
        // CastThemePalette / TomeThemePalette bridge + EffectIntensity);
        // WandAdapterMacOS additionally takes `Effects` for the shared
        // neon flash data + `drawLinePets`. Like perch, wand does NOT link
        // PaletteKit (it has its own NSColorParse and never uses `pal` /
        // `resolve`). sill 0.6.0 moves the pure `LinePet` vocabulary into
        // `Palette` (so a no-AppKit Core can validate it) and adds
        // `drawLinePets(…chaseGap:)` — both consumed by wand's line-pets
        // dedup. WandCore also takes the `Toml` module — the family's ONE
        // TOML implementation (wand's in-tree TOML.swift folded into sill in
        // Phase 1.6, then moved out to the standalone swift-toml-edit repo at
        // sill 0.11.0). wand reads
        // config via `Toml.parseFlat`, whose `Document{tables,arrays}` is
        // the exact shape wand's old `TOMLDocument` had, so the swap is
        // mechanical. Pinned to the next-minor range like the other family
        // apps; Package.resolved locks the exact commit.
        //
        // Floor 0.9.0 = the `ConfigSchema` module — one declarative `Spec`
        // describes wand's whole config.toml surface and emits the JSON
        // Schema taplo uses for completion/validation (`wand --emit-schema`).
        // 0.9.0 is an additive superset of 0.7.x; the existing
        // Palette / Toml / Effects usage is unaffected.
        // Floor 0.11.0 = the release that removed sill's in-tree `Toml`
        // (moved to swift-toml-edit, below). It also carries the `CLIKit`
        // module — the family's shared yabai-style argv tokenizer (Phase 3):
        // WandApp's CLI dispatch declares each domain's verb arity and CLIKit
        // consumes values (incl. negative `--at` coords) without the
        // `--verb=value` form. Palette / ConfigSchema / Effects usage is
        // unaffected.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "1.27.0")),
        // swift-toml-edit — the family's ONE TOML implementation (Sill-1).
        // Provides the `Toml` module WandCore reads config with
        // (`Toml.parseFlat`, whose `Document{tables,arrays}` matches wand's
        // old `TOMLDocument`). Module name unchanged so `import Toml` survives.
        // 2.0.0 only changes the nested `parse`/`.arrayOfTables` surface
        // (now `[Toml.Row]`), which wand doesn't use — parseFlat is unchanged.
        .package(url: "https://github.com/akira-toriyama/swift-toml-edit.git",
                 .upToNextMajor(from: "2.0.0")),
    ],
    targets: [
        .target(
            name: "WandCore",
            dependencies: [
                .product(name: "Palette", package: "sill"),
                .product(name: "Toml", package: "swift-toml-edit"),
                // ConfigSchema: one declarative `Spec` describes wand's whole
                // config.toml surface and emits the JSON Schema for taplo
                // completion (`wand --emit-schema`) — generated from the same
                // parser source, so editor schema and parser never drift.
                .product(name: "ConfigSchema", package: "sill"),
            ]),
        .target(
            name: "WandAdapterMacOS",
            dependencies: [
                "WandCore",
                .product(name: "Palette", package: "sill"),
                .product(name: "Effects", package: "sill"),
            ]),
        .target(name: "WandAdapterTest", dependencies: ["WandCore"]),
        .executableTarget(
            name: "WandApp",
            dependencies: [
                "WandCore",
                "WandAdapterMacOS",
                // CLIKit — the family's shared yabai-style argv tokenizer
                // (Phase 3). WandApp's CLI dispatch declares each domain's
                // verb arity and CLIKit consumes values (incl. negative
                // --at coords) without the --verb=value form.
                .product(name: "CLIKit", package: "sill"),
            ]),
        .testTarget(name: "WandCoreTests", dependencies: ["WandCore"]),
        // Drives the synthetic MouseSource end-to-end through Core's
        // recognition + matching — the real consumer of
        // WandAdapterTest that the docs describe.
        .testTarget(
            name: "WandIntegrationTests",
            dependencies: ["WandCore", "WandAdapterTest"]),
    ]
)
