# Atelier for agents (MCP)

Atelier runs an MCP server inside the app, so agents such as Claude Code and Codex can generate images and videos with your local models. Agents use the app's own engine: their runs join your queue (one image at a time) instead of loading a second copy of a model onto the GPU. An agent's run shows in the Queue and on the Create screen like one of yours (progress, previews, the result on the canvas, Stop or Cancel in the Queue stops it) without changing your prompt or settings, and is saved to the current project. Agents can also read the Create screen and change its model, prompt and settings live, so you and an agent can iterate on the same screen. While the queue is paused, an agent's request waits.

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
| `list_models` | Downloaded models: file, name, family, which one is selected in the app, and whether it takes reference images. Video models say so, with their frame rate, the inputs they take and whether they make sound. |
| `list_presets` | Saved presets, the model each belongs to, which are model defaults, and their settings. |
| `get_settings` | The full settings `generate` would start from for a model (and preset), as Draw Things configuration JSON. |
| `get_create_screen` | What's on the Create screen now: model, prompt, negative prompt, seed and whether it's random, image count, every inspector setting (Draw Things configuration JSON), the settings that differ from the model's defaults, the number of reference images, and whether the Layout editor is open. |
| `set_create_screen` | Changes the Create screen live: model, prompt, negative prompt, preset, settings, size, steps, guidance, strength, video length, seed, Random, image count, and whether the Layout editor is open. Returns the screen as `get_create_screen` does. |
| `list_history` | The newest images and videos in the current project (yours and the agent's), newest first: history step, prompt, model, seed, size, rating, and which one is on the canvas. |
| `get_image` | Shows the agent an image: what's on the canvas (the default), the project's newest (`latest`), or a History image by `history_step`. Returns it inline (`max_size`, default 1024 px on the long side) with its prompt and settings, and with `save_to` writes the full PNG. |
| `generate` | One image, or with a video model one video. Returns the image (a video's first frame) inline (1024 px on the long side), writes the full PNG, or the MP4 with its sound (settings embedded), and saves it to the current project. With `background: true` it returns a `job_id` right away instead. |
| `get_job` | Checks on a job: `waiting`, `running` (with step and total), `done` (with everything `generate` returns), `failed` or `cancelled`. Waits up to `wait_seconds` (default 30, at most 60) for it to finish first. |
| `list_jobs` | Jobs from the last hour, newest first, with status and progress. |
| `cancel_job` | Stops a job, like Cancel in the Queue. |

`generate` arguments: `prompt` (required unless `use_app_settings` is on), `negative_prompt`, `model` (file or name; default is the app's selected model), `preset`, `use_app_settings` (start from the inspector's current values; without a `prompt`, generate the Create screen as it is), `settings` (any Draw Things configuration keys, e.g. `{"sampler": 1, "shift": 3}`), `width`, `height`, `steps`, `guidance_scale`, `seed`, `input_image` (a path or `data:` URL to edit), `strength`, `reference_images` (paths, or `{"image", "weight"}`), `num_frames` or `seconds` and `audio` (a path) for video models, `save_to` (a file or folder; default is a temporary folder), `include_image` and `background`.

Settings are layered like Create's: the model's recommended settings and its default preset, then `preset`, then `settings`, then the explicit fields. An `input_image` without a size gives the output that image's aspect ratio at the model's usual pixel count. For a video model, `input_image` is the first frame and, for MiniMax H3 FL2VA, the first reference image is the last; the length snaps to the frame counts the model takes. Videos take minutes, so run them in the background (see Long runs).

## Working on the Create screen together

`get_create_screen` and `set_create_screen` let an agent work on the same Create screen you're looking at: it reads what you've set, changes the prompt or settings, and you see each change in the prompt box and inspector as it happens. You can keep editing too, so an agent should read the screen again rather than assume it's unchanged.

`set_create_screen` arguments, all optional (only what's passed changes), applied in this order: `model` (file or name; keeps the current settings, like picking it in the model menu), then `preset` (applied like the inspector's Presets menu, on top of the model's defaults; a preset for another model selects it) or `reset_settings` (back to the model's defaults and default preset), then `settings` (Draw Things configuration keys, merged into the current values), then `width`, `height` (rounded to 64), `steps`, `guidance_scale`, `strength`, `num_frames` or `seconds`. Then `prompt`, `negative_prompt`, `seed` (also turns Random off), `random_seed` and `count` (1, 2, 3, 4, 6, 8, 12 or 16). Last, `layout_editor` opens or closes the Layout editor for models that take layout prompts (FLUX.3, Ideogram 4, MOSS Image); while it's open, a new layout prompt slides the boxes on the canvas to their new places. Each call's setting changes are one step you can undo with ⌘Z.

To generate what's on the screen and get the image back, call `generate` with `use_app_settings: true` and no `prompt`: it takes the Create screen's model, prompt, negative prompt, settings and, unless Random is on, seed. It doesn't take the canvas image or the moodboard; pass those as `input_image` and `reference_images`.

To see results, including images you generated yourself with Generate, an agent calls `get_image` (the canvas by default) or picks one from `list_history`. `generate` already returns its own image inline.

For example: "Look at what I have in Atelier's Create screen, make the lighting moodier, and generate it."

## Progress and cancelling

Runs stream progress (`notifications/progress`) to clients that send a progress token. Cancelling or dropping the call doesn't stop the generation, because clients also cancel calls they give up on. The run carries on as a job, and `cancel_job` (or Cancel in the Queue) stops it.

## Long runs

Some clients give up on a tool call after a few minutes; Claude's connection to a Mac, for one, cancels calls after 180 seconds. A video can take longer than that, so every `generate` runs as a job that keeps going when its call is cancelled or dropped.

For long runs, call `generate` with `background: true`. It checks the arguments, queues the run and returns a `job_id` at once. Then call `get_job` with it: each call waits up to `wait_seconds` for the run to finish and otherwise returns its progress, so the agent checks in every half minute or so without one call outlasting the client's timeout. When the job is `done`, `get_job` returns exactly what `generate` would have, image included. A `generate` call that was cancelled or dropped without `background` shows up in `list_jobs`, and `get_job` collects its result the same way. `cancel_job`, or Cancel in the Queue, stops a job.

Clients read the tool list when they connect, so after updating Atelier reconnect the agent (for example `/mcp` in Claude Code) to see `background` and the job tools.

Jobs are kept for an hour (the newest 20 finished ones) and are forgotten when Atelier quits; their images and videos stay in the project.

## Scripted testing

`Atelier --show create --mcp 7899` starts the server on port 7899 for that launch only, without touching the setting or your saved session.
