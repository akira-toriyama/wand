// `daemon --resign`: re-sign the installed Wand.app with the
// persistent identity and restart the daemon.

import AppKit
import Foundation
import CLIKit
import ConfigSchema
import WandCore
import WandAdapterMacOS

extension WandApp {

    /// `wand --resign` re-signs the installed Wand.app with the
    /// persistent `wand Local Signing` self-signed identity and
    /// restarts the daemon. Necessary after every `brew install` /
    /// `brew upgrade wand`, because Homebrew's build sandbox
    /// blocks the in-formula `setup-signing-cert.sh` from touching
    /// the user's login keychain — install falls back to ad-hoc
    /// signing and TCC re-prompts for Accessibility on every
    /// upgrade. Same pattern as chord 0.3.3's `--resign`.
    ///
    /// Exit codes:
    ///   0 — re-signed (restart attempted, best-effort)
    ///   1 — codesign failed
    ///   2 — no Wand.app found in any expected location
    ///   3 — signing identity missing (run setup-signing-cert.sh first)
    static func runResign() -> Never {
        guard let appPath = findWandApp() else {
            FileHandle.standardError.write(Data((
                "wand: no Wand.app found at "
                + "/opt/homebrew/Cellar/wand/*/, /Applications, "
                + "or ~/Applications.\n"
                + "        install via "
                + "`brew install akira-toriyama/tap/wand` or "
                + "package locally first.\n"
            ).utf8))
            exit(2)
        }
        print("wand: detected Wand.app at \(appPath)")

        let identity = "wand Local Signing"
        guard hasSigningIdentity(identity) else {
            let setupHint = setupCertHint()
            FileHandle.standardError.write(Data((
                "wand: no '\(identity)' identity in your login keychain.\n"
                + "        run once:\n"
                + "          \(setupHint)\n"
                + "          wand --resign\n"
            ).utf8))
            exit(3)
        }

        print("wand: signing with identity '\(identity)'")
        let codesignExit = runProcess(
            "/usr/bin/codesign",
            args: ["--force", "--sign", identity, appPath])
        guard codesignExit == 0 else {
            FileHandle.standardError.write(Data((
                "wand: codesign failed (exit \(codesignExit))\n"
            ).utf8))
            exit(1)
        }

        print("wand: restarting daemon")
        let brewExit = runProcess(
            "/opt/homebrew/bin/brew",
            args: ["services", "restart", "wand"],
            captureOutput: true)
        if brewExit == 0 {
            print("wand: restarted via `brew services restart wand`")
            exit(0)
        }
        // Only `homebrew.mxcl.wand` — wand doesn't ship an
        // in-repo LaunchAgent template, so no `com.wand.wand`
        // label exists in the wild. Adding it as a fallback was
        // dead code (kickstart would always 113 / no such service).
        let label = "homebrew.mxcl.wand"
        let kick = runProcess(
            "/bin/launchctl",
            args: ["kickstart", "-k", "gui/\(getuid())/\(label)"],
            captureOutput: true)
        if kick == 0 {
            print("wand: restarted via `launchctl kickstart \(label)`")
            exit(0)
        }
        FileHandle.standardError.write(Data((
            "wand: re-signed, but couldn't restart the daemon — "
            + "start it manually.\n"
        ).utf8))
        exit(0)
    }

    /// Pick the first existing Wand.app from the canonical install
    /// locations. The brew Cellar (which carries the live binary) is
    /// preferred over manual /Applications copies.
    private static func findWandApp() -> String? {
        let cellar = "/opt/homebrew/Cellar/wand"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: cellar) {
            // `.numeric` makes "2.10.0" > "2.2.0" — a plain string
            // sort would silently pick the older 2.2.0 as "latest"
            // once a 2.10 series ships.
            let sorted = versions.sorted { a, b in
                a.compare(b, options: .numeric) == .orderedDescending
            }
            for v in sorted {
                let p = "\(cellar)/\(v)/Wand.app"
                if FileManager.default.fileExists(atPath: p) { return p }
            }
        }
        for candidate in [
            "/Applications/Wand.app",
            "\(NSHomeDirectory())/Applications/Wand.app",
        ] {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Untrusted self-signed certs don't appear in `find-identity`
    /// (that filter lists trusted identities only). Use
    /// `find-certificate` which surfaces untrusted entries too.
    private static func hasSigningIdentity(_ name: String) -> Bool {
        runProcess(
            "/usr/bin/security",
            args: ["find-certificate", "-c", name,
                   "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"],
            captureOutput: true
        ) == 0
    }

    /// Best-effort guess at where `setup-signing-cert.sh` lives on
    /// the user's machine. brew installs ship it under
    /// `share/wand/`, dev installs have it at the repo root.
    private static func setupCertHint() -> String {
        let brewShared = "/opt/homebrew/share/wand/setup-signing-cert.sh"
        if FileManager.default.fileExists(atPath: brewShared) {
            return brewShared
        }
        return "./setup-signing-cert.sh"
    }

    /// Spawn + wait. Returns the child's exit code on completion,
    /// or `-1` when `Process.run()` itself failed (executable not
    /// found, permission denied, etc.) — the catch path also emits
    /// a stderr line so the caller's generic "exit -1" message
    /// isn't the only signal.
    @discardableResult
    private static func runProcess(_ executable: String,
                                   args: [String],
                                   captureOutput: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if captureOutput {
            p.standardOutput = FileHandle.nullDevice
            p.standardError  = FileHandle.nullDevice
        }
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            FileHandle.standardError.write(Data(
                "wand: couldn't launch \(executable): \(error)\n".utf8))
            return -1
        }
    }
}
