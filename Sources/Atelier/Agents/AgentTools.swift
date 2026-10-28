#if os(macOS)
import _MediaGenerationKit
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ModelZoo
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
  struct Progress {
    var step: Int
    var total: Int?
    var message: String
    /// Queued behind other runs, not started yet.
    var isQueued = false
  }

  /// One `generate` run. A run outlives the call that started it: `background` returns its id
  /// at once, and a waiting call whose client hangs up leaves it running for `get_job`.
  @MainActor
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
    var task: Task<Void, Never>?
    /// The waiting call's progress stream, while there is one.
    var onProgress: ((Progress) -> Void)?

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

  struct ToolError: LocalizedError {
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
        "Returns what's on Atelier's Create screen right now: the selected model, prompt, negative prompt, seed and whether it's random, the image count, every inspector setting as Draw Things configuration JSON, the settings that differ from the model's defaults, and how many reference images there are. The user may have changed any of it since your last call.",
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
        prompt, negative prompt, settings and (unless Random is on) seed.
        """,
      "inputSchema": [
        "type": "object",
        "properties": [
          "prompt": ["type": "string", "description": "Required, unless use_app_settings is true: then it defaults to the Create screen's prompt."],
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
          "background": ["type": "boolean", "description": "Return a job_id right away instead of waiting for the result, then check on it with get_job. Use it for videos and anything that may take more than a couple of minutes, since some clients give up on long calls."],
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
      "description": "Lists generate jobs from the last hour, newest first: job_id, status, progress, elapsed time and prompt. A generate call that timed out or lost its connection keeps running and shows here.",
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
    // Without a prompt, use_app_settings generates the Create screen as it is.
    let fromScreen = arguments["use_app_settings"] as? Bool == true && arguments["prompt"] == nil
    let prompt = fromScreen ? create.prompt : arguments["prompt"] as? String ?? ""
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ToolError(fromScreen ? "The Create screen's prompt is empty." : "`prompt` is required.")
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

    let negativePrompt = arguments["negative_prompt"] as? String ?? (fromScreen ? create.negativePrompt : "")
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
    if let clip = item.clip {
      structured["frames"] = clip.frames.count
      structured["frames_per_second"] = clip.framesPerSecond
      structured["has_audio"] = clip.audioId != nil
    }
    return ["content": content, "structuredContent": structured]
  }

  // MARK: - Jobs

  /// Runs generate as a job. In the background it answers with the job id once the arguments
  /// check out; otherwise it waits for the result, streaming progress. Only cancelling this call
  /// (or cancel_job) stops the run: a client that just hangs up leaves it going.
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
      while !job.accepted { try? await Task.sleep(for: .milliseconds(50)) }
      if let error = job.error { throw ToolError(error) }
      var summary = Self.summary(job)
      summary["note"] = "Running in the background. Call get_job with this job_id to wait for it."
      return try Self.textResult(json: summary)
    }
    await withTaskCancellationHandler {
      _ = await job.task?.value
    } onCancel: {
      Task { @MainActor in job.task?.cancel() }
    }
    job.onProgress = nil
    return try Self.outcome(of: job)
  }

  private func getJob(_ arguments: [String: Any], progress: @escaping (Progress) -> Void) async throws -> [String: Any] {
    let job = try job(arguments)
    let wait = Double(min(max(Self.int(arguments["wait_seconds"]) ?? 30, 0), 60))
    let deadline = Date().addingTimeInterval(wait)
    var reported = -1
    while job.finishedAt == nil, Date() < deadline, !Task.isCancelled {
      if job.progress.step != reported {
        reported = job.progress.step
        progress(job.progress)
      }
      try? await Task.sleep(for: .milliseconds(250))
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
      "seed": Int(create.seed),
      "random_seed": !create.seedLocked,
      "count": create.count,
      "settings": create.settings == nil ? NSNull() : Self.jsonObject(DrawThingsJSON.encode(all, model: nil, seed: nil)),
      "changed_from_defaults": Self.jsonObject(DrawThingsJSON.encode(changed, model: nil, seed: nil)),
      "reference_images": create.moodboard.items.count,
      "layout_editor": create.layout != nil ? "open" : create.layoutFormat == nil ? "not available for this model" : "closed",
      "canvas_has_image": create.image != nil,
      "busy": create.workUnderway ?? NSNull(),
    ]
  }

  private func setCreateScreen(_ arguments: [String: Any]) async throws -> [String: Any] {
    if create.models.isEmpty { await create.refreshModelList() }
    let undoManager = Self.mainWindowUndoManager
    var notes: [String] = []

    if let name = arguments["model"] as? String {
      let model = try resolveModel(name)
      if model != create.selectedModel { create.selectedModel = model }
    }
    await create.modelLoaded()
    guard let model = create.selectedModel else { throw ToolError("No model is downloaded.") }

    if let name = arguments["preset"] as? String {
      // This model's or a shared preset first, else one for another downloaded model.
      let named = presets.presets.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
      guard
        let preset = named.first(where: { $0.model == nil || $0.model == model })
          ?? named.first(where: { preset in create.models.contains { $0.file == preset.model } })
      else { throw ToolError("No preset “\(name)” for a downloaded model. See list_presets.") }
      create.apply(preset, undoManager: undoManager)
      await create.modelLoaded()
    } else if arguments["reset_settings"] as? Bool == true {
      create.resetToModelDefaults(undoManager: undoManager)
    }

    guard var configuration = create.settings else {
      throw ToolError(create.errorMessage ?? "\(model)'s settings didn't load.")
    }
    var changed = false
    if let settings = arguments["settings"] as? [String: Any], !settings.isEmpty {
      let data = try JSONSerialization.data(withJSONObject: settings)
      guard let pasted = DrawThingsJSON.decode(data) else {
        throw ToolError("None of the keys in `settings` are settings Atelier knows. See get_create_screen.")
      }
      SettingsRegistry.apply(dump: pasted.dump, to: &configuration)
      changed = true
      let ignored = settings.keys.filter { pasted.dump[$0] == nil && $0 != "model" && $0 != "seed" }
      if !ignored.isEmpty { notes.append("Ignored unknown settings: \(ignored.sorted().joined(separator: ", ")).") }
    }
    let width = Self.int(arguments["width"])
    let height = Self.int(arguments["height"])
    if width != nil || height != nil {
      configuration.width = Self.roundTo64(width ?? configuration.width)
      configuration.height = Self.roundTo64(height ?? configuration.height)
      changed = true
    }
    if let steps = Self.int(arguments["steps"]) {
      configuration.steps = max(steps, 1)
      changed = true
    }
    if let guidance = Self.double(arguments["guidance_scale"]) {
      configuration.guidanceScale = Float(guidance)
      changed = true
    }
    if let strength = Self.double(arguments["strength"]) {
      configuration.strength = Float(min(max(strength, 0), 1))
      changed = true
    }
    let frames = Self.int(arguments["num_frames"])
    let seconds = Self.double(arguments["seconds"])
    if frames != nil || seconds != nil {
      if let video = VideoModel(model: model, loras: configuration.loras.compactMap(\.file)) {
        configuration.numFrames = video.snapped(frames ?? Int((seconds! * video.framesPerSecond).rounded()) + 1)
        changed = true
      } else {
        notes.append("\(model) isn't a video model, so num_frames and seconds were ignored.")
      }
    }
    if changed {
      create.replaceSettings(with: configuration, actionName: "Agent Settings", undoManager: undoManager)
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

    var result = createScreen()
    if !notes.isEmpty { result["notes"] = notes }
    return try Self.textResult(json: result)
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
  private static var mainWindowUndoManager: UndoManager? {
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }?.undoManager
  }

  // MARK: - Helpers

  /// The model's recommended settings with its default preset, as Create starts from.
  private func defaults(for model: String) async throws -> PipelineConfiguration {
    let template = try await create.engine.loadPipeline(for: model)
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
    var folder = fileManager.temporaryDirectory.appending(path: "Atelier", directoryHint: .isDirectory)
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
