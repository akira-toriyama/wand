// Expand `LauncherItem.dynamic` rows into NSMenuItems at menu-open
// time. The parent item carries a shell command; we run it under
// `/bin/sh -c`, bound it to a short timeout so a slow command can't
// freeze the menu, and walk stdout one line per child item with
// `{line}` substituted into the template fields.
//
// Stays in WandAdapterMacOS because the rendered NSMenuItem +
// `setIconFor` path are AppKit-only. Core only carries the data —
// `LauncherTemplate` knows the kind + raw payload string.

import AppKit
import Foundation
import WandCore

@MainActor
enum DynamicItems {

    /// Run a `dynamic` item's shell, parse the output, and emit the
    /// child NSMenuItems for the parent's submenu. Returns at least
    /// one disabled placeholder item on every code path — empty
    /// stdout / non-zero exit / timeout — so the user always sees
    /// *something* and knows the producer ran.
    static func expand(parent: LauncherItem,
                        actionTarget: MenuActionTarget) -> [NSMenuItem] {
        guard !parent.dynamic.isEmpty, let template = parent.template else {
            return [placeholder("(invalid dynamic)")]
        }
        let outcome = runShell(parent.dynamic, timeoutMs: timeoutMs)
        switch outcome {
        case .timeout:
            return [placeholder("(timeout)")]
        case .failed(let exit):
            return [placeholder("(error: exit \(exit))")]
        case .ok(let stdout):
            let lines = stdout
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return [placeholder("(no items)")] }
            return lines.map { line in
                renderChild(template: template, line: line,
                            actionTarget: actionTarget)
            }
        }
    }

    // MARK: - placeholder

    private static func placeholder(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    // MARK: - one child row

    /// Build one child `NSMenuItem` for a stdout `line`. `{line}` is
    /// substituted in the template name / icon / payload. The
    /// resulting `Action` is stashed on the item via a per-row
    /// `LauncherItem` so `MenuActionTarget.fire` can dispatch it
    /// through the same path as static items.
    private static func renderChild(template: LauncherTemplate,
                                     line: String,
                                     actionTarget: MenuActionTarget) -> NSMenuItem {
        let name = template.name.replacingOccurrences(of: "{line}", with: line)
        let iconSpec = template.icon.isEmpty ? "" :
            template.icon.replacingOccurrences(of: "{line}", with: line)
        let body = template.payload.replacingOccurrences(of: "{line}", with: line)

        let action: Action
        switch template.kind {
        case .key:   action = .key(body)
        case .ax:    action = .ax(body)
        case .shell: action = .shell(body)
        case .url:   action = .url(body)
        }

        // Reuse the same MenuActionTarget the rest of the menu uses
        // by stashing a synthetic LauncherItem on representedObject.
        // `apps` and `group` are irrelevant at click time — only
        // `action` matters for dispatch.
        let synthetic = LauncherItem(
            name: name, group: [], separatorBefore: false,
            apps: ["*"], icon: iconSpec,
            dynamic: "", template: nil, action: action)

        let mi = NSMenuItem(title: name,
                            action: #selector(MenuActionTarget.fire(_:)),
                            keyEquivalent: "")
        mi.target = actionTarget
        mi.representedObject = synthetic
        if !iconSpec.isEmpty {
            mi.image = LauncherMenu.resolveItemIcon(iconSpec)
        }
        return mi
    }

    // MARK: - bounded shell exec

    /// Hard cap on the producer command. Anything slower freezes the
    /// menu (popUp blocks the main thread while we resolve children).
    /// Tunable later via config if a real use case demands it.
    private static let timeoutMs = 500

    private enum ShellOutcome {
        case ok(String)
        case timeout
        case failed(Int32)
    }

    private static func runShell(_ cmd: String, timeoutMs: Int) -> ShellOutcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        do { try p.run() } catch {
            Log.line("dynamic-item: spawn failed — \(error)")
            return .failed(-1)
        }

        // Bound the wait — if the process is still alive after the
        // budget, kill it. Reading stdout inside the deadline avoids
        // a stale pipe blocking us forever after the timeout fires.
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        let killer = DispatchWorkItem {
            if p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)

        // Drain pipe + wait — on timeout the terminate above unblocks
        // waitUntilExit and we read whatever stdout the child managed
        // to flush before SIGTERM.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        let text = String(data: data, encoding: .utf8) ?? ""
        if p.terminationReason == .uncaughtSignal {
            return .timeout
        }
        if p.terminationStatus != 0 {
            return .failed(p.terminationStatus)
        }
        return .ok(text)
    }
}
