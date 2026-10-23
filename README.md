# Atelier

Atelier is a native macOS app for generating images with local models. It runs the same engine as Draw Things ([draw-things-community](https://github.com/drawthingsai/draw-things-community)) inside the app, so there is no server to start: live previews, progress and Cancel all work in-process.

What it does today:

- Text to image with sensible per-model defaults, and every advanced setting one search away.
- Image to image: edit an image on the canvas, outpaint by moving it in the frame, and give edit models reference images on a moodboard.
- Presets and inspector layouts.
- History kept in projects, in Draw Things' project file format, with one-click "Use Settings".
- A model and LoRA library: download from the community catalog, import `.safetensors` checkpoints and LoRAs, and make 8-bit copies of MOSS models.
- An MCP server so agents such as Claude Code can generate images with your models.

## Documentation

Start with the [user guide](docs/README.md).

- [Getting started](docs/getting-started.md): requirements, building and installing, choosing your models folder, your first image.
- [Creating images](docs/creating-images.md): the prompt, size and seed, the inspector, presets, image to image and the moodboard.
- [History and projects](docs/history.md)
- [Models and LoRAs](docs/models-and-loras.md): downloading, importing, Make 8-bit Copy.
- [Settings](docs/settings.md): models folder and performance.
- [Atelier for agents (MCP)](MCP.md)

## License

Atelier is free software, licensed under the [GNU General Public License v3.0](LICENSE). It is built on [draw-things-community](https://github.com/drawthingsai/draw-things-community), which is also GPL-3.0, and any app built on that engine must be GPL-3.0 as a whole. Models you use with Atelier keep their own licenses.
