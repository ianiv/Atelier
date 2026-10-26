# Atelier

https://github.com/user-attachments/assets/d063933f-9fdb-4bfd-97ab-bfc6a12920b0

Atelier is a native macOS app for generating images with local models, with an iPad version in development. It runs the same engine as Draw Things ([draw-things-community](https://github.com/drawthingsai/draw-things-community)) inside the app, so there is no server to start: live previews, progress and Cancel all work in-process.

What it does today:

- Text to image with sensible per-model defaults, and every advanced setting one search away.
- Image to image: edit an image on the canvas, outpaint by moving it in the frame, and give edit models reference images on a moodboard.
- Video with LTX-2, MiniMax H3, Wan and the other video models the engine runs: text or an image to video, first and last frames, references, and sound (LTX and H3 make a soundtrack; H3 and LongCat take an audio file). Clips play inline and save as MP4.
- Presets and inspector layouts.
- History kept in projects, in Draw Things' project file format, with one-click "Use Settings".
- A model and LoRA library: download from the community catalog, import `.safetensors` checkpoints and LoRAs, and make 8-bit copies of MOSS models.
- An MCP server so agents such as Claude Code can generate images and videos with your models.

## Download

Get the latest signed and notarized Atelier from [Releases](https://github.com/ianiv/Atelier/releases/latest): download the zip, open it and drag Atelier to Applications. From 0.3 on, it updates itself. It needs a Mac with Apple silicon running macOS 27 or later. To build it yourself instead, see [Getting started](docs/getting-started.md), which also covers the iPad version (an iPad with M1 or later, iPadOS 27; built from main and installed from Xcode, no download yet).

## How it differs from Draw Things

Atelier uses Draw Things' engine and project format, so your models and projects work in both. What it adds:

- **An inspector you shape yourself.** Search every setting, see what you've changed from the model's defaults in the Changed group, hide or show any setting, and keep named layouts you can export and share.
- **A queue.** Press Generate while an image is running to queue the next one, make ×N at once, reorder, pause and retry. Waiting images are kept when you quit.
- **Agents can make images.** A built-in MCP server lets agents such as Claude Code generate with your models, and their requests join the same queue.
- **Branches you can see.** History shows every branch as a graph, and the recent strip switches between everything by time and just the current lineage.
- **Click to reuse.** Clicking a recent image brings back its prompt, size and settings. History supports selecting several images at once.
- **Presets as files.** Presets are kept apart from layouts, remember their model, and export and import as JSON.
- **A native Mac app.** Built in SwiftUI with Liquid Glass, it works the way you'd expect a Mac app to: menus and keyboard shortcuts, drag and drop, copy and paste, multiple selection and a Settings window (⌘,).

## Documentation

Start with the [user guide](docs/README.md).

- [Getting started](docs/getting-started.md): requirements, building and installing, choosing your models folder, your first image.
- [Creating images](docs/creating-images.md): the prompt, size and seed, the inspector, presets, image to image and the moodboard.
- [Making videos](docs/video.md): video models, length, first and last frames, audio, and playing and exporting videos.
- [History and projects](docs/history.md)
- [Models and LoRAs](docs/models-and-loras.md): downloading, importing, Make 8-bit Copy.
- [Settings](docs/settings.md): models folder, output folder and performance.
- [Atelier for agents (MCP)](MCP.md)

## License

Atelier is free software, licensed under the [GNU General Public License v3.0](LICENSE). It is built on [draw-things-community](https://github.com/drawthingsai/draw-things-community), which is also GPL-3.0, and any app built on that engine must be GPL-3.0 as a whole. Models you use with Atelier keep their own licenses.
