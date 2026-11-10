#if os(macOS)
@preconcurrency import _MediaGenerationKit
import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ModelZoo
import Observation
import SwiftUI

/// The tools Atelier offers agents over MCP. Generation runs through Create like a press of
/// Generate (progress and previews on the canvas, saved to the current project, one run at a
/// time) and leaves the Create screen's prompt, inspector and moodboard alone;
/// `get_create_screen` and `set_create_screen` read and change them, so an agent and the user
/// can work on the same screen.
@MainActor
@Observable
final class AgentTools {
  nonisolated struct Progress {
    var step: Int
    var total: Int?
    var message: String
    /// Queued behind other runs, not started yet.
    var isQueued = false
  }

  /// One `generate` run. A run outlives the call that started it: `background` returns its id
  /// at once, and a waiting call whose client hangs up leaves it running for `get_job`.
  @MainActor
  @Observable
  final class Job {
    let id: String
    let prompt: String
    let startedAt = Date()
    var progress = Progress(step: 0, total: nil, message: "Starting", isQueued: true)
    /// Checked its arguments and joined the queue (or failed doing so).
    var accepted = false
    var result: [String: Any]?
    var error: String?
    var wasCancelled = false
    var finishedAt: Date?
    @ObservationIgnored var task: Task<Void, Never>?
    /// The waiting call's progress stream, while there is one.
    @ObservationIgnored var onProgress: ((Progress) -> Void)?

    init(id: String, prompt: String) {
      self.id = id
      self.prompt = prompt
    }

    var status: String {
      if result != nil { return "done" }
      if wasCancelled { return "cancelled" }
      if error != nil { return "failed" }
      return progress.isQueued ? "waiting" : "running"
    }
  }

  /// Wakes a wait for a job when its time is up.
  @MainActor
  @Observable
  final class Deadline {
    var hasPassed = false
  }

  nonisolated struct ToolError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  let create: CreateModel
  let presets: PresetStore
  /// What an agent's run is doing, for the Agents settings tab.
  private(set) var activity: String?
  private(set) var lastResult: String?
  /// Jobs by id; finished ones are kept for an hour (the newest 20).
  @ObservationIgnored private var jobs: [String: Job] = [:]
  @ObservationIgnored private var jobCount = 0

  init(create: CreateModel, presets: PresetStore) {
    self.create = create
    self.presets = presets
  }

  // MARK: - Definitions

  static let definitions: [[String: Any]] = [
    [
      "name": "list_models",
      "title": "List models",
      "description":
        "Lists the models downloaded in Atelier (file, name, family), which one is selected in the app, and whether each takes reference images (edit models, FLUX.2, Qwen Image 2.1). Video models say so, with their frame rate, the inputs they take (first_frame: input_image; last_frame: the first reference image; references; audio) and whether they make sound.",
      "inputSchema": ["type": "object", "properties": [String: Any]()],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "list_presets",
      "title": "List presets",
      "description":
        "Lists Atelier's saved presets: name, the model it belongs to (null means any model), whether it's that model's default, and the settings it sets.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "model": ["type": "string", "description": "Only presets usable with this model file."]
        ],
      ],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "get_settings",
      "title": "Get settings",
      "description":
        "Returns the full settings `generate` would use for a model (its recommended settings plus its default preset, then `preset` if given), as Draw Things configuration JSON. Use it to see which keys `generate`'s `settings` accepts.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "model": ["type": "string", "description": "Model file or name. Defaults to the model selected in the app."],
          "preset": ["type": "string", "description": "A preset name to apply on top."],
        ],
      ],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "get_create_screen",
      "title": "Get Create screen",
      "description":
        "Returns what's on Atelier's Create screen right now: the selected model, prompt, negative prompt, the selected style (Generate writes the prompt into its template; styled_prompt is the result), seed and whether it's random, the image count, every inspector setting as Draw Things configuration JSON, the settings that differ from the model's defaults, how many reference images there are, and `canvas`: the canvas image (its history step and size), the frame (output size), the region of the image it shows (source pixels, from the top left), its zoom and offset, the canvas mode, the mask summary and Merge into Image. The user may have changed any of it since your last call.",
      "inputSchema": ["type": "object", "properties": [String: Any]()],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "set_create_screen",
      "title": "Change Create screen",
      "description": """
        Changes Atelier's Create screen live, as if the user had edited it: the model, prompt, \
        negative prompt, seed and inspector settings. Only what you pass changes. Applied in \
        order: `model` (keeps the current settings, like picking it in the app), `preset` and \
        `reset_settings` (both start from the model's defaults), then `settings`, then the \
        explicit fields. The user can undo setting changes with ⌘Z. Returns the screen as \
        get_create_screen does. To generate what's on the screen, call generate with \
        use_app_settings true and no prompt.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "model": ["type": "string", "description": "Model file or name to select (see list_models)."],
          "prompt": ["type": "string"],
          "negative_prompt": ["type": "string"],
          "preset": ["type": "string", "description": "A preset to apply, as the inspector's Presets menu does (see list_presets). A preset for another model selects that model."],
          "reset_settings": ["type": "boolean", "description": "Put every setting back to the model's defaults (with its default preset) first."],
          "settings": ["type": "object", "description": "Settings to change, as Draw Things configuration JSON keys (see get_create_screen), e.g. {\"sampler\": 1, \"shift\": 3}. Keys you leave out keep their current values."],
          "width": ["type": "integer", "description": "Pixels, rounded to a multiple of 64."],
          "height": ["type": "integer", "description": "Pixels, rounded to a multiple of 64."],
          "steps": ["type": "integer"],
          "guidance_scale": ["type": "number"],
          "strength": ["type": "number", "description": "0–1."],
          "num_frames": ["type": "integer", "description": "Video models: how many frames, snapped to the counts the model takes."],
          "seconds": ["type": "number", "description": "Video models: how long, instead of num_frames."],
          "seed": ["type": "integer", "minimum": 0, "maximum": 4_294_967_295, "description": "Sets the seed and turns off Random, so every Generate uses it."],
          "random_seed": ["type": "boolean", "description": "true: a new seed for every Generate (the Random checkbox). false: keep the current seed."],
          "count": ["type": "integer", "description": "How many images each press of Generate makes: 1, 2, 3, 4, 6, 8, 12 or 16."],
          "layout_editor": ["type": "boolean", "description": "Open (true) or close (false) the Layout editor, which draws a layout prompt's boxes on the canvas. Only for models that take layout prompts (FLUX.3, Ideogram 4, MOSS Image). While it's open, a new layout prompt moves the boxes on screen."],
          "canvas_mode": ["type": "string", "enum": ["generate", "edit"], "description": "The canvas's Generate / Edit switch: Edit sends the canvas (and its mask) to the model. set_canvas_image switches to Edit."],
          "merge_into_image": ["type": "boolean", "description": "Merge into Image: an Edit run on part of the image, past its edges or with a mask puts its result back into the whole image (true, the default) instead of saving just the frame."],
        ],
      ],
    ],
    [
      "name": "set_canvas_image",
      "title": "Put an image on the canvas",
      "description": """
        Puts an image on the Create screen's canvas, as clicking it in History or dropping it \
        there does: fitted to the frame, in Edit mode, with no mask. Give a History step (see \
        list_history), which the next run then follows, or an image file or data: URL. Returns \
        the canvas as get_create_screen's `canvas` describes it. Then paint a mask \
        (set_canvas_mask), pick a region (set_canvas_region), or generate with use_canvas.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "history_step": ["type": "integer", "description": "A history step from list_history or generate (images only; not a video)."],
          "image": ["type": "string", "description": "Instead: path to an image, or a data: URL."],
        ],
      ],
    ],
    [
      "name": "set_canvas_mask",
      "title": "Paint the canvas mask",
      "description": """
        Paints the mask on the canvas image: the area an Edit run regenerates. Coordinates are \
        the canvas image's pixels from its top left (see get_create_screen's canvas.source_size). \
        Applied in order: `clear`, then `image` and `shapes` (by `mode`: replace the mask, the \
        default, add to it or subtract from it), then `invert`. The whole call is one ⌘Z step, \
        “Agent Mask”, and shows on the canvas as it happens. Returns the mask summary \
        (get_canvas_mask's). Needs an image on the canvas (set_canvas_image) in Edit mode.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "image": ["type": "string", "description": "A mask image the size of the canvas image (path or data: URL): white (opaque, light) regenerates; transparent or black keeps."],
          "shapes": [
            "type": "array",
            "description": "Shapes to paint: {\"shape\": \"rect\" or \"ellipse\", \"x\", \"y\", \"width\", \"height\"} or {\"shape\": \"polygon\", \"points\": [[x, y], …]} (3 points or more).",
            "items": [
              "type": "object", "required": ["shape"],
              "properties": [
                "shape": ["type": "string", "enum": ["rect", "ellipse", "polygon"]],
                "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
                "points": ["type": "array", "items": ["type": "array", "items": ["type": "number"]]],
              ],
            ],
          ],
          "mode": ["type": "string", "enum": ["replace", "add", "subtract"], "description": "What `image` and `shapes` do to the mask there is. Default replace."],
          "invert": ["type": "boolean", "description": "Flip the mask over the whole image, last."],
          "clear": ["type": "boolean", "description": "Clear the mask, first. Alone, it just clears it."],
        ],
      ],
    ],
    [
      "name": "get_canvas_mask",
      "title": "Get canvas mask",
      "description": """
        Shows the canvas mask: `overlay` (the default) is the canvas image with the mask tinted \
        red, the frame (what a run sees) outlined in yellow and anything outside the image \
        hatched; `mask` is the mask itself, white on black at the canvas image's size, as \
        set_canvas_mask takes it; `both` returns both. Comes with a summary: has_mask, the \
        image size, coverage (share of the image painted), the painted bounds, \
        coverage_in_region (share of what the frame shows) and whether the next run sends it.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "view": ["type": "string", "enum": ["overlay", "mask", "both"]],
          "max_size": ["type": "integer", "description": "Long side of the returned images in pixels, 256–2048. Default 1024."],
          "save_to": ["type": "string", "description": "Also write the full-size PNGs to this file or folder."],
        ],
      ],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "auto_mask",
      "title": "Select what to mask",
      "description": """
        Selects part of the canvas image and puts it into the mask, as the Select tool does: \
        `subject: true` picks the image's subject with Apple's Vision (with one point, the \
        subject under it), needing no download; otherwise SAM 2.1 selects what `points` (each \
        including, or with positive false excluding, what's under it) and a `box` outline. \
        Coordinates are the canvas image's pixels from its top left. `mode` is replace (the \
        default), add or subtract, as for set_canvas_mask. One ⌘Z step, “Agent Mask”. Returns \
        get_canvas_mask's overlay and summary, plus selected_pixels, SAM's score and the time \
        taken. There's no text prompt: to select by a description, look at the image \
        (get_image) and pass a point on what you mean.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "points": [
            "type": "array",
            "items": [
              "type": "object", "required": ["x", "y"],
              "properties": ["x": ["type": "number"], "y": ["type": "number"], "positive": ["type": "boolean", "description": "false excludes what's under it. Default true."]],
            ],
          ],
          "box": [
            "type": "object", "required": ["x", "y", "width", "height"],
            "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
          ],
          "subject": ["type": "boolean", "description": "Select the subject with Vision instead of SAM: all subjects, or with one point the one under it. Takes no box."],
          "mode": ["type": "string", "enum": ["replace", "add", "subtract"], "description": "Default replace."],
          "size": ["type": "string", "enum": ["tiny", "small", "large"], "description": "Which SAM 2.1 to use. Default: the one picked in the Select tool (Small unless changed)."],
        ],
      ],
    ],
    [
      "name": "set_canvas_region",
      "title": "Choose the canvas region",
      "description": """
        Zooms and moves the canvas so the frame shows part of the image, as zooming and dragging \
        it does: an Edit run then regenerates just that region, at the frame's full resolution, \
        and with Merge into Image puts it back into the whole image. Pass one of: `region` \
        (source pixels from the top left; grown about its center to the frame's shape, never \
        cropped), `fit`, `actual_size` (1 image pixel per frame pixel, keeping the center), or \
        `scale` (frame pixels per image pixel) with an optional `center`. The frame size stays \
        unless `size_to_region` is true. Returns the canvas, with the region the frame actually \
        shows: larger or smaller than asked when the zoom needed is outside 0.05×–32×.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "region": [
            "type": "object", "required": ["x", "y", "width", "height"],
            "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
          ],
          "fit": ["type": "boolean", "description": "Fit the whole image in the frame."],
          "actual_size": ["type": "boolean", "description": "Actual size, keeping what's in the middle."],
          "scale": ["type": "number", "description": "Frame pixels per image pixel, 0.05–32."],
          "center": ["type": "array", "items": ["type": "number"], "description": "With scale: the image point [x, y] to put in the middle of the frame. Default: what's there now."],
          "size_to_region": ["type": "boolean", "description": "With region or fit: first set the output size to the region's shape at about the current pixel count (multiples of 64). A setting change, undoable with ⌘Z."],
        ],
      ],
    ],
    [
      "name": "list_history",
      "title": "List history",
      "description":
        "Lists the newest images and videos in the current Atelier project, newest first: history step, prompt (shortened), model, seed, size, star rating, and whether it's a video. Includes what the user generated themselves. Use get_image to look at one.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "limit": ["type": "integer", "description": "How many to list. Default 20."]
        ],
      ],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "get_image",
      "title": "Get image",
      "description":
        "Returns an image so you can see it: what's on the Create screen's canvas (the default), the project's newest image, or a History image by step (see list_history). For a video, its first frame. Comes with its prompt and settings when it's a saved image.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "history_step": ["type": "integer", "description": "A history step from list_history or generate. Omit for the canvas."],
          "latest": ["type": "boolean", "description": "The project's newest image instead of the canvas."],
          "max_size": ["type": "integer", "description": "Long side of the returned image in pixels, 256–2048. Default 1024."],
          "save_to": ["type": "string", "description": "Also write the full-size PNG (settings embedded) to this file or folder."],
        ],
      ],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "generate",
      "title": "Generate image or video",
      "description": """
        Generates one image, or with a video model one video, with Atelier's local engine and \
        saves it to the current Atelier project (it shows in the app's History). Returns the image \
        (a video's first frame), and writes a PNG, or an MP4 with its sound, with its settings \
        embedded. Runs wait for any generation already running in the app; videos take minutes. \
        Settings start from the model's recommended settings and default preset, then `preset`, \
        then `settings`, then the explicit fields. With `input_image` the run edits that image \
        (image to image), or for video models starts from it as the first frame; \
        `reference_images` go to models that take references (see list_models). With \
        use_app_settings and no prompt, it generates what's on the Create screen: its model, \
        prompt, negative prompt, settings and (unless Random is on) seed. With use_canvas too, \
        it runs exactly what the Generate button would, canvas included: the region the frame \
        shows, the mask, and Merge into Image.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "prompt": ["type": "string", "description": "Required, unless use_app_settings is true: then it defaults to the Create screen's prompt. Can be empty."],
          "negative_prompt": ["type": "string"],
          "model": ["type": "string", "description": "Model file or name (see list_models). Defaults to the model selected in the app."],
          "preset": ["type": "string", "description": "Name of a saved preset to apply (see list_presets)."],
          "use_app_settings": ["type": "boolean", "description": "Start from the settings currently in Atelier's inspector instead of the model's defaults. Only when `model` is the app's selected model. Without `prompt`, also takes the Create screen's prompt, negative prompt and seed."],
          "settings": ["type": "object", "description": "Any other settings as Draw Things configuration JSON keys, e.g. {\"sampler\": 1, \"shift\": 3, \"loras\": [{\"file\": \"x_lora_f16.ckpt\", \"weight\": 0.8}]}. See get_settings."],
          "width": ["type": "integer", "description": "Pixels, rounded to a multiple of 64."],
          "height": ["type": "integer", "description": "Pixels, rounded to a multiple of 64."],
          "steps": ["type": "integer"],
          "guidance_scale": ["type": "number"],
          "seed": ["type": "integer", "minimum": 0, "maximum": 4_294_967_295, "description": "Random when omitted."],
          "input_image": ["type": "string", "description": "Path to an image to edit, or a data: URL. Without width/height the output takes its aspect ratio at the model's usual pixel count."],
          "strength": ["type": "number", "description": "How much of input_image to change, 0–1, for models that don't take references. 1 ignores the image."],
          "reference_images": [
            "type": "array",
            "description": "Reference (moodboard) images: paths or data: URLs, or {\"image\": …, \"weight\": 0–1}.",
            "items": [
              "anyOf": [
                ["type": "string"],
                [
                  "type": "object", "required": ["image"],
                  "properties": ["image": ["type": "string"], "weight": ["type": "number"]],
                ],
              ]
            ],
          ],
          "num_frames": ["type": "integer", "description": "Video models: how many frames, snapped to the counts the model takes."],
          "seconds": ["type": "number", "description": "Video models: how long, instead of num_frames."],
          "audio": ["type": "string", "description": "Video models that take audio (see list_models): path to an audio file."],
          "save_to": ["type": "string", "description": "Where to write the PNG or MP4: a file path, or a folder. Defaults to a temporary folder."],
          "include_image": ["type": "boolean", "description": "Return the image inline (scaled to 1024 px on the long side). Default true."],
          "use_canvas": ["type": "boolean", "description": "With use_app_settings: run exactly what the Generate button would, taking the canvas image, the region the frame shows (set_canvas_region), its mask (set_canvas_mask), the moodboard and Merge into Image. Takes no prompt, settings or input_image: change those with set_create_screen and set_canvas_image first. Returns the result (the merged whole image when it merges) and the step it followed."],
          "background": ["type": "boolean", "description": "Return a job_id right away instead of waiting for the result, then check on it with get_job. Use it for videos and anything that may take more than a couple of minutes, since some clients give up on long calls. Either way the run keeps going if the call is cancelled or dropped; only cancel_job stops it."],
        ],
      ],
    ],
    [
      "name": "get_job",
      "title": "Get job",
      "description": """
        Checks on a generate job: waiting (queued behind other runs), running (with step and \
        total), done (with everything generate returns: text, image and structured result), \
        failed or cancelled. Waits up to wait_seconds for it to finish first, so calling it in a \
        loop checks in periodically without busy polling.
        """,
      "inputSchema": [
        "type": "object",
        "required": ["job_id"],
        "properties": [
          "job_id": ["type": "string", "description": "From generate with background, or list_jobs."],
          "wait_seconds": ["type": "integer", "description": "How long to wait for the job to finish before returning its progress, 0–60. Default 30."],
        ],
      ],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "list_jobs",
      "title": "List jobs",
      "description": "Lists generate jobs from the last hour, newest first: job_id, status, progress, elapsed time and prompt. A generate call that timed out, was cancelled or lost its connection keeps running and shows here.",
      "inputSchema": ["type": "object", "properties": [String: Any]()],
      "annotations": ["readOnlyHint": true],
    ],
    [
      "name": "cancel_job",
      "title": "Cancel job",
      "description": "Stops a generate job, like Cancel in Atelier's Queue: a waiting job leaves the queue and a running one stops.",
      "inputSchema": [
        "type": "object",
        "required": ["job_id"],
        "properties": ["job_id": ["type": "string"]],
      ],
    ],
  ]

  // MARK: - Calls

  func call(
    _ name: String, arguments: [String: Any], progress: @escaping (Progress) -> Void
  ) async throws -> [String: Any] {
    switch name {
    case "list_models": return try Self.textResult(json: await listModels())
    case "list_presets": return try Self.textResult(json: listPresets(arguments))
    case "get_settings": return try await getSettings(arguments)
    case "get_create_screen": return try Self.textResult(json: createScreen())
    case "set_create_screen": return try await setCreateScreen(arguments)
    case "set_canvas_image": return try await setCanvasImage(arguments)
    case "set_canvas_mask": return try await setCanvasMask(arguments)
    case "get_canvas_mask": return try getCanvasMask(arguments)
    case "set_canvas_region": return try await setCanvasRegion(arguments)
    case "auto_mask": return try await autoMask(arguments)
    case "list_history": return try Self.textResult(json: listHistory(arguments))
    case "get_image": return try await getImage(arguments)
    case "generate": return try await startGenerate(arguments, progress: progress)
    case "get_job": return try await getJob(arguments, progress: progress)
    case "list_jobs": return try Self.textResult(json: jobs.values.sorted { $0.startedAt > $1.startedAt }.map(Self.summary))
    case "cancel_job": return try cancelJob(arguments)
    default: throw ToolError("Unknown tool \(name).")
    }
  }

  private func listModels() async -> [[String: Any]] {
    if create.models.isEmpty { await create.refreshModelList() }
    return create.models.map { model in
      var entry: [String: Any] = [
        "file": model.file, "name": model.name, "version": model.version ?? NSNull(),
        "selected_in_app": model.file == create.selectedModel,
        "takes_reference_images": takesReferences(model: model.file, loras: []),
        "video": ModelTraits(model).isVideo,
      ]
      if let video = VideoModel(model: model.file) {
        entry["frames_per_second"] = video.framesPerSecond
        entry["makes_audio"] = video.makesAudio
        entry["video_inputs"] =
          (video.takesLastFrame ? ["first_frame", "last_frame"] : ["first_frame"])
          + (video.takesReferences ? ["references"] : []) + (video.takesAudio ? ["audio"] : [])
      }
      return entry
    }
  }

  private func listPresets(_ arguments: [String: Any]) throws -> [[String: Any]] {
    let model = try (arguments["model"] as? String).map(resolveModel)
    let list = model.map { presets.presets(for: $0).own + presets.presets(for: $0).shared } ?? presets.presets
    return list.map { preset in
      [
        "name": preset.name, "model": preset.model ?? NSNull(),
        "default_for": presets.defaults.filter { $0.value == preset.name }.keys.sorted(),
        "settings": Self.jsonObject(DrawThingsJSON.encode(preset.values, model: nil, seed: nil)),
      ]
    }
  }

  private func getSettings(_ arguments: [String: Any]) async throws -> [String: Any] {
    let model = try resolveModel(arguments["model"] as? String)
    var configuration = try await defaults(for: model)
    if let name = arguments["preset"] as? String { try apply(presetNamed: name, model: model, to: &configuration) }
    let values = Dictionary(uniqueKeysWithValues: SettingsRegistry.all.map { ($0.id, $0.get(configuration)) })
    return try Self.textResult(json: Self.jsonObject(DrawThingsJSON.encode(values, model: model, seed: nil)))
  }

  private func generate(
    _ arguments: [String: Any], progress: @escaping (Progress) -> Void
  ) async throws -> [String: Any] {
    if arguments["use_canvas"] as? Bool == true { return try await generateFromCanvas(arguments, progress: progress) }
    // Without a prompt, use_app_settings generates the Create screen as it is.
    let fromScreen = arguments["use_app_settings"] as? Bool == true && arguments["prompt"] == nil
    // The screen's prompt as Generate sends it: written into the selected style.
    let prompt = fromScreen ? create.styledPrompts.prompt : arguments["prompt"] as? String ?? ""
    // An empty prompt is fine, as it is for Generate, but one left out is more likely a mistake.
    guard fromScreen || arguments["prompt"] is String else {
      throw ToolError("`prompt` is required (it can be empty).")
    }
    if create.models.isEmpty { await create.refreshModelList() }
    let model = try resolveModel(arguments["model"] as? String)
    var notes: [String] = []

    var configuration: PipelineConfiguration
    if arguments["use_app_settings"] as? Bool == true {
      guard model == create.selectedModel, let settings = create.settings else {
        throw ToolError("use_app_settings needs `model` to be the app's selected model (\(create.selectedModel ?? "none")).")
      }
      configuration = settings
    } else {
      configuration = try await defaults(for: model)
    }
    if let name = arguments["preset"] as? String {
      try apply(presetNamed: name, model: model, to: &configuration)
    }
    var sizeGiven = false
    if let settings = arguments["settings"] as? [String: Any], !settings.isEmpty {
      let data = try JSONSerialization.data(withJSONObject: settings)
      guard let pasted = DrawThingsJSON.decode(data) else {
        throw ToolError("None of the keys in `settings` are settings Atelier knows. See get_settings.")
      }
      SettingsRegistry.apply(dump: pasted.dump, to: &configuration)
      sizeGiven = pasted.dump["width"] != nil || pasted.dump["height"] != nil
      let ignored = settings.keys.filter {
        pasted.dump[$0] == nil && $0 != "model" && $0 != "seed"
      }
      if !ignored.isEmpty { notes.append("Ignored unknown settings: \(ignored.sorted().joined(separator: ", ")).") }
    }
    let width = Self.int(arguments["width"])
    let height = Self.int(arguments["height"])
    if width != nil || height != nil {
      configuration.width = Self.roundTo64(width ?? configuration.width)
      configuration.height = Self.roundTo64(height ?? configuration.height)
      sizeGiven = true
    }
    if let steps = Self.int(arguments["steps"]) { configuration.steps = max(steps, 1) }
    if let guidance = Self.double(arguments["guidance_scale"]) { configuration.guidanceScale = Float(guidance) }
    if let strength = Self.double(arguments["strength"]) { configuration.strength = Float(min(max(strength, 0), 1)) }
    let video = VideoModel(model: model, loras: configuration.loras.compactMap(\.file))
    if let video {
      if let frames = Self.int(arguments["num_frames"]) {
        configuration.numFrames = video.snapped(frames)
      } else if let seconds = Self.double(arguments["seconds"]) {
        configuration.numFrames = video.snapped(Int((seconds * video.framesPerSecond).rounded()) + 1)
      } else {
        configuration.numFrames = video.snapped(configuration.numFrames)
      }
    }

    let seed: UInt32
    if let value = Self.int(arguments["seed"]) {
      guard value >= 0, value <= Int(UInt32.max) else { throw ToolError("`seed` must be 0–4294967295.") }
      seed = UInt32(value)
    } else if fromScreen, create.seedLocked {
      seed = create.seed
    } else {
      seed = UInt32.random(in: 0...UInt32.max)
    }

    let negativePrompt = arguments["negative_prompt"] as? String ?? (fromScreen ? create.styledPrompts.negativePrompt : "")
    var request = GenerationEngine.Request(
      model: model, prompt: prompt, negativePrompt: negativePrompt,
      seed: seed, configuration: configuration)
    if let source = arguments["input_image"] as? String {
      let image = try Self.loadImage(source)
      if !sizeGiven {
        // The input's aspect ratio at about the model's usual pixel count.
        let area = Double(configuration.width * configuration.height)
        let aspect = Double(image.width) / Double(image.height)
        configuration.width = Self.roundTo64(Int((area * aspect).squareRoot()))
        configuration.height = Self.roundTo64(Int((area / aspect).squareRoot()))
        request.configuration = configuration
      }
      // Filled, not fitted: rounding the size to 64 shifts the aspect ratio a little, and a fitted
      // image would leave transparent slivers for the model to inpaint.
      let size = CGSize(width: configuration.width, height: configuration.height)
      let placement = CanvasState()
      placement.scale = max(size.width / Double(image.width), size.height / Double(image.height))
      request.canvas = placement.render(image, size: size)
      request.canvasIsImported = true
    }
    let takesReferences = self.takesReferences(
      model: model, loras: configuration.loras.compactMap(\.file))
    if request.canvas != nil, !takesReferences, configuration.strength >= 1 {
      notes.append("Strength is 1, so this model ignored input_image. Pass a lower `strength` to keep some of it.")
    }
    for entry in arguments["reference_images"] as? [Any] ?? [] {
      let object = entry as? [String: Any]
      guard let source = (entry as? String) ?? (object?["image"] as? String) else {
        throw ToolError("Each reference image is a path, a data: URL or {\"image\": …, \"weight\": …}.")
      }
      let weight = Float(Self.double(object?["weight"]) ?? 1)
      guard weight > 0 else { continue }
      let image = ImageLoader.fitted(try Self.loadImage(source), maxSide: Moodboard.maxSide)
      request.moodboard.append(.init(image: image, weight: min(weight, 1)))
    }
    if !request.moodboard.isEmpty, !takesReferences {
      notes.append("\(model) doesn't take reference images; they were sent anyway and likely ignored.")
    }
    if let path = arguments["audio"] as? String {
      guard let video, video.takesAudio else {
        throw ToolError("\(model) doesn't take an audio file. See list_models.")
      }
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw ToolError("No audio file at \(url.path).")
      }
      request.audio = url
    }

    let summary = String(prompt.prefix(60))
    activity = "Waiting: “\(summary)”"
    progress(Progress(step: 0, total: nil, message: "Waiting for the current run to finish", isQueued: true))
    defer { activity = nil }
    let item = try await create.generate(forAgent: request) { [weak self] update in
      guard case .state(let state) = update else { return }
      let message = Self.describe(state)
      var step = 0
      var total: Int?
      if case .generating(let current, let all) = state {
        step = current
        total = all
      }
      self?.activity = "\(message): “\(summary)”"
      progress(Progress(step: step, total: total, message: message))
    }
    return try await result(
      of: item, model: model, configuration: configuration, seed: seed, summary: summary, notes: notes,
      arguments: arguments)
  }

  /// What a finished run answers with: the file written, the image inline and the structured
  /// result (plus `extra`).
  private func result(
    of item: HistoryItem, model: String, configuration: PipelineConfiguration, seed: UInt32, summary: String,
    notes: [String], arguments: [String: Any], extra: [String: Any] = [:]
  ) async throws -> [String: Any] {
    let png = try await create.history.pngData(item)
    let url = try Self.outputURL(
      arguments["save_to"] as? String, name: create.history.fileName(for: item),
      extension: item.isVideo ? "mp4" : "png")
    if item.isVideo {
      try await create.history.exportVideo(item, to: url)
    } else {
      try png.write(to: url)
    }

    let project = create.history.project.name
    let seconds = item.sidecar.durationSeconds
    lastResult = "“\(summary)” saved to \(project) in \(GenerationTime.text(seconds))"
    var text =
      "Saved to Atelier project “\(project)” (step \(item.id.logicalTime)) and \(url.path).\n"
      + "Model \(model), \(configuration.width)×\(configuration.height), \(configuration.steps) steps, "
      + "guidance \(configuration.guidanceScale), seed \(seed), \(GenerationTime.text(seconds))."
    if let clip = item.clip {
      text += "\nVideo: " + ClipBadge.length(clip) + ". The image below is its first frame."
    }
    if let timings = item.sidecar.timings { text += "\nTimings: " + timings.lines.joined(separator: "; ") + "." }
    if !notes.isEmpty { text += "\n" + notes.joined(separator: "\n") }
    var content: [[String: Any]] = [["type": "text", "text": text]]
    if arguments["include_image"] as? Bool != false, let image = ImageLoader.image(from: png, maxSide: 1024),
      let preview = Self.jpeg(image)
    {
      content.append(["type": "image", "data": preview.base64EncodedString(), "mimeType": "image/jpeg"])
    }
    var structured: [String: Any] = [
      "path": url.path, "project": project, "history_step": item.id.logicalTime, "model": model,
      "seed": Int(seed), "width": configuration.width, "height": configuration.height,
      "steps": configuration.steps, "duration_seconds": seconds,
    ]
    if let timings = item.sidecar.timings { structured["timings"] = timings.json }
    if let clip = item.clip {
      structured["frames"] = clip.frames.count
      structured["frames_per_second"] = clip.framesPerSecond
      structured["has_audio"] = clip.audioId != nil
    }
    structured.merge(extra) { _, new in new }
    return ["content": content, "structuredContent": structured]
  }

  /// `generate` with use_canvas: the request the Generate button would queue (`screenRequest`),
  /// run where Generate would run it, so the canvas region, mask and Merge into Image behave as
  /// they do for the user, merge and layered storage included (`CreateModel.run`).
  private func generateFromCanvas(
    _ arguments: [String: Any], progress: @escaping (Progress) -> Void
  ) async throws -> [String: Any] {
    guard arguments["use_app_settings"] as? Bool == true else {
      throw ToolError("use_canvas runs the Create screen as Generate would, so it needs use_app_settings: true too.")
    }
    if arguments["input_image"] != nil {
      throw ToolError("use_canvas takes the canvas as the input, so leave out input_image; put an image there with set_canvas_image.")
    }
    // Only what Generate would send goes: anything else is changed on the screen first, where the
    // user sees it.
    let screenFields = [
      "prompt", "negative_prompt", "model", "preset", "settings", "width", "height", "steps", "guidance_scale",
      "strength", "reference_images", "num_frames", "seconds", "audio",
    ]
    let extra = screenFields.filter { arguments[$0] != nil }
    if !extra.isEmpty {
      throw ToolError(
        "With use_canvas, generate runs the Create screen as it is, so it doesn't take \(extra.joined(separator: ", ")). Change them with set_create_screen first.")
    }
    if create.models.isEmpty { await create.refreshModelList() }
    await create.modelLoaded()
    if let problem = create.runTargetProblem {
      throw ToolError(problem + (create.runTargetMaskProblem != nil ? " (set_canvas_mask with clear: true clears it)" : ""))
    }
    guard var request = create.screenRequest(), let model = create.selectedModel else {
      throw ToolError(create.errorMessage ?? "The Create screen has no model or settings loaded yet.")
    }
    // The request's own canvas, not what the canvas shows: while a run's preview covers it, Generate
    // still takes the image beneath.
    guard request.canvas != nil else {
      if !create.canvasShowsImage { try canvasImage() }
      throw ToolError(
        create.canvasMode == .generate
          ? "The canvas is in Generate mode, so a run wouldn't take it. Call set_create_screen with canvas_mode \"edit\"."
          : "Edit means nothing to this model at Strength 100% with no mask: paint a mask (set_canvas_mask) or lower `strength` (set_create_screen).")
    }
    let seed: UInt32
    if let value = Self.int(arguments["seed"]) {
      guard value >= 0, value <= Int(UInt32.max) else { throw ToolError("`seed` must be 0–4294967295.") }
      seed = UInt32(value)
    } else {
      seed = create.seedLocked ? create.seed : UInt32.random(in: 0...UInt32.max)
    }
    request.seed = seed
    if create.videoModel?.takesAudio == true, create.audio.url != nil { request.audio = create.audio.snapshot() }
    let region = request.merge?.placement.cropRect ?? create.canvasPlacement?.cropRect
    let merged = request.merge != nil

    let summary = String(request.prompt.prefix(60))
    activity = "Waiting: “\(summary)”"
    progress(Progress(step: 0, total: nil, message: "Waiting for the current run to finish", isQueued: true))
    defer { activity = nil }
    let item = try await create.generate(forAgent: request, target: create.runTarget) { [weak self] update in
      guard case .state(let state) = update else { return }
      let message = Self.describe(state)
      var step = 0
      var total: Int?
      if case .generating(let current, let all) = state {
        step = current
        total = all
      }
      self?.activity = "\(message): “\(summary)”"
      progress(Progress(step: step, total: total, message: message))
    }
    let parent = item.inputTensorId.flatMap { create.history.item(tensorId: $0) }
    // The saved image's own size: a merged one is the whole (maybe grown) image, not the frame.
    let saved = await create.history.image(for: item)
    let size = saved.map { ["width": $0.width, "height": $0.height] } ?? ["width": item.sidecar.width, "height": item.sidecar.height]
    var notes: [String] = []
    if merged { notes.append("Merged into the whole image (\(size["width"]!)×\(size["height"]!)).") }
    if let parent { notes.append("It follows history step \(parent.id.logicalTime).") }
    return try await result(
      of: item, model: model, configuration: request.configuration, seed: seed, summary: summary, notes: notes,
      arguments: arguments,
      extra: [
        "parent_history_step": parent?.id.logicalTime ?? NSNull(), "merged": merged,
        "canvas_size": size,
        "region": region.map(Self.json) ?? NSNull(),
      ])
  }

  // MARK: - Jobs

  /// Runs generate as a job. In the background it answers with the job id once the arguments
  /// check out; otherwise it waits for the result, streaming progress. Nothing that happens to
  /// the call stops the run; cancel_job and the Queue do.
  private func startGenerate(
    _ arguments: [String: Any], progress: @escaping (Progress) -> Void
  ) async throws -> [String: Any] {
    pruneJobs()
    jobCount += 1
    let job = Job(id: "job-\(jobCount)", prompt: (arguments["prompt"] as? String) ?? create.prompt)
    jobs[job.id] = job
    let background = arguments["background"] as? Bool == true
    if !background { job.onProgress = progress }
    job.task = Task { [weak self] in
      do {
        guard let self else { return }
        let result = try await self.generate(arguments) { update in
          job.accepted = true
          job.progress = update
          job.onProgress?(update)
        }
        job.result = result
      } catch is CancellationError {
        job.wasCancelled = true
      } catch {
        job.error = error.localizedDescription
      }
      job.accepted = true
      job.finishedAt = Date()
      job.onProgress = nil
    }

    if background {
      // Bad arguments fail here rather than in the first get_job.
      await waitUntil { job.accepted }
      if let error = job.error { throw ToolError(error) }
      var summary = Self.summary(job)
      summary["note"] = "Running in the background. Call get_job with this job_id to wait for it."
      return try Self.textResult(json: summary)
    }
    // A cancelled call only stops waiting: clients cancel calls they give up on (Claude's
    // bridge does at three minutes), so only cancel_job and the Queue stop the run itself.
    await waitUntil { job.finishedAt != nil }
    job.onProgress = nil
    guard job.finishedAt != nil else {
      throw ToolError("Stopped waiting; \(job.id) is still running. Call get_job to collect it.")
    }
    return try Self.outcome(of: job)
  }

  private func getJob(_ arguments: [String: Any], progress: @escaping (Progress) -> Void) async throws -> [String: Any] {
    let job = try job(arguments)
    let wait = Double(min(max(Self.int(arguments["wait_seconds"]) ?? 30, 0), 60))
    if wait > 0 {
      let deadline = Deadline()
      let timer = Task {
        try? await Task.sleep(for: .seconds(wait))
        deadline.hasPassed = true
      }
      defer { timer.cancel() }
      var reported = -1
      for await (step, isOver) in Observations({ @MainActor in
        (job.progress.step, job.finishedAt != nil || deadline.hasPassed)
      }) {
        if isOver { break }
        if step != reported {
          reported = step
          progress(job.progress)
        }
      }
    }
    guard job.finishedAt != nil else { return try Self.textResult(json: Self.summary(job)) }
    return try Self.outcome(of: job)
  }

  private func cancelJob(_ arguments: [String: Any]) throws -> [String: Any] {
    let job = try job(arguments)
    if job.finishedAt == nil { job.task?.cancel() }
    return try Self.textResult(json: Self.summary(job))
  }

  private func job(_ arguments: [String: Any]) throws -> Job {
    let id = arguments["job_id"] as? String ?? ""
    guard let job = jobs[id] else { throw ToolError("No job “\(id)”. Jobs last an hour and end when Atelier quits; see list_jobs.") }
    return job
  }

  private func pruneJobs() {
    let finished = jobs.values.filter { $0.finishedAt != nil }.sorted { $0.startedAt > $1.startedAt }
    for (index, job) in finished.enumerated() where index >= 20 || job.finishedAt! < Date().addingTimeInterval(-3600) {
      jobs[job.id] = nil
    }
  }

  /// A finished job's answer: what generate returns, or its error.
  private static func outcome(of job: Job) throws -> [String: Any] {
    if job.wasCancelled { throw CancellationError() }
    if let error = job.error { throw ToolError(error) }
    guard var result = job.result else { throw ToolError("\(job.id) hasn't finished.") }
    if var structured = result["structuredContent"] as? [String: Any] {
      structured["job_id"] = job.id
      result["structuredContent"] = structured
    }
    return result
  }

  private static func summary(_ job: Job) -> [String: Any] {
    var summary: [String: Any] = [
      "job_id": job.id, "status": job.status, "prompt": shortened(job.prompt),
      "elapsed_seconds": Int((job.finishedAt ?? Date()).timeIntervalSince(job.startedAt)),
    ]
    if job.finishedAt == nil {
      summary["message"] = job.progress.message
      if job.progress.step > 0 { summary["step"] = job.progress.step }
      if let total = job.progress.total { summary["total_steps"] = total }
    }
    if let error = job.error { summary["error"] = error }
    if let structured = job.result?["structuredContent"] as? [String: Any] {
      summary["history_step"] = structured["history_step"]
      summary["path"] = structured["path"]
      summary["timings"] = structured["timings"]
    }
    return summary
  }

  // MARK: - Create screen

  private func createScreen() -> [String: Any] {
    let all = create.values(for: SettingsRegistry.all.map(\.id))
    let changed = create.values(for: create.changedSettings.map(\.id))
    return [
      "model": create.selectedModel ?? NSNull(),
      "model_name": create.selectedModelInfo?.name ?? NSNull(),
      "loading_model": create.isLoadingModel,
      "prompt": create.prompt,
      "negative_prompt": create.negativePrompt,
      "style": create.style?.name ?? NSNull(),
      "styled_prompt": create.style == nil ? NSNull() : create.styledPrompts.prompt,
      "style_tags": create.style.map { style in
        Dictionary(uniqueKeysWithValues: style.tags.map { ($0, $0 == Style.subject ? create.prompt : create.styleValues[$0] ?? "") })
      } ?? NSNull(),
      "seed": Int(create.seed),
      "random_seed": !create.seedLocked,
      "count": create.count,
      "settings": create.settings == nil ? NSNull() : Self.jsonObject(DrawThingsJSON.encode(all, model: nil, seed: nil)),
      "changed_from_defaults": Self.jsonObject(DrawThingsJSON.encode(changed, model: nil, seed: nil)),
      "reference_images": create.moodboard.items.count,
      "layout_editor": create.layout != nil ? "open" : create.layoutFormat == nil ? "not available for this model" : "closed",
      "canvas_has_image": create.image != nil,
      "canvas": canvasState(),
      "busy": create.workUnderway ?? NSNull(),
    ]
  }

  private func setCreateScreen(_ arguments: [String: Any]) async throws -> [String: Any] {
    if create.models.isEmpty { await create.refreshModelList() }
    var notes: [String] = []

    if let name = arguments["model"] as? String {
      let model = try resolveModel(name)
      if model != create.selectedModel { create.selectedModel = model }
    }
    await create.modelLoaded()
    guard var model = create.selectedModel else { throw ToolError("No model is downloaded.") }

    var preset: Preset?
    if let name = arguments["preset"] as? String {
      // This model's or a shared preset first, else one for another downloaded model.
      let named = presets.presets.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
      guard
        let found = named.first(where: { $0.model == nil || $0.model == model })
          ?? named.first(where: { preset in create.models.contains { $0.file == preset.model } })
      else { throw ToolError("No preset “\(name)” for a downloaded model. See list_presets.") }
      preset = found
      if let other = found.model, other != model {
        // Switches models, applying the preset once the new model's defaults load. Undo can't
        // go back across a model switch, so the step starts from what that gives.
        create.apply(found, undoManager: nil)
        await create.modelLoaded()
        preset = nil
        model = create.selectedModel ?? model
      }
    }
    // The preset or reset and the edits after it are one ⌘Z step, registered once at the end,
    // and only when something changed. What it undoes back to is read after the last wait, so
    // an edit the user made meanwhile stays out of it.
    await Self.settleUndo()
    let before = create.settings
    if let preset {
      create.apply(preset, undoManager: nil)
    } else if arguments["preset"] == nil, arguments["reset_settings"] as? Bool == true {
      create.resetToModelDefaults(undoManager: nil)
    }

    guard var configuration = create.settings else {
      throw ToolError(create.errorMessage ?? "\(model)'s settings didn't load.")
    }
    if let settings = arguments["settings"] as? [String: Any], !settings.isEmpty {
      let data = try JSONSerialization.data(withJSONObject: settings)
      guard let pasted = DrawThingsJSON.decode(data) else {
        throw ToolError("None of the keys in `settings` are settings Atelier knows. See get_create_screen.")
      }
      SettingsRegistry.apply(dump: pasted.dump, to: &configuration)
      let ignored = settings.keys.filter { pasted.dump[$0] == nil && $0 != "model" && $0 != "seed" }
      if !ignored.isEmpty { notes.append("Ignored unknown settings: \(ignored.sorted().joined(separator: ", ")).") }
    }
    let width = Self.int(arguments["width"])
    let height = Self.int(arguments["height"])
    if width != nil || height != nil {
      configuration.width = Self.roundTo64(width ?? configuration.width)
      configuration.height = Self.roundTo64(height ?? configuration.height)
    }
    if let steps = Self.int(arguments["steps"]) {
      configuration.steps = max(steps, 1)
    }
    if let guidance = Self.double(arguments["guidance_scale"]) {
      configuration.guidanceScale = Float(guidance)
    }
    if let strength = Self.double(arguments["strength"]) {
      configuration.strength = Float(min(max(strength, 0), 1))
    }
    let frames = Self.int(arguments["num_frames"])
    let seconds = Self.double(arguments["seconds"])
    if frames != nil || seconds != nil {
      if let video = VideoModel(model: model, loras: configuration.loras.compactMap(\.file)) {
        configuration.numFrames = video.snapped(frames ?? Int((seconds! * video.framesPerSecond).rounded()) + 1)
      } else {
        notes.append("\(model) isn't a video model, so num_frames and seconds were ignored.")
      }
    }
    // Should the model have changed under it anyway, undo can't go back across that: the step
    // starts from the new model's values, as the inspector's own undo does.
    let restoring = before?.model == configuration.model ? before : create.settings
    if let restoring, !Self.sameSettings(restoring, configuration) {
      Self.asOneUndoStep {
        create.replaceSettings(with: configuration, restoring: restoring, actionName: "Agent Settings", undoManager: $0)
      }
    }

    if let prompt = arguments["prompt"] as? String {
      // With the Layout editor open, the boxes glide to the new layout instead of jumping.
      withAnimation(create.layout == nil ? nil : .smooth(duration: 0.8)) { create.prompt = prompt }
    }
    if let open = arguments["layout_editor"] as? Bool {
      if !open {
        create.closeLayout()
      } else if create.layoutFormat == nil {
        notes.append("\(model) doesn't take layout prompts, so the Layout editor stayed closed.")
      } else if create.layout == nil {
        create.openLayout()
      }
    }
    if let negative = arguments["negative_prompt"] as? String { create.negativePrompt = negative }
    if let value = Self.int(arguments["seed"]) {
      guard value >= 0, value <= Int(UInt32.max) else { throw ToolError("`seed` must be 0–4294967295.") }
      create.seed = UInt32(value)
      create.seedLocked = true
    }
    if let random = arguments["random_seed"] as? Bool { create.seedLocked = !random }
    if let count = Self.int(arguments["count"]) {
      let counts = [1, 2, 3, 4, 6, 8, 12, 16]
      guard counts.contains(count) else { throw ToolError("`count` must be one of 1, 2, 3, 4, 6, 8, 12 or 16.") }
      create.count = count
    }
    if let mode = arguments["canvas_mode"] as? String {
      guard let canvasMode = CreateModel.CanvasMode(rawValue: mode) else {
        throw ToolError("`canvas_mode` is \"generate\" or \"edit\".")
      }
      create.canvasMode = canvasMode
      if canvasMode == .edit, create.effectiveCanvasMode == .generate {
        notes.append("Edit means nothing to \(model) at Strength 100% with no mask, so runs still generate from the prompt alone until you paint a mask (set_canvas_mask) or lower `strength`.")
      }
    }
    if let merge = arguments["merge_into_image"] as? Bool { create.mergeIntoImage = merge }

    var result = createScreen()
    if !notes.isEmpty { result["notes"] = notes }
    return try Self.textResult(json: result)
  }

  // MARK: - Canvas

  /// The canvas as an agent sees it: what's on it, the frame, the region of the image the frame
  /// shows (all in the image's pixels from its top left), the mode and the mask.
  private func canvasState() -> [String: Any] {
    let shows =
      create.canvasClip != nil ? "video" : create.canvasShowsImage ? "image" : create.image != nil ? "run preview" : "empty"
    var state: [String: Any] = [
      "has_image": create.canvasShowsImage,
      "shows": shows,
      "canvas_mode": create.canvasMode.rawValue,
      // Edit means nothing at Strength 100% with no mask, so runs fall back to Generate.
      "canvas_mode_in_effect": create.effectiveCanvasMode.rawValue,
      "merge_into_image": create.mergeIntoImage,
      "merge_applies": create.canMergeIntoImage,
      "can_paint_mask": create.canPaintMask,
    ]
    if let frame = create.frameSize { state["frame"] = Self.json(frame) }
    guard create.canvasShowsImage, let image = create.image else { return state }
    let sourceSize = CGSize(width: image.width, height: image.height)
    state["source_step"] = create.imageItem?.id.logicalTime ?? NSNull()
    state["source_size"] = Self.json(sourceSize)
    if let placement = create.canvasPlacement {
      let crop = placement.cropRect
      state["region"] = Self.json(crop)
      state["scale"] = (placement.zoom.x + placement.zoom.y) / 2
      state["fitted"] = create.canvas.scale == nil
      state["offset"] = ["x": create.canvas.offset.width, "y": create.canvas.offset.height]
      // Half a pixel of slack for rounding to whole frame pixels.
      state["extends_past_image"] = !CGRect(origin: .zero, size: sourceSize).insetBy(dx: -0.5, dy: -0.5).contains(crop)
    }
    state["mask"] = maskSummary()
    return state
  }

  /// get_canvas_mask's summary, also what set_canvas_mask returns.
  private func maskSummary() -> [String: Any] {
    guard let stats = create.canvasMaskStats, let image = create.image else { return ["has_mask": false] }
    return [
      "has_mask": stats.paintedPixels > 0,
      "source_size": Self.json(CGSize(width: image.width, height: image.height)),
      "painted_pixels": stats.paintedPixels,
      "coverage": stats.paintedFraction,
      "bounds": stats.bounds.map(Self.json) ?? NSNull(),
      "coverage_in_region": stats.frameFraction ?? NSNull(),
      // Painted inside the frame, in Edit, for a target that takes masks: what Generate sends.
      "sent_with_next_run": create.runTargetTakesMasks && create.screenFrameHasPaint,
    ]
  }

  /// The canvas image an agent can work on, or why there isn't one.
  @discardableResult
  private func canvasImage() throws -> CGImage {
    if create.canvasClip != nil {
      throw ToolError("The canvas plays a video. Put an image on it with set_canvas_image first.")
    }
    guard create.canvasShowsImage, let image = create.image else {
      throw ToolError(
        create.image != nil
          ? "The canvas shows a run's preview. Wait for it (get_job), or put an image there with set_canvas_image."
          : "The canvas is empty. Call set_canvas_image first.")
    }
    return image
  }

  private func setCanvasImage(_ arguments: [String: Any]) async throws -> [String: Any] {
    let step = Self.int(arguments["history_step"])
    let source = arguments["image"] as? String
    guard (step == nil) != (source == nil) else {
      throw ToolError("Pass `history_step` (see list_history) or `image` (a path or data: URL), not both.")
    }
    if let step {
      guard let item = create.history.items.first(where: { $0.id.logicalTime == step }) else {
        throw ToolError("No history step \(step) in “\(create.history.project.name)”. See list_history.")
      }
      guard !item.isVideo else { throw ToolError("History step \(step) is a video; the canvas mask and region work on images.") }
      guard await create.placeOnCanvas(item) else { throw ToolError("Couldn't read history step \(step)'s image.") }
    } else if let source {
      create.placeOnCanvas(try Self.loadImage(source))
    }
    return try Self.textResult(json: canvasState())
  }

  private func setCanvasMask(_ arguments: [String: Any]) async throws -> [String: Any] {
    // Before reading the mask it builds on: nothing waits after that, so the mask can't land on
    // another image or overwrite an edit made meanwhile.
    await Self.settleUndo()
    let image = try canvasImage()
    let sourceRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let size = "\(image.width)×\(image.height)"
    let clear = arguments["clear"] as? Bool == true
    let invert = arguments["invert"] as? Bool == true
    let mode = arguments["mode"] as? String ?? "replace"
    guard ["replace", "add", "subtract"].contains(mode) else {
      throw ToolError("`mode` is \"replace\" (the default), \"add\" or \"subtract\".")
    }
    let shapes = arguments["shapes"] as? [Any]
    let maskSource = arguments["image"] as? String
    if arguments["shapes"] != nil, shapes == nil { throw ToolError("`shapes` is an array of shapes.") }
    guard clear || invert || shapes != nil || maskSource != nil else {
      throw ToolError("Pass `shapes`, `image`, `invert` or `clear`.")
    }
    guard create.canEditMask else { throw ToolError(maskUnavailableReason()) }

    let erases = mode == "subtract"
    var strokes: [CanvasMask.Stroke] = []
    var notes: [String] = []
    for (index, entry) in (shapes ?? []).enumerated() {
      guard let shape = entry as? [String: Any] else { throw ToolError("Shape \(index + 1) isn't an object.") }
      let stroke = try Self.stroke(shape, number: index + 1, erases: erases)
      let bounds = stroke.kind == .polygon ? Self.bounds(of: stroke.points) : Self.bounds(of: stroke.points).standardized
      guard bounds.intersects(sourceRect) else {
        throw ToolError("Shape \(index + 1) lies wholly outside the \(size) canvas image (coordinates are its pixels from the top left).")
      }
      strokes.append(stroke)
    }
    if let maskSource {
      let mask = try Self.loadImage(maskSource)
      guard mask.width == image.width, mask.height == image.height else {
        throw ToolError(
          "The mask image is \(mask.width)×\(mask.height), but the canvas image is \(size). Make it that size: white regenerates, black or transparent keeps.")
      }
      if let stroke = CanvasMask.Stroke.bitmap(mask, erases: erases) {
        strokes.append(stroke)
      } else {
        notes.append("The mask image paints nothing (no opaque pixels light enough).")
      }
    }
    // Replacing starts from nothing; only shapes or an image replace (invert alone flips what's there).
    let replaces = clear || (mode == "replace" && (shapes != nil || maskSource != nil))
    let base = replaces ? nil : create.canvasMask
    var mask = base ?? CanvasMask()
    mask.strokes += strokes
    if invert { mask.strokes.append(.invert) }
    // As the canvas's own Invert Mask: flipping a mask that's there paints nothing new, so it's
    // allowed where painting isn't (an older server); anything else paints.
    let invertsExisting = invert && strokes.isEmpty && base != nil
    let paintsNew = strokes.contains { !$0.erases } || (invert && !invertsExisting)
    if paintsNew, !create.canPaintMask {
      throw ToolError(
        "\(create.runTargetServerName ?? "The server") can't take masks: its Atelier is older. Run on this device (Run on in the app), or only clear the mask.")
    }
    Self.asOneUndoStep {
      create.setMask(mask.strokes.isEmpty ? nil : mask, actionName: CreateModel.agentMaskActionName, undoManager: $0)
    }
    var result = maskSummary()
    if !notes.isEmpty { result["notes"] = notes }
    return try Self.textResult(json: result)
  }

  /// Why the mask can't change now (`canEditMask` is false with an image on the canvas).
  private func maskUnavailableReason() -> String {
    if create.videoModel != nil { return "\(create.selectedModel ?? "This model") makes video, which takes no mask." }
    if create.layout != nil { return "The Layout editor is open over the canvas. Close it with set_create_screen {layout_editor: false}." }
    if create.canvasMode != .edit {
      return "The canvas is in Generate mode, where there's no mask. Call set_create_screen with canvas_mode \"edit\"."
    }
    return "The mask can't change now."
  }

  /// One `set_canvas_mask` shape as a mask stroke.
  private static func stroke(_ shape: [String: Any], number: Int, erases: Bool) throws -> CanvasMask.Stroke {
    switch shape["shape"] as? String {
    case "rect", "ellipse":
      guard let x = double(shape["x"]), let y = double(shape["y"]), let width = double(shape["width"]),
            let height = double(shape["height"])
      else { throw ToolError("Shape \(number) needs x, y, width and height.") }
      guard width > 0, height > 0 else { throw ToolError("Shape \(number) has no size: width and height must be above 0.") }
      let rect = CGRect(x: x, y: y, width: width, height: height)
      return shape["shape"] as? String == "rect" ? .rect(rect, erases: erases) : .ellipse(in: rect, erases: erases)
    case "polygon":
      let points = (shape["points"] as? [Any] ?? []).compactMap { point -> CGPoint? in
        if let pair = point as? [Any], pair.count == 2, let x = double(pair[0]), let y = double(pair[1]) {
          return CGPoint(x: x, y: y)
        }
        if let object = point as? [String: Any], let x = double(object["x"]), let y = double(object["y"]) {
          return CGPoint(x: x, y: y)
        }
        return nil
      }
      guard points.count >= 3 else { throw ToolError("Shape \(number), a polygon, needs `points` with at least 3 [x, y] pairs.") }
      let bounds = Self.bounds(of: points)
      guard bounds.width > 0, bounds.height > 0 else { throw ToolError("Shape \(number), a polygon, has no area.") }
      return .polygon(points, erases: erases)
    default:
      throw ToolError("Shape \(number)'s `shape` is \"rect\", \"ellipse\" or \"polygon\".")
    }
  }

  private static func bounds(of points: [CGPoint]) -> CGRect {
    guard let first = points.first else { return .null }
    return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
  }

  /// auto_mask: a selection by SAM 2.1 or Vision, put into the mask as one undo step.
  private func autoMask(_ arguments: [String: Any]) async throws -> [String: Any] {
    if arguments["text"] != nil || arguments["prompt"] != nil {
      throw ToolError(
        "auto_mask doesn't take a text prompt. Look at the image (get_image) and pass `points` on what you mean, a `box` around it, or `subject: true`.")
    }
    let image = try canvasImage()
    guard create.canEditMask else { throw ToolError(maskUnavailableReason()) }
    let modeName = arguments["mode"] as? String ?? "replace"
    guard let mode = AutoMaskMode(rawValue: modeName) else {
      throw ToolError("`mode` is \"replace\" (the default), \"add\" or \"subtract\".")
    }
    let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let size = "\(image.width)×\(image.height)"
    var points: [SAMSegmenter.Point] = []
    for (index, entry) in (arguments["points"] as? [Any] ?? []).enumerated() {
      guard let point = entry as? [String: Any], let x = Self.double(point["x"]), let y = Self.double(point["y"]) else {
        throw ToolError("Point \(index + 1) needs x and y.")
      }
      let location = CGPoint(x: x, y: y)
      guard imageRect.contains(location) else {
        throw ToolError("Point \(index + 1) is outside the \(size) canvas image (its pixels from the top left).")
      }
      points.append(SAMSegmenter.Point(location: location, positive: point["positive"] as? Bool ?? true))
    }
    // As many as SAM's prompt encoder takes beside the box (`SAMGeometry.promptInputs`): the
    // Select tool drops the earliest past that, which an agent wouldn't see.
    let pointLimit = SAMGeometry.maxPromptPoints - (arguments["box"] == nil ? 0 : 2)
    guard points.count <= pointLimit else {
      throw ToolError(
        "auto_mask takes at most \(pointLimit) points\(arguments["box"] == nil ? "" : " with a box") (\(points.count) given). Use fewer, or select in steps with mode add and subtract.")
    }
    var box: CGRect?
    if let value = arguments["box"] {
      guard let object = value as? [String: Any], let x = Self.double(object["x"]), let y = Self.double(object["y"]),
            let width = Self.double(object["width"]), let height = Self.double(object["height"])
      else { throw ToolError("`box` is {\"x\", \"y\", \"width\", \"height\"} in the canvas image's pixels.") }
      guard width > 0, height > 0 else { throw ToolError("`box` has no size: width and height must be above 0.") }
      let rect = CGRect(x: x, y: y, width: width, height: height).intersection(imageRect)
      guard !rect.isNull, rect.width > 0, rect.height > 0 else {
        throw ToolError("`box` doesn't overlap the \(size) canvas image.")
      }
      box = rect
    }
    let subject = arguments["subject"] as? Bool == true
    if subject {
      guard box == nil, points.count <= 1, points.first?.positive != false else {
        throw ToolError("`subject` takes at most one point, to pick the subject under it, and no box. For points and boxes, leave out `subject` (SAM 2.1).")
      }
    } else if points.isEmpty, box == nil {
      throw ToolError("Pass `points`, a `box`, or `subject: true`.")
    }
    let samSize = try (arguments["size"] as? String).map { name in
      guard let size = SAMFiles.Size(rawValue: name) else { throw ToolError("`size` is \"tiny\", \"small\" or \"large\".") }
      return size
    } ?? create.autoMask.size
    if !subject, SAMFiles.installed(samSize) == nil {
      throw ToolError(
        "SAM 2.1 \(samSize.title) isn't downloaded. Ask the user to download it in Atelier: on the Create screen pick the Select tool (the wand beside Brush and Eraser) and use the download in its bar. Or use `subject: true`, which needs no download.")
    }
    if mode == .subtract {
      guard create.canvasMask != nil else {
        throw ToolError("There's no mask to subtract from. Select with mode replace or add first, or paint one with set_canvas_mask.")
      }
    } else if !create.canPaintMask {
      throw ToolError(
        "\(create.runTargetServerName ?? "The server") can't take masks: its Atelier is older. Run on this device (Run on in the app).")
    }

    let selection: AutoMaskSelection
    var extra: [String: Any] = [:]
    do {
      if subject {
        let (picked, time) = try await create.subjectSelection(at: points.first?.location)
        selection = picked
        extra["decode_ms"] = Self.milliseconds(time)
        extra["encode_ms"] = NSNull()
        extra["score"] = NSNull()
      } else {
        let (picked, result) = try await create.samSelection(SAMSegmenter.Prompt(points: points, box: box), size: samSize)
        selection = picked
        extra["score"] = Double(result.score)
        extra["encode_ms"] = result.encodeTime.map(Self.milliseconds) ?? NSNull()
        extra["decode_ms"] = Self.milliseconds(result.decodeTime)
      }
    } catch let error as SubjectMask.Failure {
      throw ToolError(
        error.localizedDescription + " Try `subject: true` without a point, or select with SAM 2.1 (`points` or a `box`).")
    } catch let error as AutoMaskError {
      throw ToolError(Self.hint(for: error))
    }
    guard selection.selectedPixels > 0 else {
      throw ToolError("Nothing was selected. Try another point, add a box, or use `subject: true`.")
    }
    extra["selected_pixels"] = selection.selectedPixels
    extra["selected_with"] = subject ? "vision" : "sam 2.1 \(samSize.rawValue)"
    // After the selection (which can take seconds), before the mask it builds on is read.
    await Self.settleUndo()
    let committed = Self.asOneUndoStep {
      create.commitAutoMask(selection, mode: mode, actionName: CreateModel.agentMaskActionName, undoManager: $0)
    }
    guard committed else {
      throw ToolError(
        create.image !== selection.image
          ? "The canvas changed while selecting. Call auto_mask again."
          : mode == .subtract ? "There's no mask to subtract from any more."
          : create.canEditMask && !create.canPaintMask
          ? create.runTargetMaskProblem
          ?? "\(create.runTargetServerName ?? "The server") can't take masks: its Atelier is older. Run on this device (Run on in the app)."
          : maskUnavailableReason())
    }
    return try getCanvasMask(["view": "overlay"], extra: extra)
  }

  private static func hint(for error: AutoMaskError) -> String {
    switch error {
    case .notDownloaded(let size):
      "SAM 2.1 \(size.title) isn't downloaded. Ask the user to download it from the Select tool's bar in Atelier, or use `subject: true`."
    case .noMaskToSubtract: "There's no mask to subtract from. Select with mode replace or add first."
    case .imageChanged: "The canvas changed while selecting. Call auto_mask again."
    case .cannotPaint: "The mask can't be changed now: put an image on the canvas with set_canvas_image, in Edit mode, with an image model."
    case .emptyPrompt: "Pass `points`, a `box`, or `subject: true`."
    case .nothingSelected: "Nothing was selected. Try another point, add a box, or use `subject: true`."
    }
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000
  }

  /// get_canvas_mask, and auto_mask's answer with its own fields (`extra`) in the summary.
  private func getCanvasMask(_ arguments: [String: Any], extra: [String: Any] = [:]) throws -> [String: Any] {
    let image = try canvasImage()
    let view = arguments["view"] as? String ?? "overlay"
    guard ["overlay", "mask", "both"].contains(view) else { throw ToolError("`view` is \"overlay\" (the default), \"mask\" or \"both\".") }
    let maxSide = min(max(Self.int(arguments["max_size"]) ?? 1024, 256), 2048)
    let sourceSize = CGSize(width: image.width, height: image.height)
    var views: [(name: String, image: CGImage)] = []
    if view != "mask" {
      guard let overlay = create.canvasMaskOverlay() else { throw ToolError("Couldn't draw the overlay.") }
      views.append(("overlay", overlay))
    }
    if view != "overlay" {
      guard let mask = (create.canvasMask ?? CanvasMask()).image(sourceSize: sourceSize) else { throw ToolError("Couldn't draw the mask.") }
      views.append(("mask", mask))
    }
    var summary = maskSummary().merging(extra) { _, new in new }
    if let saveTo = arguments["save_to"] as? String {
      var saved: [String: String] = [:]
      for entry in views {
        // Two views to one file name: each gets its own suffix.
        var target = saveTo
        if views.count > 1, !saveTo.hasSuffix("/"), !(saveTo as NSString).pathExtension.isEmpty {
          let path = (saveTo as NSString).deletingPathExtension
          target = "\(path)-\(entry.name).\((saveTo as NSString).pathExtension)"
        }
        let url = try Self.outputURL(target, name: "Canvas \(entry.name == "mask" ? "Mask" : "Overlay")", extension: "png")
        guard let png = ImageTensor.png(entry.image) else { throw ToolError("Couldn't encode the \(entry.name).") }
        try png.write(to: url)
        saved[entry.name] = url.path
      }
      summary["saved"] = saved
    }
    let data = try JSONSerialization.data(withJSONObject: Self.tidy(summary), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    var content: [[String: Any]] = [["type": "text", "text": String(decoding: data, as: UTF8.self)]]
    for entry in views {
      if let preview = Self.jpeg(ImageLoader.fitted(entry.image, maxSide: maxSide)) {
        content.append(["type": "image", "data": preview.base64EncodedString(), "mimeType": "image/jpeg"])
      }
    }
    return ["content": content, "structuredContent": Self.tidy(summary)]
  }

  private func setCanvasRegion(_ arguments: [String: Any]) async throws -> [String: Any] {
    await Self.settleUndo()
    let image = try canvasImage()
    let sourceSize = CGSize(width: image.width, height: image.height)
    let sourceRect = CGRect(origin: .zero, size: sourceSize)
    let regionArgument = arguments["region"]
    let fit = arguments["fit"] as? Bool == true
    let actualSize = arguments["actual_size"] as? Bool == true
    let scale = Self.double(arguments["scale"])
    guard [regionArgument != nil, fit, actualSize, scale != nil].filter(\.self).count == 1 else {
      throw ToolError("Pass one of `region`, `fit`, `actual_size` or `scale`.")
    }
    let sizeToRegion = arguments["size_to_region"] as? Bool == true
    if sizeToRegion, actualSize || scale != nil {
      throw ToolError("size_to_region goes with `region` or `fit`, which name the area to size the output to.")
    }
    var result: [String: Any] = [:]
    var notes: [String] = []

    /// Sets the output size to `area`'s shape at about the current pixel count, as one undo step.
    func size(to area: CGSize) {
      guard sizeToRegion, var configuration = create.settings else { return }
      let size = CanvasPlacement.frameSize(
        forRegion: area, pixelCount: Double(configuration.width * configuration.height))
      guard Int(size.width) != configuration.width || Int(size.height) != configuration.height else { return }
      configuration.width = Int(size.width)
      configuration.height = Int(size.height)
      Self.asOneUndoStep { create.replaceSettings(with: configuration, actionName: "Agent Settings", undoManager: $0) }
      notes.append("The output size is now \(configuration.width)×\(configuration.height).")
    }

    if let regionArgument {
      guard let object = regionArgument as? [String: Any], let x = Self.double(object["x"]), let y = Self.double(object["y"]),
            let width = Self.double(object["width"]), let height = Self.double(object["height"])
      else { throw ToolError("`region` is {\"x\", \"y\", \"width\", \"height\"} in the canvas image's pixels.") }
      guard width > 0, height > 0 else { throw ToolError("`region` has no size: width and height must be above 0.") }
      let region = CGRect(x: x, y: y, width: width, height: height)
      guard region.intersects(sourceRect) else {
        throw ToolError("`region` doesn't overlap the \(image.width)×\(image.height) canvas image (its pixels from the top left).")
      }
      size(to: region.size)
      guard let frameSize = create.frameSize else { throw ToolError("The Create screen has no output size yet.") }
      let grown = CanvasPlacement.grown(region, toShapeOf: frameSize)
      let wanted = CanvasPlacement.zoomAndOffset(showing: grown, sourceSize: sourceSize, frameSize: frameSize).scale
      create.showRegion(grown)
      result["requested_region"] = Self.json(region)
      result["grown_region"] = Self.json(grown)
      let clamped = !CanvasState.range.contains(wanted)
      result["clamped"] = clamped
      if clamped {
        notes.append(
          "Showing that region needs a zoom of \(String(format: "%.3g", wanted))×, outside the canvas's 0.05×–32×, so the frame shows `region` instead.")
      }
    } else if fit {
      size(to: sourceSize)
      create.canvas.zoomToFit()
    } else if actualSize {
      create.canvas.zoom(to: 1)
    } else if let scale {
      guard CanvasState.range.contains(scale) else { throw ToolError("`scale` must be 0.05–32 (frame pixels per image pixel).") }
      var center: CGPoint
      if let crop = create.canvasPlacement?.cropRect { center = CGPoint(x: crop.midX, y: crop.midY) } else {
        center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
      }
      if let value = arguments["center"] {
        guard let pair = value as? [Any], pair.count == 2, let x = Self.double(pair[0]), let y = Self.double(pair[1]) else {
          throw ToolError("`center` is [x, y] in the canvas image's pixels.")
        }
        center = CGPoint(x: x, y: y)
      }
      create.canvas.scale = scale
      create.canvas.offset = CanvasPlacement.offset(centering: center, scale: scale, sourceSize: sourceSize)
    }
    let state = canvasState()
    result.merge(state) { _, new in new }
    if state["extends_past_image"] as? Bool == true {
      notes.append("The frame reaches past the image's edges: an Edit run fills in what's outside, and with Merge into Image the image grows to hold it.")
    }
    if let crop = create.canvasPlacement?.cropRect, !crop.intersects(sourceRect) {
      notes.append("The frame shows none of the image.")
    }
    if create.effectiveCanvasMode == .generate {
      notes.append("Runs don't take the canvas now (canvas_mode_in_effect is generate): paint a mask, lower `strength`, or set canvas_mode edit.")
    }
    if !notes.isEmpty { result["notes"] = notes }
    return try Self.textResult(json: result)
  }

  private static func json(_ rect: CGRect) -> [String: Any] {
    ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
  }

  private static func json(_ size: CGSize) -> [String: Any] {
    ["width": Int(size.width), "height": Int(size.height)]
  }

  // MARK: - Images

  private func listHistory(_ arguments: [String: Any]) -> [[String: Any]] {
    let limit = max(Self.int(arguments["limit"]) ?? 20, 1)
    return create.history.items.prefix(limit).map { item in
      let sidecar = item.sidecar
      return [
        "history_step": item.id.logicalTime, "prompt": Self.shortened(sidecar.prompt),
        "model": sidecar.model, "seed": Int(sidecar.seed), "width": sidecar.width, "height": sidecar.height,
        "rating": create.history.rating(of: item), "video": item.isVideo,
        "on_canvas": create.imageItem == item || create.canvasClip == item,
      ]
    }
  }

  private func getImage(_ arguments: [String: Any]) async throws -> [String: Any] {
    let item: HistoryItem?
    let image: CGImage
    if let step = Self.int(arguments["history_step"]) {
      guard let found = create.history.items.first(where: { $0.id.logicalTime == step }) else {
        throw ToolError("No history step \(step) in “\(create.history.project.name)”. See list_history.")
      }
      item = found
    } else if arguments["latest"] as? Bool == true {
      guard let newest = create.history.items.first else { throw ToolError("The project has no images yet.") }
      item = newest
    } else {
      item = create.imageItem ?? create.canvasClip
    }
    if let item {
      guard let loaded = await create.history.image(for: item) else { throw ToolError("Couldn't read that image.") }
      image = loaded
    } else {
      guard let canvas = create.image else { throw ToolError("The canvas is empty.") }
      image = canvas
    }

    var text: String
    if let item {
      let sidecar = item.sidecar
      text =
        "History step \(item.id.logicalTime) in “\(create.history.project.name)”\(item.isVideo ? " (a video; this is its first frame)" : "").\n"
        + "Model \(sidecar.model), \(sidecar.width)×\(sidecar.height), \(sidecar.steps) steps, "
        + "guidance \(sidecar.guidanceScale), seed \(sidecar.seed).\nPrompt: \(sidecar.prompt)"
      if !sidecar.negativePrompt.isEmpty { text += "\nNegative prompt: \(sidecar.negativePrompt)" }
      if let timings = sidecar.timings { text += "\nTimings: " + timings.lines.joined(separator: "; ") + "." }
    } else {
      text = "The canvas image (\(image.width)×\(image.height)), not a saved history image: an imported image or a run in progress."
    }
    if let saveTo = arguments["save_to"] as? String {
      let url = try Self.outputURL(
        saveTo, name: item.map(create.history.fileName(for:)) ?? "Canvas", extension: "png")
      let png = try item.map { try HistoryStore.pngData(image, sidecar: $0.sidecar) } ?? ImageTensor.png(image)
      guard let png else { throw ToolError("Couldn't encode the image.") }
      try png.write(to: url)
      text += "\nSaved to \(url.path)."
    }
    let maxSide = min(max(Self.int(arguments["max_size"]) ?? 1024, 256), 2048)
    var content: [[String: Any]] = [["type": "text", "text": text]]
    if let preview = Self.jpeg(ImageLoader.fitted(image, maxSide: maxSide)) {
      content.append(["type": "image", "data": preview.base64EncodedString(), "mimeType": "image/jpeg"])
    }
    return ["content": content]
  }

  private static func shortened(_ prompt: String) -> String {
    let line = prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
    return line.count > 160 ? String(line.prefix(160)) + "…" : line
  }

  /// The main window's undo manager, which the Create screen's ⌘Z uses.
  static var mainWindowUndoManager: UndoManager? {
    undoManagerForChecks
      ?? NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }?.undoManager
  }

  /// The undo manager a scripted check chose for its whole run (the window's, or a stand-in when
  /// a launch with the screen locked opens no window). Never set in normal use.
  static var undoManagerForChecks: UndoManager?

  /// Whether two configurations hold the same value for every setting.
  private static func sameSettings(_ a: PipelineConfiguration?, _ b: PipelineConfiguration?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.model == b.model && SettingsRegistry.all.allSatisfy { $0.get(a) == $0.get(b) }
  }

  /// Waits a moment for an undo group still open on the main window's undo manager (a user's
  /// event's, which the undo manager closes itself: closing it here would make that close throw),
  /// so the change after it can be a ⌘Z step of its own. Called before a tool reads the state it
  /// changes, so an edit the user makes meanwhile isn't overwritten. Gives up when the call is
  /// cancelled.
  private static func settleUndo() async {
    guard let undoManager = mainWindowUndoManager else { return }
    let deadline = Date().addingTimeInterval(0.3)
    while undoManager.groupingLevel > 0, Date() < deadline {
      guard (try? await Task.sleep(for: .milliseconds(5))) != nil else { break }
    }
  }

  /// Makes `change` (which registers undo) a ⌘Z step of its own on the main window's undo
  /// manager; call `settleUndo` first. It groups by event, and agent calls reach the main actor
  /// through dispatch, not as events: with no user event between calls, AppKit never closes the
  /// event group a change opens (`beginUndoGrouping` at level 0 opens one too), so every call
  /// until the next event would be one step. So at level 0 the change gets a plain group, with
  /// grouping by event off just while it's open, and leaves nothing open. In the rare case a
  /// user's group is still open after `settleUndo`, the change joins it, keeping its name.
  @discardableResult
  private static func asOneUndoStep<T>(_ change: (UndoManager?) throws -> T) rethrows -> T {
    guard let undoManager = mainWindowUndoManager else { return try change(nil) }
    guard undoManager.groupingLevel == 0 else {
      let name = undoManager.undoActionName
      defer { undoManager.setActionName(name) }
      return try change(undoManager)
    }
    let groupsByEvent = undoManager.groupsByEvent
    undoManager.groupsByEvent = false
    undoManager.beginUndoGrouping()
    defer {
      undoManager.endUndoGrouping()
      undoManager.groupsByEvent = groupsByEvent
    }
    return try change(undoManager)
  }

  // MARK: - Helpers

  /// The model's recommended settings with its default preset, as Create starts from.
  private func defaults(for model: String) async throws -> PipelineConfiguration {
    let template = try await create.backend(for: .local).loadPipeline(for: model)
    var configuration = ModelDefaults.recommended(for: model, configuration: template)
    for (id, value) in presets.defaultPreset(for: model)?.values ?? [:] {
      SettingsRegistry.byID[id]?.set(&configuration, value)
    }
    return configuration
  }

  private func apply(presetNamed name: String, model: String, to configuration: inout PipelineConfiguration) throws {
    let usable = presets.presets(for: model)
    guard
      let preset = (usable.own + usable.shared).first(where: {
        $0.name.caseInsensitiveCompare(name) == .orderedSame
      })
    else {
      throw ToolError("No preset “\(name)” for \(model). See list_presets.")
    }
    for (id, value) in preset.values {
      SettingsRegistry.byID[id]?.set(&configuration, value)
    }
  }

  /// A downloaded model by file or name; nil means the app's selected model.
  private func resolveModel(_ name: String?) throws -> String {
    guard let name, !name.isEmpty else {
      guard let selected = create.selectedModel else { throw ToolError("No model is downloaded.") }
      return try resolveModel(selected)
    }
    if let model = create.models.first(where: { $0.file == name })
      ?? create.models.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    {
      return model.file
    }
    throw ToolError("“\(name)” isn't a downloaded model. See list_models.")
  }

  /// Mirrors `CreateModel.usesReferences`. ModelZoo only knows a community model's version once
  /// its pipeline has loaded, so the catalog's version name is checked too.
  private func takesReferences(model: String, loras: [String]) -> Bool {
    if ModelZoo.versionForModel(model) == .qwenImage2_1
      || create.models.first(where: { $0.file == model })?.version == "Qwen Image 2.1"
    {
      return true
    }
    let modifiers = [ModelZoo.modifierForModel(model)] + loras.map(LoRAZoo.modifierForModel)
    return modifiers.contains {
      switch $0 {
      case .kontext, .kontextKv, .qwenimageEditPlus, .qwenimageEdit2511, .fl2va, .ref2va: true
      default: false
      }
    }
  }

  private static func loadImage(_ source: String) throws -> CGImage {
    if source.hasPrefix("data:") {
      guard let comma = source.firstIndex(of: ","),
        let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
        let image = ImageLoader.image(from: data)
      else { throw ToolError("Couldn't decode the data: URL image.") }
      return image
    }
    let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
    guard let image = ImageLoader.image(at: url) else {
      throw ToolError("Couldn't read an image at \(url.path).")
    }
    return image
  }

  private static func outputURL(_ saveTo: String?, name: String, extension ext: String) throws -> URL {
    let fileManager = FileManager.default
    var folder = TemporaryFiles.folder(.agent)
    if let saveTo, !saveTo.isEmpty {
      let url = URL(fileURLWithPath: (saveTo as NSString).expandingTildeInPath)
      var isDirectory: ObjCBool = false
      let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      if !(exists && isDirectory.boolValue), !saveTo.hasSuffix("/") {
        try fileManager.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url.pathExtension.isEmpty ? url.appendingPathExtension(ext) : url
      }
      folder = url
    }
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(path: name).appendingPathExtension(ext)
  }

  private nonisolated static func describe(_ state: MediaGenerationPipeline.State) -> String {
    switch state {
    case .downloading(let received, let total):
      return total > 0 ? "Downloading \(received * 100 / total)%" : "Downloading"
    case .encodingText: return "Encoding prompt"
    case .encodingInputs: return "Encoding inputs"
    case .generating(let step, let total): return "Step \(step) of \(total)"
    case .decoding: return "Decoding"
    case .postprocessing, .completed: return "Finishing"
    case .cancelling, .cancelled: return "Cancelling"
    default: return "Preparing"
    }
  }

  /// The inline copy: JPEG keeps the response small; the full PNG is on disk.
  private static func jpeg(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  /// Settings are Floats; printed as Doubles they read 0.69999999999999996.
  private static func tidy(_ value: Any) -> Any {
    switch value {
    case let dictionary as [String: Any]: return dictionary.mapValues(tidy)
    case let array as [Any]: return array.map(tidy)
    case let number as NSNumber where CFNumberIsFloatType(number):
      return Double(String(format: "%.6g", number.doubleValue)) ?? number
    default: return value
    }
  }

  private static func roundTo64(_ value: Int) -> Int {
    max(Int((Double(value) / 64).rounded()), 1) * 64
  }

  private static func int(_ value: Any?) -> Int? {
    (value as? NSNumber).map(\.intValue) ?? (value as? String).flatMap { Int($0) }
  }

  private static func double(_ value: Any?) -> Double? {
    (value as? NSNumber).map(\.doubleValue) ?? (value as? String).flatMap { Double($0) }
  }

  private static func jsonObject(_ data: Data?) -> Any {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
  }

  private static func textResult(json: Any) throws -> [String: Any] {
    let data = try JSONSerialization.data(
      withJSONObject: tidy(json), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
  }
}
#endif
