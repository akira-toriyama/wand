// `wand` with no arguments: daemon bootstrap — config load, tap +
// overlay + tome + failsafe wiring, then the AppKit run loop.

import AppKit
import Foundation
import CLIKit
import ConfigSchema
import WandCore
import WandAdapterMacOS

extension WandApp {

    /// Exit fatally when `[failsafe]` is missing — same policy for
    /// both `--validate` and `runServer()` so they don't drift.
    /// See CLAUDE.md "Safety invariants" for the WHY of the
    /// mandatory-block rule.
    static func requireFailsafeBlock(_ cfg: WandConfig) {
        guard !cfg.failsafeBlockPresent else { return }
        let msg = "wand: FATAL: config.toml is missing the required "
            + "[failsafe] block. wand refuses to start without it "
            + "(low-level mouse interception needs the safety net "
            + "configured explicitly). Copy the [failsafe] block "
            + "from the bundled template:\n"
            + "  https://raw.githubusercontent.com/akira-toriyama/"
            + "wand/main/config.toml\n"
        FileHandle.standardError.write(Data(msg.utf8))
        Log.line("startup: [failsafe] block missing — refusing to start")
        exit(2)
    }

    @MainActor
    static func runServer() -> Never {
        // Refresh the taplo schema sidecar next to the user config so
        // editor completion / validation just works (idempotent; writes
        // only on change). The ConfigWatcher tracks config.toml itself —
        // not the directory — so this sibling write never triggers a
        // reload. Best-effort: a failure is non-fatal (never blocks
        // start), so the daemon is unaffected if ~/.config/wand isn't
        // writable.
        WandConfig.installSchema()

        let cfg = WandConfig.load()
        // A1: run the strict schema validate on the daemon load path too and
        // surface violations as WARNINGS (does NOT reject — load() already
        // clamped/dropped; this only makes the mismatches visible in the log,
        // matching facet/perch).
        WandConfig.warnSchemaViolations(
            (try? String(contentsOfFile: WandConfig.path, encoding: .utf8)) ?? "")
        requireFailsafeBlock(cfg)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)            // LSUIElement: no Dock icon
        AXTarget.ensureTrusted()

        let source = MacOSMouseSource(
            trigger: cfg.trigger,
            minStrokePx: cfg.recognition.minStrokePx,
            maxSegmentMs: cfg.recognition.maxSegmentMs,
            cancelReversals: cfg.recognition.cancelReversals,
            cancelWindowMs: cfg.recognition.cancelWindowMs
        )

        // Launcher trigger — only allocated when opted in at startup.
        // Like the gesture tap, its button is baked into the event
        // mask, so toggling enabled / changing button needs a restart
        // (surfaced as pending-restart in `--status`).
        let launcher: LauncherSource? = cfg.launcher.enabled
            ? MacOSLauncherSource(trigger: cfg.launcher.trigger)
            : nil

        // Construct Controller up front so the overlay's onSample
        // closure can read its live `config` snapshot per-sample,
        // instead of capturing the startup rules locally. Otherwise
        // dispatch (which reads `controller.config`) and the assist
        // tooltips (which would read captured locals) would drift
        // apart after a hot-reload — the user would see candidate
        // cards for the OLD rule set while a NEW rule fired.
        let controller = Controller(source: source,
                                    launcher: launcher,
                                    config: cfg)

        // Fire-moment effect managers — owned by Main for the
        // daemon's lifetime. Declared up here (instead of after the
        // overlay block) so the overlay's `onCherryEaten` hook can
        // close over `arcadeScoreManager` directly.
        let decalManager = DecalManager()
        let burstManager = BurstManager()
        let arcadeScoreManager = ArcadeScoreManager()

        // Gesture-trail overlay (passive observer of the sample
        // stream). Held for the process lifetime via `app.run()`.
        // Declared `outside` the `if` so the live-reload hook below
        // can hot-apply `[overlay]` changes without a restart.
        var overlay: GestureOverlay?
        if cfg.overlay.enabled {
            overlay = GestureOverlay(cfg)
            overlay?.show()
            // Chomp cherry pickup — `+N` arcade-score popup floats
            // up from the cherry's screen position when the face
            // catches it. Always uses the `.arcadeScore` kind here
            // (independent of `[cast.fire.burst].kind` which only
            // governs the rule-fire moment); cherries are a chomp-
            // theme flourish and the popup is part of that vibe.
            overlay?.onCherryEaten = { [weak controller] cocoaPt in
                MainActor.assumeIsolated {
                    guard let cfg = controller?.config else { return }
                    // Trail colour resolved per-fire so the popup
                    // matches the live theme even if the user has
                    // overridden `[cast.overlay.trail].color`.
                    let color = TrailColorMode.parse(
                        cfg.overlay.trail.color, fallback: .systemYellow
                    ).currentColor(
                        at: CACurrentMediaTime(),
                        strokeSeed: UInt64.random(in: 0..<UInt64.max),
                        cyclePeriod: TimeInterval(
                            cfg.overlay.colorCycleMs) / 1000.0)
                    arcadeScoreManager.emit(
                        at: cocoaPt, color: color,
                        kind: .arcadeScore)
                }
            }
            // Cache the target app icon across drag samples — a single
            // NSRunningApplication lookup per stroke (the bundleID is
            // frozen at button-down) keeps the per-sample path cheap.
            var lastIconBundle = ""
            source.onSample = { [weak controller] s in
                // Read rules + excludes from the live Controller so
                // a hot-reload is visible to the assist tooltips. The
                // tap callback fires these on the main thread but
                // isn't statically @MainActor — `assumeIsolated` is
                // the documented bridge.
                guard let live = controller?.config else { return }
                var valid = false
                var hint: GestureHint? = nil      // nil only before any direction
                if s.pattern.isEmpty {
                    valid = !s.expired            // neutral start
                } else if s.expired || s.cancelled
                    || Matcher.isExcluded(bundleID: s.bundleID,
                                          by: live.excludeApps) {
                    hint = GestureHint(shape: arrows(s.pattern), rows: [])
                } else {
                    // `valid` = the current shape is still a prefix
                    // of at least one reachable rule — i.e. NOT off
                    // every rule yet. We deliberately don't gate on
                    // exact-match-fires-now: drawing just `D` when
                    // rules `DL` / `DLU` exist is still on-track and
                    // should keep the trail in the match colour
                    // (and skip the chomp ghost + GAME OVER cues
                    // until a non-prefix direction lands). The exact-
                    // match-fires signal is still available — any
                    // `hint.rows.fires = true` carries it.
                    let cands = Matcher.candidates(
                        prefix: s.pattern, bundleID: s.bundleID,
                        rules: live.rules,
                        isFocusedFallback: s.isFocusedFallback)
                    valid = !cands.isEmpty
                    hint = assistHint(pattern: s.pattern,
                                      candidates: cands)
                }
                let iconToSet: NSImage??
                if !s.bundleID.isEmpty && s.bundleID != lastIconBundle {
                    lastIconBundle = s.bundleID
                    iconToSet = NSRunningApplication
                        .runningApplications(withBundleIdentifier: s.bundleID)
                        .first?.icon
                } else {
                    iconToSet = nil
                }
                MainActor.assumeIsolated {
                    if let icon = iconToSet { overlay?.setOriginIcon(icon) }
                    overlay?.addPoint(s.point, valid: valid, hint: hint)
                }
            }
            source.onStrokeEnd = {
                lastIconBundle = ""
                MainActor.assumeIsolated { overlay?.clear() }
            }
            Log.line("overlay: enabled (match=\(cfg.overlay.trail.color), "
                     + "noMatch=\(cfg.overlay.trail.colorNoMatch), "
                     + "width=\(cfg.overlay.trail.width))")
        }

        // Push `[overlay]` changes to the live overlay so edits take
        // effect without a restart. `applyConfig` covers every
        // overlay knob; `[trigger]` and the `[recognition]` timing
        // knobs still need a restart (Controller.reload logs them).
        // The favicon prewarm rides on the same callback so the
        // moment a user adds `icon = "favicon:..."` to their config
        // and saves, the host(s) start downloading in the background
        // — no need to wait for the next panel open to populate the
        // cache. The outer `if let overlay` is gone so prewarm fires
        // even on configs that disable the overlay; `overlay?` makes
        // the applyConfig call a no-op when the overlay is nil.
        controller.onConfigChanged = { [weak overlay] new in
            MainActor.assumeIsolated {
                overlay?.applyConfig(new)
                FaviconCache.prewarm(from: new)
                IconSetCache.prewarm(from: new)
            }
        }
        // Boot-time prewarm: kick off background fetches for every
        // remote icon referenced in the current config (favicons
        // and external icon-set entries — lucide / phosphor /
        // tabler / heroicons) before the first panel open. The
        // cache hits are populated by the time the user
        // middle-clicks, so the placeholder flash collapses to
        // "happens only on stale cache / network failure".
        FaviconCache.prewarm(from: controller.config)
        IconSetCache.prewarm(from: controller.config)

        // Post-fire fire-moment effects — decal (Splatoon-style
        // splatter/blob/scorch/star) AND trail-end burst (particle
        // explosion). Both live in their own click-through windows,
        // INDEPENDENT of `[cast.overlay].enabled`, so the user can
        // disable the trail HUD and still get the cursor-anchored
        // fire effects. The managers themselves are declared
        // earlier (so the overlay's cherry hook can close over the
        // arcade-score manager); here we just wire the rule-fire
        // dispatch into them.
        controller.onGestureFire = { [weak controller] cgPoint in
            MainActor.assumeIsolated {
                guard let cfg = controller?.config else { return }
                let cocoaPoint = ScreenCoords.cocoaPoint(fromCG: cgPoint)
                // Resolve the trail colour via TrailColorMode so the
                // decal "trail" fallback honours the dynamic modes
                // (`rainbow` / `neon` / `splatoon`) rather than
                // collapsing to `.systemBlue` when the user picks one.
                let color = TrailColorMode.parse(
                    cfg.overlay.trail.color, fallback: .systemBlue
                ).currentColor(at: CACurrentMediaTime(),
                               strokeSeed: UInt64.random(in: 0..<UInt64.max),
                               cyclePeriod: TimeInterval(
                                cfg.overlay.colorCycleMs) / 1000.0)
                let decalSpec = cfg.fire.decal
                if decalSpec.kind != .off, decalSpec.durationMs > 0 {
                    // Decal is always the Splatoon multi-team palette
                    // (#115 dropped the `color` knob). The full
                    // palette flows through so each splat unit can
                    // pick its own team colour — the Splatoon
                    // "multi-shot" feel where one decal lands a
                    // mix of team inks at the cursor.
                    decalManager.emit(
                        at: cocoaPoint,
                        color: NSColorParse.randomSplatoonInk(),
                        palette: NSColorParse.splatoonInks,
                        kind: decalSpec.kind,
                        durationSec: TimeInterval(decalSpec.durationMs)
                            / 1000.0,
                        size: CGFloat(decalSpec.size))
                }
                if cfg.fire.burst.kind != .off {
                    // Resolve burst colour with the same three-mode
                    // grammar as decal: `""` / `"trail"` inherits the
                    // trail accent, `"splatoon"` picks a random ink,
                    // anything else parses as static colour.
                    let burstSpec = cfg.fire.burst
                    let burstColor: NSColor
                    switch burstSpec.color.trimmingCharacters(
                        in: .whitespaces).lowercased() {
                    case "", "trail":
                        burstColor = color
                    case "splatoon":
                        burstColor = NSColorParse.randomSplatoonInk()
                    default:
                        burstColor = NSColorParse.nsColor(
                            burstSpec.color) ?? color
                    }
                    // Dispatch by kind — only one of the managers
                    // gates on the kind it handles (others no-op),
                    // so the same call shape works regardless of
                    // which arcade-flavour the user picked.
                    burstManager.emit(
                        at: cocoaPoint, color: burstColor,
                        kind: burstSpec.kind,
                        intensity: CGFloat(cfg.intensity.multiplier))
                    arcadeScoreManager.emit(
                        at: cocoaPoint, color: burstColor,
                        kind: burstSpec.kind)
                }
            }
        }
        _ = decalManager   // hold a reference for the process lifetime
        _ = burstManager   // ditto — fire-moment effects need both alive
        _ = arcadeScoreManager   // arcade-score popup manager

        controller.start()

        // Live-reload on config edits (no `--reload` needed). Held for
        // the process lifetime via `app.run()`.
        let watcher = ConfigWatcher(path: WandConfig.path) {
            Log.line("config: file changed — reloading")
            controller.reload(cause: "file-change")
        }
        watcher.start()

        let failsafe = FailsafeMonitor(config: cfg.failsafe)
        failsafe.start()

        app.run()
        exit(0)
    }
}
