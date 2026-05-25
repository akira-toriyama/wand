// swift-tools-version:6.0
//
// wand — macOS daemon for cursor-anchored mouse automation.
// Currently ships the gesture trigger (formerly the standalone
// `stroke` project, hence the `stroke` binary name we still expose);
// the launcher trigger lands as a sibling feature.
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
        .executable(name: "stroke", targets: ["WandApp"]),
        .library(name: "WandCore", targets: ["WandCore"]),
    ],
    targets: [
        .target(name: "WandCore"),
        .target(name: "WandAdapterMacOS", dependencies: ["WandCore"]),
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
