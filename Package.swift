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
        // dedup. Since 0.7.0 WandCore also takes the `Toml` module — the
        // family's ONE hand-rolled TOML subset parser (wand's in-tree
        // TOML.swift folded into sill in atelier Phase 1.6). wand reads
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
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "0.9.1")),
    ],
    targets: [
        .target(
            name: "WandCore",
            dependencies: [
                .product(name: "Palette", package: "sill"),
                .product(name: "Toml", package: "sill"),
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
