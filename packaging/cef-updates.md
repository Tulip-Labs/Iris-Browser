# Keeping Iris (Chromium) on the newest CEF

Iris (Chromium) is only as safe as the Chromium inside libcef. Chromium ships
security fixes every week or so; `.github/workflows/cef-update.yml` carries
them into Iris without anyone typing a version.

## What runs

Twice a day (`23 5,17 * * *` UTC) and on demand from the Actions tab:

1. `packaging/check/cef-update.py latest` reads Spotify's `index.json`, takes
   the newest **stable** linux64 build that has a **minimal** tarball, and
   compares it with `packaging/cef_version.lock`.
2. If it is newer (or Spotify rebuilt the same version: another SHA-1, or the
   lock has no checksums yet), the workflow downloads the tarball (about
   320 MB), checks the SHA-1 against the index, and measures the SHA-256.
3. `cef-update.py apply` rewrites the lock, the CEF source in the Flatpak
   manifest (URL, SHA-256, comment), the docs that name the build, Iris
   (Chromium)'s patch version and its release notes. It opens a pull request
   from `cef-update/<chromium version>`.
4. A pull request made with the workflow's token starts no workflows, so the
   workflow starts `linux.yml` (CEF only: Rust core tests, bindings checked
   against the new headers, ABI check, Odin tests, Flatpak build, headless
   Weston run) and `cef-smoke.yml` on that branch, and waits.
5. Green and the same Chromium major: it merges (squash) and starts
   `release-cef.yml` for the new `cef-vX.Y.Z`. Green and a **new major**: it
   comments and leaves the merge to a person. Red: it comments and fails the
   run, so GitHub emails you; nothing is merged and Iris stays on the CEF in
   the lock.

The workflows read the pin from the lock (`packaging/check/cef-pin.sh`) and
never name a CEF version, so the bot never has to edit a workflow file (a
workflow run with `GITHUB_TOKEN` is not allowed to).

## One-time repository settings

- Settings > Actions > General > Workflow permissions: **Read and write**,
  and **Allow GitHub Actions to create and approve pull requests**.
- If `main` is protected: the merge needs the checks to pass (they attach to
  the branch's head commit, so they count) and no required human review, or
  the pull request waits for you, which is a safe way to fail.
- Set the repository variable `CEF_AUTORELEASE` to `false` to stop at the
  merge and publish releases yourself.

## Limits, said plainly

- **The free tier cannot build Chromium or CEF** (about 150 GB of disk, hours
  of CPU). This downloads Spotify's prebuilt minimal build, which is why it
  fits. There is no `libcef_dll_wrapper` to build: Iris calls CEF's C API.
- **It takes longer than 5 to 10 minutes.** The 320 MB download, the Rust
  core, the Flatpak build and the Weston run make one update about 30 to 60
  minutes on a free runner (unmeasured). The waiting job uses runner time:
  public repositories have none metered; a private one spends its free
  minutes.
- **Fixes arrive after Spotify publishes, not when Chromium does.** Spotify
  builds CEF some hours to days after Chrome's stable release; this polls
  twice a day. "Within hours" is not promised.
- **The index and workflow have not run yet.** They were written where
  `cef-builds.spotifycdn.com` is unreachable. The decision logic has tests
  against a made-up index (`python3 -I packaging/check/test_cef_update.py`);
  the first real run is the real test. Run it by hand once from the Actions
  tab and read the log.
- **Scheduled workflows in a public repository are switched off after 60 days
  without activity.** The workflow re-enables itself each run (best effort,
  unverified); merged update pull requests count as activity.
- **Major versions** change the C API: the bindings are frozen at API 15600
  and `bind_cef.sh` regenerates them in CI, so a new major usually needs a
  person even when the build is green.
- The first run fills in the lock's empty checksums (same CEF, no release).
