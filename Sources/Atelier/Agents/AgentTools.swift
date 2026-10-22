import CoreGraphics
import Foundation
import ImageIO
import ModelZoo
import Observation
import _MediaGenerationKit

/// The tools Atelier offers agents over MCP. Generation goes through the app's own engine (one
/// run at a time, shared with Create) and saves into the current project like a run from Create;
/// the Create screen's prompt, settings and canvas are left alone.
@MainActor
@Observable
final class AgentTools {
  struct Progress {
    var step: Int
    var total: Int?
    var message: String
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
        "Lists the image models downloaded in Atelier (file, name, family), which one is selected in the app, and whether each takes reference images (edit models, FLUX.2, Qwen Image 2.1).",
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
      "name": "generate",
      "title": "Generate image",
      "description": """
        Generates one image with Atelier's local engine and saves it to the current Atelier project \
        (it shows in the app's History). Returns the image, and writes a PNG with its settings \
        embedded. Runs wait for any generation already running in the app. Settings start from \
        the model's recommended settings and default preset, then `preset`, then `settings`, then \
        the explicit fields. With `input_image` the run edits that image (image to image); \
        `reference_images` go to models that take references (see list_models).
        """,
      "inputSchema": [
        "type": "object",
        "required": ["prompt"],
        "properties": [
          "prompt": ["type": "string"],
          "negative_prompt": ["type": "string"],
          "model": ["type": "string", "description": "Model file or name (see list_models). Defaults to the model selected in the app."],
          "preset": ["type": "string", "description": "Name of a saved preset to apply (see list_presets)."],
          "use_app_settings": ["type": "boolean", "description": "Start from the settings currently in Atelier's inspector instead of the model's defaults. Only when `model` is the app's selected model."],
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
          "save_to": ["type": "string", "description": "Where to write the PNG: a file path, or a folder. Defaults to a temporary folder."],
          "include_image": ["type": "boolean", "description": "Return the image inline (scaled to 1024 px on the long side). Default true."],
        ],
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
    case "generate": return try await generate(arguments, progress: progress)
    default: throw ToolError("Unknown tool \(name).")
    }
  }

  private func listModels() async -> [[String: Any]] {
    if create.models.isEmpty { await create.refreshModelList() }
    return imageModels.map {
      [
        "file": $0.file, "name": $0.name, "version": $0.version ?? NSNull(),
        "selected_in_app": $0.file == create.selectedModel,
        "takes_reference_images": takesReferences(model: $0.file, loras: []),
      ]
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
    guard let prompt = arguments["prompt"] as? String,
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw ToolError("`prompt` is required.") }
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

    let seed: UInt32
    if let value = Self.int(arguments["seed"]) {
      guard value >= 0, value <= Int(UInt32.max) else { throw ToolError("`seed` must be 0–4294967295.") }
      seed = UInt32(value)
    } else {
      seed = UInt32.random(in: 0...UInt32.max)
    }

    var request = GenerationEngine.Request(
      model: model, prompt: prompt, negativePrompt: arguments["negative_prompt"] as? String ?? "",
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

    let summary = String(prompt.prefix(60))
    activity = "Waiting: “\(summary)”"
    progress(Progress(step: 0, total: nil, message: "Waiting for the engine"))
    defer { activity = nil }
    let startedAt = Date()
    let result = try await create.engine.generate(request) { [weak self] update in
      let message: String
      var step = 0
      var total: Int?
      switch update {
      case .state(let state):
        message = Self.describe(state)
        if case .generating(let current, let all) = state {
          step = current
          total = all
        }
      case .preview:
        return
      }
      Task { @MainActor in
        self?.activity = "\(message): “\(summary)”"
        progress(Progress(step: step, total: total, message: message))
      }
    }
    let item = try await create.history.save(
      result, request: request, startedAt: startedAt, finishedAt: Date())
    let png = try await create.history.pngData(item)
    let url = try Self.outputURL(arguments["save_to"] as? String, name: create.history.fileName(for: item))
    try png.write(to: url)

    let project = create.history.project.name
    let seconds = item.sidecar.durationSeconds
    lastResult = "“\(summary)” saved to \(project) in \(GenerationTime.text(seconds))"
    var text =
      "Saved to Atelier project “\(project)” (step \(item.id.logicalTime)) and \(url.path).\n"
      + "Model \(model), \(configuration.width)×\(configuration.height), \(configuration.steps) steps, "
      + "guidance \(configuration.guidanceScale), seed \(seed), \(GenerationTime.text(seconds))."
    if !notes.isEmpty { text += "\n" + notes.joined(separator: "\n") }
    var content: [[String: Any]] = [["type": "text", "text": text]]
    if arguments["include_image"] as? Bool != false, let image = ImageLoader.image(from: png, maxSide: 1024),
      let preview = Self.jpeg(image)
    {
      content.append(["type": "image", "data": preview.base64EncodedString(), "mimeType": "image/jpeg"])
    }
    return [
      "content": content,
      "structuredContent": [
        "path": url.path, "project": project, "history_step": item.id.logicalTime, "model": model,
        "seed": Int(seed), "width": configuration.width, "height": configuration.height,
        "steps": configuration.steps, "duration_seconds": seconds,
      ],
    ]
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
    if let model = imageModels.first(where: { $0.file == name })
      ?? imageModels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    {
      return model.file
    }
    if create.models.contains(where: { $0.file == name || $0.name == name }) {
      throw ToolError("“\(name)” is a video model; agents can only make still images for now.")
    }
    throw ToolError("“\(name)” isn't a downloaded model. See list_models.")
  }

  /// Downloaded models that make still images (video models aren't offered to agents yet).
  private var imageModels: [MediaGenerationResolvedModel] {
    create.models.filter { !ModelTraits($0).isVideo }
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

  private static func outputURL(_ saveTo: String?, name: String) throws -> URL {
    let fileManager = FileManager.default
    var folder = fileManager.temporaryDirectory.appending(path: "Atelier", directoryHint: .isDirectory)
    if let saveTo, !saveTo.isEmpty {
      let url = URL(fileURLWithPath: (saveTo as NSString).expandingTildeInPath)
      var isDirectory: ObjCBool = false
      let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      if !(exists && isDirectory.boolValue) && !saveTo.hasSuffix("/") {
        try fileManager.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url.pathExtension.isEmpty ? url.appendingPathExtension("png") : url
      }
      folder = url
    }
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(path: name).appendingPathExtension("png")
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
