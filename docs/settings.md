# Settings

Open **Atelier ▸ Settings** (⌘,).

## Models

### Models directory

The folder Atelier reads models and LoRAs from, and downloads and imports into. Click **Choose…** or type a path, then **Apply**. When it's never been set, Atelier uses `~/Documents/Models`, or the folder in the `DRAWTHINGS_MODELS_DIR` environment variable. You can point it at Draw Things' models folder to share models between the two apps.

## Images

### Saved images

**Include Generation Settings in Saved Images** (on by default) embeds the prompt, negative prompt, model, seed and settings in images you export, save from the canvas or drag out of Atelier. They're written the way Draw Things writes them, so either app can load them back (in Atelier, with **Load Settings from Image**). Turn it off to save plain images.

### Output folder

**Save Generated Images to Output Folder** (off by default) also writes every new image to a folder of your choice as a PNG, as Draw Things' output folder setting does. Each file is named like an export ("Project 12-1234567.png": the project, the image's step and its seed), and a number is added rather than replacing a file that's already there. With **Include Generation Settings in Saved Images** on, the files carry their settings too.

**Output folder** is the folder used. Type a path or click **Choose…**. When it's never been set, it's `~/Pictures/Atelier/Output/`. It can be on an external drive; if the folder can't be written (the drive isn't connected, say), the image is still saved in the project and the status bar says it didn't reach the folder.

Each project can turn saving on or off for itself and use its own folder, from **Output Folder…** in the project menu (see [Projects](history.md#projects)). Projects follow these settings until you change that.

## Performance

These match Draw Things' Machine Settings. **Automatic** uses what the engine picks for your Mac, shown in brackets. Changes apply from the next generation.

| Setting | What it does |
| --- | --- |
| JIT Weights Loading | Loads weights only when they're needed. Saves memory on smaller Macs at some cost in speed. |
| Weights Cache Size | Keeps model weights in memory so large models reload in under a second instead of several. Lower it to use less memory; Off disables it. |
| Metal Flash Attention | Faster attention on Apple silicon. Quantized attention is faster still on M5 and later. |
| Use Apple Neural Engine for 8-bit S Models | Runs 8-bit S models on the Neural Engine. Usually faster on M4; on M5 often slower but more power efficient. |
| Merge LoRA | Merging LoRA weights into the model is 10–30% faster. Running them separately keeps quantized weights and uses less memory. |
| Use High Resolution Preview When Possible | Sharper step previews, decoded on the Neural Engine when it can, so it rarely slows generation. Off shows a quicker low-resolution preview. |

## Agents

Lets Claude Code, Codex, Gemini CLI, Cursor, VS Code and other MCP clients on this Mac generate images with your models. Pick your agent to see how to connect it. See [Atelier for agents (MCP)](../MCP.md).

## Where Atelier keeps things

| What | Where |
| --- | --- |
| Projects (your images and their settings) | `~/Pictures/Atelier/Projects/` |
| Models, LoRAs, `custom.json`, `custom_lora.json` | Your models directory |
| Presets and inspector layouts | `~/Library/Application Support/Atelier/` (the Presets and inspector menus have Show Folder items) |
| Images saved to the output folder | `~/Pictures/Atelier/Output/`, or the folder you set (in Settings or for a project) |
| Moodboard images | `~/Library/Application Support/Atelier/Moodboard/` |
