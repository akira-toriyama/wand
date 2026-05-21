# Homebrew packaging

stroke ships through the personal tap at
[`akira-toriyama/homebrew-tap`](https://github.com/akira-toriyama/homebrew-tap)
as `Formula/stroke.rb`. The file in
[`stroke.rb`](stroke.rb) here is the **reference copy** — it can't carry
a real `sha256` (a hash cannot self-reference the tarball that contains
it) so a fresh checkout edited by hand would fail until the live tap
copy is bumped. Treat this directory as documentation; the tap is the
source of truth.

## Release flow

The release plumbing is automated end-to-end:

1. **Merge `feat:` / `fix:` / `perf:` commits to `main`.**
   [`release.yml`](../../.github/workflows/release.yml) runs git-cliff to
   compute the next semver, builds `Stroke.app` (ad-hoc signed for CI;
   reproducible per-machine when users `brew reinstall`), zips it, and
   updates a single rolling **DRAFT** GitHub Release with notes +
   `Stroke.zip` attached. No tag is created yet.
2. **Review the draft in the GitHub UI and click Publish.** GitHub creates
   the tag (`vX.Y.Z`) on the target commit at publish time.
3. **[`update-tap.yml`](../../.github/workflows/update-tap.yml) fires on
   `release:published`**, downloads the source tarball, computes its
   sha256, and bumps `Formula/stroke.rb` in the tap repo to the new tag.
   Idempotent — re-running on the same tag is a no-op when the formula
   already matches. Requires the `HOMEBREW_TAP_TOKEN` repo secret
   (fine-grained PAT with `Contents: Read & write` scoped to the tap).
4. **Users get the update.** `brew upgrade stroke` pulls the new tag and
   re-installs from source.

`workflow_dispatch` with `dry_run = true` is a full preview (no draft, no
version consumed, no tap bump). Use it to sanity-check release notes
before a sensitive bump.

## TCC grant persistence across `brew upgrade`

The formula's install step tries `./setup-signing-cert.sh` first. When
that succeeds, every `brew reinstall` / `brew upgrade` signs the bundle
with the same stable identity, so the Accessibility grant stays put.

The script can fail inside the Homebrew install sandbox (locked login
keychain, openssl wrappers, etc.). In that case the install falls back
to ad-hoc signing and emits a LOUD warning (per
[`stroke.rb`](stroke.rb)'s `opoo` branch) with a copy-pasteable recovery
path: run the script outside the sandbox, then `brew reinstall stroke`.
Same hybrid pattern facet and ws-tabs use.

## Bumping by hand (escape hatch)

If `update-tap` is broken or the tap needs a manual touch, the steps
match what the workflow does:

```sh
TAG=v1.2.3
curl -fsSL -o /tmp/src.tgz \
  "https://github.com/akira-toriyama/stroke/archive/refs/tags/${TAG}.tar.gz"
SHA="$(sha256sum /tmp/src.tgz | awk '{print $1}')"

cd /path/to/akira-toriyama/homebrew-tap
sed -i -E "s|archive/refs/tags/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz|archive/refs/tags/${TAG}.tar.gz|g" Formula/stroke.rb
sed -i -E "s|sha256 \"[0-9a-f]{64}\"|sha256 \"${SHA}\"|g"                                            Formula/stroke.rb
# Drop a leftover `revision N` line on any version bump (a fresh tag
# naturally resets revision).
sed -i -E '/^  revision [0-9]+$/d' Formula/stroke.rb
git commit -am "homebrew: bump stroke to ${TAG}"
git push
```
