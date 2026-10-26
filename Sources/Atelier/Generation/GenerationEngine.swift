import AudioConverter
import CoreGraphics
import DataModels
import Dflat
import Diffusion
import Foundation
import ImageGenerator
import LocalImageGenerator
import ModelZoo
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
    /// The image of the project step that `canvas` is exactly (fitted, same size), if any: the
    /// result follows that step. When not set, the canvas is saved as a step of its own first.
    var canvasTensorId: Int64?
    /// The image of the project step the result follows (the current step when the run
    /// started); nil follows the newest step.
    var parentTensorId: Int64?
    /// The canvas image came from outside the project (saved as an Imported step).
    var canvasIsImported = false
    /// Identifies the canvas `canvas` was rendered from (image, placement and size), so queued
    /// runs from the same canvas save it as a step only once.
    var canvasKey: String?
    /// Moodboard images sent as references (weight above zero only).
    var moodboard: [Reference] = []
    /// An audio file for video models that take one (`VideoModel.takesAudio`), kept by
    /// `AudioInputStore`.
    var audio: URL?
  }

  /// What a run made: one frame for an image, every frame of a clip and its soundtrack for video.
  struct Output: @unchecked Sendable {
    var frames: [Tensor<FloatType>]
    /// PCM in [channels, samples] order at `audioSampleRate`.
    var audio: Tensor<Float>?
    var audioSampleRate: Int = 0
    /// Set for video; a clip plays at this rate.
    var framesPerSecond: Double?
    /// The audio file the run took (H3 Ref2VA, LongCat), resampled, kept with the clip.
    var audioInput: Tensor<Float>?

    var isVideo: Bool { framesPerSecond != nil }
  }

  struct Reference: Sendable {
    var image: CGImage
    var weight: Float
  }

  enum Progress: Sendable {
    case state(MediaGenerationPipeline.State)
    case preview(CGImage, step: Int, totalSteps: Int)
    /// A video run's preview: one image per latent frame, played as a flip-book.
    case previewFrames([CGImage], step: Int, totalSteps: Int)
  }

  private var pipeline: MediaGenerationPipeline?
  /// The model and image inputs (canvas, then moodboard sizes) of the last run, see
  /// `dropCachedModelsIfInputsChanged`.
  private var lastImageInputs: (model: String, canvas: Bool, sizes: [[Int]])?

  private var isRunning = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  private func waitForTurn() async {
    guard isRunning else {
      isRunning = true
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }

  /// Hands the engine to the next waiting run, if any.
  private func endTurn() {
    if waiting.isEmpty {
      isRunning = false
    } else {
      waiting.removeFirst().resume()
    }
  }

  /// Points MGK's default environment at `directory`, loads its custom.json, and drops any
  /// cached pipeline.
  func setModelsDirectory(_ directory: String) async {
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    MediaGenerationEnvironment.default.externalUrls = [url]
    pipeline = nil
    await ModelLibrary.loadCustomModels(in: url)
  }

  /// Points MGK at `directory` unless it already is, keeping the cached pipeline.
  func useModelsDirectory(_ directory: String) async {
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    if MediaGenerationEnvironment.default.externalUrls != [url] {
      await setModelsDirectory(directory)
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
  ) async throws -> Output {
    // Create and agents (AgentServer) share this engine. The actor alone would interleave two
    // runs at their awaits, so each waits its turn.
    await waitForTurn()
    defer { endTurn() }
    try Task.checkCancellation()
    var pipeline = try await pipeline(for: request.model)
    await applyPerformanceSettings(using: pipeline)
    dropCachedModelsIfInputsChanged(request)
    if let video = request.configuration.videoModel,
      let output = try await generateVideo(request, video: video, pipeline: pipeline, progress: progress)
    {
      return output
    }
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
    guard !results.isEmpty else {
      throw MediaGenerationKitError.generationFailed("No image was returned")
    }
    // A video model reaches here only when the engine couldn't be called directly: its frames
    // come back without sound.
    if let video = request.configuration.videoModel {
      return Output(
        frames: results.flatMap { Self.frames(of: $0.tensor) },
        framesPerSecond: Self.framesPerSecond(video, request.configuration))
    }
    return Output(frames: [results[0].tensor])
  }

  // MARK: - Video

  /// Runs a video model on MGK's own engine instance, past MGK, which keeps only the frames:
  /// `LocalImageGenerator.generate` takes an audio file as an `.audio` hint and returns the
  /// soundtrack LTX and MiniMax H3 make. Moodboard images go in with their weights, which MGK
  /// fixes at 1. Returns nil when MGK's engine or the model's template can't be found (MGK changed
  /// its internals), so the run falls back to MGK, without sound.
  private func generateVideo(
    _ request: Request, video: VideoModel, pipeline: MediaGenerationPipeline,
    progress: @escaping @Sendable (Progress) -> Void
  ) async throws -> Output? {
    guard let engine = Self.engineResources(),
      let template = Self.reflectedChild(pipeline, "storage").flatMap({
        Self.reflectedChild($0, "recommendedTemplate")
      }) as? GenerationConfiguration
    else { return nil }
    var settings = request.configuration
    settings.seed = request.seed
    settings.batchCount = 1
    settings.batchSize = 1
    settings.numFrames = video.snapped(settings.numFrames)
    let configuration = settings.engineConfiguration(template: template)

    // As MGK: the canvas is the image at the output size. Its transparency isn't a mask here:
    // the video models that take sound refuse a mask.
    let image = request.canvas.flatMap(ImageTensor.tensor(from:))
    var hints: [(ControlHintType, [(AnyTensor, Float)])] = []
    let shuffles: [(AnyTensor, Float)] = request.moodboard.compactMap { reference in
      ImageTensor.tensor(from: reference.image).map { ($0 as AnyTensor, reference.weight) }
    }
    if !shuffles.isEmpty { hints.append((.shuffle, shuffles)) }
    var audioInput: Tensor<Float>?
    if let url = request.audio, video.takesAudio {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let waveform = try AudioInput(contentsOf: url.path, sampleRate: video.audioSampleRate).waveform
      audioInput = waveform
      hints.append((.audio, [(waveform as AnyTensor, 1)]))
    }

    let highResolution = Self.previewsAvailable && PerformanceSetting.highResolutionPreview
    let size = CGSize(width: settings.width, height: settings.height)
    let version = video.version
    let totalSteps = settings.steps
    let cancellation = EngineCancellation()
    let prompt = request.prompt
    let negativePrompt = request.negativePrompt
    progress(.state(.preparing))
    let result: ([Tensor<FloatType>]?, [Tensor<Float>]?, Int) = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        engine.queue.async {
          let result = engine.generator.generate(
            trace: ImageGeneratorTrace(fromBridge: true), image: image, scaleFactor: 1, mask: nil,
            hints: hints, text: prompt, negativeText: negativePrompt, configuration: configuration,
            fileMapping: [:], keywords: [],
            cancellation: { cancellation.set($0) },
            feedback: { signpost, _, latent in
              guard !cancellation.isCancelled else { return false }
              let state = Self.state(for: signpost, totalSteps: totalSteps)
              progress(.state(state))
              if let latent, case .generating(let step, let total) = state {
                let frames = Self.previewFrames(
                  latent, version: version, highResolution: highResolution, size: size)
                if !frames.isEmpty { progress(.previewFrames(frames, step: step, totalSteps: total)) }
              }
              return !cancellation.isCancelled
            })
          cancellation.finish()
          if cancellation.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            continuation.resume(returning: result)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
    let frames = (result.0 ?? []).flatMap(Self.frames(of:))
    guard !frames.isEmpty else {
      throw MediaGenerationKitError.generationFailed("No video was returned")
    }
    var audio = result.1?.first
    let framesPerSecond = Self.framesPerSecond(video, settings)
    // LongCat lip-syncs to the voice it's given and makes no sound: the clip keeps that voice.
    if audio == nil, version == .longcatVideoAvatar1_5, let audioInput {
      audio = AudioInput(waveform: audioInput, sampleRate: video.audioSampleRate).waveformTensor(
        videoFrames: frames.count, framesPerSecond: max(Int(framesPerSecond.rounded()), 1))
    }
    return Output(
      frames: frames, audio: audio, audioSampleRate: video.audioSampleRate,
      framesPerSecond: framesPerSecond, audioInput: audioInput)
  }

  /// Stable Video Diffusion plays at its FPS setting; the others at the rate they were trained at.
  private static func framesPerSecond(_ video: VideoModel, _ settings: PipelineConfiguration) -> Double {
    video.version == .svdI2v ? Double(max(settings.fps, 1)) : video.framesPerSecond
  }

  /// A result tensor's frames: the engine returns one tensor per frame, or a batch of them.
  private static func frames(of tensor: Tensor<FloatType>) -> [Tensor<FloatType>] {
    let shape = tensor.shape
    guard shape.count == 4, shape[0] > 1 else { return [tensor] }
    return (0..<shape[0]).map { tensor[$0..<($0 + 1), 0..<shape[1], 0..<shape[2], 0..<shape[3]].copied() }
  }

  /// MGK's mapping of the engine's signposts (`MediaGenerationPipeline.State.init(signpost:)`).
  private nonisolated static func state(
    for signpost: ImageGeneratorSignpost, totalSteps: Int
  ) -> MediaGenerationPipeline.State {
    switch signpost {
    case .textEncoded: .encodingText
    case .imageEncoded, .controlsGenerated: .encodingInputs
    case .sampling(let step):
      .generating(step: min(max(step + 1, 1), max(totalSteps, 1)), totalSteps: totalSteps)
    case .imageDecoded: .decoding
    case .secondPassImageEncoded, .secondPassSampling, .secondPassImageDecoded, .faceRestored,
      .imageUpscaled:
      .postprocessing
    }
  }

  /// Every latent frame of a preview, decoded with the tiny autoencoder (High Resolution
  /// Preview) or straight from the latent and scaled to the output size.
  private nonisolated static func previewFrames(
    _ latent: Tensor<FloatType>, version: ModelVersion, highResolution: Bool, size: CGSize
  ) -> [CGImage] {
    let images = ImageConverter.cgImages(
      fromLatent: latent, canUseTAESD: highResolution, version: version
    ).0
    return highResolution ? images : images.map { scaled($0, to: size) ?? $0 }
  }

  /// The engine instance MGK built (`MediaGenerationEnvironment.Storage.cachedLocalResources`),
  /// with the queue it runs on; nil until the first run creates it.
  private static func engineResources() -> (generator: LocalImageGenerator, queue: DispatchQueue)? {
    let storage = reflectedChild(MediaGenerationEnvironment.default, "storage")
    let resources = storage.flatMap { reflectedChild($0, "cachedLocalResources") }
    guard let generator = resources.flatMap({ reflectedChild($0, "generator") }) as? LocalImageGenerator,
      let queue = resources.flatMap({ reflectedChild($0, "queue") }) as? DispatchQueue
    else { return nil }
    return (generator, queue)
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
    engineResources().flatMap { reflectedChild($0.generator.modelPreloader, "workspace") } as? Workspace
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
    return scaled(image, to: size) ?? image
  }

  private nonisolated static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
    let width = Int(size.width), height = Int(size.height)
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
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

/// Cancels a direct engine run (MGK's `MediaGenerationCancellationBridge`): the engine hands over
/// its cancel function once sampling starts, and the feedback callback stops it at the next step.
private final class EngineCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelEngine: (() -> Void)?
  private var cancelled = false
  private var finished = false

  var isCancelled: Bool { lock.withLock { cancelled } }

  func set(_ cancel: @escaping () -> Void) {
    let cancelNow = lock.withLock {
      cancelEngine = cancel
      return cancelled && !finished
    }
    if cancelNow { cancel() }
  }

  func cancel() {
    let cancelEngine = lock.withLock {
      cancelled = true
      return finished ? nil : self.cancelEngine
    }
    cancelEngine?()
  }

  func finish() {
    lock.withLock {
      finished = true
      cancelEngine = nil
    }
  }
}
