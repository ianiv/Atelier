# Roadmap

Planned work that isn't built yet. Items marked **User request** or **User-reported bug** came from Atelier users.

## Models and LoRAs

- **Import from Hugging Face links.** Paste a Hugging Face link to a model or LoRA and Atelier downloads and imports it directly, as Draw Things does.
- **Change a selected LoRA in place.** Pick a different LoRA for an entry in the Inspector's LoRA list without removing it and adding the new one.

## Canvas

- **Selection lost right after importing an image.** Drop an image on the canvas and use Select (Subject or points) straight away, and the selection and its points can vanish when the image's History entry is saved; mask and paint undo steps made in that moment are lost too. It shows mostly in large projects, where that save takes longer. Found by reading the code (the import's History entry resets the Select session and the canvas's undo steps) and not yet confirmed with a run; it is also why `--automask-check --subject` fails in a project with many steps.

## Agents

- **Unit tests for off-canvas jobs in the queue.** Run Again keeping a job off the canvas and in its project, renaming a project with such a job waiting, and leaving these jobs out of the saved queue.
