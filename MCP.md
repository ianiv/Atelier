# Atelier for agents (MCP)

Atelier runs an MCP server inside the app, so agents such as Claude Code and Codex can generate images and videos with your local models. Agents use the app's own engine: their runs join your queue (one image at a time) instead of loading a second copy of a model onto the GPU. An agent's run shows in the Queue and on the Create screen like one of yours (progress, previews, the result on the canvas, Stop or Cancel in the Queue stops it) without changing your prompt or settings, and is saved to the current project. Agents can also read the Create screen and change its model, prompt and settings live, so you and an agent can iterate on the same screen. One tool, `edit_image`, works the other way: it edits part of an image as a job of its own and leaves the Create screen exactly as you have it (see [Without touching the Create screen](#without-touching-the-create-screen)). While the queue is paused, an agent's request waits.

## Turn it on

1. Open Atelier → Settings (⌘,) → **Agents**.
2. Turn on **Let agents generate images**. The status line shows the address, `http://127.0.0.1:7862/mcp` unless you change the port.

If the port is taken, Status says by what: another app it names, "another app or system service" when macOS doesn't say which, or one of Atelier's own servers. Free the port (or pick another) and click **Try Again** beside Status. The Port field won't take a port Compute uses (Settings ▸ Compute) while Compute is on, and Compute's won't take the MCP server's; the field keeps its port and Status says whose the other one is.

By default the server listens only on this Mac (127.0.0.1 and ::1) and refuses requests from web pages. To use it from another computer, see [From another device](#from-another-device). Atelier must be open while an agent uses it. The MCP server is in the Mac app only; the iPad version doesn't have it.

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

### From another device

Set **Access** to **Local network** to let agents on other computers on your local network or tailnet use the server (addresses in the private ranges, link-local, and Tailscale's 100.64.0.0/10 and fd7a:115c:a1e0::/48; anything else is turned away before it's answered). Agents on this Mac keep working as before.

- **Require Token** (on by default): agents on other devices send the token shown under it as `Authorization: Bearer <token>`; without it, or with a wrong one, they get 401. **Show**, **Copy** and **Regenerate** are beside it; Regenerate takes effect at once, so update your other devices' setup afterwards. Agents on this Mac never need the token. With Require Token off, anyone on your network can use the server.
- In **Connect an Agent**, pick one of this Mac's network addresses (its local network address, its `.local` name, its Tailscale address) under **Address**: the setup shown then includes the token. For Codex it's an entry for `~/.codex/config.toml` (`http_headers`), since its `mcp add` command has no header option. For example:

  ```
  claude mcp add --transport http atelier http://192.168.1.20:7862/mcp --header "Authorization: Bearer <token>"
  ```

- Agents on other devices can't use this Mac's files: paths in `image`, `input_image`, `reference_images`, `mask`, the moodboard and `edit_image`'s references, `measure_reference`'s `path` and `edit_image_look`'s `reference_path` are refused, and so are `audio`, `save_to`, `lut_path`, `profile_path` and `save_profile_to`. Send images as `data:` URLs (or name a `history_step`), and use a built-in `lut` or a library `profile`; results come back inline, and `get_image` with `full_size: true` returns the full-resolution PNG. Results, including `get_job` and `list_jobs` for jobs started on this Mac, don't include this Mac's file paths (`list_grain_profiles` leaves out its `folder`).
- Anyone on your network with the token can generate and read or change the Create screen. Without HTTPS (below), traffic is plain HTTP and isn't encrypted. A request from a web page on another site is refused.
- If the Mac's firewall is on, macOS may ask whether Atelier can accept incoming connections the first time you turn this on.

#### HTTPS

**Encryption ▸ HTTPS** (with Access on Local network) encrypts what other devices send and get. With either certificate, other devices can't use plain HTTP at all: the server's own port (7862) then answers this Mac only, so agents here keep their `http://127.0.0.1:7862/mcp` setup.

- **Tailscale certificate**: Atelier's own Tailscale node (Settings ▸ Compute ▸ Tailscale, signed in) gets a certificate for its tailnet name and serves HTTPS on port 443 of your tailnet, at `https://<name>.<tailnet>.ts.net/mcp`. Your tailnet needs **MagicDNS** and **HTTPS Certificates** turned on, in the [DNS page of the Tailscale admin console](https://login.tailscale.com/admin/dns); Settings links there. The first certificate can take a minute. Atelier asks Tailscale for it again each day, and **Renew** asks now; either way Tailscale only issues a new certificate when the current one has less than 14 days left, and otherwise hands back the one it has. Status warns when the certificate has under 14 days left or a renewal failed. The certificate comes from Let's Encrypt, which publishes every certificate's name in public Certificate Transparency logs, so your tailnet's name (`<tailnet>.ts.net`) and this device's name on it become public. **Limit access to your Tailscale account** (Settings ▸ Compute) applies here too. Only devices on your tailnet can reach this address; a Tailscale app on the client is enough.
- **Imported certificate**: **Import…** a `.p12` file (a certificate with its private key, and any intermediates) and type its password. HTTPS is then on the **HTTPS Port** on every interface, for the same networks as plain HTTP. Left empty (Automatic), that's two past the server's port (7864 by default; 7863 is Compute's): `https://<host>:7864/mcp`. If Compute is on that port, or moves there later, automatic HTTPS takes the next free one; Status shows which. A port you type stays put, and Compute's Port field won't take it. With the Tailscale certificate the HTTPS Port shows 443, which can't be changed, and Compute can't use 443 then. If the HTTPS port is taken, Status says by what, with **Try Again** beside it. The certificate must name the host clients use; Settings shows its name, expiry and SHA-256 fingerprint. The file and its password are kept in your Keychain. **Remove** forgets them.

Settings ▸ Agents ▸ Encryption ▸ Status says where HTTPS is listening, or why it isn't. **Connect an Agent** then offers the `https://` addresses. The token rules don't change.

Then ask for an image, for example: "Use Atelier to make a 1024×1024 watercolor of a lighthouse at dusk with FLUX.2 klein, then save it to ~/Desktop."

## Tools

| Tool | What it does |
| --- | --- |
| `list_models` | Downloaded models: file, name, family, which one is selected in the app, and whether it takes reference images. A file that's only another model's refiner (LongCat-Video Avatar 1.6's OPSD half) isn't listed; naming it selects or runs its model. Video models say so, with their frame rate, the inputs they take and whether they make sound. |
| `list_presets` | Saved presets, the model each belongs to, which are model defaults, and their settings. |
| `get_settings` | The full settings `generate` would start from for a model (and preset), as Draw Things configuration JSON. |
| `get_create_screen` | What's on the Create screen now: model, prompt, negative prompt, the selected [style](docs/styles.md), its tag boxes and the prompt it writes (`style`, `style_tags`, `styled_prompt`; `SUBJECT` is the prompt), seed and whether it's random, image count, every inspector setting (Draw Things configuration JSON), the settings that differ from the model's defaults, the number of reference images and the `moodboard` itself (as `get_moodboard` lists it), whether the Layout editor is open, and `canvas` (see [Masks and regions on the canvas](#masks-and-regions-on-the-canvas)). |
| `set_create_screen` | Changes the Create screen live: model, prompt, negative prompt, preset, settings, size, steps, guidance, strength, video length, seed, Random, image count, whether the Layout editor is open, the canvas mode (Generate or Edit) and Merge into Image. Returns the screen as `get_create_screen` does. |
| `set_canvas_image` | Puts a History image (`history_step`, with the mask it last had unless `mask: false`), an image file or `data:` URL (`image`, no mask), or a new sketch (`blank: "white"`) on the canvas, as clicking or dropping it does: fitted, in Edit mode. |
| `set_canvas_mask` | Paints the canvas mask, the area an Edit run regenerates: rectangles, ellipses and polygons (`shapes`), a mask `image` or another History image's mask (`from_history_step`), replacing the mask (the default), adding to it or subtracting from it, then `invert`; or `clear`; `hidden` hides or shows it and the paint (Show/Hide Mask and Paint). Each call is one ⌘Z step, "Agent Mask" (see below for one exception). |
| `set_canvas_paint` | Paints colors on the canvas image, as Brush on the canvas's Color layer does: rectangles, ellipses, polygons and brush strokes (`shapes`, each with its own `color` or erasing), and what the mask covers (`fill_from_mask`); or `clear`. Each call is one ⌘Z step, "Agent Paint". Filling the mask with a flat color the prompt then names ("replace the green area with…") tells an edit model exactly where to work: see [Face fix](#face-fix). |
| `get_canvas_mask` | Shows the mask: the canvas image with the mask tinted red and the frame outlined (`overlay`, the default), the mask itself white on black (`mask`), or `both`, with a summary of how much is painted, where, and how much of the frame. `save_to` writes the full-size PNGs. With `history_step`, shows that image's remembered mask instead. |
| `auto_mask` | Selects part of the canvas image into the mask, as the Select tool does: the subject with Apple's Vision (`subject: true`, with one point the subject under it), or SAM 2.1 from `points` and a `box`. Replace (the default), add or subtract; one ⌘Z step, "Agent Mask". |
| `set_canvas_region` | Zooms and moves the canvas so the frame shows part of the image (`region`), the whole image (`fit`), actual size (`actual_size`), or a `scale` around a `center`. Returns the region the frame actually shows. `size_to_region` also sets the output size to the region's shape. |
| `find_faces` | Finds the faces in the canvas image, or in a History image (`history_step`, which leaves the canvas alone), with Apple's Vision: each face's `box`, `center`, `confidence`, tilt and turn (`roll`, `yaw`, degrees) and `landmarks`, largest first. `region` searches only part of the image, for a face that's small in a large picture. |
| `grow_canvas_mask` | Grows the canvas mask by `pixels` on every side, or with a negative number shrinks it. One ⌘Z step, "Agent Mask". |
| `set_canvas_frame` | Frames a `box` of the canvas image (default: the mask's bounds): pads it, grows it to an `aspect_ratio`, keeps it inside the image, and sets the output size from `width` and `height` or from a `scale` (frame pixels per image pixel). Returns the canvas with the region shown. A changed output size is one ⌘Z step, "Agent Settings". |
| `get_moodboard` | Lists the moodboard's reference images in order: `position`, `id`, size, `weight`, whether it's `sent`, and `picture`, the number a prompt calls it by. `include_images` returns a thumbnail of each. |
| `set_moodboard` | Changes the moodboard: `clear`, `remove`, `add` (a file, a `data:` URL or a History step, with a `weight` and `position`), `weights` and `order`. Each call is one ⌘Z step, "Agent Moodboard". |
| `edit_image` | Edits part of an image in one call without touching the Create screen: the image (`history_step` or `image`), the `region` to regenerate and its size (`width` and `height`, or `scale`), a `mask`, `paint`, `reference_images`, the prompt and settings. The result is merged back into the whole image and saved as a new step after the source. Runs as a job like `generate`. See [Without touching the Create screen](#without-touching-the-create-screen). |
| `list_history` | The newest images and videos in the current project (yours and the agent's), newest first: history step, `kind` (`image` or `video`), prompt, model, seed, size, rating, `has_mask` (it remembers a mask), and which one is on the canvas. It also lists [input entries](docs/history.md#input-entries) with `kind: "input"` and a `reason` (`imported`, `moodboard`, `cleared`, `mask` or `draw`): the canvas and moodboard as they were before runs, with `has_image`, `has_mask` and `moodboard` (how many images). They have no prompt or settings. |
| `get_image` | Shows the agent an image: what's on the canvas (the default), the project's newest generated image (`latest`), or a History image by `history_step`, an input entry's canvas image included (an entry with an empty canvas has none). Returns it inline (`max_size`, default 1024 px on the long side) with its prompt and settings, and with `save_to` writes the full PNG; `full_size: true` returns the full-resolution PNG inline instead (settings embedded), for agents that can't read files on this Mac. It's at the image's own size; for a History image with a region refined zoomed in, `full_detail: true` returns it at the detail that region keeps instead (larger, and the text gives both sizes). Masks, regions and `canvas_size` are always in the image's own pixels. Its `save_to` PNG is at the size `full_detail` asks for; `generate`'s saved PNG follows **Export Refined Images At** in Settings ▸ Images (full detail by default). |
| `match_colors` | Matches an edited image's colors to its original (the image it was edited from, else its first moodboard image), like **Match Colors to Original** on the canvas: `history_step` (default: the canvas image), and how far each part moves to the original's, each 0–1: `tint` (the color balance, default 1), `saturation` (default 1), `brightness` (default 0) and `contrast` (default 0). `original_history_step` names the image to match to instead (pass the source step after an edit made with paint, whose recorded input is the painted frame). `unchanged_only` (default false) measures the two images only where the edit left the picture alone, so something it added or removed isn't taken for a color shift; it measures the parts that barely changed from the original, and falls back to the whole image when less than a quarter of the picture qualifies (most of it was edited, or the whole picture shifted) or when the original has another shape. `strength` (0–1) and `luminance` (true, false, or a number 0–1) are still taken as shortcuts: `strength` sets `tint` and `saturation`, and `strength` × `luminance` sets `brightness` and `contrast`; the four override them. Amounts are taken in whole percents. However far saturation and contrast are asked to move, they're stretched or squeezed by at most 2× and 1.5×. It runs as a job in the Queue on this device, like `generate`: it waits and returns the new `history_step` (saved after the step in its project, and shown on the canvas when that follows the queue), the step it matched (`matched_step`), `original_history_step` when one was named, the settings used (with `strength` as the tint and `luminance` as whether the lightness moved), the shift removed (`delta_a`, `delta_b`; positive `delta_b` means the edit had come out warmer, plus `delta_l` when brightness or contrast is above 0), `unchanged_fraction` (how much of the image was measured, when that was only its unchanged areas) and its `job_id`. With `background: true` it returns a `job_id` right away for `get_job`, `list_jobs` and `cancel_job`. A step that's already waiting or being matched with the same settings isn't queued again: the call joins that job. Other settings queue another job. |
| `edit_image_look` | Gives an image a look on the [Edit screen](docs/editing.md) without a model and saves it after its source: grain, color matching, a grade, a LUT, halation, lens and vignette. See [Edit screen looks](#edit-screen-looks). |
| `list_grain_profiles` | The grain profiles in the library (the Edit screen's profile menu): `name`, `source` (the reference it was measured from), `created`, `settings` (grain.py's `blur`, `motion`, `angle`, `lum`, `chroma`, `size`, `csize`, `colour`, `tint`, `expo`, `real`), a one-line `summary`, `ref_width`, `curve`, `has_ref_stats` (it can drive `options.match.colour`) and `real_noise_patches` (it can drive `options.grain.real`), plus the library's `folder`. |
| `measure_reference` | Measures a reference's grain as Match Reference and `grain.py --match` do, without rendering: `path` (an image file) or `history_step`. Returns the fitted `settings` (`lum`, `size`, `chroma`, `csize`, and `colour` 0.6 as `--match` sets it), `brightness_curve`, `reference` (its size, `grain_shape` at 1/2/4 px, `colour_blotches` at 1/2/4/8 px, `colour_blotch_strength`, `band_noise`, `rgb_mean`, `rgb_std`), `ours` (the fitted grain's `grain_shape` and `colour_blotches`) and `report`, grain.py's printed lines. Fails for an image with no flat, mid-bright area to measure. |
| `generate` | One image, or with a video model one video. Returns the image (a video's first frame) inline (1024 px on the long side), writes the full PNG, or the MP4 with its sound (settings embedded), and saves it to the current project. With `background: true` it returns a `job_id` right away instead. |
| `get_job` | Checks on a job: `waiting`, `running` (with step and total), `done` (with everything its tool, `generate`, `edit_image`, `match_colors` or `edit_image_look`, returns), `failed` or `cancelled`. Waits up to `wait_seconds` (default 30, at most 60) for it to finish first. |
| `list_jobs` | `generate`, `edit_image`, `match_colors` and `edit_image_look` jobs from the last hour, newest first, with the tool, status and progress (a `generate` or `edit_image` job's `prompt`, a `match_colors` or `edit_image_look` job's `label`), and for finished ones their `timings` (see below). |
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
- `set_canvas_mask` changes the mask. `shapes` are `{"shape": "rect"}` or `"ellipse"` with `x`, `y`, `width`, `height`, or `{"shape": "polygon", "points": [[x, y], …]}`; `image` is a mask the size of the canvas image (white regenerates; black or transparent keeps). `from_history_step` takes the mask another History image remembers (`list_history`'s `has_mask`), stretched to fill the canvas image when the sizes differ; adding or subtracting it uses only what it paints. `mode` says what they do to the mask there is: `replace` (the default), `add` or `subtract`. `invert` flips the result over the whole image, and `clear` empties it first (alone, it just clears it). `hidden: true` hides the mask and the paint together, last, as the app's Show/Hide Mask and Paint does: they're kept but not drawn, and runs (`generate` with `use_canvas` included) go as if there were neither (no mask, no paint in the input, no Draw entry); `hidden: false` shows them again, and any other change to the mask or the paint shows them too. Alone, `hidden` just hides or shows them. The result says `layers_hidden`. After a masked run that merges, the result keeps the mask, hidden. `get_canvas_mask`'s summary has `layers_hidden` too. Each call is one ⌘Z step named "Agent Mask". In the rare case one of your own changes is still waiting to close its undo step when the call comes, the agent's change joins your step after a moment (it keeps your step's name). It returns the mask summary.
- `set_canvas_paint` paints colors on the canvas image: a layer over it that the next Edit run takes as part of its input (it doesn't change the mask). `shapes` are those of `set_canvas_mask` plus `{"shape": "stroke", "points": [[x, y], …], "radius": r}` (a brush stroke, radius in image pixels, default 8); each may have a `color` (`"#RRGGBB"` or `"#RRGGBBAA"`) or `"erase": true` to take paint away. `color` is the default for shapes without one and for `fill_from_mask`, which fills what the canvas mask covers (the mask stays); it falls back to the app's paint color. `clear` removes the paint first (alone, it just clears it), and `hidden` hides or shows the mask and paint together, last, as for `set_canvas_mask`. Each call is one ⌘Z step named "Agent Paint". It returns `has_paint`, `strokes` and `bounds`, and a `note` when the paint would be replaced (Strength 100% with no mask: lower `strength` or paint a mask). `set_canvas_image` with `blank: "white"` starts a sketch: a white image the frame's size. Before a run with paint, a Draw input entry with the painted image is recorded.
- `get_canvas_mask` shows the mask as an overlay (`view: "overlay"`, the default: the canvas image tinted red where painted, the frame outlined in yellow, anything outside the image hatched), as the mask itself (`"mask"`: white on black, the canvas image's size, which `set_canvas_mask` takes back as `image`), or `"both"`. Its summary: `has_mask`, `source_size`, `painted_pixels`, `coverage` (the share of the image painted), `bounds`, `coverage_in_region` (the share of what the frame shows) and `sent_with_next_run`. With `history_step` it shows that image's remembered mask over that image (no frame) and leaves the canvas alone.
- `auto_mask` selects for you, as the Create screen's Select tool does, and puts the selection into the mask. With `subject: true` Apple's Vision picks the image's subject (with one point in `points`, the subject under it; no box), with nothing to download. Otherwise SAM 2.1 selects from `points` (`{"x", "y"}`, with `"positive": false` to leave out what's under it; at most 14, or 12 with a box) and a `box` (`{"x", "y", "width", "height"}`); `size` picks Tiny, Small or Large (default: the one picked in the Select tool). SAM must be downloaded first: an agent can't start that, so it asks you to, from the Select tool's bar. `mode` is `replace` (the default), `add` or `subtract`, as for `set_canvas_mask`, and the call is one ⌘Z step named "Agent Mask". It returns `get_canvas_mask`'s overlay and summary plus `selected_pixels`, `selected_with`, `score` (SAM's own estimate), `encode_ms` (null when the image was already encoded, or for Vision) and `decode_ms`. There's no text prompt: an agent looks at the image (`get_image`) and passes a point on what it means.
- `set_canvas_region` picks what the frame shows. A `region` of another shape than the frame is grown about its center to the frame's shape, never cropped; the frame size stays, so a small region is regenerated at the frame's full resolution. `fit` shows the whole image, `actual_size` shows it at 1×, and `scale` (frame pixels per image pixel, 0.05–32) with an optional `center` ([x, y]) zooms around a point. It returns the region the frame actually shows, which is larger or smaller than asked when the zoom needed is outside 0.05×–32× (`clamped`). With `size_to_region: true` (with `region` or `fit`), it first sets the output size to the region's shape at about the current pixel count, as one ⌘Z step.
- `find_faces` finds faces with Apple's Vision, with nothing to download: in the canvas image, or with `history_step` in a History image, leaving the canvas alone. It returns `source_size` and `faces`, largest first, each with `box` and `center` (the image's pixels), `confidence`, `roll` and `yaw` (the head's tilt and turn in degrees, when Vision gives them) and `landmarks` (`left_eye`, `right_eye`, `nose`, `outer_lips`, `face_contour` as `[x, y]` points; left and right are the image's). The box runs from about the brows to the chin, not the whole head, so pad it for the frame and grow a mask made from it. Vision can miss a face that is a few percent of a large image: pass `region` around the head to search only there, at its own resolution (the faces still come back in the whole image's pixels). `max_faces` (default 10) limits the list. When it finds no face it fails with an error saying so, rather than returning an empty list.
- `grow_canvas_mask` moves the mask's edge out by `pixels` (the canvas image's pixels, up to 512), with a round brush, or in with a negative number. A mask from `auto_mask` or a face's box usually wants a few dozen pixels more, so the run has room to blend the edit in. The mask is always hard-edged; the softness of an edit's edge is the Mask Blur settings (`set_create_screen` `settings` `{"maskBlur": …, "maskBlurOutset": …}`). One ⌘Z step, "Agent Mask". It returns the mask summary with `grown_by`.
- `set_canvas_frame` works out the frame for you, where `set_canvas_region` takes the numbers. `box` is what to frame (default: the mask's bounds). It's padded by `padding` pixels or by `padding_ratio` of its longer side (default 0.25), grown about its center to `aspect_ratio` (`"W:H"` or a number; default the output's shape), never cropped, and moved, not shrunk, to lie inside the image (`stay_inside_image: false` leaves it centered on the box). Then the output size: `width` and `height`; or `scale`, frame pixels per image pixel, which sizes the output to the region at exactly that zoom, sides rounded up to multiples of 64 with the region grown to match, so nothing of the padded box is cropped (a 912×1152 region at `scale` 4 is a 3648×4608 output; a 200×200 one at `scale` 1 becomes 256×256); or neither, which keeps the output size, or its pixel count when `aspect_ratio` changes its shape. It returns the canvas as `get_create_screen` does, plus `requested_box`, `padded_box`, `clamped` and `notes`. A changed output size is one ⌘Z step, "Agent Settings"; the zoom isn't undoable, as with `set_canvas_region`.
- `get_moodboard` lists the moodboard: `images` in order, each with `position` (1 is first), `id`, `width`, `height`, `weight`, `sent` (weight above 0) and `picture`, the number a prompt calls it by; and `model_takes_references`, with a `note` when the selected model takes none (the images stay on the board but aren't sent). Pictures are numbered in order, counting only the images sent: with an image on the canvas in Edit the canvas is Picture 1 (`canvas_is_picture_1`) and the first moodboard image Picture 2. `include_images: true` also returns each image as a 256 px thumbnail. The moodboard belongs to the app, not to a project.
- `set_moodboard` changes it, in this order: `clear`; `remove` (ids, or positions as they were before the call); `add` (each `{"image": path or data: URL}` or `{"history_step": N}`, with `weight`, default 1, and `position`, default the end); `weights` (`{"id" or "position", "weight"}`, positions as before the call; 0 keeps an image on the board but out of runs); `order` (every image's id in the new order). Images are scaled to 1536 px on the long side. It returns the listing. The whole call is one ⌘Z step, "Agent Moodboard" (a call that changes nothing adds none; and since the moodboard's own controls aren't undoable, the step does nothing once you've changed the board by hand after it, rather than take your change back too), and like any moodboard change it's recorded in History as a Moodboard input entry.
- `get_create_screen`'s `canvas` has `has_image`, `shows`, `source_step` (the History step on the canvas, if any), `source_size`, `frame` (the output size), `region`, `scale`, `fitted`, `offset`, `extends_past_image`, `canvas_mode` and `canvas_mode_in_effect` (Edit means nothing to most models at Strength 100% with no mask, so runs then generate from the prompt alone), `merge_into_image`, `merge_applies`, `pending_selection` (a Select tool selection not yet in the mask, which Generate and `use_canvas` add first: `points`, `box`, `subject`, `busy`, `failure`; null when there's none), `can_paint_mask` (whether `set_canvas_mask` can paint now: an image in Edit mode, an image model, no Layout editor, and a run target that takes masks), `has_paint` (colors painted on the image, `set_canvas_paint`), `layers_hidden` (the mask and paint are hidden, so runs go without them) and `mask` (the summary). `set_create_screen` takes `canvas_mode` (`"generate"` or `"edit"`) and `merge_into_image`.
- `generate` with `use_app_settings: true` and `use_canvas: true` runs what Generate would. With Merge into Image on (the default), a masked run, or one on part of the image or past its edges, is merged back into the whole image; it's saved as a step after the image it refined, keeping its mask and region, as yours are. Its result adds `merged`, `parent_history_step` (null when the canvas image was imported rather than taken from History: it's then kept with the new step instead), `canvas_size` (the saved image's own size; a zoomed-in refine also keeps its region at the detail it was made at, which `get_image` with `full_detail` shows) and `region`. It runs where Run on says, as Generate does, and fails when that's a server too old to take masks. As Generate does, a selection the user made with the Select tool and hasn't added yet is added to the mask first (waiting for it if it's still being worked out; one "Add Selection" ⌘Z step), and the result says `selection_added` and `selection_undo_step` (the step's name: a change of the user's still open would take it into its own step). A call cancelled while it waits adds nothing.

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

## Face fix

A small face in a large image usually comes out soft or wrong: the model had only a few hundred pixels for it. The fix is to regenerate just the face at several times its size and put it back. With an edit model that takes reference images (see `list_models`), such as MiniMax H3 Image, the prompt can also say whose face it should be. Four things make it work:

- **Zoom.** The frame shows only the region around the face, at a `scale` that gives the model a few megapixels to work with.
- **Mask.** Only the face (grown a little, so the edge blends) is regenerated; the rest of the region is context.
- **Green fill.** The mask is filled with a flat color and the prompt names it, which tells an edit model exactly where to work.
- **Reference.** The face to put there goes along as the next picture.

The example below is a 3200×5056 portrait in History step 12, with a face about 560×700 pixels. The region is 912×1152 around it, and at `scale` 4 the run is 3648×4608.

On the canvas, a step at a time, where you can watch and step in:

1. `set_create_screen` `{"model": "minimax_h3_image_i8x.ckpt", "steps": 6, "guidance_scale": 1}`, then `set_canvas_image` `{"history_step": 12}`.
2. `find_faces` returns the face's `box`, here `{"x": 1320, "y": 720, "width": 560, "height": 700}`. If it finds none, pass a `region` around the head.
3. `set_canvas_mask` `{"shapes": [{"shape": "ellipse", "x": 1320, "y": 720, "width": 560, "height": 700}]}` (or `auto_mask` with a point at the face's `center`), then `grow_canvas_mask` `{"pixels": 48}`.
4. `set_canvas_frame` `{"box": {"x": 1320, "y": 720, "width": 560, "height": 700}, "padding": 176, "aspect_ratio": "19:24", "scale": 4}`: the frame shows the 912×1152 region at (1144, 494) and the output size becomes 3648×4608.
5. `set_canvas_paint` `{"fill_from_mask": true, "color": "#00FF00"}`.
6. `set_moodboard` `{"clear": true, "add": [{"image": "~/Pictures/reference-face.jpg"}]}`: the canvas is Picture 1, so this is Picture 2 (`get_moodboard` says so).
7. `set_create_screen` `{"prompt": "Replace the green area in Picture 1 with the face of the woman in Picture 2: same head angle and expression as the body suggests, natural skin texture, lit like the rest of the scene. Keep everything outside the green area unchanged."}`
8. `generate` `{"use_app_settings": true, "use_canvas": true}`: the result is merged back into the 3200×5056 image and saved as a new step, say 13.
9. `match_colors` `{"history_step": 13, "original_history_step": 12, "unchanged_only": true}`.

Or in one call, leaving the Create screen alone (`find_faces` `{"history_step": 12}` gives the box without putting the image on the canvas):

```json
{
  "history_step": 12,
  "model": "minimax_h3_image_i8x.ckpt",
  "prompt": "Replace the green area in Picture 1 with the face of the woman in Picture 2: same head angle and expression as the body suggests, natural skin texture, lit like the rest of the scene. Keep everything outside the green area unchanged.",
  "region": {"x": 1144, "y": 494, "width": 912, "height": 1152},
  "scale": 4,
  "mask": {"shapes": [{"shape": "ellipse", "x": 1320, "y": 720, "width": 560, "height": 700}], "grow": 48},
  "paint": {"fill_mask": true, "color": "#00FF00"},
  "reference_images": ["~/Pictures/reference-face.jpg"],
  "steps": 6,
  "guidance_scale": 1
}
```

That's `edit_image`'s arguments; then `match_colors` as in step 9, with the step it returns.

Notes:

- `match_colors` needs `original_history_step` here. An edit made with paint records the painted frame as its input, so without it the colors are measured against a picture with the green in it. `unchanged_only: true` measures only what the edit left alone, so the new face isn't taken for a color shift.
- Paint is only the run's input. Outside the mask the result is the source's own pixels, and none of the green survives where the model did its job; if some does, grow the mask less or say more firmly what replaces it.
- Use a seed other than the one that made the picture (`edit_image` and `generate` pick a random one unless told). MiniMax H3 Image given the same seed reproduces the picture and barely applies the edit.
- The same steps fix anything small: a hand, a sign, a distant figure. Without a reference, leave out the moodboard or `reference_images` and describe what belongs there; with a model that takes no references, leave out the paint too, lower `strength`, and let the mask do the work.

## Without touching the Create screen

`edit_image` does a whole masked, zoomed edit as one job, on its own copy of everything. Nothing on the Create screen changes: not the canvas image, its zoom, mask or paint, not the prompt, the inspector, the seed or the moodboard, not the step selected in History, and nothing is added to ⌘Z. No preview or result lands on the canvas. You see the job in the Queue and the status bar, the result in History (and in the output folder, and as a notification, if those are on), and you can cancel it there. Use it when the user is busy on the Create screen, or when an agent fixes a batch of images.

Arguments:

- The image: `history_step`, or `image` (a path or `data:` URL), exactly one.
- The frame: `region` (the image's pixels from its top left; default the whole image) is what the model sees and regenerates. Its size is `width` and `height`, or `scale` (frame pixels per image pixel, 0.05–32; the sides are rounded up to 64 and the region grows to match about its center, so the zoom is exact and nothing of the region is cropped), or with neither the region's shape at the model's usual pixel count. A region of another shape than the size is grown about its center, never cropped, then moved to stay inside the image where it fits. Keep the region inside the image: where it reaches past the edges, or is larger than the image, the run fills in what's outside and the merged result grows to hold it, so it comes back larger than the source (`extends_past_image` is true, `canvas_size` is the new size, and a note says so), as Merge into Image does on the canvas.
- `mask`: `{"shapes", "image", "select", "grow", "invert"}`, built in that order. `shapes` and `image` are `set_canvas_mask`'s; `select` is `auto_mask`'s (`{"subject": true}`, or `points` and a `box` for SAM 2.1, with `size`); `grow` moves the edge as `grow_canvas_mask` does; `invert` flips the result. It needs at least one of `shapes`, `image` and `select`. Without a mask the whole region is regenerated.
- `paint`: `{"shapes", "fill_mask", "color"}`. `fill_mask` fills what the mask covers with `color`; `shapes` are `set_canvas_paint`'s, each with its own `color` or the default. There's no app paint color to fall back to here, so a color is required.
- `reference_images`: as `generate` takes them, plus `{"history_step": N}`. The image itself is Picture 1 and these follow. Only for models that take references.
- The run: `prompt` (required), `negative_prompt`, `model` (default the app's selected model), `preset`, `settings`, `use_app_settings` (read the inspector's values; they aren't changed), `steps`, `guidance_scale`, `strength`, `seed`. Settings layer as `generate`'s do. For a softer mask edge pass `settings` `{"maskBlur": …, "maskBlurOutset": …}`.
- `merge_into_image` (default true) puts the result back into the whole image; false saves just the frame. `save_to`, `include_image` and `background` are `generate`'s.

It returns what `generate` returns, plus `merged`, `parent_history_step` (the step it edited), `canvas_size` (the saved image's size), `source_size` (the image's own; they differ when the region reached past it), `extends_past_image`, `region` and `scale` (what the run saw), `mask` (`painted_pixels`, `bounds`, `coverage_in_region`; null without one), `has_paint`, `references` (how many went along) and `job_id`. The result is saved after its source step in the project that was open when it was called, even if you open another before it finishes (the result then says which project, and its `history_step` is a step there; if that project was renamed or deleted meanwhile, the job fails saying so); an image from a file is saved with it. The source keeps the mask it remembers: an `edit_image` mask is the job's alone.

It says what's wrong rather than guessing: both or neither of `image` and `history_step`; a video model, or a video step; `reference_images` for a model that takes none; a mask that covers nothing inside `region`; `fill_mask` with no mask; no mask at Strength 100% on a model that doesn't read the image as a reference (lower `strength` or pass a `mask`); a region that would need a zoom outside 0.05×–32×; SAM 2.1 not downloaded.

`edit_image` runs on this Mac only, with this Mac's models, whatever Run on says. `get_job`, `list_jobs` and `cancel_job` work on its jobs as on `generate`'s.

## Edit screen looks

`edit_image_look` renders an image (`history_step`, by default the canvas image) with an [Edit screen](docs/editing.md) look at full size and saves it as a new step after its source, through the same job as the screen's **Save to History**: in the Queue on this Mac whatever Run on says, after what's waiting, saved into the step's own project. It needs no model, and leaves the Edit screen as the user has it.

It's non-destructive like the screen. For a step saved from Edit (by the screen or this tool), it goes back to the image that step was made from and starts from the look the step records (settings, profile data, reference measurements and LUT), so a second call changes the look rather than adding grain over grain. For any other step it starts from no change: no blur, no grain, nothing. Over that base go, in order:

1. The profile: `profile` (a name from `list_grain_profiles`) or `profile_path` (a `.grain.json` anywhere, grain.py's or Grain Studio's): its settings and grain data. Or, with `match_reference: true`, the profile Match Reference fits to the reference, as `grain.py --match` does: grain, size, colour noise and colour size, `colour` 0.6, its brightness curve, RGB statistics and real noise. `match_reference` takes the place of a profile, so passing both is an error.
2. The LUT, at strength 1: `lut`, one of the [built-in looks](docs/editing.md#built-in-luts) by name (Warm Film, Teal and Orange, Faded Matte, Punchy Slide, Bleach Bypass, Sodium Night, Cool Phone Night, Golden Hour, Tri-X Mono, Cross Process), or `lut_path`, a 3D `.cube` LUT (sizes 2–129). Passing both is an error, as is a name that isn't a built-in (the error lists them).
3. The reference: `reference_path` (an image file) or `reference_history_step`, measured for the color and histogram matches. It sets `options.match.target` to `reference`.
4. `options`: a partial look, by section. A section or key left out stays as the layers below set it.

`options` sections and keys:

- `match`: `target` (`reference` or `original`, the image the step was made from, shown as **Step's Input** on the Edit screen; a step made from no image has none), `tint`, `saturation`, `brightness`, `contrast` (0–1, how far each moves to the target's, as `match_colors`), `colour` (grain.py's per-channel color match to the profile's reference; needs a profile).
- `histogram`: `amount` (0–1), `space` (`luma`, the default, or `rgb`).
- `grade`: `exposure` (stops), `temperature` (−100 to 100), `tint` (grain.py's green − / magenta +, about −30 to 30), `contrast`, `saturation`, `vibrance` (−1 to 1).
- `lut`: `strength` (0–1). The table comes from `lut` or `lut_path`.
- `halation`: `amount`, `threshold` (default 0.8), `radius` (1–200 px, default 20), `warmth` (default 0.6).
- `lens`: `motion` (px; smears above 1), `angle` (degrees), `blur` (px; grain.py's default is 3).
- `vignette`: `amount` (−1 to 1), `size`, `softness` (0–1).
- `grain`: grain.py's `lum` (its default 9), `size` (1), `chroma` (3), `csize` (1), `real` (needs a profile with real noise) and `seed` (7). `grain` also takes grain.py's other flat names, `blur`, `motion`, `angle`, `colour`, `tint` and `expo`, and moves them to their sections, so a grain.py settings dict can go in as it is.

For grain.py's own default look from a plain step, pass `{"grain": {"lum": 9, "chroma": 3, "blur": 3}}` or a profile. It checks what it's given and says what's wrong: an unknown section or key, a value of the wrong type or out of range, matches with nothing to match to (no reference, or `original` for a step not made from an image), `colour` or `real` without a profile that has the data, `match_reference` without a reference or with no flat, mid-bright area in it. `save_profile_to` also writes the look as a `.grain.json` profile (grain.py's format, no seed) to that file, or into that folder under the profile's name.

It waits and returns the new `history_step`, `source_step`, `edited_step` (the step passed, when it was an edit of `source_step`), `options` (the full look used), `profile`, `reference` and `lut` names, `width` and `height`, `match_report` (with `match_reference`: what `measure_reference` returns), `saved_profile`, `notes` and `job_id`. With `background: true` it returns a `job_id` at once for `get_job`, `list_jobs` and `cancel_job`. The same edit that's already waiting or running (from the screen or another call) isn't queued again: the call joins it.

## With a server chosen

Agents work with this Mac's models, and their jobs run on this Mac even when Create's **Run on** is set to a [paired server](docs/remote.md): `list_models` lists this Mac's. The exception is a model only the selected server has, as with `use_app_settings` while Create is on such a model: that job runs on the server, and its result still comes back to the current project. A `generate` with `use_canvas` runs where Generate would: on the server Run on names. `edit_image` always runs on this Mac, and fails for a model only the server has. Agents can't reach a server's tools, and paired devices can't reach these.

## Progress and cancelling

Runs stream progress (`notifications/progress`) to clients that send a progress token. Cancelling or dropping the call doesn't stop the generation, because clients also cancel calls they give up on. The run carries on as a job, and `cancel_job` (or Cancel in the Queue) stops it.

## Long runs

Some clients give up on a tool call after a few minutes; Claude's connection to a Mac, for one, cancels calls after 180 seconds. A video can take longer than that, so every `generate` (and `edit_image`) runs as a job that keeps going when its call is cancelled or dropped.

For long runs, call `generate` (or `edit_image`) with `background: true`. It checks the arguments, queues the run and returns a `job_id` at once. Then call `get_job` with it: each call waits up to `wait_seconds` for the run to finish and otherwise returns its progress, so the agent checks in every half minute or so without one call outlasting the client's timeout. When the job is `done`, `get_job` returns exactly what `generate` would have, image included. A `generate` call that was cancelled or dropped without `background` shows up in `list_jobs`, and `get_job` collects its result the same way. `cancel_job`, or Cancel in the Queue, stops a job.

For benchmarks, a finished run's result (from `generate`, `get_job` and `list_jobs`) has `timings` in its structured content, in seconds: `load_and_encode_prompt`, `encode_inputs`, `before_sampling`, `steps` (each step), `sampling`, `decode` (frames and soundtrack), `after_decode` and `total`. If the engine gave no end-of-sampling signal, `last_step_and_decode` replaces the last step and `decode`. `get_image` lists the same timings for a History item.

Clients read the tool list when they connect, so after updating Atelier reconnect the agent (for example `/mcp` in Claude Code) to see `background` and the job tools.

Jobs are kept for an hour (the newest 20 finished ones) and are forgotten when Atelier quits; their images and videos stay in the project.

## Scripted testing

`Atelier --show create --mcp 7899` starts the server on port 7899 for that launch only, without touching the setting or your saved session. `--mcp-network` (with or without `--mcp`) also puts it on the local network for that launch. `--agent-net-check --project NAME --quit` checks the network access (token, paths, origins, HTTPS with a throwaway certificate, and ports that are taken) on a server of its own, leaving your settings and Keychain alone.
