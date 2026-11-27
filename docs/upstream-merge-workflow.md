# Upstream merge workflow

This fork currently follows `noahhaasis/negs` `main` for new app features. The older parity audit in `upstream-sync.md` describes a separate, historical Python parity target; it does not select the branch for this app sync.

## Sync policy

- Start from the custom app branch until its integration is promoted. For routine syncs, use `origin/main` after that promotion.
- The custom base is authoritative for a conflicted file. `scripts/start_upstream_sync.sh` keeps the custom version for each conflicted path and preserves upstream's non-conflicting files and hunks.
- Also review upstream deletions that do not conflict: a file unchanged on the custom branch can still be a required dependency of custom build or app code. Check deleted paths referenced by custom scripts (for example `core/ODIN_VERSION` consumed by `core/build.py`) and restore them from the custom base when still required.
- Review the merge diff and record the base SHA and upstream SHA. The helper leaves the merge uncommitted for review.

Run a sync locally:

```sh
rtk proxy env UPSTREAM_SYNC_BRANCH="upstream-sync-local-$(date -u +%Y%m%d-%H%M%S)" \
  bash scripts/start_upstream_sync.sh origin/studio-port-upstream-sync
```

The scheduled GitHub workflow checks for new upstream commits daily, merges them onto the configured base, resolves conflicts using this policy, builds and verifies the universal app, then opens a PR. Set the repository variable `UPSTREAM_SYNC_BASE_BRANCH` to the branch containing the accepted custom app; it defaults to `studio-port-upstream-sync` until the integration is promoted to `main`.

## Universal macOS acceptance

Build only the universal app package. The package script requires at least 6 GiB free by default, checks both Rust target libraries and the active macOS SDK before compiling, serializes Rust builds by architecture, and verifies the resulting ZIP. Adjust `MIN_FREE_BUILD_GB` only after checking the available space against the full build's peak use.

```sh
rtk proxy env MACOS_ARCHS="arm64 x86_64" CLEAN_BUILD_CACHE=0 \
  bash scripts/package_macos_app.sh
rtk lipo -archs dist/negs-macos/Negs.app/Contents/MacOS/NegsApp
```

Confirm both `arm64` and `x86_64` are present. Launch the app and inspect the updated workflows and custom Negs UI before promoting the PR. The package report is at `dist/negs-macos/package-report.json`.

Do not promote a sync just because its merge and package build completed: review the code diff and launch the packaged app. The sync workflow never writes to `upstream` or updates the fork's base branch directly.
