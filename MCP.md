# Atelier for agents (MCP)

Atelier runs an MCP server inside the app, so agents such as Claude Code and Codex can generate images with your local models. Agents use the app's own engine: their runs join your queue (one image at a time) instead of loading a second copy of a model onto the GPU. An agent's run shows in the Queue and on the Create screen like one of yours (progress, previews, the result on the canvas, Stop or Cancel in the Queue stops it) without changing your prompt or settings, and is saved to the current project. While the queue is paused, an agent's request waits.

## Turn it on

1. Open Atelier → Settings (⌘,) → **Agents**.
2. Turn on **Let agents generate images**. The status line shows the address, `http://127.0.0.1:7862/mcp` unless you change the port.

The server listens only on this Mac (127.0.0.1 and ::1) and refuses requests from web pages. Atelier must be open while an agent uses it. The MCP server is in the Mac app only; the iPad version doesn't have it.

## Connect an agent

The Agents tab shows the setup for each agent below, for the port you've chosen, with a Copy button. Each needs doing once.

### Claude Code

```bash
claude mcp add --transport http atelier http://127.0.0.1:7862/mcp
```

Add `--scope user` to make it available in every project, not just the current folder. Check it with `claude mcp list`, or `/mcp` inside Claude Code.

### Codex

```bash
codex mcp add atelier --url http://127.0.0.1:7862/mcp
```

This adds it to `~/.codex/config.toml`, which the Codex CLI and app share. Check it with `codex mcp list`, or `/mcp` inside Codex.

### Gemini CLI

```bash
gemini mcp add --transport http atelier http://127.0.0.1:7862/mcp
```

This adds it for the current folder; add `-s user` to make it available everywhere.

### Cursor

Add Atelier to `~/.cursor/mcp.json` (or `.cursor/mcp.json` in a project), next to any servers already there:

```json
{
  "mcpServers": {
    "atelier": { "url": "http://127.0.0.1:7862/mcp" }
  }
}
```

### VS Code

```bash
code --add-mcp '{"name":"atelier","type":"http","url":"http://127.0.0.1:7862/mcp"}'
```

Copilot's agent mode can then use Atelier's tools.

### Others

Other clients that speak Streamable HTTP can use the same address. Clients that only launch stdio servers can go through a bridge such as `npx mcp-remote http://127.0.0.1:7862/mcp`.

Then ask for an image, for example: "Use Atelier to make a 1024×1024 watercolor of a lighthouse at dusk with FLUX.2 klein, then save it to ~/Desktop."

## Tools

| Tool | What it does |
| --- | --- |
| `list_models` | Downloaded models: file, name, family, which one is selected in the app, and whether it takes reference images. |
| `list_presets` | Saved presets, the model each belongs to, which are model defaults, and their settings. |
| `get_settings` | The full settings `generate` would start from for a model (and preset), as Draw Things configuration JSON. |
| `generate` | One image. Returns it inline (1024 px on the long side), writes the full PNG (settings embedded) and saves it to the current project. |

`generate` arguments: `prompt` (required), `negative_prompt`, `model` (file or name; default is the app's selected model), `preset`, `use_app_settings` (start from the inspector's current values), `settings` (any Draw Things configuration keys, e.g. `{"sampler": 1, "shift": 3}`), `width`, `height`, `steps`, `guidance_scale`, `seed`, `input_image` (a path or `data:` URL to edit), `strength`, `reference_images` (paths, or `{"image", "weight"}`), `save_to` (a file or folder; default is a temporary folder) and `include_image`.

Settings are layered like Create's: the model's recommended settings and its default preset, then `preset`, then `settings`, then the explicit fields. An `input_image` without a size gives the output that image's aspect ratio at the model's usual pixel count.

Long runs stream progress (`notifications/progress`) to clients that send a progress token, and cancelling the call in the client stops the generation.

## Scripted testing

`Atelier --show create --mcp 7899` starts the server on port 7899 for that launch only, without touching the setting or your saved session.
