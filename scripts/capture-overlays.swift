#!/usr/bin/env swift
//
// scripts/capture-overlays.swift
//
// Synthesizes a right-button gesture via CGEvent and screenshots wand's
// overlays (assist card / badge / trail) at the apex. Re-run when the
// overlay design changes to regenerate `docs/images/*.png`.
//
// Usage:
//   swift scripts/capture-overlays.swift [out-dir]
//
// Requires Accessibility permission for whatever process invokes swift
// (Terminal.app / iTerm2 / etc.), and a running wand daemon.
//
// The gesture starts at your CURRENT cursor position — place the
// cursor over a window (VS Code, Chrome, …) before the countdown ends.

import Cocoa
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images"

func sleepMs(_ ms: Int) {
    Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
}

func postMouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .right) {
    CGEvent(mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: p, mouseButton: button)?
        .post(tap: .cghidEventTap)
}

func postKey(_ vk: CGKeyCode) {
    CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true)?
        .post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false)?
        .post(tap: .cghidEventTap)
}

@discardableResult
func screencap(_ path: String, region: String? = nil) -> Bool {
    let t = Process()
    t.launchPath = "/usr/sbin/screencapture"
    var args = ["-x"]
    if let r = region { args.append(contentsOf: ["-R", r]) }
    args.append(path)
    t.arguments = args
    do { try t.run(); t.waitUntilExit(); return t.terminationStatus == 0 }
    catch { return false }
}

try? FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true)

print("wand overlay capture")
print("Place cursor over a window (VS Code / Chrome / ...).")
print("Gesture starts at the CURRENT cursor position in 5s — keep hands off.")
sleepMs(5000)

// Clear any open context menu / popover.
postKey(0x35) // Escape
sleepMs(150)

guard let start = CGEvent(source: nil)?.location else {
    print("could not read cursor position"); exit(1)
}
print("Starting gesture at (\(Int(start.x)), \(Int(start.y)))")

// Begin gesture — do NOT relocate the cursor across the screen.
postMouse(.rightMouseDown, at: start)
sleepMs(150)

// Move ~30px down — registers a D segment, assist cards refresh.
let apex = CGPoint(x: start.x, y: start.y + 30)
postMouse(.rightMouseDragged, at: apex)
sleepMs(350)

// Tight crop around start + cursor + the reachable assist card to the right.
let rx = Int(start.x) - 100
let ry = Int(start.y) - 80
let region = "\(rx),\(ry),420,220"
let outPath = "\(outDir)/assist-card.png"
let ok = screencap(outPath, region: region)
print(ok ? "saved \(outPath)" : "screencapture failed")

// Scribble-cancel: 3 reversals at 40ms intervals trips wand's default
// cancel-reversals = 2 well inside the 500ms window, so release fires
// nothing and no click is replayed to the app.
postMouse(.rightMouseDragged, at: CGPoint(x: start.x, y: start.y - 30)); sleepMs(40)
postMouse(.rightMouseDragged, at: CGPoint(x: start.x, y: start.y + 30)); sleepMs(40)
postMouse(.rightMouseDragged, at: CGPoint(x: start.x, y: start.y - 30)); sleepMs(40)
postMouse(.rightMouseUp, at: CGPoint(x: start.x, y: start.y - 30))

// Final Escape just in case some app raced a context menu open anyway.
sleepMs(150)
postKey(0x35)
print("done")
