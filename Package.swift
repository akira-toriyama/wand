// swift-tools-version:6.0
//
// stroke — global mouse-gesture daemon for macOS.
//
// Architecture is hexagonal (Ports & Adapters), mirroring facet's
// three-layer split. See docs/architecture.md for the diagram.
//
//   StrokeCore           pure logic: stroke recognition, rule
//                        matching, TOML config. No AppKit, no AX,
//                        no CG event handling. Fully testable.
//
//   StrokeAdapterMacOS   real-world glue: CGEventTap mouse capture,
//                        AXUIElementCopyElementAtPosition window
//                        targeting (the heart of the cursor-anchored
//                        spine), action dispatch via AX + CGEvent.
//
//   StrokeAdapterTest    synthetic MouseSource for end-to-end tests
//                        of the recognition + matching pipeline
//                        without real mouse hardware.
//
//   StrokeApp            executable target: @main, CLI argv,
//                        Controller orchestration.
//
// Tests live under Tests/<Module>Tests. GUI is deliberately absent
// — the app is config.toml-driven (no settings window).

import PackageDescription

let package = Package(
    name: "stroke",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "stroke", targets: ["StrokeApp"]),
        .library(name: "StrokeCore", targets: ["StrokeCore"]),
    ],
    targets: [
        .target(name: "StrokeCore"),
        .target(name: "StrokeAdapterMacOS", dependencies: ["StrokeCore"]),
        .target(name: "StrokeAdapterTest", dependencies: ["StrokeCore"]),
        .executableTarget(
            name: "StrokeApp",
            dependencies: [
                "StrokeCore",
                "StrokeAdapterMacOS",
            ]),
        .testTarget(name: "StrokeCoreTests", dependencies: ["StrokeCore"]),
        // Drives the synthetic MouseSource end-to-end through Core's
        // recognition + matching — the real consumer of
        // StrokeAdapterTest that the docs describe.
        .testTarget(
            name: "StrokeIntegrationTests",
            dependencies: ["StrokeCore", "StrokeAdapterTest"]),
    ]
)
