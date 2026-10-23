# Settings

Open **Atelier ▸ Settings** (⌘,).

## General

### Models directory

The folder Atelier reads models and LoRAs from, and downloads and imports into. Click **Choose…** or type a path, then **Apply**. When it's never been set, Atelier uses `~/Documents/Models`, or the folder in the `DRAWTHINGS_MODELS_DIR` environment variable. You can point it at Draw Things' models folder to share models between the two apps.

### Performance

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

Lets Claude Code and other MCP clients on this Mac generate images with your models. See [Atelier for agents (MCP)](../MCP.md).

## Where Atelier keeps things

| What | Where |
| --- | --- |
| Projects (your images and their settings) | `~/Pictures/Atelier/Projects/` |
| Models, LoRAs, `custom.json`, `custom_lora.json` | Your models directory |
| Presets and inspector layouts | `~/Library/Application Support/Atelier/` (the Presets and inspector menus have Show Folder items) |
| Moodboard images | `~/Library/Application Support/Atelier/Moodboard/` |
