# Roadmap

Planned work that isn't built yet. Items marked **User request** or **User-reported bug** came from Atelier users.

## Models and LoRAs

- **Import from Hugging Face links.** Paste a Hugging Face link to a model or LoRA and Atelier downloads and imports it directly, as Draw Things does.
- **Change a selected LoRA in place.** Pick a different LoRA for an entry in the Inspector's LoRA list without removing it and adding the new one.

## Canvas

- **Blemish removal.** A tool that makes it easy to remove freckles, moles and other unwanted marks on skin.
- **Select by description.** Type what you want selected ("the red car", "her hair") and Segment Anything selects it. The Select tool had a placeholder **Select:** text field for this, removed in 6423498 because the feature was never finished.

- **Edit runs don't record their input.** `--edit-input-check` fails 5 checks (z_image_turbo, 2 steps): the first Edit run doesn't record its input, iterating in place and Rerun don't link to the first result, Use Settings on the second step leaves Generate mode instead of putting the first result on the canvas in Edit, and Use Settings with its input deleted shows no note. Fails the same way without the 2026-11-21 fixes.
- **Clip playback falls behind.** `--canvas-clip-check` "the picture keeps up" showed 4 of 48 frames in 2 s on a copy of the HyperFlow project, with and without the 2026-11-21 fixes. The screen was locked during those runs, which may be the cause; rerun unlocked before investigating.

## Samplers

- **DPM++ 2M Trailing breaks on MiniMax H3 Image.** At 768 px, 8 steps (seed 1234, 2026-11-21), the result shows smeared mosaic bricks; DDIM Trailing and DPM++ 2M Karras are fine. Check whether 0.19.0 (before the Scheduler work, 5d91b6f) does the same, then find the cause (likely its schedule vs the trained sigma grid, as with LCM).

## Agents

- **Masked outpainting at 2 steps comes back empty.** `--agent-canvas-check` at `--steps 2` (z_image_turbo, Strength 0.7): `edit_image` on a region reaching past the image fails with “Generation failed”. The frame has transparent (code 1) and masked (code 2) areas, so the engine runs `generateImageWithMask1AndMask2`, which returned no image. The same check passes in full at `--steps 4`. Check whether 0.19.0 (before the Scheduler work, 5d91b6f) does the same.
- **`--edit-input-check` leaves its test prompt in the prompt history.** Like `--agent-canvas-check` did, it should put the recent prompts back.

- **Unit tests for off-canvas jobs in the queue.** Run Again keeping a job off the canvas and in its project, renaming a project with such a job waiting, and leaving these jobs out of the saved queue.
