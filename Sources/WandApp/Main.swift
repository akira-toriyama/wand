// Entry point: argv → domain dispatch only. Three modes chosen by
// the argv shape: server (bare `wand` — install tap, wait), client
// (`daemon --reload` / `--quit` / `tome --open` — post DNC to the
// running server), standalone (`config --validate` / `--doctor` /
// `cast --test` / `--record` / `--help`). The command bodies live in
// `Commands+<domain>.swift` as extensions of this enum; this file
// owns parsing and the one-verb-per-domain policy, nothing else.
//
// `@main enum WandApp` — NOT top-level `main.swift`. The enum
// form lets a future XCTest `@testable import WandApp` work
// without launching the daemon (same trap as facet/ws-tabs —
// don't reintroduce main.swift).

import AppKit
import Foundation
import CLIKit
import ConfigSchema
import WandCore
import WandAdapterMacOS

@main
enum WandApp {

    static func printHelp() -> Never {
        let help = """
        wand — global mouse-gesture daemon for macOS.

        USAGE
          wand                              run as agent (CGEventTap loop)
          wand <domain> --<verb> [VALUE …]  one-shot control command

        SERVER MODE
          wand                              run as agent. Set WAND_DEBUG=1 in
                                              the environment for verbose log to
                                              stderr + /tmp/wand.log (run.sh sets it).

        daemon — lifecycle (need a running daemon; exit 3 if none)
          wand daemon --reload              re-read ~/.config/wand/config.toml
                                              (also automatic on file save). Live:
                                              [[cast.cursor.rule]] / [exclude].apps /
                                              [cast.recognition] / [cast.overlay] /
                                              [cast.fire]. Restart only: [cast]
                                              button+modifiers, [tome] enabled+
                                              button+modifiers.
          wand daemon --show                print rule count, trigger, last
                                              gestures, counters, last reload
          wand daemon --quit                terminate the running daemon
          wand daemon --resign              re-sign Wand.app with the persistent
                                              "wand Local Signing" identity + restart
                                              (run once after `brew install` / upgrade)

        cast — gesture engine
          wand cast --test PATTERN [APP]    dry-run: which rule would fire for a
                                              pattern (optionally for a bundle id)
          wand cast --record                interactive recorder: draw a gesture,
                                              get a paste-ready [[cast.cursor.rule]] on
                                              stdout. Refuses if the daemon runs.

        tome — launcher menu
          wand tome --open                  ask the daemon to pop the tome menu
            --items <PATH>                    at a screen point with the given
            --at <X> <Y>                      [[tome.cursor.item]] file. Cocoa coords
            [--selection <TEXT>]              (Y-up; --at accepts negatives). For an
            [--title <TEXT>]                  upstream trigger. $WAND_SELECTION is
                                              exported to shell actions if --selection
                                              given (unset otherwise);
                                              --title overrides the AX-fetched
                                              focused-window title for $WAND_TARGET_TITLE.
          wand tome --validate --items <PATH>
                                            validate a standalone items file.

        config — settings
          wand config --validate            validate config.toml against the schema;
                                            exit 0 if valid, 1 on a schema
                                            violation (bad type/enum/range,
                                            typo'd key), 2 if unparseable.
                                              Warnings (clamps, collisions, typos)
                                              print to stderr + /tmp/wand.log.
          wand config --doctor              health check: Accessibility, config,
                                              daemon, event tap, tuning + rules
          wand config --emit-schema         print the config.toml JSON Schema
                                              (Draft-07) to stdout. Generated from
                                              wand's own parser, so it always matches
                                              the binary. Regenerate with:
                                                wand config --emit-schema > config.schema.json

          wand --help, -h                   this help

        EXIT CODES
          0   success
          2   usage / bad flag / invalid config (loud on stderr)
          3   daemon precondition: a daemon command with no daemon running,
              or `cast --record` with a daemon running

        CONFIG
          ~/.config/wand/config.toml is the single source of truth.
          wand never writes to it; runtime CLI flags affect the
          current session only.

        DOCS
          https://github.com/akira-toriyama/wand
        """
        print(help)
        exit(0)
    }

    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())

        // Debug logging is triggered by the WAND_DEBUG env var (set by
        // run.sh), NOT a CLI flag — run.sh and a brew/raw launch start the
        // same artifact, so the signal is injected at launch time. A normal
        // launch sets nothing and stays quiet; `--debug` on argv now exits 2.
        debugMode = ProcessInfo.processInfo.environment["WAND_DEBUG"] != nil

        // Bare `wand` = server mode (the LSUIElement launch path). Every
        // other invocation is a yabai-style `wand <domain> --<verb>` control
        // command. The domain noun is peeled here; CLIKit then tokenizes the
        // rest against that domain's verb-arity spec (so e.g. `--at -100 50`
        // negatives are consumed as values, not mistaken for flags).
        guard let domain = argv.first else { runServer() }
        switch domain {
        case "--help", "-h": printHelp()
        case "daemon": dispatchDaemon(Array(argv.dropFirst()))
        case "cast":   dispatchCast(Array(argv.dropFirst()))
        case "tome":   dispatchTome(Array(argv.dropFirst()))
        case "config": dispatchConfig(Array(argv.dropFirst()))
        default:
            CLIKit.die("wand",
                "unknown command '\(domain)'. Domains: daemon cast tome config "
                + "(or bare `wand` for server). See `wand --help`.")
        }
    }

    // MARK: domain dispatch (CLIKit tokenizes; wand keeps verb policy — D4)

    /// Parse `argv` against `spec`, mapping any usage error to a loud
    /// exit 2. (CLIKit's tokenizer is pure; wand owns the exit.)
    private static func parseOrDie(_ argv: [String], _ spec: CLIKit.Spec) -> CLIKit.Invocation {
        do { return try CLIKit.parse(argv, spec: spec) }
        catch let e as CLIKit.ParseError { CLIKit.die("wand", e.usageMessage) }
        catch { CLIKit.die("wand", "\(error)") }
    }

    /// Exactly one of `verbs` must be present. CLIKit already rejected
    /// unknown flags; this is wand's mutual-exclusion policy (a domain
    /// has one action; modifiers attach to it).
    private static func requireOneVerb(_ inv: CLIKit.Invocation, among verbs: [String],
                                       domain: String) -> String {
        let present = inv.names.filter { verbs.contains($0) }
        if present.count == 1 { return present[0] }
        if present.isEmpty {
            CLIKit.die("wand", "`wand \(domain)` needs a verb: "
                + verbs.joined(separator: " ") + ". See `wand --help`.")
        }
        CLIKit.die("wand", "`wand \(domain)`: incompatible verbs "
            + present.joined(separator: " ") + " — pick one. See `wand --help`.")
    }

    @MainActor
    private static func dispatchDaemon(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--reload": .flag, "--quit": .flag, "--show": .flag, "--resign": .flag,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--reload", "--quit", "--show", "--resign"],
                              domain: "daemon") {
        case "--reload": runClient(cmd: "reload")
        case "--quit":   runClient(cmd: "quit")
        case "--show":   runShow()
        case "--resign": runResign()
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }

    @MainActor
    private static func dispatchCast(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--test": .requiredThenOptional(1), "--record": .flag,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--test", "--record"], domain: "cast") {
        case "--test":
            let vs = inv.values("--test")               // PATTERN [APP]
            runTest(pattern: vs.first ?? "", bundleID: vs.count > 1 ? vs[1] : nil)
        case "--record": runRecord()
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }

    @MainActor
    private static func dispatchTome(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--open": .flag, "--validate": .flag,
            "--items": .value, "--at": .values(2), "--selection": .value, "--title": .value,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--open", "--validate"], domain: "tome") {
        case "--open":
            runTomeOpen(inv)
        case "--validate":
            guard let path = inv.value("--items") else {
                CLIKit.die("wand", "`wand tome --validate` needs --items <PATH>. "
                    + "See `wand --help`.")
            }
            runValidateItems(path: path)
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }

    @MainActor
    private static func dispatchConfig(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--validate": .flag, "--doctor": .flag, "--emit-schema": .flag,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--validate", "--doctor", "--emit-schema"],
                              domain: "config") {
        case "--validate": runValidateConfig()
        case "--doctor":   runDoctor()
        case "--emit-schema":
            // Generated from the same declarative `configSpec` that decodes
            // the config, so editor schema and parser can't drift.
            print(WandConfig.jsonSchema, terminator: "")
            exit(0)
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }


    /// Exit fatally when `[failsafe]` is missing — same policy for
    /// both `--validate` and `runServer()` so they don't drift.
    /// See CLAUDE.md "Safety invariants" for the WHY of the
    /// mandatory-block rule.
}
