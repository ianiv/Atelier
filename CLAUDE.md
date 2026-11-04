# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Atelier is a native SwiftUI app (macOS 27 + iPadOS 27, Apple silicon) that generates images and video with local models. It embeds the Draw Things engine ([draw-things-community](https://github.com/drawthingsai/draw-things-community)) in-process — no server — and reads/writes Draw Things' model folder and project file format. GPL-3.0.

## Commands

Build only through the script; outputs land in `build/` (gitignored), never Xcode's default DerivedData.

```bash
Scripts/build.sh [Debug|Release] [mac|ipad|ipad-sim]   # default: Release mac → build/Atelier.app
Scripts/clean-builds.sh [--all]                        # unregister stray builds from Launch Services; --all wipes build caches
swiftformat .                                          # format (config in .swiftformat)
Scripts/install-hooks.sh                               # once per clone: pre-commit hook formats staged Swift files
Scripts/ipad-layout-shots.sh [outdir]                  # screenshots every screen at many window sizes (needs Debug ipad-sim build)
Scripts/generate_project_format.sh                     # regenerate Sources/ProjectFormat from the pinned engine's .fbs schemas (needs bazelisk)
Scripts/release.sh [version]                           # signed/notarized zip + Sparkle appcast.xml in build/release/
```

- The first build resolves Swift packages into `build/SourcePackages` (slow). The engine source is browsable at `build/SourcePackages/checkouts/draw-things-community`.
- Signing: `Config/Atelier.xcconfig` signs ad hoc by default; an untracked `Config/Local.xcconfig` may set `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY`. Don't put a team into the project file.
- A build phase copies `*_tae.zip` preview decoders from `/Applications/Draw Things.app` if present (release builds exclude them).
- Installing over an existing app breaks its signature: remove `/Applications/Atelier.app` first, then `ditto build/Atelier.app /Applications/Atelier.app`.

### Tests

There is no XCTest target. Verification is done by launching the built Mac app with scripted-run flags (`Sources/Atelier/Automation/`), which drive the real UI and engine and print progress / `PASS`/`FAIL` lines:

```bash
build/Atelier.app/Contents/MacOS/Atelier --generate --model <file.ckpt> --prompt "…" --width 1024 --height 1024 [--steps N] [--snapshot-dir DIR] --quit
build/Atelier.app/Contents/MacOS/Atelier --queue-check --project <scratch project> [--model M] [--steps N] --quit
```

Other checks: `--project-check`, `--edit-input-check`, `--inspector-check`, `--library-check`, `--ux-check`, `--timeline-check`, `--timeline-export-check`, `--upscale-check`, `--flashvsr-check`, `--model-folders-check`, `--styles-check`, `--cleanup-check`, `--engine-check`, `--reuse latest|STEP`, `--resize-bench`, `--show <section>`. Usage for each is in the doc comment at the top of its `Automation*.swift` file. Always pass `--project NAME` for checks that write, so the user's current project isn't touched; scripted runs also skip saving `SessionState`. These need real models in the user's models folder — never hardcode its path. Automation is Mac-only (`#if os(macOS)`).

## Architecture

Two targets: **Atelier** (the app, `Sources/Atelier`) and **ProjectFormat** (`Sources/ProjectFormat`, generated dflat/FlatBuffers Swift for Draw Things' project schemas — don't hand-edit; excluded from SwiftFormat). The Xcode project uses explicit file references, so new Swift files must be added to `Atelier.xcodeproj/project.pbxproj`.

Engine dependency: the app imports `_MediaGenerationKit` (MGK) from draw-things-community at a pinned revision, plus non-product modules built as its dependencies (`ModelZoo`, `ModelOp`, `Diffusion`, scripting types) for things MGK doesn't expose. When MGK lacks something, the pattern is to reach into the engine's own types following the engine's code, with comments naming the engine function being mirrored.

Core flow:

- **`CreateModel`** (`Create/`) — `@Observable` state behind the Create screen: model, inspector values, canvas/moodboard, and it owns the `GenerationEngine`, `JobQueue`, and `HistoryStore` reference. Generate snapshots everything into a `GenerationEngine.Request` and enqueues it.
- **`JobQueue`** (`Queue/`) — ordered jobs (generations and upscaled timeline exports), run one at a time by `CreateModel`; persisted across quits (`SavedQueue`).
- **`GenerationEngine`** (`Generation/`) — an actor that caches the pipeline for the current model and runs one generation. `PipelineConfiguration` (in `Inspector/SettingsRegistry.swift`) wraps MGK's `Configuration` plus engine-only settings MGK doesn't expose; `EngineConfiguration.swift` converts it to the engine's `GenerationConfiguration` for direct engine calls (video). `ModelDefaults` supplies app-side defaults for models missing from MGK's catalog.
- **Projects / History** — `Project` reads and writes Draw Things-format `.sqlite3` files (dflat tables + s4nnc tensor store) under `~/Pictures/Atelier/Projects/`, mirroring the engine's `ImageHistoryManager`. `ProjectMapping` converts between Atelier's settings dump and `TensorHistoryNode`. `HistoryStore` exposes the current project's branching steps. Step IDs (lineage, logicalTime) get renumbered by fork/delete, so items are keyed by **image tensor id** everywhere (history, session state, timelines).
- **Inspector** — `SettingsRegistry` defines every setting and which models use it (`ModelTraits`); layouts and presets are separate, exportable JSON.
- **Library** — `ModelLibrary`: download catalog, downloads, checkpoint/LoRA import (registered with the running engine via `ModelZoo`/`LoRAZoo`), MOSS 8-bit copies.
- **Timeline / Upscale** — the Video Editor composes clips (by first-frame tensor id) with AVFoundation; upscaling uses Apple Super Resolution or FlashVSR+ (`Upscale/FlashVSR`).
- **Agents** (Mac only) — `AgentServer` is an MCP server (Streamable HTTP, JSON-RPC over POST) on `127.0.0.1:7862` via `LoopbackHTTPServer`; `AgentTools` defines tools. Agent runs join the same `JobQueue` and can read/change the Create screen. User docs in `MCP.md`.
- **App** — `AtelierApp` wires the stores; `AppSettings` holds paths (models dir defaults to `~/Documents/Models` or `DRAWTHINGS_MODELS_DIR`); `Updater` is Sparkle (Mac only).

## Conventions

- **Pure SwiftUI.** All AppKit use is confined to `App/MacPlatform.swift`; Mac-vs-iPad modifier shims live in `App/PlatformViews.swift` (iPad counterparts in `iPadPlatform.swift`). Don't add AppKit/UIKit elsewhere. Platform differences use `#if os(macOS)` / `#if os(iOS)`; changes must build for both `mac` and `ipad-sim`.
- Formatting: 2-space indent, no line limit (see `.swiftformat`). `redundantSelf` and `preferForLoop` are disabled deliberately — enabling them broke the build.
- Doc comments explain *why* and name the engine code being followed; match that style.
- User-facing docs live in `docs/` and `MCP.md`; update them when behavior they describe changes.
- Releases: `release.sh` sets the build number to the commit count (Sparkle compares it); attach both the zip and `appcast.xml` to a `v<version>` GitHub release.
