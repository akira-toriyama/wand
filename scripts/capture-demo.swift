#!/usr/bin/env swift
//
// scripts/capture-demo.swift
//
// Records a short screen video of wand reacting to a synthesized gesture,
// for the motion demo embedded in docs/glossary.md (docs/images/gesture-demo.gif).
// Sibling of capture-overlays.swift, which grabs a still instead.
//
// Pipeline (the GIF in docs/ was produced exactly this way):
//
//   1. Put a Chrome window on-screen, then find its center (CG global coords):
//        # owner contains "chrome", layer 0, largest on-screen window
//        # e.g. center (3975, 1031) -> start a touch above center (3975, 951)
//
//   2. Record + fire the gesture (this script):
//        swift scripts/capture-demo.swift 3975 951 /tmp/wand-demo.mov
//      Sends a heads-up notification, screen-records for 7s, and synthesizes a
//      right-button DU ("下→上") drag = the "新しいタブ" gesture rule.
//
//   3. Crop to the overlay + convert to GIF (crop is centered on the start
//      point; scale = video_width / display_point_width, here 4096/5120 = 0.8,
//      so start*0.8 = (3180,761), crop 960x680 with top-left (2700,460)):
//        ffmpeg -y -ss 1.8 -i /tmp/wand-demo.mov -t 2.0 \
//          -vf "crop=960:680:2700:460,scale=760:-2,fps=24" /tmp/f%03d.png
//        gifski --fps 24 --quality 90 -o docs/images/gesture-demo.gif /tmp/f*.png
//
// Requires Accessibility (to post the gesture) + Screen Recording (for
// screencapture) for whatever process invokes swift, and a running wand daemon.
//
// IMPORTANT: this hijacks the cursor for a few seconds and fires a real action
// (opens a new Chrome tab). Per project workflow, warn before running it
// unattended.
//
// Usage:
//   swift scripts/capture-demo.swift <start-x> <start-y> [out.mov]

import Cocoa
import CoreGraphics

let a = CommandLine.arguments
guard a.count >= 3, let sx = Double(a[1]), let sy = Double(a[2]) else {
    FileHandle.standardError.write(Data("usage: capture-demo.swift <start-x> <start-y> [out.mov]\n".utf8))
    exit(2)
}
let start = CGPoint(x: sx, y: sy)
let outMov = a.count > 3 ? a[3] : "/tmp/wand-demo.mov"

func sleepMs(_ ms: Int) { Thread.sleep(forTimeInterval: Double(ms) / 1000.0) }
func warp(_ p: CGPoint) {
    CGWarpMouseCursorPosition(p)
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
}
func post(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .right) {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: b)?
        .post(tap: .cghidEventTap)
}
func key(_ vk: CGKeyCode) {
    CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false)?.post(tap: .cghidEventTap)
}

// 1) heads-up notification
let n = Process()
n.launchPath = "/usr/bin/osascript"
n.arguments = ["-e", "display notification \"録画開始。まもなくDUジェスチャー発火。対象ウィンドウを見てください。\" with title \"wand デモ｜実行中\" sound name \"Glass\""]
try? n.run(); n.waitUntilExit()

// 2) start recording (7s, -k draws clicks)
try? FileManager.default.removeItem(atPath: outMov)
let rec = Process()
rec.launchPath = "/usr/sbin/screencapture"
rec.arguments = ["-v", "-k", "-V", "7", outMov]
try? rec.run()

sleepMs(1500)            // recorder warmup + lead-in
key(0x35); sleepMs(150)  // clear any stray context menu
warp(start); sleepMs(250)

// 3) gesture DU -> "新しいタブ" (down, then up past start). One reversal < cancel=2.
post(.rightMouseDown, start); sleepMs(280)
var p = start
for _ in 0..<8  { p.y += 12; post(.rightMouseDragged, p); sleepMs(20) }  // D (+96)
sleepMs(320)                                                            // assist cards settle
for _ in 0..<14 { p.y -= 12; post(.rightMouseDragged, p); sleepMs(20) } // U (-168 -> above start)
sleepMs(280)
post(.rightMouseUp, p)   // fires 新しいタブ + match exit effect
sleepMs(1800)            // hold to record the effect

rec.waitUntilExit()      // recording auto-stops at 7s
print("recorded \(outMov) — now crop + gifski (see header) to make the GIF")
