# Roadmap

Planned work that isn't built yet. Items marked **User request** or **User-reported bug** came from Atelier users.

## Models and LoRAs

- **Import from Hugging Face links.** Paste a Hugging Face link to a model or LoRA and Atelier downloads and imports it directly, as Draw Things does.
- **Change a selected LoRA in place.** Pick a different LoRA for an entry in the Inspector's LoRA list without removing it and adding the new one.

## Canvas


## Agents

- **`edit_image` between two of your own runs turns "canvas follows run" back on.** With one of your runs going, another queued, and an agent's `edit_image` waiting between them: look at a History image during the first run, and the second run still covers the canvas when it starts. It should stay off the canvas, as it does without the agent's job.
- **`edit_image` reports an error when its project is renamed while it waits.** The result is saved in the renamed project, but the tool call fails instead of returning it.
- **`set_canvas_frame` accepts `true` / `false` for `width` and `height`.** They should be rejected as its other numbers are.
- **`--agent-canvas-check` leaves its test prompt in the prompt history.** Its "Generate during an edit" section should put the recent prompts back.
- **Unit tests for off-canvas jobs in the queue.** Run Again keeping a job off the canvas and in its project, renaming a project with such a job waiting, and leaving these jobs out of the saved queue.
