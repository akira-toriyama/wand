# Canonical copy of the Homebrew formula. The live copy lives in the tap repo
# at akira-toriyama/homebrew-tap as Formula/stroke.rb. Keep this in sync and
# bump `url` / `sha256` on every release tag (see packaging/homebrew/README.md).
#
# The release.yml workflow's `update-tap` job does the bump automatically when
# a draft release is Published — this file is the manual-edit reference, not
# what brew actually reads.
class Stroke < Formula
  desc "Global mouse-gesture daemon for macOS — acts on the window under the cursor"
  homepage "https://github.com/akira-toriyama/stroke"
  # Reference copy. The REAL sha256 lives only in the tap's Formula/stroke.rb
  # (a sha cannot self-reference the tarball that contains it). Per-release
  # steps: packaging/homebrew/README.md.
  url "https://github.com/akira-toriyama/stroke/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/akira-toriyama/stroke.git", branch: "main"

  # Builds with the Swift toolchain from Xcode *or* the Command Line Tools;
  # a full Xcode.app is not required. swift-tools-version 6.0 needs a Swift 6
  # toolchain — older toolchains fail fast with a clear version error.
  depends_on macos: :ventura

  def install
    # No external SwiftPM deps; --disable-sandbox lets swiftpm write its cache.
    system "swift", "build", "--disable-sandbox", "-c", "release"

    app = prefix/"Stroke.app"
    (app/"Contents/MacOS").mkpath
    cp "Info.plist", app/"Contents/Info.plist"
    cp ".build/release/stroke", app/"Contents/MacOS/stroke"

    # Ship the signing helper under share/ so users can recover the
    # persistent-TCC path later via `brew reinstall`, without needing to
    # clone the source repo.
    pkgshare.install "setup-signing-cert.sh"
    chmod 0755, pkgshare/"setup-signing-cert.sh"

    # Hybrid signing (best-effort cert, loud fallback):
    # 1. Try to set up / reuse a stable per-user self-signed identity in
    #    the login keychain. When this works, the code-signing leaf hash
    #    stays constant across reinstalls, so TCC grants (Accessibility)
    #    persist across `brew upgrade`.
    # 2. If the script fails — locked login keychain, brew sandbox
    #    quirks, missing openssl, etc. — fall back to ad-hoc signing
    #    (always works) and emit a LOUD warning with a copy-pasteable
    #    recovery path. Without the warning the fallback is silent and
    #    users only notice when macOS re-prompts on every upgrade.
    #    Same pattern facet / ws-tabs use.
    sign_id = "-"
    if quiet_system "./setup-signing-cert.sh"
      id_file = ".signing-id"
      sign_id = File.read(id_file).strip if File.exist?(id_file)
    end
    system "codesign", "--force", "--sign", sign_id, app

    if sign_id == "-"
      opoo <<~EOS
        Could not set up a stable self-signed identity in the login keychain —
        signed Stroke.app ad-hoc. The app works fine, but every
        `brew upgrade stroke` produces a new code hash, so macOS will
        re-prompt for Accessibility on every upgrade.

        To make grants persist across upgrades, run once after install:
          #{opt_pkgshare}/setup-signing-cert.sh
          brew reinstall stroke

        Verify:
          codesign -dvv #{opt_prefix}/Stroke.app
          # expect: Authority="stroke Local Signing"
      EOS
    else
      ohai "Signed Stroke.app with stable self-signed identity " \
           "(\"#{sign_id}\") — TCC grants persist across upgrades."
    end

    # Same binary doubles as the thin CLI client (--reload / --quit / etc).
    bin.install_symlink app/"Contents/MacOS/stroke" => "stroke"
  end

  def caveats
    <<~EOS
      stroke is a global mouse-gesture daemon (LSUIElement, no Dock icon).
      It acts on the window UNDER the cursor — not the focused one — so
      gestures land where you're pointing even on multi-display setups.

      First-run setup:
        1) Drop the config template:
             curl --create-dirs -o ~/.config/stroke/config.toml \\
               https://raw.githubusercontent.com/akira-toriyama/stroke/main/config.toml
        2) Launch the daemon once so macOS shows the AX prompt:
             open #{opt_prefix}/Stroke.app
        3) Grant Accessibility to "stroke" (System Settings → Privacy &
           Security → Accessibility), then relaunch with `stroke`.

      CLI (no daemon needed for these):
        stroke --validate    parse config.toml
        stroke --record      interactive recorder — draw, see the pattern
        stroke --help        all flags

      Client commands (talk to the running daemon over DNC):
        stroke --reload      re-read config.toml live
        stroke --quit        terminate the running daemon

      Auto-start on login (optional):
        Add #{opt_prefix}/Stroke.app to System Settings → General → Login Items.

      Persistent Accessibility grants across `brew upgrade` need a stable
      code-signing identity. The install creates one automatically when it
      can; if the install printed a "fell back to ad-hoc" warning (or
      `codesign -dvv #{opt_prefix}/Stroke.app` shows no Authority line),
      run once:
        #{opt_pkgshare}/setup-signing-cert.sh
        brew reinstall stroke
    EOS
  end

  test do
    assert_path_exists prefix/"Stroke.app/Contents/MacOS/stroke"
    # --validate touches no event tap / AX — safe in the test sandbox.
    system bin/"stroke", "--validate"
  end
end
