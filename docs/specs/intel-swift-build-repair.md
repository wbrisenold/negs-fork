# Intel macOS Swift Build Repair

## Status

Draft from the failed cached Intel debug build on 2026-11-26. The compiler emitted 136 distinct Swift error diagnostics across the macOS app sources. The Rust core built successfully; after the log stopped advancing and a Swift frontend held a core for several minutes, the build was stopped. No current app bundle was staged or opened. The temporary compiler log is not part of the repository.

## Goal

Restore a coherent, buildable Intel macOS app source tree on `ux-architecture-integration`, preserving the intended editing, library, and adjustment workflows from issues 1–3. Then prove that the cached debug runner launches the executable built from the current checkout.

## Observed failure surface

- `EditorModel` call sites and its current API disagree across editing, comparison, Lightroom, negative, and color-filter features.
- `Theme` and `AppTheme` disagree about appearance, color scheme, palette, and change notification APIs.
- `CompareCanvas` expects missing or incompatible `ViewerSheet`, `PreviewCanvas`, `ZoomLink`, `SheetInk`, comparison, and stock-name APIs.
- Additional independent diagnostics occur in `PhotoFolderWatcher`, `PhotoLibrary`, `ThemePicker`, `TitleBar`, and app construction sites.
- Treat the 136 count as a baseline for this build, not 136 independent fixes; collapse cascades to their owning API/type mismatches before editing.

## Requirements

1. Reproduce and retain the complete compiler log under `target/macos-app/cached-debug-build.log` from one serialized `rtk scripts/run_cached_debug_app.sh` run; record its exit status.
2. Group diagnostics by missing declaration, signature mismatch, access control, and type-check failure. Find each owning model/view declaration and its callers before changing code.
3. Restore or adapt the intended source contracts at their owning modules. Do not add dummy computed properties, empty marker types, or broad compatibility shims just to silence callers.
4. Keep module boundaries from issues 1–3: editing-session lifecycle and render readiness belong to the editing session seam; Library location and selection transitions belong to the Library workflow seam; adjustment grouping, availability, edited state, and help belong to adjustment discovery. Views remain presentation code.
5. Keep the Intel Odin toolchain on MacPorts as documented in `AGENTS.md`; do not rebuild Homebrew LLVM or substitute a Z3 dylib.
6. Preserve serialized build use and the existing `target/macos-app` cache. Do not build from a second terminal while SwiftPM is active.
7. If Swift frontends remain active without log progress, inspect the process tree and log before deciding to stop; never start another runner to retry while the first one still owns the SwiftPM cache.

## Acceptance

- `python3 -m py_compile core/install_odin.py` and `git diff --check` pass.
- A fresh single `rtk scripts/run_cached_debug_app.sh` completes successfully and reports the executable path it launched.
- The launched process resolves to the app bundle staged by that runner and contains the executable built from this checkout; an older app in `dist/` is not accepted as current.
- Inspect the running app and exercise Library entry, photo selection, Develop navigation, adjustment discovery, and the previously crashing “Analyze with AI” action. Record outcomes separately; a successful compile alone does not establish those workflows.
- After the Intel debug app is verified, run the universal macOS packaging workflow required by `AGENTS.md` before claiming release acceptance.

## Non-goals

- Repairing or rebuilding the Homebrew LLVM/Z3 installation.
- Opening or relabeling an older packaged app as the latest build.
- Removing app features or hiding broken controls to make compilation pass.
- Treating the renderer, library, or inspector as architecturally complete based only on UI availability.
