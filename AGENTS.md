# Negs project guidance

## Targets and repository boundaries

- The product target is the universal macOS app (`arm64` and `x86_64`). Use its package workflow as the acceptance gate.
- Keep the `upstream` remote pointed at `noahhaasis/negs`. Develop and push this fork's work on a branch; never push this fork's feature work to upstream `main`.
- Core image processing belongs in the Rust crates. SwiftUI owns macOS presentation and interaction. For this fork integration, validate the universal macOS app; other platforms and standalone CLI/web builds are outside the acceptance gate.
- Keep generated output (`target/`, `.build/`, `/dist/`), personal image assets, and locally licensed LUTs out of Git. Do not add user photos or local app bundles to commits.
- The Referent LogC3 LUT is third-party material. Local packaging may bundle the copy installed by the developer, but source archives and public GitHub releases must not redistribute it without permission. The app can use a bundled local copy or the user's Resolve-installed/custom LUT.

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
  swift test --package-path macos --filter QuickFrameTests/testRawPreviewQualityScaleIs38PercentAndNeverUpscales
  ```

- Report measured timings with the host, build mode, image dimensions, preview scale, and whether the number is engine-only or end-to-end. A single local result is not a general performance promise. Verify user-visible RAW behavior separately from unit tests and meter microbenchmarks.

## Build and package

- Use `scripts/package_macos_app.sh` for the universal app (`MACOS_ARCHS="arm64 x86_64"`, the default). It checks the macOS SDK, Rust target libraries, and free disk before building, then verifies the generated package. Verify both executable slices with `lipo -archs`.
- For iterative macOS UI work, run `rtk scripts/run_cached_debug_app.sh` after each source change. It rebuilds the native core and cached Intel **debug** executable, stages it into the existing app bundle, replaces the old process, launches the updated app, and verifies the launched executable path. Do not treat a source edit or a successful compile as a running-app update. Then exercise the reported interaction in the visible app and inspect its result before calling a crash fixed. If packaging or launch fails, report that the running app still has the old code.

  The script reuses the SwiftPM cache rather than rebuilding the optimized app and DMG after every UI edit. The universal release acceptance gate remains `scripts/package_macos_app.sh`.

  Manual fallback, only when repairing the runner itself:

  ```sh
  rtk swift build --package-path macos \
    --scratch-path target/macos-app/swift-x86_64-apple-macosx14.0 \
    -c debug --triple x86_64-apple-macosx14.0
  mkdir -p target/macos-app/debug-app
  rm -rf target/macos-app/debug-app/Negs.app
  ditto dist/negs-macos/Negs.app target/macos-app/debug-app/Negs.app
  cp target/macos-app/swift-x86_64-apple-macosx14.0/x86_64-apple-macosx/debug/NegsApp \
    target/macos-app/debug-app/Negs.app/Contents/MacOS/NegsApp
  codesign --force --deep --sign - target/macos-app/debug-app/Negs.app
  open -na target/macos-app/debug-app/Negs.app
  ```

  This manual fallback reuses the cache and existing packaged helpers/resources; it does not validate the universal app. Keep local caches with `CLEAN_BUILD_CACHE=0` when packaging during an iteration. Do not run debug and release builds concurrently.
- Serialize local builds: run only one Cargo, SwiftPM, or packaging build at a time. Do not start a second build while one is running, including from another terminal or agent.
- Reuse the established local outputs (`target/macos-app` for packaged app builds and SwiftPM scratch output under it); do not create dated, per-feature, or duplicate build directories. Use `MACOS_ARCHS="arm64 x86_64"` and the default `BUILD_TARGET_DIR=target/macos-app` for release acceptance.
- After a successful local package, `scripts/package_macos_app.sh` removes `target/macos-app`, the Intel test cache at `target/x86_64-apple-darwin`, and `target/debug`; the app and releases remain in `dist/`, and `target/release` is preserved. Set `CLEAN_BUILD_CACHE=0` to retain local caches when iterating.
- Before switching a local build configuration, stop the prior build and remove stale generated outputs instead of keeping parallel copies. Use `scripts/cleanup_storage.py` to inspect safe cleanup candidates; preserve `target/release` binaries referenced by the app, tests, and analysis scripts. CI may use its isolated matrix outputs.
- Public CI and release builds must remain reproducible without local files, external LUTs, or developer credentials. Keep third-party assets out of source tarballs.
- Avoid committing build output or screenshots; keep only source, tests, docs, and intentional small fixtures.

## Upstream updates

- Use `scripts/start_upstream_sync.sh [base-ref]` and follow `docs/upstream-merge-workflow.md`. This fork currently syncs `upstream/main`; the separate parity audit records an older experiment and is not the sync target.
- The custom base branch is authoritative for every conflicted file. The sync helper keeps its version for conflicts and retains upstream's non-conflicting changes. Review the full merge and universal package before promoting it.
