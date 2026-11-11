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
| `get_create_screen` | What's on the Create screen now: model, prompt, negative prompt, the selected [style](docs/styles.md), its tag boxes and the prompt it writes (`style`, `style_tags`, `styled_prompt`; `SUBJECT` is the prompt), seed and whether it's random, image count, every inspector setting (Draw Things configuration JSON), the settings that differ from the model's defaults, the number of reference images, whether the Layout editor is open, and `canvas` (see [Masks and regions on the canvas](#masks-and-regions-on-the-canvas)). |
| `set_create_screen` | Changes the Create screen live: model, prompt, negative prompt, preset, settings, size, steps, guidance, strength, video length, seed, Random, image count, whether the Layout editor is open, the canvas mode (Generate or Edit) and Merge into Image. Returns the screen as `get_create_screen` does. |
| `set_canvas_image` | Puts a History image (`history_step`, with the mask it last had unless `mask: false`) or an image file or `data:` URL (`image`, no mask) on the canvas, as clicking or dropping it does: fitted, in Edit mode. |
| `set_canvas_mask` | Paints the canvas mask, the area an Edit run regenerates: rectangles, ellipses and polygons (`shapes`), a mask `image` or another History image's mask (`from_history_step`), replacing the mask (the default), adding to it or subtracting from it, then `invert`; or `clear`. Each call is one ⌘Z step, "Agent Mask" (see below for one exception). |
| `get_canvas_mask` | Shows the mask: the canvas image with the mask tinted red and the frame outlined (`overlay`, the default), the mask itself white on black (`mask`), or `both`, with a summary of how much is painted, where, and how much of the frame. `save_to` writes the full-size PNGs. With `history_step`, shows that image's remembered mask instead. |
| `auto_mask` | Selects part of the canvas image into the mask, as the Select tool does: the subject with Apple's Vision (`subject: true`, with one point the subject under it), or SAM 2.1 from `points` and a `box`. Replace (the default), add or subtract; one ⌘Z step, "Agent Mask". |
| `set_canvas_region` | Zooms and moves the canvas so the frame shows part of the image (`region`), the whole image (`fit`), actual size (`actual_size`), or a `scale` around a `center`. Returns the region the frame actually shows. `size_to_region` also sets the output size to the region's shape. |
| `list_history` | The newest images and videos in the current project (yours and the agent's), newest first: history step, prompt, model, seed, size, rating, `has_mask` (it remembers a mask), and which one is on the canvas. |
| `get_image` | Shows the agent an image: what's on the canvas (the default), the project's newest (`latest`), or a History image by `history_step`. Returns it inline (`max_size`, default 1024 px on the long side) with its prompt and settings, and with `save_to` writes the full PNG. |
| `match_colors` | Matches an edited image's colors to its original (the image it was edited from, else its first moodboard image), like **Match Colors to Original** on the canvas: `history_step` (default: the canvas image), and how far each part moves to the original's, each 0–1: `tint` (the color balance, default 1), `saturation` (default 1), `brightness` (default 0) and `contrast` (default 0). `unchanged_only` (default false) measures the two images only where the edit left the picture alone, so something it added or removed isn't taken for a color shift; it falls back to the whole image when the original has another shape or about half the image or more has changed. `strength` (0–1) and `luminance` (true, false, or a number 0–1) are still taken as shortcuts: `strength` sets `tint` and `saturation`, and `strength` × `luminance` sets `brightness` and `contrast`; the four override them. Amounts are taken in whole percents. However far saturation and contrast are asked to move, they're stretched or squeezed by at most 2× and 1.5×. It runs as a job in the Queue on this device, like `generate`: it waits and returns the new `history_step` (saved after the step in its project, and shown on the canvas when that follows the queue), the step it matched (`matched_step`), the settings used (with `strength` as the tint and `luminance` as whether the lightness moved), the shift removed (`delta_a`, `delta_b`; positive `delta_b` means the edit had come out warmer, plus `delta_l` when brightness or contrast is above 0), `unchanged_fraction` (how much of the image was measured, when that was only its unchanged areas) and its `job_id`. With `background: true` it returns a `job_id` right away for `get_job`, `list_jobs` and `cancel_job`. A step that's already waiting or being matched with the same settings isn't queued again: the call joins that job. Other settings queue another job. |
| `generate` | One image, or with a video model one video. Returns the image (a video's first frame) inline (1024 px on the long side), writes the full PNG, or the MP4 with its sound (settings embedded), and saves it to the current project. With `background: true` it returns a `job_id` right away instead. |
| `get_job` | Checks on a job: `waiting`, `running` (with step and total), `done` (with everything its tool, `generate` or `match_colors`, returns), `failed` or `cancelled`. Waits up to `wait_seconds` (default 30, at most 60) for it to finish first. |
| `list_jobs` | `generate` and `match_colors` jobs from the last hour, newest first, with the tool, status and progress (a `generate` job's `prompt`, a `match_colors` job's `label`), and for finished ones their `timings` (see below). |
| `cancel_job` | Stops a job, like Cancel in the Queue. |

`generate` arguments: `prompt` (required unless `use_app_settings` is on; can be empty), `negative_prompt`, `model` (file or name; default is the app's selected model), `preset`, `use_app_settings` (start from the inspector's current values; without a `prompt`, generate the Create screen as it is), `use_canvas` (with `use_app_settings`: run exactly what Generate would, canvas included; see [Masks and regions on the canvas](#masks-and-regions-on-the-canvas)), `settings` (any Draw Things configuration keys, e.g. `{"sampler": 1, "shift": 3}`), `width`, `height`, `steps`, `guidance_scale`, `seed`, `input_image` (a path or `data:` URL to edit), `strength`, `reference_images` (paths, or `{"image", "weight"}`), `num_frames` or `seconds` and `audio` (a path) for video models, `save_to` (a file or folder; default is a temporary folder, emptied the next time Atelier opens), `include_image` and `background`.

Settings are layered like Create's: the model's recommended settings and its default preset, then `preset`, then `settings`, then the explicit fields. An `input_image` without a size gives the output that image's aspect ratio at the model's usual pixel count. For a video model, `input_image` is the first frame and, for MiniMax H3 FL2VA, the first reference image is the last; the length snaps to the frame counts the model takes. Videos take minutes, so run them in the background (see Long runs).

## Working on the Create screen together

`get_create_screen` and `set_create_screen` let an agent work on the same Create screen you're looking at: it reads what you've set, changes the prompt or settings, and you see each change in the prompt box and inspector as it happens. You can keep editing too, so an agent should read the screen again rather than assume it's unchanged.

`set_create_screen` arguments, all optional (only what's passed changes), applied in this order: `model` (file or name; keeps the current settings, like picking it in the model menu), then `preset` (applied like the inspector's Presets menu, on top of the model's defaults; a preset for another model selects it) or `reset_settings` (back to the model's defaults and default preset), then `settings` (Draw Things configuration keys, merged into the current values), then `width`, `height` (rounded to 64), `steps`, `guidance_scale`, `strength`, `num_frames` or `seconds`. Then `prompt`, `negative_prompt`, `seed` (also turns Random off), `random_seed` and `count` (1, 2, 3, 4, 6, 8, 12 or 16). Last, `layout_editor` opens or closes the Layout editor for models that take layout prompts (FLUX.3, Ideogram 4, MOSS Image); while it's open, a new layout prompt slides the boxes on the canvas to their new places. Each call's setting changes are one step you can undo with ⌘Z. In the rare case one of your own changes is still waiting to close its undo step when the call comes, the agent's change joins your step after a moment (it keeps your step's name).

To generate what's on the screen and get the image back, call `generate` with `use_app_settings: true` and no `prompt`: it takes the Create screen's model, prompt (written into the selected style, as Generate does), negative prompt, settings and, unless Random is on, seed. Add `use_canvas: true` and it runs exactly what the Generate button would, canvas included: the canvas image in Edit mode, the region the frame shows, the mask and Merge into Image, and the moodboard. It then takes no prompt, settings or `input_image` (change those on the screen first with `set_create_screen` and `set_canvas_image`). Without `use_canvas` it doesn't take the canvas image or the moodboard; pass those as `input_image` and `reference_images`.

To see results, including images you generated yourself with Generate, an agent calls `get_image` (the canvas by default) or picks one from `list_history`. `generate` already returns its own image inline.

For example: "Look at what I have in Atelier's Create screen, make the lighting moodier, and generate it."

## Masks and regions on the canvas

An agent can refine part of an image the way you would on the Create screen, one step at a time: put an image on the canvas, paint a mask over what should change, zoom the frame onto a region, then generate. Each step shows on the canvas as it happens, and an agent can do any one of them alone ("mask the sky" can stop at the mask, for you to check and generate). Coordinates are always the canvas image's pixels, from its top left; `get_create_screen`'s `canvas.source_size` gives its size.

- `set_canvas_image` puts an image on the canvas: `history_step` (it becomes the step the next run follows, as clicking it in History does) or `image` (a path or `data:` URL, like a dropped image). It's fitted to the frame and the canvas switches to Edit. The mask on the canvas stays with the image it was on: each image remembers the last mask it had, painted or used by a run. A History image comes back with its own (`mask: false` leaves it off, without forgetting it); a file or `data:` URL has none. The result says `mask_restored`.
- `set_canvas_mask` changes the mask. `shapes` are `{"shape": "rect"}` or `"ellipse"` with `x`, `y`, `width`, `height`, or `{"shape": "polygon", "points": [[x, y], …]}`; `image` is a mask the size of the canvas image (white regenerates; black or transparent keeps). `from_history_step` takes the mask another History image remembers (`list_history`'s `has_mask`), stretched to fill the canvas image when the sizes differ; adding or subtracting it uses only what it paints. `mode` says what they do to the mask there is: `replace` (the default), `add` or `subtract`. `invert` flips the result over the whole image, and `clear` empties it first (alone, it just clears it). Each call is one ⌘Z step named "Agent Mask". In the rare case one of your own changes is still waiting to close its undo step when the call comes, the agent's change joins your step after a moment (it keeps your step's name). It returns the mask summary.
- `get_canvas_mask` shows the mask as an overlay (`view: "overlay"`, the default: the canvas image tinted red where painted, the frame outlined in yellow, anything outside the image hatched), as the mask itself (`"mask"`: white on black, the canvas image's size, which `set_canvas_mask` takes back as `image`), or `"both"`. Its summary: `has_mask`, `source_size`, `painted_pixels`, `coverage` (the share of the image painted), `bounds`, `coverage_in_region` (the share of what the frame shows) and `sent_with_next_run`. With `history_step` it shows that image's remembered mask over that image (no frame) and leaves the canvas alone.
- `auto_mask` selects for you, as the Create screen's Select tool does, and puts the selection into the mask. With `subject: true` Apple's Vision picks the image's subject (with one point in `points`, the subject under it; no box), with nothing to download. Otherwise SAM 2.1 selects from `points` (`{"x", "y"}`, with `"positive": false` to leave out what's under it; at most 14, or 12 with a box) and a `box` (`{"x", "y", "width", "height"}`); `size` picks Tiny, Small or Large (default: the one picked in the Select tool). SAM must be downloaded first: an agent can't start that, so it asks you to, from the Select tool's bar. `mode` is `replace` (the default), `add` or `subtract`, as for `set_canvas_mask`, and the call is one ⌘Z step named "Agent Mask". It returns `get_canvas_mask`'s overlay and summary plus `selected_pixels`, `selected_with`, `score` (SAM's own estimate), `encode_ms` (null when the image was already encoded, or for Vision) and `decode_ms`. There's no text prompt: an agent looks at the image (`get_image`) and passes a point on what it means.
- `set_canvas_region` picks what the frame shows. A `region` of another shape than the frame is grown about its center to the frame's shape, never cropped; the frame size stays, so a small region is regenerated at the frame's full resolution. `fit` shows the whole image, `actual_size` shows it at 1×, and `scale` (frame pixels per image pixel, 0.05–32) with an optional `center` ([x, y]) zooms around a point. It returns the region the frame actually shows, which is larger or smaller than asked when the zoom needed is outside 0.05×–32× (`clamped`). With `size_to_region: true` (with `region` or `fit`), it first sets the output size to the region's shape at about the current pixel count, as one ⌘Z step.
- `get_create_screen`'s `canvas` has `has_image`, `shows`, `source_step` (the History step on the canvas, if any), `source_size`, `frame` (the output size), `region`, `scale`, `fitted`, `offset`, `extends_past_image`, `canvas_mode` and `canvas_mode_in_effect` (Edit means nothing to most models at Strength 100% with no mask, so runs then generate from the prompt alone), `merge_into_image`, `merge_applies`, `pending_selection` (a Select tool selection not yet in the mask, which Generate and `use_canvas` add first: `points`, `box`, `subject`, `busy`, `failure`; null when there's none), `can_paint_mask` (whether `set_canvas_mask` can paint now: an image in Edit mode, an image model, no Layout editor, and a run target that takes masks) and `mask` (the summary). `set_create_screen` takes `canvas_mode` (`"generate"` or `"edit"`) and `merge_into_image`.
- `generate` with `use_app_settings: true` and `use_canvas: true` runs what Generate would. With Merge into Image on (the default), a masked run, or one on part of the image or past its edges, is merged back into the whole image; it's saved as a step after the image it refined, keeping its mask and region, as yours are. Its result adds `merged`, `parent_history_step` (null when the canvas image was imported rather than taken from History: it's then kept with the new step instead), `canvas_size` (the saved image's size) and `region`. It runs where Run on says, as Generate does, and fails when that's a server too old to take masks. As Generate does, a selection the user made with the Select tool and hasn't added yet is added to the mask first (waiting for it if it's still being worked out; one "Add Selection" ⌘Z step), and the result says `selection_added` and `selection_undo_step` (the step's name: a change of the user's still open would take it into its own step). A call cancelled while it waits adds nothing.

Mask only ("mask the sky in step 12"):

1. `set_canvas_image` `{"history_step": 12}`
2. `set_canvas_mask` `{"shapes": [{"shape": "rect", "x": 0, "y": 0, "width": 1152, "height": 300}]}`
3. `get_canvas_mask` to check it; you can then refine the mask with the brush, or press Generate yourself.

Mask, then edit ("make the jacket red"):

1. `set_canvas_image` `{"history_step": 12}`, then `get_image` to find the jacket.
2. `set_canvas_mask` `{"shapes": [{"shape": "polygon", "points": [[400, 380], [760, 380], [800, 896], [360, 896]]}]}`
3. `set_create_screen` `{"prompt": "a red leather jacket", "strength": 0.8}`
4. `generate` `{"use_app_settings": true, "use_canvas": true}`

Select the subject, then edit ("put the teapot in gold"):

1. `set_canvas_image` `{"history_step": 12}`
2. `auto_mask` `{"subject": true}` (or `{"subject": true, "points": [{"x": 620, "y": 550}]}` for the one under a point)
3. `get_canvas_mask` to check it covers the teapot.
4. `set_create_screen` `{"prompt": "a polished gold teapot", "strength": 0.8}`, then `generate` `{"use_app_settings": true, "use_canvas": true}`

Zoom, then edit ("add detail to the face"):

1. `set_canvas_image` `{"history_step": 12}`
2. `set_canvas_region` `{"region": {"x": 480, "y": 120, "width": 256, "height": 256}}`: the frame now shows the face at the frame's full resolution.
3. `set_create_screen` `{"strength": 0.4}`
4. `generate` `{"use_app_settings": true, "use_canvas": true}`: the result merges back into the whole image, and the canvas keeps showing the face.

## With a server chosen

Agents work with this Mac's models, and their jobs run on this Mac even when Create's **Run on** is set to a [paired server](docs/remote.md): `list_models` lists this Mac's. The exception is a model only the selected server has, as with `use_app_settings` while Create is on such a model: that job runs on the server, and its result still comes back to the current project. A `generate` with `use_canvas` runs where Generate would: on the server Run on names. Agents can't reach a server's tools, and paired devices can't reach these.

## Progress and cancelling

Runs stream progress (`notifications/progress`) to clients that send a progress token. Cancelling or dropping the call doesn't stop the generation, because clients also cancel calls they give up on. The run carries on as a job, and `cancel_job` (or Cancel in the Queue) stops it.

## Long runs

Some clients give up on a tool call after a few minutes; Claude's connection to a Mac, for one, cancels calls after 180 seconds. A video can take longer than that, so every `generate` runs as a job that keeps going when its call is cancelled or dropped.

For long runs, call `generate` with `background: true`. It checks the arguments, queues the run and returns a `job_id` at once. Then call `get_job` with it: each call waits up to `wait_seconds` for the run to finish and otherwise returns its progress, so the agent checks in every half minute or so without one call outlasting the client's timeout. When the job is `done`, `get_job` returns exactly what `generate` would have, image included. A `generate` call that was cancelled or dropped without `background` shows up in `list_jobs`, and `get_job` collects its result the same way. `cancel_job`, or Cancel in the Queue, stops a job.

For benchmarks, a finished run's result (from `generate`, `get_job` and `list_jobs`) has `timings` in its structured content, in seconds: `load_and_encode_prompt`, `encode_inputs`, `before_sampling`, `steps` (each step), `sampling`, `decode` (frames and soundtrack), `after_decode` and `total`. If the engine gave no end-of-sampling signal, `last_step_and_decode` replaces the last step and `decode`. `get_image` lists the same timings for a History item.

Clients read the tool list when they connect, so after updating Atelier reconnect the agent (for example `/mcp` in Claude Code) to see `background` and the job tools.

Jobs are kept for an hour (the newest 20 finished ones) and are forgotten when Atelier quits; their images and videos stay in the project.

## Scripted testing

`Atelier --show create --mcp 7899` starts the server on port 7899 for that launch only, without touching the setting or your saved session.
