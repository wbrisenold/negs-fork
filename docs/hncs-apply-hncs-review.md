# HNCS `apply_hncs` Review

## Scope and conclusion

This review compares Negs' `HasselbladHncs` output against `apply_hncs()` in [songjiun10-collab/Hncs](https://github.com/songjiun10-collab/Hncs), and uses the supplied side-by-side screenshot as visual evidence. The checked revisions were HNCS `513567c2b0eb44c159ebac74b0491bdcf823c377` and Negs `3d2254cce5eecaad84b6efff781c3385541691ad`. It is a source review; the Python and Rust implementations were not run against the original CR3 or against each other.

Negs' current **HNCS Reference** is not output-equivalent to the repository's Python `apply_hncs()`. It reproduces the broad sequence of exposure lift, local CLAHE, and a film curve, but intentionally blends the local-contrast result at 55%, adds warm-skin/highlight lift protection, and uses its own RGB/Lab conversion and gamut compression. The reference-mode name therefore overstates Python parity.

The paired screenshot is consistent with the main tone-path effects: the right HNCS result appears brighter in the skin midtones and has stronger fine texture. Both images already show warm skin and green foliage, so the screenshot does not show a clear new green or orange hue cast caused by the HNCS step. CLAHE is the most plausible contributor to the extra texture because it boosts local contrast in existing grain and noise. That attribution remains provisional: the underlying rendered pixels are unavailable, and the editor state also includes a Fuji C200 stock, Fuji Crystal paper, Silver Retention 37, and other adjustments.

## Implementation comparison

| Stage | Python `apply_hncs()` | Negs `HasselbladHncs` | Review impact |
| --- | --- | --- | --- |
| Input | 8-bit BGR array passed to OpenCV's BGR-to-Lab conversion | `ImageBuf` in the selected Negs output space and transfer encoding; converted to sRGB for Lab processing and converted back | The implementations do not necessarily receive or interpret the same pixel values. |
| Exposure | Applies an 8-bit LUT with `L = L^0.8` | Applies the same exponent to normalized Lab lightness, then quantizes to 8-bit | Same intent, but conversion and rounding are not guaranteed to match. |
| Local contrast | OpenCV CLAHE, `clipLimit=1.25`, 8×8 grid, at full strength | Reimplemented CLAHE with the same nominal clip limit/grid, then blends only 55% of its difference from the lifted lightness by default | Negs is deliberately weaker than the Python function. CLAHE can expose grain/noise and local texture. |
| Film curve | `toe_lift=0`, `shoulder_start=0.5`, `white_point=1` by default | Identity through 0.5, then a smoothstep shoulder to white | The selected curve is intended to match the Python defaults. |
| Skin/highlights | No separate skin-protection term; preserves input Lab a/b before OpenCV's inverse conversion | Backs off upward lightness lift for warm chromatic pixels and highlights, 55% by default | Adds behavior absent from the Python function; it changes lightness, not the intended chroma. |
| Color conversion/output | OpenCV Lab conversion and BGR output | Custom sRGB/Lab conversion, custom gamut compression, then conversion back to Negs' output space | A likely source of pixel-level hue/chroma differences, especially near gamut boundaries. |

The Python reference is implemented in [`brands/hasselblad/look.py`](https://github.com/songjiun10-collab/Hncs/blob/main/brands/hasselblad/look.py#L157-L181), with its curve in [`core/curve.py`](https://github.com/songjiun10-collab/Hncs/blob/main/core/curve.py#L12-L35). Negs dispatches `HasselbladHncs` to `apply_reference()` and `HasselbladHncsSmooth` to the global smooth path in [`hncs.rs`](../crates/spektrafilm-core/src/hncs.rs#L90-L165). Current HNCS settings default to `clahe_strength=55` and `skin_protection=55` in [`post.rs`](../crates/spektrafilm-core/src/post.rs#L181-L200).

Negs applies HNCS after the film/print/scan pipeline, then applies Silver Retention and the ordinary post adjustments. See [`Pipeline::try_process_with_backend` and `apply_post`](../crates/spektrafilm-core/src/pipeline.rs#L810-L870). Thus the final export combines HNCS with the selected film, paper, and subsequent edits. The first supplied screenshot shows Highlights at −113, Silver Retention at 37, Black Point at −3.3%, and White Point at 96.3%; unless these are held fixed across both images, the comparison does not isolate HNCS alone.

## What the screenshot supports

- **Brighter skin and midtones:** consistent with the `L^0.8` lift. This is the strongest direct explanation for a tonal difference between the two sides.
- **More visible grain or fine texture on the right:** consistent with applying local CLAHE after Negs has rendered the film/print/scan result. CLAHE remaps local histograms, so it can increase local contrast in grain, sensor noise, hair, and fabric texture together ([OpenCV CLAHE documentation](https://docs.opencv.org/3.4.2/d2/d74/tutorial_js_histogram_equalization.html)). Negs' source comment explicitly records visible mottling from the local operation and provides a smooth alternative.
- **Warm skin and green foliage:** both are already present on the left, so they are not evidence that HNCS introduced those hues. The Python recipe is specifically lightness-oriented and retains Lab a/b; Negs also intends to retain chroma, although its conversion/gamut mapping can alter colors. Base camera rendering, the film/paper chain, gamut handling, Silver Retention, and post adjustments remain possible contributors.
- **Not evidence of camera HNCS parity:** the source filename identifies a Canon R6 CR3. Applying the Python function to this image can apply that repo's generic HNCS-inspired look; it cannot recreate Hasselblad's sensor-specific camera rendering.

## Reference meaning and alternatives

The supplied Python repository presents itself as a measured approximation project, not as Hasselblad source code. Its README says it approximates brand rendering from official or near-official samples. Hasselblad's public description says HNCS combines its LUT, film curve, and other colour processing, but does not publish their exact implementation. Calling the Python function “the repo's Hasselblad look” is accurate; calling it the actual Hasselblad algorithm is not. See the [reference repo README](https://github.com/songjiun10-collab/Hncs#hncs) and [Hasselblad's HNCS description](https://www.hasselblad.com/learn/hasselblad-natural-colour-solution/).

Options depend on the intended result:

1. **For parity with `apply_hncs()`:** make a distinct compatibility path that accepts the same 8-bit sRGB BGR input, reproduces OpenCV's Lab/CLAHE and LUT rounding behavior, uses full-strength CLAHE, and omits Negs-only skin protection. Keep the current reduced-strength/protection behavior as a separate look. Exact parity must be measured against Python on identical input pixels; matching parameter names is insufficient.
2. **For a cleaner portrait result:** use `HNCS Smooth`, or retain the lift/curve while lowering local-contrast strength. This deliberately departs from `apply_hncs()` but avoids its image-dependent CLAHE boost to grain and noise. Reducing CLAHE will not correct a pre-existing warm/green color balance.
3. **For a camera color profile rather than an HNCS-inspired look:** use a measured camera profile or a DNG/DCP/ICC workflow at RAW rendering. Hasselblad's proprietary camera pipeline is not recoverable from the public `apply_hncs()` function. The reference repo's own structural experiments also caution against assuming that a more elaborate illuminant-specific model is better: its reported comparisons use camera JPEGs as targets, not verified Phocus/HNCS output, and its structural model did not beat the simpler baseline at the larger sample size. See its [structural research and limitations](https://github.com/songjiun10-collab/Hncs/blob/main/docs/hncs_structural_research.en.md#limitations).

## Review findings

### Medium: “HNCS Reference” differs from its named Python reference

The default local-contrast strength is 55%, while `apply_hncs()` runs CLAHE at full strength; Negs additionally applies `protect_hncs_lift()`. The conversions are also not bit-exact OpenCV conversions. Users selecting a “Reference” mode should not be led to expect the named Python function's output.

**Suggested resolution:** either implement and verify an explicit Python-compatible mode or rename the current mode to make its approximate/reduced-CLAHE behavior clear. Keep the smooth path separately selectable.

### Medium: the reference path has no discovered cross-language pixel-parity test

The in-file Rust test exercises only the smooth path's independence from neighboring tiles. I found no Rust test that compares `apply_reference()` to the Python function on the same RGB/BGR fixture. The Python repo does pin golden output for its own implementation, but that does not prove Rust parity.

**Suggested validation:** use a fixed, licensed synthetic or small test image. Feed the same encoded sRGB BGR pixels to Python and Rust; compare intermediate Lab/lightness stages and final pixels, reporting mean and 95th-percentile ΔE00 plus luminance error. Include a smooth ramp, saturated green, skin-like colors, near-gamut colors, and a grain/noise patch.

### Unresolved from screenshot alone: cause of the base color cast

Because warm skin and green foliage are visible on both sides, and because film/paper/retention/post settings are also present, the screenshots do not isolate which earlier stage establishes those colors. The side-by-side does support the HNCS lightness/texture changes described above. A fixed-input Python-vs-Rust comparison is needed to identify additional conversion/gamut differences.

## Verification limits

This was a static code review plus visual inspection of the supplied screenshots and primary-source research. No build, tests, Python execution, pixel-difference analysis, or export was run. No implementation files were changed.

## Implementation follow-up (2026-11-26)

Negs now exposes a separate `HNCS Python Baseline` render look backed by `hncs::apply_hncs_python()`. It fixes CLAHE strength at 100%, disables Negs' additional skin/highlight protection, and truncates the film-curve LUT values like NumPy's `astype(np.uint8)`. Existing `HNCS Reference` and `HNCS Smooth` behavior and controls remain separate. The Rust path still approximates OpenCV's 8-bit Lab conversion and CLAHE details; this is not claimed as bit-exact parity. No pixel comparison or export has been performed. The universal package gate was not run because the host volume had 3.7 GiB free, below the script's 6 GiB minimum.
