# macOS app source and build contract

## One source and one app

- `studio-port-upstream-sync` is the source of truth for the Negs macOS app. Make the source change, commit it, and push it to `origin/studio-port-upstream-sync` before building. The local debug runner refuses another branch, a dirty tree, or a commit that is not the pushed branch head.
- The only app users should open is `dist/negs-macos/Negs.app`. `target/macos-app` contains compiler caches and temporary promotion staging only. Do not launch an app from `/tmp`, a ticket worktree, or a variant directory under `dist`.
- App bundles and screenshots are generated output and stay out of Git. The commit is the durable source record; the push triggers the Intel packaging workflow, which uploads a SHA-named GitHub Actions artifact.

## Local builds

For an iterative Intel build:

```sh
rtk scripts/run_cached_debug_app.sh
```

The runner checks the pushed source revision, reuses `target/macos-app` SwiftPM output, builds the debug executable, copies the existing app resources into a staging bundle under `target/macos-app`, stamps the bundle with its source revision, and verifies the executable contains the saturation overlay, skin-tone overlay, and depth-map controls. Only after those checks pass does it replace and open `dist/negs-macos/Negs.app`; it verifies the running process path. A failed build leaves the previous canonical app in place.

For the optimized Intel package and its ZIP/DMG:

```sh
MACOS_ARCHS=x86_64 CLEAN_BUILD_CACHE=0 rtk bash scripts/package_macos_app.sh
```

The package script assembles and verifies the new bundle under `target/macos-app` before promoting it to the canonical path. It rejects alternate `DIST_DIR` and `APP_NAME` values. After a successful promotion it removes stale `Negs.app` variants under `dist/negs-*`; the verifier fails if any extra app bundle remains under `dist`.

## Regression gate and retained build

`.github/workflows/source-of-truth-macos.yml` runs on every push to `studio-port-upstream-sync` on a native Intel macOS runner. It runs the RAW meter and preview-scale regression tests, the Swift preview-quality test, and the Intel package verification. It uploads the ZIP, DMG, build manifest, and package report under `negs-macos-intel-<commit-sha>` for 90 days. The app manifest records the exact source SHA, source branch, build mode, and `x86_64` architecture. The package gate checks the Intel executable and all four feature markers: `Saturation overlay`, `Skin tone overlay`, `Depth map preview`, and `Create Depth Mask`.

The Git commit remains after the Actions artifact expires, so the matching app can always be rebuilt from the exact source revision. The app bundle itself is never committed.
