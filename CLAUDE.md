# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Atelier is a native SwiftUI app (macOS 26 + iPadOS 27, Apple silicon) that generates images and video with local models. It embeds the Draw Things engine ([draw-things-community](https://github.com/drawthingsai/draw-things-community)) in-process — no server — and reads/writes Draw Things' model folder and project file format. GPL-3.0.

## Commands

Build only through the script; outputs land in `build/` (gitignored, a symlink to `build.noindex/` so Spotlight skips them), never Xcode's default DerivedData.

```bash
Scripts/build.sh [Debug|Release] [mac|ipad|ipad-sim]   # default: Release mac → build/Atelier.app
Scripts/test.sh                                        # unit tests (Sources/AtelierTests), Mac only; needs no models
Scripts/clean-builds.sh [--all]                        # unregister stray builds from Launch Services; --all wipes build caches
swiftformat .                                          # format (config in .swiftformat)
Scripts/install-hooks.sh                               # once per clone: pre-commit hook formats staged Swift files
Scripts/ipad-layout-shots.sh [outdir]                  # screenshots every screen at many window sizes (needs Debug ipad-sim build)
Scripts/generate_project_format.sh                     # regenerate Sources/ProjectFormat from the pinned engine's .fbs schemas (needs bazelisk)
Scripts/build-tailscale.sh [--with-test-control]      # build TailscaleKit into build/Tailscale (needs Go); optional, see Compute below
Scripts/release.sh [version]                           # signed/notarized zip + Sparkle appcast.xml in build/release/
```

- The first build resolves Swift packages into `build/SourcePackages` (slow). The engine source is browsable at `build/SourcePackages/checkouts/draw-things-community`.
- Signing: `Config/Atelier.xcconfig` signs ad hoc by default; an untracked `Config/Local.xcconfig` may set `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY`. Don't put a team into the project file.
- A build phase copies `*_tae.zip` preview decoders from `/Applications/Draw Things.app` if present (release builds exclude them).
- Installing over an existing app breaks its signature: remove `/Applications/Atelier.app` first, then `ditto build/Atelier.app /Applications/Atelier.app`.

### Tests

`Scripts/test.sh` runs the Swift Testing unit tests in `Sources/AtelierTests`, for pure logic that needs no models. They run inside the app as a scripted run does, so the user's data is left alone; files go in a test-only folder. Everything else is verified by launching the built Mac app with scripted-run flags (`Sources/Atelier/Automation/`), which drive the real UI and engine and print progress / `PASS`/`FAIL` lines:

```bash
build/Atelier.app/Contents/MacOS/Atelier --generate --model <file.ckpt> --prompt "…" --width 1024 --height 1024 [--steps N] [--snapshot-dir DIR] --quit
build/Atelier.app/Contents/MacOS/Atelier --queue-check --project <scratch project> [--model M] [--steps N] --quit
```

Other checks: `--project-check`, `--edit-input-check`, `--refine-check`, `--agent-canvas-check`, `--automask-check`, `--inspector-check`, `--library-check`, `--ux-check`, `--timeline-check`, `--timeline-export-check`, `--upscale-check`, `--color-match-check`, `--flashvsr-check`, `--model-folders-check`, `--model-move-check`, `--styles-check`, `--cleanup-check`, `--engine-check`, `--playback-check`, `--canvas-clip-check`, `--remote-check`, `--remote-net-check`, `--remote-url-check`, `--remote-tailnet-check`, `--remote-shots`, `--reuse latest|STEP`, `--resize-bench`, `--show <section>`. Usage for each is in the doc comment at the top of its `Automation*.swift` file. Always pass `--project NAME` for checks that write, so the user's current project isn't touched; scripted runs also skip saving `SessionState`. These need real models in the user's models folder — never hardcode its path. Automation is Mac-only (`#if os(macOS)`).

## Architecture

Two targets: **Atelier** (the app, `Sources/Atelier`) and **ProjectFormat** (`Sources/ProjectFormat`, generated dflat/FlatBuffers Swift for Draw Things' project schemas — don't hand-edit; excluded from SwiftFormat). The Xcode project uses explicit file references, so new Swift files must be added to `Atelier.xcodeproj/project.pbxproj`.

Engine dependency: the app imports `_MediaGenerationKit` (MGK) from draw-things-community at a pinned revision, plus non-product modules built as its dependencies (`ModelZoo`, `ModelOp`, `Diffusion`, scripting types) for things MGK doesn't expose. When MGK lacks something, the pattern is to reach into the engine's own types following the engine's code, with comments naming the engine function being mirrored.

Core flow:

- **`CreateModel`** (`Create/`) — `@Observable` state behind the Create screen: model, inspector values, canvas/moodboard, and it owns the `GenerationEngine`, `JobQueue`, and `HistoryStore` reference. Generate snapshots everything into a `GenerationEngine.Request` and enqueues it with a `JobTarget`; it reaches whatever runs a job through `backend(for:)`, a `GenerationBackend`, not the engine directly. `models` is always this device's list; `availableModels` is what the pickers offer, which on a server is its catalog.
- **`JobQueue`** (`Queue/`) — ordered jobs (generations, image and clip upscales, and Match Colors to Original as `.generation` requests; upscaled timeline exports as `.export`), run by `CreateModel` one at a time on this device and one at a time per server, alongside each other (`running`, `runningRemote`); local ones persisted across quits (`SavedQueue`). The status bar and canvas follow one run, `foregroundJobID`.
- **`GenerationEngine`** (`Generation/`) — an actor that caches the pipeline for the current model and runs one generation. `PipelineConfiguration` (in `Inspector/SettingsRegistry.swift`) wraps MGK's `Configuration` plus engine-only settings MGK doesn't expose; `EngineConfiguration.swift` converts it to the engine's `GenerationConfiguration` for direct engine calls (video). `ModelDefaults` supplies app-side defaults for models missing from MGK's catalog.
- **Projects / History** — `Project` reads and writes Draw Things-format `.sqlite3` files (dflat tables + s4nnc tensor store) under `~/Pictures/Atelier/Projects/`, mirroring the engine's `ImageHistoryManager`. `ProjectMapping` converts between Atelier's settings dump and `TensorHistoryNode`. `HistoryStore` exposes the current project's branching steps. Step IDs (lineage, logicalTime) get renumbered by fork/delete, so items are keyed by **image tensor id** everywhere (history, session state, timelines).
- **Inspector** — `SettingsRegistry` defines every setting and which models use it (`ModelTraits`); layouts and presets are separate, exportable JSON.
- **Library** — `ModelLibrary`: download catalog, downloads, checkpoint/LoRA import (registered with the running engine via `ModelZoo`/`LoRAZoo`), MOSS 8-bit copies.
- **Timeline / Upscale** — the Video Editor composes clips (by first-frame tensor id) with AVFoundation; upscaling uses Apple Super Resolution or FlashVSR+ (`Upscale/FlashVSR`).
- **Agents** (Mac only) — `AgentServer` is an MCP server (Streamable HTTP, JSON-RPC over POST) on `127.0.0.1:7862` via `LoopbackHTTPServer`; `AgentTools` defines tools. Agent runs join the same `JobQueue` and can read/change the Create screen. User docs in `MCP.md`.
- **Compute** (`Remote/`) — any copy can serve jobs to paired devices (`RemoteServer`) and run jobs on a paired server (`RemoteBackend`, a `GenerationBackend`, reached through `CreateModel.backend(for:)`), over Network.framework with TLS-PSK and per-device keys in the Keychain. A device's job joins this machine's `JobQueue`; the client's project is the only copy of the work. A listener's keys are fixed when it starts, so it's replaced whenever they change (see `RemoteListener`). `RemoteModelTraits` answers for models a server has that this device's `ModelZoo` doesn't know: ask it rather than `ModelZoo` for anything a client may need about a model by file name. `RemoteTailnet` is Atelier's own tailnet node (TailscaleKit from libtailscale, pinned in `Scripts/build-tailscale.sh`). It's optional at compile time: `build/Tailscale/Tailscale.xcconfig`, written by that script, is what links it, so use `#if canImport(TailscaleKit)` around anything needing it. Its sockets are bridged into the same TLS-PSK path as everything else (`RemoteSocketBridge`, `RemoteListener`'s bridge). User docs in `docs/remote.md`.
- **App** — `AtelierApp` wires the stores; `AppSettings` holds paths (models dir defaults to `~/Documents/Models` or `DRAWTHINGS_MODELS_DIR`); `Updater` is Sparkle (Mac only).

## Conventions

- **Pure SwiftUI.** All AppKit use is confined to `App/MacPlatform.swift`; Mac-vs-iPad modifier shims live in `App/PlatformViews.swift` (iPad counterparts in `iPadPlatform.swift`). Don't add AppKit/UIKit elsewhere. Platform differences use `#if os(macOS)` / `#if os(iOS)`; changes must build for both `mac` and `ipad-sim`.
- The Mac target is macOS 26, so anything newer needs a fallback; the compiler reports it. `ARCHS` is arm64 for the Mac because below macOS 27 Xcode would also build Intel, which has no `Float16`.
- Formatting: 2-space indent, no line limit (see `.swiftformat`). `redundantSelf` and `preferForLoop` are disabled deliberately — enabling them broke the build.
- Doc comments explain *why* and name the engine code being followed; match that style.
- User-facing docs live in `docs/` and `MCP.md`; update them when behavior they describe changes.
- Releases: `release.sh` sets the build number to the commit count (Sparkle compares it); attach both the zip and `appcast.xml` to a `v<version>` GitHub release.
