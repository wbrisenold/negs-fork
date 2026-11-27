# Negs project guidance

## Targets and repository boundaries

- The current Negs source of truth is branch `studio-port-upstream-sync`; build the Intel macOS app from a clean commit on that branch after it is pushed to `origin`.
- The codebase-memory graph indexes this checkout as `negs-source-truth`; use that project alias with graph tools rather than the filesystem path.
- The active workstation target is Intel macOS (`x86_64-apple-darwin`). Keep Intel build, preview, and packaging paths working when changing native code.
- Keep the `upstream` remote pointed at `noahhaasis/negs`. Develop and push this fork's work on a branch; never push this fork's feature work to upstream `main`.
- Core image processing belongs in the Rust crates. SwiftUI owns macOS presentation and interaction. Preserve the CLI, web, and non-macOS builds unless a task explicitly narrows scope.
- Keep generated output (`target/`, `.build/`, `/dist/`), personal image assets, and locally licensed LUTs out of Git. Do not add user photos or local app bundles to commits.
- The Referent LogC3 LUT is third-party material. Local packaging may bundle the copy installed by the developer, but source archives and public GitHub releases must not redistribute it without permission. The app can use a bundled local copy or the user's Resolve-installed/custom LUT.
- When creating, updating, or reporting GitHub issues, follow [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) so completion reflects merged PRs and their target branch.

## Preview performance contract

- Keep interactive RAW previews at or below 38% of the source dimensions. `EditorModel.rawPreviewScale(requested:)` is the single clamp: requested quality may be lower, never higher. Full-resolution export remains separate from the interactive preview path.
- Keep expensive full-frame exposure metering on the reduced-area meter path; do not restore a full-resolution wide-kernel blur for the meter. Preserve asynchronous/coalesced preview work and reuse cached decoded/processed data where valid; slider changes should not synchronously block the main/UI thread.
- Treat performance as a regression-gated feature. The optimized Intel Rust gate is in `.github/workflows/release.yml`: run the 12 MP meter test with a 500 ms ceiling and verify the 38% RAW preview dimensions. Keep both checks on the `x86_64-apple-darwin` release test path.
- Local gate commands:

  ```sh
  CARGO_TARGET_X86_64_APPLE_DARWIN_RUNNER='arch -x86_64' \
    cargo test --locked --release --target x86_64-apple-darwin -p spektrafilm-core --lib metering_preview_keeps_area_reduction_on_large_raw_frames
  CARGO_TARGET_X86_64_APPLE_DARWIN_RUNNER='arch -x86_64' \
    cargo test --locked --release --target x86_64-apple-darwin -p spektrafilm-core --lib interactive_preview_at_editor_quality_keeps_expected_detail
  swift test --package-path macos \
    --scratch-path target/macos-app/swift-x86_64-apple-macosx14.0 \
    -c debug --triple x86_64-apple-macosx14.0 \
    --filter QuickFrameTests/testRawPreviewQualityScaleIs38PercentAndNeverUpscales
  ```

- Report measured timings with the host, build mode, image dimensions, preview scale, and whether the number is engine-only or end-to-end. A single local result is not a general performance promise. Verify user-visible RAW behavior separately from unit tests and meter microbenchmarks.

## Build and package

- Read [`docs/macos-app-build.md`](docs/macos-app-build.md) before building or opening Negs. It defines the only supported source branch, build commands, canonical app path, promotion checks, and GitHub artifact gate.
- For app-wide UI consistency requests or screenshot-based UI bugs, follow the screen audit and label review in [`docs/native-macos-ui.md`](docs/native-macos-ui.md) before making broad changes.
- For user-visible UI work, follow the fresh-app visual acceptance steps in [`docs/macos-app-build.md`](docs/macos-app-build.md); source changes and a successful build alone do not establish that the requested change is visible or usable.
- Run `rtk scripts/run_cached_debug_app.sh` for iterative Intel UI work. It builds, verifies, promotes, and opens only `dist/negs-macos/Negs.app`.
- Use `MACOS_ARCHS=x86_64 rtk bash scripts/package_macos_app.sh` for the optimized Intel release package. Local package builds retain caches by default; set `CLEAN_BUILD_CACHE=1` only when intentionally reclaiming build-cache space. The package gate verifies feature strings, source revision, Intel architecture, signature, and the single canonical app bundle.
- Serialize local builds: run only one Cargo, SwiftPM, or packaging build at a time. Do not start a second build while one is running, including from another terminal or agent.
- Reuse the established local outputs (`target/macos-app` for packaged app builds and SwiftPM scratch output under it); do not create dated, per-feature, or duplicate build directories. For this Intel workstation, use `MACOS_ARCHS=x86_64` and the default `BUILD_TARGET_DIR=target/macos-app`.
- Run local Intel Swift tests with the same `--scratch-path` and `--triple` as the app runner so tests do not create a second cold app build. CI uses explicit isolated caches and cleanup.
- Build-cache cleanup is opt-in for local runs. Never clear SwiftPM/Cargo caches during normal iteration; use `scripts/cleanup_storage.py` only when reclaiming disk space and after stopping builds.
- Before switching a local build configuration, stop the prior build and remove stale generated outputs instead of keeping parallel copies. Use `scripts/cleanup_storage.py` to inspect safe cleanup candidates; preserve `target/release` binaries referenced by the app, tests, and analysis scripts. CI may use its isolated matrix outputs.
- Public CI and release builds must remain reproducible without local files, external LUTs, or developer credentials. Keep third-party assets out of source tarballs.
- Avoid committing build output or screenshots; keep only source, tests, docs, and intentional small fixtures.
