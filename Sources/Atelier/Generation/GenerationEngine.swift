import CoreGraphics
import Dflat
import Diffusion
import Foundation
import LocalImageGenerator
import NNC
import _MediaGenerationKit

/// Owns a cached pipeline for the current model and runs one generation at a time.
actor GenerationEngine {
  struct Request: Sendable {
    var model: String
    var prompt: String
    var negativePrompt: String
    var seed: UInt32
    /// Every setting for this run, taken from the inspector when the job started.
    var configuration: PipelineConfiguration
    /// Edit mode: the canvas frame rendered at the output size, transparent where the image
    /// doesn't cover it (the engine turns those pixels into the inpaint mask).
    var canvas: CGImage?
    /// The image brought in from outside that `canvas` was made from, saved as an Imported step.
    var importedInput: CGImage?
    /// Moodboard images sent as references (weight above zero only).
    var moodboard: [Reference] = []
  }

  struct Reference: Sendable {
    var image: CGImage
    var weight: Float
  }

  enum Progress: Sendable {
    case state(MediaGenerationPipeline.State)
    case preview(CGImage, step: Int, totalSteps: Int)
  }

  private var pipeline: MediaGenerationPipeline?
  /// The model and image inputs (canvas, then moodboard sizes) of the last run, see
  /// `dropCachedModelsIfInputsChanged`.
  private var lastImageInputs: (model: String, canvas: Bool, sizes: [[Int]])?

  /// Points MGK's default environment at `directory` and drops any cached pipeline.
  func setModelsDirectory(_ directory: String) {
    MediaGenerationEnvironment.default.externalUrls = [
      URL(fileURLWithPath: directory, isDirectory: true)
    ]
    pipeline = nil
  }

  /// Points MGK at `directory` unless it already is, keeping the cached pipeline.
  func useModelsDirectory(_ directory: String) {
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    if MediaGenerationEnvironment.default.externalUrls != [url] {
      setModelsDirectory(directory)
    }
  }

  /// Models from the catalog (built-in plus custom.json) whose files are in the models directory.
  /// Includes the community catalog (fetched once, then cached): the offline list alone misses
  /// downloaded community models such as Krea 2 and Ideogram 4.
  func downloadedModels() async -> [MediaGenerationResolvedModel] {
    let models = await MediaGenerationEnvironment.default.downloadableModels(
      includeDownloaded: true, offline: false)
    return models.filter(\.isDownloaded).sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Loads (or reuses) the pipeline for `model` and returns its recommended configuration.
  func loadPipeline(for model: String) async throws -> MediaGenerationPipeline.Configuration {
    try await pipeline(for: model).configuration
  }

  func generate(
    _ request: Request,
    progress: @escaping @Sendable (Progress) -> Void
  ) async throws -> MediaGenerationPipeline.Result {
    var pipeline = try await pipeline(for: request.model)
    await applyPerformanceSettings(using: pipeline)
    dropCachedModelsIfInputsChanged(request)
    pipeline.configuration = request.configuration
    pipeline.configuration.seed = request.seed
    pipeline.configuration.batchCount = 1
    pipeline.configuration.batchSize = 1
    // MGK takes encoded images; PNG keeps the canvas's transparency.
    var inputs: [MediaGenerationPipeline.Input] = []
    if let canvas = request.canvas {
      guard let png = ImageTensor.png(canvas) else { throw ProjectError.badImage }
      inputs.append(MediaGenerationPipeline.data(png))
    }
    for reference in request.moodboard {
      guard let png = ImageTensor.png(reference.image) else { throw ProjectError.badImage }
      inputs.append(MediaGenerationPipeline.data(png).moodboard())
    }
    let results = try await pipeline.generate(
      prompt: request.prompt,
      negativePrompt: request.negativePrompt,
      inputs: inputs,
      stateHandler: Self.stateHandler(
        forwardingTo: progress,
        size: CGSize(width: request.configuration.width, height: request.configuration.height))
    )
    guard let result = results.first else {
      throw MediaGenerationKitError.generationFailed("No image was returned")
    }
    return result
  }

  /// Hands the Performance settings to the engine through the same workspace dictionary Draw
  /// Things writes them to. Its model preloader subscribes to those keys and applies a change
  /// (dropping cached weights when needed) on the generation queue, ahead of the next run.
  private func applyPerformanceSettings(using pipeline: MediaGenerationPipeline) async {
    if Self.engineWorkspace() == nil {
      // MGK creates the engine on the first generation. Make it now with a run that fails before
      // loading anything (a moodboard image that doesn't decode), so even the first real run gets
      // these settings: the preloader reads them when it subscribes, as the engine starts.
      var warmUp = pipeline
      warmUp.configuration.steps = 1
      _ = try? await warmUp.generate(
        prompt: "", negativePrompt: "",
        inputs: [MediaGenerationPipeline.data(Data([0])).moodboard()])
    }
    guard var dictionary = Self.engineWorkspace()?.dictionary else { return }
    // Setting an unchanged value is a no-op in Dflat, so this only acts on changes.
    for setting in PerformanceSetting.allCases {
      dictionary[setting.rawValue, Int.self] = setting.value
    }
  }

  /// Engine workaround: some models build different layers depending on the images sent.
  /// Flux.3 adds its reference layers (embedder, refiner block, modulations) only when a run has
  /// references, but the weights cache keeps the model's weights under the model file either way.
  /// After a run without references, the next run with them finds the cache, skips reading the
  /// file and leaves the reference layers unloaded: the canvas is ignored or the result is a
  /// patchwork of tiles. The model preloader likewise reuses a model compiled for other inputs
  /// (`ModelPreloader.retrieveUNet` doesn't compare them). So when the images sent change, empty
  /// both: set the weights cache and "keep model in memory" to 0 and back.
  private func dropCachedModelsIfInputsChanged(_ request: Request) {
    let images = [request.canvas].compactMap { $0 } + request.moodboard.map(\.image)
    let inputs = (
      model: request.model, canvas: request.canvas != nil,
      sizes: images.map { [$0.width, $0.height] }
    )
    defer { lastImageInputs = inputs }
    guard let last = lastImageInputs, last.model == inputs.model,
      last.canvas != inputs.canvas || last.sizes != inputs.sizes,
      var dictionary = Self.engineWorkspace()?.dictionary
    else { return }
    // The preloader applies each change in order on the generation queue, ahead of this run.
    for key in ["total_weights_cache", "keep_model_in_memory"] {
      let value = dictionary[key, Int.self]
      dictionary[key, Int.self] = 0
      dictionary[key, Int.self] = value
    }
  }

  /// The workspace MGK's local engine was built with. MGK keeps it internal
  /// (`MediaGenerationEnvironment.Storage.cachedLocalResources.generator`), so it's read by
  /// reflection; nil until the engine exists.
  private static func engineWorkspace() -> Workspace? {
    let storage = reflectedChild(MediaGenerationEnvironment.default, "storage")
    let resources = storage.flatMap { reflectedChild($0, "cachedLocalResources") }
    let generator = resources.flatMap { reflectedChild($0, "generator") } as? LocalImageGenerator
    return generator.flatMap { reflectedChild($0.modelPreloader, "workspace") } as? Workspace
  }

  /// The stored property `label` of `value`, with an Optional unwrapped (nil when it's .none).
  private nonisolated static func reflectedChild(_ value: Any, _ label: String) -> Any? {
    var mirror: Mirror? = Mirror(reflecting: value)
    while let current = mirror {
      if let child = current.children.first(where: { $0.label == label }) {
        let wrapped = Mirror(reflecting: child.value)
        return wrapped.displayStyle == .optional ? wrapped.children.first?.value : child.value
      }
      mirror = current.superclassMirror
    }
    return nil
  }

  /// Tiny-autoencoder archives the engine force-loads from Bundle.main to decode previews
  /// (`ImageConverter+CoreML.swift`). Decoding a preview without them traps, so previews are
  /// only requested when every archive is bundled (a build phase copies them from Draw Things.app).
  private static let taeArchives = [
    "flux_1_tae", "flux_2_tae", "ltx_2.3_tae", "ltx_2_tae", "minimax_h3_tae",
    "qwen_image_2.1_tae", "qwenimage_tae", "sd3_tae", "sd_tae", "sdxl_tae", "wan_2.1_tae",
  ]

  nonisolated static let previewsAvailable = taeArchives.allSatisfy {
    Bundle.main.url(forResource: $0, withExtension: "zip") != nil
  }

  /// MGK calls the state handler on its own generation queue, so build it outside the actor.
  private nonisolated static func stateHandler(
    forwardingTo progress: @escaping @Sendable (Progress) -> Void,
    size: CGSize
  ) -> @Sendable (MediaGenerationPipeline.State, MediaGenerationPipeline.Preview?) -> Void {
    let highResolution = previewsAvailable && PerformanceSetting.highResolutionPreview
    return { state, preview in
      progress(.state(state))
      guard let preview, !preview.isEmpty, case .generating(let step, let total) = state else {
        return
      }
      if highResolution {
        progress(.preview(preview[0], step: step, totalSteps: total))
      } else if let image = lowResolutionPreview(preview, size: size) {
        progress(.preview(image, step: step, totalSteps: total))
      }
    }
  }

  /// The engine's quick preview straight from the latent (no autoencoder), scaled up to the
  /// output size so the canvas treats it like a full preview. MGK's `Preview` always decodes with
  /// TAESD, so its latent and model version are read by reflection.
  private nonisolated static func lowResolutionPreview(
    _ preview: MediaGenerationPipeline.Preview, size: CGSize
  ) -> CGImage? {
    guard let tensor = reflectedChild(preview, "tensor") as? Tensor<FloatType>,
      let version = reflectedChild(preview, "version") as? ModelVersion,
      let image = ImageConverter.cgImages(fromLatent: tensor, canUseTAESD: false, version: version)
        .0.first
    else { return nil }
    let width = Int(size.width), height = Int(size.height)
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return image }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
  }

  private func pipeline(for model: String) async throws -> MediaGenerationPipeline {
    if let pipeline, pipeline.model == model {
      return pipeline
    }
    let loaded = try await MediaGenerationPipeline.fromPretrained(model, backend: .local)
    pipeline = loaded
    return loaded
  }
}
