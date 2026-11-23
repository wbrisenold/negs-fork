# Open-source relighting options for Negs

Research date: 2026-11-23

## Recommendation

The user selected a native Intel port of [ComfyUI-ReLight](https://github.com/EnragedAntelope/comfyui-relight). Its MIT license is included in the macOS app bundle. The current native implementation is a model-free first slice: three soft radial colored lights with position, radius, intensity, negative fill, and global strength. It shares the Rust post pipeline and GPU display pass, so preview and export use the same color-space-aware math.

This does not yet reproduce all upstream controls. Directional-gradient lights, subject-mask interaction, rim light, cast shadows, background glow, and the eight upstream presets remain future work. Do not describe this implementation as full upstream parity. [Upstream source](https://github.com/EnragedAntelope/comfyui-relight/blob/main/relight.py), [MIT license](https://github.com/EnragedAntelope/comfyui-relight/blob/main/LICENSE)

PIXLRelight is a feed-forward model conditioned by a target-light photograph or Blender Cycles PBR render passes. It uses a bundled Marigold intrinsic decomposer for the target-photo mode, downloads weights/config on first run, and defaults to CUDA. Its sub-0.1-second timing is an upstream claim, not a measurement on Negs' Intel Mac. [Inference modes and setup](https://github.com/mlfarinha/pixlrelight#inference)

## Intel macOS feasibility

Upstream requires `torch>=2.3` and `torchvision>=0.18`. The PyTorch maintainers stopped publishing/testing Intel macOS x86_64 binaries after the 2.2 release line; the official notice explicitly says there would be no macOS x86_64 binaries for 2.3. The current Intel target therefore cannot install the documented dependency set from official wheels. [PIXLRelight requirements](https://github.com/mlfarinha/pixlrelight/blob/main/requirements.txt), [PyTorch x86_64 macOS deprecation notice](https://dev-discuss.pytorch.org/t/pytorch-macos-x86-builds-deprecation-starting-january-2024/1690)

The code can still be integrated as an optional, out-of-process backend, but making it usable on Intel needs a separately validated runtime plan: test whether the model works with the last official Intel build (Torch 2.2.2) despite the upstream minimum, or maintain a source-built/converted runtime. Do not claim Intel support until that path is exercised end to end. Do not bundle the model files in Negs packages because of their noncommercial license.

## Capabilities and integration shape

- Input image plus a target illumination photo, or input plus Blender Cycles EXR passes.
- The target-photo route estimates albedo, diffuse shading, and residual lighting with Marigold, then relights through a transformer model.
- Inference resizes to a configurable target side length (512 by default) and returns the result at the source dimensions.
- The model is trained on indoor scenes and does not synthesize absent content; large cast-shadow or specular changes may not transfer faithfully.
- It is not a point-light rig with native x/y/intensity sliders. A Negs panel should start with a target-light reference picker and a controlled blend/strength, while a full PBR-light UI would need a scene reconstruction and Cycles pass-generation workflow.

Because Negs keeps processing in Rust and UI in SwiftUI, the procedural light controls live in `PostParams` and are applied in Rust, with a matching WGSL display path. This avoids a Python or model runtime on Intel. Future mask-aware modes can consume the existing foreground mask while keeping the CPU export and interactive GPU preview in parity.

## What the module would expose in Negs

- One to three lights, each with normalized position, inner and outer radius, and optional RGB color/intensity.
- Radial and directional-gradient shapes.
- Colored-light, color-correction, and combined modes.
- Global effect strength, mask blur, and subject interaction modes: whole frame, foreground light, and back/rim light.
- Foreground mask input from Negs' existing mask system; rim mode also produces background glow and a directional cast shadow.
- Presets: Soft Window Light, Dramatic Side Light, Warm Sunset Glow, Cool Blue Moonlight, Studio Key Light, Rim Light (Behind), Spotlight, and Negative Light (Darken).
- Preset geometry-lock behavior and an explicit master strength control; when a preset owns a value, show its value and disable that control to avoid a misleading slider.

The source project documents that the mask is white for subject and black for background, and that subject-aware modes need a mask. Negs would need to define which existing mask is supplied and how an absent mask behaves. The depth map could improve lighting falloff or occlusion, but the source node's documented contract is a foreground mask, so depth support should be an additional Negs feature rather than represented as source parity. [ReLight inputs and subject interaction](https://github.com/EnragedAntelope/comfyui-relight#-detailed-parameters-reference)

## Alternatives checked

| Project | Strength | Why it is not the first Negs integration |
| --- | --- | --- |
| [IC-Light](https://github.com/lllyasviel/IC-Light) | Popular Apache-2.0 codebase; text-conditioned and background-conditioned learned relighting, useful for generative portrait/background relighting. | It is a diffusion workflow, not a deterministic editor-grade light rig. The official demo setup is Python/PyTorch with a CUDA install command. The project warns that its default BRIA RMBG 1.4 segmenter is non-commercial and says commercial use needs another segmenter. Intel macOS has no current prebuilt PyTorch x86_64 binaries after the 2.2 release line, making a bundled/local inference route a poor fit. [IC-Light README and license](https://github.com/lllyasviel/IC-Light), [BRIA warning](https://github.com/lllyasviel/IC-Light#model-notes), [PyTorch x86 build notice](https://dev-discuss.pytorch.org/t/pytorch-macos-x86-builds-deprecation-starting-january-2024/1690) |
| [ComfyUI-ReLight](https://github.com/EnragedAntelope/comfyui-relight) | Deterministic, MIT-licensed multi-light editing with three lights, mask-aware rim/shadow behavior, and eight presets. | Better fit for native Intel execution, but it is a ComfyUI node rather than a Rust library and its image-processing implementation would need to be ported. [Repository](https://github.com/EnragedAntelope/comfyui-relight) |
| [DeepIntrinsicRelighting](https://github.com/CVC-Color/DeepIntrinsicRelighting) | Official research implementation and datasets for intrinsic-based relighting. | Research repo with older PyTorch/CUDA-oriented setup and checkpoints hosted separately; no clear software license is exposed in the repository listing. It is not a ready-to-integrate editor module. [Repository](https://github.com/CVC-Color/DeepIntrinsicRelighting) |
| [Lite2Relight](https://github.com/prraoo/lite2relight) | 3D-aware portrait relighting research implementation. | Official README recommends Linux and a high-end NVIDIA GPU with CUDA 12.1+, so it does not fit the Intel Mac local target. [Requirements](https://github.com/prraoo/lite2relight#requirements) |

## Negs integration fit

Negs' documented architecture puts image processing in Rust and the editor UI in SwiftUI. The current implementation deliberately has no model runtime or weights. It evaluates light falloff in the active output color space's linear RGB and exposes the same parameters in the inspector. Full ComfyUI-ReLight behavior remains unimplemented as listed above.

The ReLight repository's MIT license is confirmed. The native port is not a full implementation of the source node, and this maintenance pass does not establish a measured Intel performance result.
