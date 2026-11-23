# Upstream merge workflow

This fork keeps its custom macOS presentation and image-processing features while adopting upstream engine and platform updates. Integrate upstream on an isolated branch so changes can be reviewed together without rewriting the fork's working branch.

## Start a sync

1. Confirm the worktree is clean and `origin` points to this fork while `upstream` points to `noahhaasis/negs`.
2. Start from the desired fork base. Routine syncs start from `origin/main`. For the first integration of existing custom work, pass that branch explicitly:

   ```sh
   scripts/start_upstream_sync.sh origin/studio-port-upstream-sync
   ```

   The helper fetches both remotes, creates `upstream-sync-YYYY-MM-DD`, and merges `upstream/main`. With no argument, it uses `origin/main`.
3. If conflicts remain, resolve each by behavior. Preserve Negs-specific UI and processing while adopting compatible upstream changes. Do not globally choose `--ours` or `--theirs`. Run `git diff --check`, inspect `git diff --name-only --diff-filter=U`, and confirm conflict markers are gone.
4. Review the complete diff against both parents. Pay particular attention to Rust pipeline and parameter changes, SwiftUI call sites, package scripts, new resources, and upstream migration notes.

## Validate the universal macOS app

Keep validation focused on the app bundle. Serialize Cargo, SwiftPM, and packaging builds, then build both macOS slices:

```sh
MACOS_ARCHS="arm64 x86_64" CLEAN_BUILD_CACHE=0 scripts/package_macos_app.sh
lipo -archs dist/negs-macos/Negs.app/Contents/MacOS/NegsApp
```

Confirm `lipo` reports both `arm64` and `x86_64`. The packaging script runs `scripts/verify_macos_package.py` against its generated release archive and writes `dist/negs-macos/package-report.json`. Launch the packaged app and inspect the updated workflows alongside the custom Negs UI. Do not gate this sync on Windows, web, CLI-only, or Intel-only package builds.

Record the upstream commit, fork base, conflict resolutions, build output, and visible app checks in the integration commit or pull request. A successful compile alone is not visual app acceptance.

## Promote the integration

Push the integration branch to `origin` and open a pull request targeting this fork's `main`. After review and validation, update only `origin/main` through the pull request or a verified fast-forward. Never push this fork's work to `upstream/main`. Keep the integration branch as an audit trail until accepted.

The helper intentionally does not resolve conflicts, push branches, or update `main`; upstream changes can affect shared engine and UI behavior, so those steps need review.
