# Canonical copy of the Homebrew formula. The live copy lives in the tap repo
# at akira-toriyama/homebrew-tap as Formula/wand.rb. Keep this in sync and
# bump `url` / `sha256` on every release tag (see packaging/homebrew/README.md).
#
# The release.yml workflow's `update-tap` job does the bump automatically when
# a draft release is Published — this file is the manual-edit reference, not
# what brew actually reads.
class Wand < Formula
  desc "macOS daemon for cursor-anchored mouse automation — cast + tome"
  homepage "https://github.com/akira-toriyama/wand"
  # Reference copy. The REAL sha256 lives only in the tap's Formula/wand.rb
  # (a sha cannot self-reference the tarball that contains it). Per-release
  # steps: packaging/homebrew/README.md.
  url "https://github.com/akira-toriyama/wand/archive/refs/tags/v3.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/akira-toriyama/wand.git", branch: "main"

  # Builds with the Swift toolchain from Xcode *or* the Command Line Tools;
  # a full Xcode.app is not required. swift-tools-version 6.0 needs a Swift 6
  # toolchain — older toolchains fail fast with a clear version error.
  depends_on macos: :tahoe

  def install
    # SwiftPM resolves sill / swift-toml-edit from GitHub at build time;
    # --disable-sandbox lets swiftpm write its cache.
    system "swift", "build", "--disable-sandbox", "-c", "release"

    app = prefix/"Wand.app"
    (app/"Contents/MacOS").mkpath
    cp "Info.plist", app/"Contents/Info.plist"
    cp ".build/release/wand", app/"Contents/MacOS/wand"

    # Ship the signing helper under share/ so users can recover the
    # persistent-TCC path later via `brew reinstall`, without needing to
    # clone the source repo.
    pkgshare.install "setup-signing-cert.sh"
    chmod 0755, pkgshare/"setup-signing-cert.sh"

    # Ad-hoc sign the bundle. The persistent "wand Local Signing"
    # identity is not set up here: Homebrew's build sandbox blocks
    # `security` from touching the user's login keychain, and the
    # script needs a terminal for the login password it asks for once
    # (without one it exits 1). The user runs the shipped script once
    # in a terminal, then `wand daemon --resign` after every install /
    # upgrade — same pattern as chord.
    system "codesign", "--force", "--sign", "-", app

    # Same binary doubles as the thin CLI client (daemon --reload / --quit / etc).
    bin.install_symlink app/"Contents/MacOS/wand" => "wand"
  end

  # `brew services start wand` → a LaunchAgent that runs the daemon at
  # login. Runs the executable inside the bundle so TCC keys the
  # Accessibility grant to the same (persistent self-signed) identity
  # the user granted to Wand.app. keep_alive restarts it if it dies;
  # an un-granted start doesn't crash (the app loop stays up), so this
  # won't hot-loop while the user is granting AX.
  service do
    run [opt_prefix/"Wand.app/Contents/MacOS/wand"]
    keep_alive true
    log_path var/"log/wand.log"
    error_log_path var/"log/wand.log"
  end

  def caveats
    <<~EOS
      wand is a macOS daemon for cursor-anchored mouse automation
      (LSUIElement, no Dock icon). Two trigger families share one daemon:

        - cast (right-button + drag → recognise a LURD shape → fire a rule)
        - tome (middle-click → non-activating panel of rows, opt-in)

      Both act on the window UNDER the cursor — not the focused one —
      so actions land where you're pointing even on multi-display setups.

      First-run setup:
        1) Drop the config template:
             curl --create-dirs -o ~/.config/wand/config.toml \\
               https://raw.githubusercontent.com/akira-toriyama/wand/main/config.toml
        2) Launch the daemon once so macOS shows the AX prompt:
             open #{opt_prefix}/Wand.app
        3) Grant Accessibility to "wand" (System Settings → Privacy &
           Security → Accessibility), then relaunch with `wand`.

      CLI (no daemon needed for these):
        wand config --validate   parse config.toml
        wand config --doctor     Accessibility / config / daemon / tap check
        wand cast --record       interactive recorder — draw, see the pattern
        wand --help              all domains and verbs

      Client commands (talk to the running daemon over DNC):
        wand daemon --reload     re-read config.toml live
        wand daemon --quit       terminate the running daemon
        wand tome --open         external-trigger entry to the tome
                                 (for an upstream trigger: a chord hotkey,
                                 or a text-selection observer)

      Auto-start on login:
        brew services start wand
        (or add #{opt_prefix}/Wand.app to System Settings → General →
        Login Items). Grant Accessibility to "wand" first, or the
        background daemon can't tap mouse events.

      Persistent Accessibility grants across `brew upgrade` need a stable
      code-signing identity; the install signs ad-hoc (the build sandbox
      cannot reach your login keychain). Run once, in a terminal — it
      asks for your login password once:
        #{opt_pkgshare}/setup-signing-cert.sh
        wand daemon --resign
      After every `brew upgrade wand`:
        wand daemon --resign
      Verify: codesign -dvv #{opt_prefix}/Wand.app
        # expect: Authority="wand Local Signing"

      Migrating from `stroke` (pre-v3.0):
        mkdir -p ~/.config/wand && \\
          mv ~/.config/stroke/config.toml ~/.config/wand/  2>/dev/null
        brew uninstall stroke 2>/dev/null
        # Re-grant Accessibility — Wand.app is a new bundle id to TCC.
    EOS
  end

  test do
    assert_path_exists prefix/"Wand.app/Contents/MacOS/wand"
    # `config --validate` touches no event tap / AX — safe in the test
    # sandbox. It needs a config with the mandatory [failsafe] block
    # (a missing block is a fatal error by design), so seed one under
    # the test HOME.
    (testpath/".config/wand").mkpath
    (testpath/".config/wand/config.toml").write "[failsafe]\n"
    system bin/"wand", "config", "--validate"
  end
end
