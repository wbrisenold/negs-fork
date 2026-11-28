# macOS app source and build contract

## One source and one app

- `/Users/A1990/Downloads/negs-main-source-truth` on `studio-port-upstream-sync` is the only source checkout. The local gate rejects another path, another branch, or more than one Git worktree. Debug builds may include local uncommitted edits; release packaging still requires a clean commit pushed to `origin/studio-port-upstream-sync`.
- The only app users should open is `dist/negs-macos/Negs.app`. `target/macos-app` contains compiler caches and temporary promotion staging only. The debug runner promotes a debug-build executable into that same canonical bundle: “debug” is the build mode, not a second app path. Never manually launch a bundle from `target/` or from a sibling checkout.
- App bundles and screenshots are generated output and stay out of Git. The commit is the durable source record; the push triggers the Intel packaging workflow, which uploads a SHA-named GitHub Actions artifact.

## Debug promotion gate

- The debug build is approved for local use only when the runner exits successfully: it builds the current local source, records whether the tree is dirty, validates architecture, manifest, feature markers, and signature, promotes the candidate, and confirms the running process uses the canonical path.
- Promote the debug executable into the existing `dist/negs-macos/Negs.app` bundle. This replaces the prior app at the same path; do not retain or open a second debug app bundle or create another `dist` directory.
- Keep the current canonical app in place until the staged candidate passes pre-promotion verification. If build, verification, promotion, or launch-path checks fail, restore the prior canonical app and report the failure.
- The optimized package uses the same canonical path. The app's source revision and build mode in its manifest identify whether the current canonical app came from a debug or release build.

## Local builds

For an iterative Intel build:

```sh
rtk scripts/run_cached_debug_app.sh
```

The runner checks the canonical path, branch, and single-worktree rule, reuses `target/macos-app` SwiftPM output, and builds the current local source. It copies the existing app resources into a staging bundle under `target/macos-app`, stamps the bundle with its commit and dirty status, and verifies the executable contains the saturation overlay, skin-tone overlay, and depth-map controls. Only after those checks pass does it replace and open `dist/negs-macos/Negs.app`; it verifies the running process path. A failed build leaves the previous canonical app in place.

For the optimized Intel package and its ZIP/DMG:

```sh
MACOS_ARCHS=x86_64 rtk bash scripts/package_macos_app.sh
```

The package script assembles and verifies the new bundle under `target/macos-app` before promoting it to the canonical path. It rejects alternate `DIST_DIR` and `APP_NAME` values. Local builds retain compiler caches by default; only set `CLEAN_BUILD_CACHE=1` when intentionally reclaiming storage. After a successful promotion it removes stale `Negs.app` variants under `dist/negs-*`; the verifier fails if any extra app bundle remains under `dist`.

Run local Intel Swift tests with the same scratch path as the app runner, so tests reuse the app-module cache:

```sh
swift test --package-path macos \
  --scratch-path target/macos-app/swift-x86_64-apple-macosx14.0 \
  -c debug --triple x86_64-apple-macosx14.0 \
  --filter PhotoLibraryWorkflowTests
```

## UI acceptance

For every user-visible UI change:

1. Run `rtk scripts/run_cached_debug_app.sh` from the canonical checkout to build and inspect local changes. Commit and push only after the local result passes.
2. Confirm the runner reports the expected source SHA, `x86_64`, and the canonical `dist/negs-macos/Negs.app` process path.
3. Open the affected screen in that launched app. Capture a fresh screenshot under `target/macos-app/` and compare it with the accepted design/spec using the same view and representative content.
4. Name the visible differences and exercise each changed control or workflow. If the screenshot or interaction check is unavailable, report that part as unverified; a compile, merged PR, or process launch is not visual acceptance.

Keep screenshots in `target/`; they are verification artifacts, not source or release files.

## Regression gate and retained build

`.github/workflows/source-of-truth-macos.yml` runs on every push to `studio-port-upstream-sync` on a native Intel macOS runner. It runs the RAW meter and preview-scale regression tests, the Swift preview-quality test, and the Intel package verification. It uploads the ZIP, DMG, build manifest, and package report under `negs-macos-intel-<commit-sha>` for 90 days. The app manifest records the exact source SHA, source branch, build mode, and `x86_64` architecture. The package gate checks the Intel executable and all four feature markers: `Saturation overlay`, `Skin tone overlay`, `Depth map preview`, and `Create Depth Mask`.

The Git commit remains after the Actions artifact expires, so the matching app can always be rebuilt from the exact source revision. The app bundle itself is never committed.
