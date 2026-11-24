# Roadmap

Planned work that isn't built yet. Items marked **User request** or **User-reported bug** came from Atelier users.

## Models and LoRAs

- **pi-H3 (2- and 4-step MiniMax H3 video).** **User request.** [Lakonik/pi-H3](https://huggingface.co/Lakonik/pi-H3) ([docs](https://github.com/Lakonik/LakonLab/blob/main/docs/piH3.md), MiniMax H3 Community License) distills H3 video+audio to 2 or 4 steps. Its four adapters (2/4 step, each with or without DWD) are LoRAs on attention out and feed-forward plus full replacements for every block's `adaln_proj` (`[96768, 8]`), `norm_out`, `proj_out` and `audio_proj_out`, trained on the pruned H3 (`multimodalart/MiniMax-H3-Pruned`: `adaln_rank` 8, 1025-entry time table), so they ship as a merged checkpoint (pruned base + adapter, then Make 8-bit Copy), not a LoRA. Check that the engine's curve-form time path (`layout.usesTimeCurve`) loads that layout. Sampling is one Euler step per network call, no guidance, on fixed grids (`max_raw_t` 0.93 / 0.96, `final_step_size_scale` 0.6, shift 12 video / 3 audio): 2-step video σ [0.99374, 0.86534], audio [0.97552, 0.61636]; 4-step video [0.99654, 0.96445, 0.89930, 0.69565], audio from the same formula with shift 3 (`RFSigmaGridDiscretization`, separate audio grid). Stage 1: the non-DWD adapters, decoded by the H3 VAE, plus defaults (guidance 1, 24 fps, 17n+5 frames, 768 short side) and `docs/video.md`. Stage 2: DWD, which decodes pixels from the last step's features (`dwd_norm_out` → `SolH3DWDHead`: 8 blocks × 2048, 4 register tokens, 4×32×32 pixel patches, its own path for every 5th frame) instead of the video VAE; needs an engine port of the head (read LakonLab's `DWDHeadMixin` first) and a sampler that returns features. Audio still decodes through the audio VAE.

## Video references

- **Up to three reference videos (H3 Ref2VA).** **User request.** The model takes up to 3 clips as `<Video 1>`–`<Video 3>` (2–15 s each, ≤ 15 s in total, ≤ 12 reference files overall); today only the canvas clip goes in, as `<Video 1>`. Needs an engine change: the port reads a reference clip only from the canvas tensor, so moodboard clips would go in as further videos, each with its own length, 24 fps resampling, 17n+5 snap and `resolve_canvas_size` canvas, placed on the clock before the target like the first. Then: video entries on the moodboard (imported media and History clips), labels, the refusal rules per clip, SavedQueue / remote / agent plumbing, docs.
- **Video plus audio references.** **User request.** Atelier refuses a reference clip together with an audio input, copying the engine CLI. MiniMax's pipeline accepts both: the clip's own soundtrack (or another file) goes in as `<Audio N>`, which an edit that keeps the original sound needs. Check what the engine port does with a canvas clip and an audio tensor together, lift the refusal once it works, and offer the clip's own soundtrack as the audio reference. Related exactness gaps from the same comparison: frames go to the text encoder as images, not video tokens, and are resized bilinear, not Lanczos.

## Canvas

- **Select by description.** Type what you want selected ("the red car", "her hair") and Segment Anything selects it. The Select tool had a placeholder **Select:** text field for this, removed in 6423498 because the feature was never finished.

## Edit screen

- **Frequency separation.** Split the image on the Edit screen into a low-frequency band (blurred copy: colour, tone, soft shading) and a high-frequency band (original minus the blur: texture, pores, fine detail), which add back up exactly. Edit one band without touching the other: smooth blotchy colour on the low band without smudging texture, heal marks on the high band without shifting the colour under them. The Heal tool (and any other Edit screen brush) gets a band choice (Texture / Color / Both) plus a blur radius for the split. Uses no model; recorded in the edit's look (`Edit.Record`) like the rest. Builds on Tool UI and Blemish removal.
- **Experimental: frequency separation with edit models.** After the items above. A merge option per Edit run that recombines the result with the original by band (the split from Frequency separation), as a step after an ordinary run. Only for edits that stay aligned pixel for pixel (relight, recolor, refine); edits that move or reshape things ghost, so it's never the default, and the blur radius must exceed the detail being kept.
  - **Keep original texture:** the model's low band (light, colour, mood) under the original's high band, so pores, grain, hair and sharpness survive the VAE round trip, with less identity drift.
  - **Keep original color:** the original's low band under the model's high band, for refine / add-detail passes: new detail without colour or exposure drift (what Match Colors… corrects today, more exactly).

## Samplers

- **DPM++ 2M Trailing breaks on MiniMax H3 Image.** At 768 px, 8 steps (seed 1234, 2026-11-21), the result shows smeared mosaic bricks; DDIM Trailing and DPM++ 2M Karras are fine. Check whether 0.19.0 (before the Scheduler work, 5d91b6f) does the same, then find the cause (likely its schedule vs the trained sigma grid, as with LCM).

## Known failures


- **Edit runs don't record their input.** `--edit-input-check` fails 5 checks (z_image_turbo, 2 steps): the first Edit run doesn't record its input, iterating in place and Rerun don't link to the first result, Use Settings on the second step leaves Generate mode instead of putting the first result on the canvas in Edit, and Use Settings with its input deleted shows no note. Fails the same way without the 2026-11-21 fixes.
- **Clip playback falls behind.** `--canvas-clip-check` "the picture keeps up" showed 4 of 48 frames in 2 s on a copy of the HyperFlow project, with and without the 2026-11-21 fixes. The screen was locked during those runs, which may be the cause; rerun unlocked before investigating.
- **Agent tools can pick the wrong step.** `history_step` numbers aren't unique: steps saved from the same source share a number on their branches, and the agent tools take the first one listed, so an agent can act on a sibling of the step it meant. Affects every tool that takes `history_step`. Found while building Crop (2026-11-22); `--edit-tools-check` works around it.

## Tests and checks

- **`--edit-input-check` leaves its test prompt in the prompt history.** Like `--agent-canvas-check` did, it should put the recent prompts back.

## Upstream

- **Report or patch libccv's BF16 → FP16 conversion.** `ccv_bfloat_to_half_precision` in `lib/ccv_util.c` (liuliu/ccv, at 710baf94 as pinned through s4nnc; added in 819aa2af, 2025-01) builds its union from `f[i]`, the output buffer, instead of `h[i]`, the input: `u = { .h = { 0, f[i] } };` should be `u = { .h = { 0, h[i] } };`. Every CPU `Tensor<Float16>(from:)` of a BFloat16 tensor returns garbage. In Draw Things it shows when Merge LoRA is Always on a BF16 model (e.g. `moodypromix_zitv13_f16`, whose linear weights are BF16): merged images are grey noise. Atelier works around it in the engine fork by converting through Float32 (branch `bf16-lora-merge`, 2026-11-22). The sibling `ccv_bfloat_to_double` has the same kind of typo (`h[1]` for `h[i]`, line 1827), already reported as https://github.com/liuliu/ccv/issues/270 (open, no replies), with a fix in https://github.com/liuliu/ccv/pull/281 (open since 2026-10-13, unreviewed). That PR fixes only `ccv_bfloat_to_double`, not `ccv_bfloat_to_half_precision`: comment on it asking to include the one-line half-precision fix too, or open a separate PR. Once upstream ccv is fixed and the s4nnc/engine pins pick it up, the workaround can go.
