# Spike: one soundtrack for a stitched cut (video-to-audio)

Status: stopped 2026-10-29. Nothing was run; `Scripts/soundtrack/score_cut.py` is written but untested.

## Idea

H3 and the other video models can't continue the previous clip's soundtrack, so the
plan was to score the finished cut from the Video Editor with a video-to-audio (V2A) model.

## Why it was stopped

V2A models generate a new track from the pictures. They throw away the existing audio
and can't produce intelligible speech. The dialogue can be kept by mixing the clips' own
audio over the generated bed (the script's `--keep-original` mode ducks the bed under it).
But voices that don't match between clips, or lines cut off at a join, stay broken. That
needs continuity at generation time (for example, H3 Ref2VA with the previous clip's audio
as the reference), not scoring afterwards. V2A still helps cuts with no dialogue, or cuts
where the room tone, music or ambience jumps at each join.

## Models checked

| Model | License (weights) | Memory | Mac | Notes |
|---|---|---|---|---|
| MMAudio large_44k_v2 | CC BY-NC 4.0 (code MIT) | ~6 GB | MPS in upstream demo | Trained on 8 s; long cuts need windows plus crossfades |
| HunyuanVideo-Foley XL / XXL | Tencent Hunyuan Community (excludes EU, UK, South Korea) | 16 / 20 GB (8 / 12 GB with offload) | CUDA-first | Heavier, higher quality claims |
| ThinkSound | Apache 2.0 (VAE: Stability Community) | larger | macOS install documented | Needs a multimodal LLM for its chain-of-thought step |

## Engine and app fit

- draw-things-community (8dbbb5c6) has no V2A model. It does have pieces a native port
  could reuse: `CLIPImageModel` and `LTX2Vocoder` (SnakeBeta, BigVGAN-style). Synchformer,
  the MMAudio flow transformer and its 1D VAE would be new. The fork must not be modified,
  so a port would live in Atelier on s4nnc. That's weeks of work.
- A quicker route is a Python sidecar (a uv venv in Application Support, downloaded on first
  use). It's Mac only.
- App hook: `TimelineComposition.make` already builds two alternating audio tracks; a
  soundtrack would be a third track across the whole cut, with clip audio muted or ducked.

## Script

`Scripts/soundtrack/score_cut.py --video cut.mp4 --prompt "..." --out scored.mp4 [--keep-original]`
needs the MMAudio repo installed. It scores 8 s windows with a 1 s overlap, using the same
seed for every window, joins them with equal-power crossfades and muxes the result with
ffmpeg. The ffmpeg ducking graph was checked on synthetic input. The model path was not run.
