# Native macOS generation app on MediaGenerationKit

## Context
The Draw Things app's UI is cluttered, its history is hard to browse and reuse, managing models and LoRAs is painful, and there is no real queue. We want a native macOS SwiftUI app built on the same engine `draw-things-cli` uses: no RPC server, and previews, progress and cancel run in-process.

Pain points to fix first, in priority order:
1. Sensible per-model defaults, with advanced settings tucked away.
2. A browsable history with one-click reuse of settings.
3. Model and LoRA management.
4. A batch queue.

v1 covers text-to-image, LoRAs, image-to-image/references and video.

Working name: **Atelier**. It's a placeholder: the target and folder name are the only places it appears. Type names don't carry an app prefix (a convention carried over from draw-things-community's AGENTS.md).

## Background for a new session
- The engine is the official `https://github.com/drawthingsai/draw-things-community`, pinned by revision (see Repo, build and packaging). `/Users/ianiv/Code/draw-things-community` is a local checkout of it (a personal fork, 2 commits ahead). Use it to **read** engine source; file references in this plan point there. Nothing is ever upstreamed, so don't suggest PRs to drawthingsai.
- Always build with `swift build --build-system native`. The default SwiftPM build system stamps the SDK in a way that breaks Metal 4 and i8x models. In draw-things-community, `./Scripts/build_cli.sh [product ...]` does this.
- Models live in `/Volumes/External 2TB/DrawThings/Models`. It has `custom_lora.json` (LoRA registry), `custom.json`, `custom_configs.json`, and MOSS files `moss_image_sft_i8x.ckpt` + `qwen_3.5_9b_i5x.ckpt`, plus LoRAs `lenovo_moss_lora_f16.ckpt` and `nicegirls_v2_moss_lora_f16.ckpt`. The Mac has 48 GiB RAM.
- Community recommended settings come from `https://models.drawthings.ai/configs.json`. It has no MOSS entry yet, which is why the CLI falls back to generic defaults.
- A two-pass run (N steps, "Processing…", then a short second sampling pass) means hires fix is on (`configuration.hiresFix`, `LocalImageGenerator.swift:4286`). Expose it clearly in Advanced and default it off.
- Related prior art: `/Users/ianiv/Code/WeeTodd-Studio` (SwiftUI studio app) talks to Draw Things over gRPC through a helper built on `_MediaGenerationKit` (`studio/README.md`, `scripts/build_drawthings_client.py`).

## Foundation: MediaGenerationKit, not the CLI file
The CLI's generation code is almost all `private` inside `/Users/ianiv/Code/draw-things-community/Apps/DrawThingsCLI/DrawThingsCLI.swift`. `/Users/ianiv/Code/draw-things-community/Libraries/MediaGenerationKit` (SwiftPM product `_MediaGenerationKit`) is a clean public façade over the same `LocalImageGenerator`:
- **Generation:** `MediaGenerationPipeline.fromPretrained(_:backend:)` gives a pipeline with a mutable `configuration`. `generate(prompt:negativePrompt:inputs:stateHandler:)` reports `State` (downloading, encoding, `generating(step:totalSteps:)`, decoding…) plus lazily decoded `CGImage` previews (`MediaGenerationPipeline.swift:545-610, 886`). Cancelling the Swift `Task` cancels the generation.
- **Recommended settings:** `ConfigurationResolver.recommendedTemplate(for:loras:offline:)` already does LoRA-aware matching, which covers the "sensible defaults" goal.
- **Model catalog:** `MediaGenerationEnvironment.default` provides `downloadableModels`, `resolveModel`, `inspectModel` and `ensure(_:stateHandler:)` with download progress, and `maxTotalWeightsCacheSize` for keeping weights in memory.
- **LoRA import:** `LoRAImporter(file:version:).inspect()/import(to:)`. This is the flow we ran by hand with LoRAConverter.
- **Inputs for image-to-image and references:** `.file`/`.data` inputs and `.mask()/.moodboard()/.depth()`.

**Checked against the source at the pinned revision (Phase 1):**
- The module is `_MediaGenerationKit` (`import _MediaGenerationKit`), not `MediaGenerationKit` as AGENTS.md's sample shows.
- `DataModels` is `@_exported` (`MediaGenerationExecutionUtilities.swift:3`), so `SamplerType`, `SeedMode`, `GenerationConfiguration` etc. are usable without extra imports. `ModelZoo`/`LoRAZoo` are not exported.
- `ConfigurationResolver` is **internal**, not public. The app can't call `recommendedTemplate` or tell whether the catalog had an entry. What it gets instead: `fromPretrained` already merges the recommended template into `pipeline.configuration`. Atelier treats a configuration that still equals `GenerationConfiguration.default` (20 steps, UniPC AYS, guidance 4.5) as "not in the catalog" and applies its fallback table (`ModelDefaults.swift`).
- `MediaGenerationPipeline.Configuration` has no public init and isn't Codable; it can only be read off a pipeline and mutated. The sidecar dumps it field by field via `Mirror`. Phase 2's "Use settings" has to write fields back onto a fresh pipeline's configuration.
- `MediaGenerationEnvironment.default` is a `static var`; `externalUrls` is settable (nonmutating) and also sets `ModelZoo.externalUrls`. `.local(directory:)` builds a separate environment, so Atelier sets `default.externalUrls` and uses `.local`.
- `downloadableModels(includeDownloaded:offline:)` lists ModelZoo specs (built-in + custom.json), each with `isDownloaded`; "downloaded models" is that list filtered.
- `Result.write(to:type:)` writes encoded bytes directly; there is no metadata hook, so the PNG tEXt chunk needs re-encoding in the app (not done in Phase 1).
- **Live previews need app resources the community repo doesn't ship.** `Preview[i]` decodes with the tiny autoencoders (`canUseTAESD: true`), and `ImageConverter+CoreML.swift` force-unwraps `Bundle.main.url(forResource: "<model>_tae", withExtension: "zip")` (e.g. `flux_2_tae` for MOSS), so a missing archive traps at the first preview. `Scripts/package_app.sh` copies the 11 `*_tae.zip` from `/Applications/Draw Things.app` (override with `DRAWTHINGS_APP`); `GenerationEngine` only decodes previews when all are bundled, so a build without them still generates, just with no step previews.
- **Toolchain:** with the Command Line Tools selected, the macOS 27 SDK's `@State` macro has no plugin (`SwiftUIMacros` ships only in Xcode). `Package.swift` adds Xcode's macOS plugin path to the Atelier target when Xcode is installed (same compiler build, 6.4.0.34.1).
- `generate` returns `[Result]` and reports `State` with `generating(step:totalSteps:)` and a lazily decoded `Preview`; second-pass work (hires fix) shows as `.postprocessing`.

**Phase 2 notes:**
- `HistoryStore` is an `@Observable` index (newest first) shared by Create and History; new outputs are inserted as they save. Each PNG now carries its sidecar JSON as an `iTXt` chunk (keyword `Atelier`, UTF-8) inserted after IHDR, so no re-encode.
- "Use settings" restores model, prompt, negative prompt, seed (locked) and the inspector settings, applied onto the fresh pipeline's recommended configuration. Other configuration fields aren't written back; they come from the same recommended template, and the saved configurations of a run and its "Use settings" rerun compared equal field for field.
- Same settings and seed give a visually identical image but not a bit-identical one: reruns differ by up to 3 to 5 levels out of 255 on many pixels, including two reruns of each other with identical saved configurations (Klein 4 steps, MOSS 8 steps). Inferred to be GPU run-to-run noise in the engine, not missing settings.
- Delete moves the PNG and sidecar to the Trash. `Automation` gained `--reuse latest|PNG [--new-seed]` (compares pixels with the original) and `--show history`.

Gaps to fill. These are small additions in MGK or the app, guided by `/Users/ianiv/Code/draw-things-community/Libraries/MediaGenerationKit/AGENTS.md`: small, value-based API, no request objects, async for long work.
1. **Per-call LoRA metadata** for LoRAs that aren't registered yet. Port the CLI's `loraOverrideMapping` (`DrawThingsCLI.swift:1015`), or register LoRAs through `LoRAZoo.appendCustomSpecification` when importing.
2. **Fallback defaults for models missing from the community config catalog.** MOSS today falls back to generic 20 steps / UniPC AYS. Add an app-side table that seeds the inspector from the catalog description values, for example MOSS: 50 steps, Text Guidance 3, Shift 5, `resolutionDependentShift = false`, DDIM Trailing.
3. **Video output.** `Result` is a tensor per frame. Extract the CLI's AVFoundation `writeVideo` (`DrawThingsCLI.swift:2385`) into a small shared helper, or reimplement it in the app. Audio track: check what MGK exposes when we reach the video phase.
4. **Metadata.** Neither MGK nor the CLI records settings. The app stores the full `Configuration` with every output (see History).

## App architecture (`~/Code/Atelier/Sources/Atelier/`, macOS 14+)
- **`GenerationEngine`** (actor). Owns a cached `MediaGenerationPipeline` per model and recreates it only when the model changes. Runs one job at a time and publishes progress and the preview `CGImage` to the UI on the main actor.
- **`JobQueue`** (`@Observable`). An ordered list of `Job {prompt, negativePrompt, configuration, inputs, count}`. Supports pause, reorder, cancel and retry. "Variations" expands into N jobs (seed sweep, or a prompt list with one prompt per line).
- **`HistoryStore`**. One folder per day under `~/Pictures/Atelier/`. Each output gets a PNG/MOV plus a `.json` sidecar holding the prompt, the full configuration, model, LoRAs, seed and duration. Loaded into an in-memory index at launch; no database for v1. The sidecar also goes into the PNG as a tEXt chunk, so files stay self-describing.
- **`ModelLibrary`**. Wraps the `MediaGenerationEnvironment` catalog and LoRAZoo. Shows downloaded vs available, download progress and disk usage, and filters LoRAs by the selected model's version.

**UI layout:** a `NavigationSplitView` with sidebar sections Create, Queue, History, Models and LoRAs.
- **Create:** canvas (live preview, then the result), a prompt composer under it, and a settings inspector. Phases 1 and 2 shipped a simple version with prompt, model, size and seed in an Essentials section and a collapsed Advanced section. Phase 3 replaces it with the design below.
- **History:** a grid with a detail pane. Actions: "Use settings" (loads them into Create), "Rerun with new seed", "Reveal in Finder", delete, and filter by model or prompt text.
- **Models / LoRAs:** a catalog list with search, download, delete and drag-to-import (`.safetensors` goes through LoRAImporter or ModelImporter).

**Settings inspector (Phase 3).** Full write-up with rationale: `/mnt/project-files/design/settings-inspector.md` (project files).
- **Decisions (Ianiv, 2026-10-21):** the prompt is not in the inspector; layouts are switched by hand, not per model family; presets are wanted, separate from layouts.
- **Layout of Create.** The prompt composer sits under the canvas: multi-line, grows to about 6 lines, negative prompt as a disclosure, Generate beside it. The toolbar holds the model picker, preset menu, Generate/Cancel and the inspector toggle, and is customizable (`.toolbar(id:)`). The inspector holds a search field, a **Changed** group when anything differs from defaults, the current layout's sections, and "Reset All to Model Defaults" at the bottom.
- **macOS conventions.** Inspector collapsible and remembered (`@SceneStorage`, `InspectorCommands`, ⌥⌘I). Dense label/control rows with `.help` tooltips instead of captions. Feature sections (hires fix, tiling, refiner, TeaCache, CFG-Zero*, upscaler) get an enable checkbox, reset and disclosure in the header, with expansion persisted. Changed values are marked, with per-row reset. Every row has a context menu: Reset to Default, Copy Value, Hide from/Show in Inspector. Sliders pair with editable number fields. Size is one row that opens a popover (aspect grid, megapixels, W/H); LoRAs and sampler use searchable popovers or menus with readable names. Setting changes are undoable, with slider drags coalesced. The inspector stays editable while a job runs; edits apply to the next run. Shortcuts: ⌘L focus prompt, ⌘R roll seed.
- **Settings registry.** One descriptor per `Configuration` field (about 80): stable id, title, help, section, control kind and range, key path, parent toggle, and an applicability predicate on the selected model (`MediaGenerationResolvedModel.version`, video or not). The inspector, search, changed markers, reset, presets and History's "Use settings" all read from it. This also lets "Use settings" write back every field, not just the Phase 2 subset.
- **Visibility.** Each setting is **shown**, **tucked** (under a "More: N" disclosure in its section) or **not applicable** (hidden automatically for the selected model). Everything stays reachable through the search field, a Show All toggle (or ⌥), and the Changed group, which always surfaces tucked settings whose value differs from the model default.
- **Layouts** (which controls are shown, their order, which sections start expanded). Edit with right-click Hide/Show or a Customize Inspector… sheet (grouped checklist, drag to reorder). Stored as JSON in `~/Library/Application Support/Atelier/Layouts/`, exportable and importable. Built-ins: Simple, Standard, Everything. Switched by hand from the inspector header menu.
- **Presets** (saved values). Toolbar menu with "Save Current Settings as Preset…"; a preset applies on top of the model's defaults. Stored as JSON next to layouts and exportable. Presets don't change the layout, and layouts don't change values.

**Settings:** models directory (default `/Volumes/External 2TB/DrawThings/Models`, or the `DRAWTHINGS_MODELS_DIR` resolution) and weights cache size.

## Repo, build and packaging
- New git repo at `~/Code/Atelier` with its own `Package.swift` (swift-tools 5.9, macOS 14). It has one executable target `Atelier` in `Sources/Atelier/`.
- It depends on the official repo pinned to a revision:
  `.package(url: "https://github.com/drawthingsai/draw-things-community", revision: "8dbbb5c69b83c6312eb10622611d46a943de6f88")` (upstream `main` as of 2026-10-21, includes MOSS Image support). Bump the revision deliberately to pick up new models.
- The only library product upstream exports is `_MediaGenerationKit`, so the app uses **only MGK's public API**. Fill the gaps above in the app (fallback defaults, LoRA registration via `custom_lora.json`, video writing, metadata).
- If the app truly needs an engine change or a non-exported module (e.g. `ModelZoo`/`LoRAZoo`), switch the dependency to the local fork (`.package(path: "../draw-things-community")`, or `swift package edit`), make the change there as a separate commit, and note it here.
- **Known fork-only fix:** `327c0386` "Fix Qwen3 attention layout when vision embeddings are injected" (`Libraries/SwiftDiffusion/Sources/Models/Qwen3.swift`) isn't upstream. In phase 6 (image-to-image/references), test reference-image generation on models whose Qwen3 text encoder takes vision embeddings. If it's broken, point the dependency at the fork.
- `Scripts/build.sh` runs `swift build -c release --build-system native --product Atelier`; the native build system is required for Metal 4 and i8x models.
- `Scripts/package_app.sh` builds, then wraps the binary in `Atelier.app` (Info.plist, icon placeholder, ad-hoc codesign) at `build/Atelier.app`.
- Keep generated build products and `build/` out of git via `.gitignore`.

## Phases (each one usable on its own)
1. Skeleton: model picker, prompt, Essentials, generate with live preview and cancel, save to history folder.
2. History browser with "Use settings" and rerun.
3. Settings inspector: prompt composer under the canvas, inspector conventions, settings registry covering the full `Configuration`, search and Changed group, customizable layouts, presets. Comes before the queue because the queue needs an inspector that stays editable while jobs run.
4. Queue, batch and variations.
5. Model and LoRA library: download, import, delete, filtered LoRA picker.
6. Image-to-image and reference inputs.
7. Video: frames, output writing and an inline player.

## Verification
- In `~/Code/Atelier`: `Scripts/build.sh` builds and `Scripts/package_app.sh` produces a launchable `build/Atelier.app`.
- Generate with `moss_image_sft_i8x.ckpt` at 1152×896. Check that live previews advance through 50 steps with no second pass, cancel stops within a step, and the PNG plus sidecar appear and reload in History.
- "Use settings" on a history item reproduces the same image for the same seed.
- Settings inspector: the prompt is under the canvas; hiding a setting and then changing it from search puts it in the Changed group; a custom layout survives relaunch and round-trips through export/import; a preset applied to a different model keeps that model's defaults for settings the preset doesn't set; "Use settings" restores every registry field.
- Queue 5 variations, then pause, reorder and cancel one.
- Import a `.safetensors` LoRA from ~/Downloads. It should show up only for matching models, and a generation with it should run.
- Run an LTX video at a small frame count and check that it writes and plays back.
- A clean clone builds from scratch (no local path dependency): `rm -rf .build && Scripts/build.sh`.
