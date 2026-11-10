@preconcurrency import _MediaGenerationKit
@preconcurrency import AudioConverter
import CoreGraphics
@preconcurrency import DataModels
@preconcurrency import Dflat
@preconcurrency import Diffusion
import Foundation
@preconcurrency import ImageGenerator
@preconcurrency import LocalImageGenerator
@preconcurrency import ModelZoo
@preconcurrency import NNC
import Synchronization
@preconcurrency import Upscaler

/// Owns a cached pipeline for the current model and runs one generation at a time.
actor GenerationEngine {
  nonisolated struct Request: Sendable {
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
    /// Edit mode with a painted mask: the frame's mask codes as a PNG at the output size
    /// (`CanvasMask.frameMask`), sent as MGK's `.mask()` input. Set with `canvas`.
    var mask: Data?
    /// Merge the result back into the canvas image it was refined from (`CanvasMerge`), on the
    /// device whose project holds it. Set with `canvas` (`setRefineInputs`).
    var merge: RefineMerge?
    /// Moodboard images sent as references (weight above zero only).
    var moodboard: [Reference] = []
    /// An audio file for video models that take one (`VideoModel.takesAudio`), kept by
    /// `AudioInputStore`.
    var audio: URL?
    /// Started from a timeline frame: where the result goes on the timeline.
    var placement: TimelinePlacement?
    /// Upscales a clip instead of generating (see `upscale(_:frames:progress:)`).
    var upscale: ClipUpscale?
    /// Upscales `canvas` instead of generating (`CreateModel`'s `upscaled(image:as:request:progress:)`).
    var imageUpscale: ImageUpscale?
  }

  /// What a run made: one frame for an image, every frame of a clip and its soundtrack for video.
  nonisolated struct Output: Sendable {
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

  nonisolated struct Reference: Sendable {
    var image: CGImage
    var weight: Float
  }

  nonisolated enum Progress: Sendable {
    case state(MediaGenerationPipeline.State)
    case preview(CGImage, step: Int, totalSteps: Int)
    /// A video run's preview: one image per latent frame, played as a flip-book.
    case previewFrames([CGImage], step: Int, totalSteps: Int)
  }

  private var pipeline: MediaGenerationPipeline?
  /// The model and image inputs (canvas, then moodboard sizes) of the last run, see
  /// `dropCachedModelsIfInputsChanged`.
  private var lastImageInputs: (model: String, canvas: Bool, mask: Bool, sizes: [[Int]])?

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

  /// Points MGK's default environment at the models folders (a file is looked up in each, in
  /// order, and downloads go to the first), loads their custom.json and custom_lora.json, and
  /// drops any cached pipeline.
  func setModelsDirectories(_ directories: [String]) async {
    let urls = directories.map { URL(fileURLWithPath: $0, isDirectory: true) }
    MediaGenerationEnvironment.default.externalUrls = urls
    pipeline = nil
    await ModelLibrary.loadCustomSpecifications(in: urls)
  }

  /// Points MGK at the models folders unless it already is, keeping the cached pipeline.
  func useModelsDirectories(_ directories: [String]) async {
    let urls = directories.map { URL(fileURLWithPath: $0, isDirectory: true) }
    if MediaGenerationEnvironment.default.externalUrls != urls {
      await setModelsDirectories(directories)
    }
  }

  /// Models from the catalog (built-in plus custom.json) whose files are in the models folders.
  /// Includes the community catalog (fetched once, then cached): the offline list alone misses
  /// downloaded community models such as Krea 2 and Ideogram 4.
  func downloadedModels() async -> [MediaGenerationResolvedModel] {
    let models = await CommunityCatalog.models()
    return models.filter(\.isDownloaded).sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Loads (or reuses) the pipeline for `model` and returns its recommended configuration.
  func loadPipeline(for model: String) async throws -> PipelineConfiguration {
    try await PipelineConfiguration(pipeline(for: model).configuration)
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
    pipeline.configuration = request.configuration.base
    pipeline.configuration.seed = request.seed
    pipeline.configuration.batchCount = 1
    pipeline.configuration.batchSize = 1
    // MGK takes encoded images; PNG keeps the canvas's transparency.
    var inputs: [MediaGenerationPipeline.Input] = []
    if let canvas = request.canvas {
      guard let png = ImageTensor.png(canvas) else { throw ProjectError.badImage }
      inputs.append(MediaGenerationPipeline.data(png))
      if let mask = request.mask { inputs.append(MediaGenerationPipeline.data(mask).mask()) }
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
            Self.reflected($0, "recommendedTemplate", as: GenerationConfiguration.self)
          })
    else { return nil }
    let version = video.version
    var settings = request.configuration
    settings.seed = request.seed
    settings.batchCount = 1
    settings.batchSize = 1
    settings.numFrames = video.snapped(settings.numFrames)
    // The engine returns nothing, with no reason, when LongCat is missing any of these: only its
    // no-CFG path is wired (`isCfgEnabled`), and it needs an image and a voice to animate.
    if version == .longcatVideoAvatar1_5 {
      settings.guidanceScale = 1
      guard request.canvas != nil, request.audio != nil else {
        throw MediaGenerationKitError.generationFailed(
          "LongCat needs a portrait on the canvas and an audio file to lip-sync to.")
      }
    }
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
      try await ModelLibrary.downloadAudioEncoder(for: request.model) { _, _, _ in }
    }

    let highResolution = Self.previewsAvailable && PerformanceSetting.highResolutionPreview
    let size = CGSize(width: settings.width, height: settings.height)
    let totalSteps = settings.steps
    let cancellation = EngineCancellation()
    let previews = PreviewDecoder()
    let prompt = request.prompt
    let negativePrompt = request.negativePrompt
    progress(.state(.preparing))
    let engineHints = hints
    let result: EngineResult = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        engine.queue.async {
          let result = engine.generator.generate(
            trace: ImageGeneratorTrace(fromBridge: true), image: image, scaleFactor: 1, mask: nil,
            hints: engineHints, text: prompt, negativeText: negativePrompt, configuration: configuration,
            fileMapping: [:], keywords: [],
            cancellation: { cancel in
              // Made to be called from another thread (MGK's bridge does), but not typed @Sendable.
              nonisolated(unsafe) let cancel = cancel
              cancellation.set { cancel() }
            },
            feedback: { signpost, _, latent in
              guard !cancellation.isCancelled else { return false }
              let state = Self.state(for: signpost, totalSteps: totalSteps)
              progress(.state(state))
              // Sampling is over (the engine reports one past the last step, then decodes): a
              // preview still waiting would only compete with decoding the video for the GPU and
              // Neural Engine, and the video replaces it moments later.
              switch signpost {
              case .sampling(let step) where step < totalSteps: break
              case .textEncoded, .imageEncoded, .controlsGenerated: break
              default: previews.close()
              }
              // The engine waits on this callback, and decoding a long video's preview takes
              // seconds (~4 s for 124 H3 frames with the tiny autoencoder), so it's decoded on
              // the preview queue instead. The latent is the engine's own CPU copy for this step
              // (`unet.decode(…).rawValue.toCPU()`), so it stays valid after the callback returns.
              if let latent, case .generating(let step, let total) = state {
                nonisolated(unsafe) let latent = latent
                previews.submit {
                  let frames = Self.previewFrames(
                    latent, version: version, highResolution: highResolution, size: size)
                  guard !frames.isEmpty else { return }
                  previews.deliver { progress(.previewFrames(frames, step: step, totalSteps: total)) }
                }
              }
              return !cancellation.isCancelled
            })
          previews.close()
          cancellation.finish()
          if cancellation.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            continuation.resume(returning: EngineResult(frames: result.0, audio: result.1))
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
    let frames = (result.frames ?? []).flatMap(Self.frames(of:))
    guard !frames.isEmpty else {
      throw MediaGenerationKitError.generationFailed("No video was returned")
    }
    var audio = result.audio?.first
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

  // MARK: - Upscale

  /// Upscales an image with an ESRGAN model alone, as a strength 0 run does once it has loaded its
  /// model and encoded its prompt (`LocalImageGenerator.upscaleImageAndToCPU`), so it needs neither.
  func upscale(
    image: CGImage, model file: String, scale: Int, progress: @escaping @Sendable (Progress) -> Void
  ) async throws -> Output {
    await waitForTurn()
    defer { endTurn() }
    try Task.checkCancellation()
    progress(.state(.preparing))
    guard UpscalerZoo.isModelDownloaded(file), let tensor = ImageTensor.tensor(from: image) else {
      throw ProjectError.badImage
    }
    let upscaler = RealESRGANer<FloatType>(
      filePath: UpscalerZoo.filePathForModelDownloaded(file),
      nativeScaleFactor: UpscalerZoo.scaleFactorForModel(file),
      forcedScaleFactor: scale == 2 ? .x2 : .x4,
      numberOfBlocks: UpscalerZoo.numberOfBlocksForModel(file),
      isNHWCPreferred: DeviceCapability.isNHWCPreferred,
      tileSize: DeviceCapability.RealESRGANerTileSize)
    return try await onEngineQueue { _ in
      let graph = DynamicGraph()
      let result = graph.withNoGrad {
        upscaler.upscale(graph.variable(tensor.toGPU(0))).0.rawValue.toCPU()
      }
      return Output(frames: [result])
    }
  }

  /// Upscales a clip's `frames` as `request.upscale` says, to `request.configuration`'s size
  /// (FlashVSR+, with the request's seed) or by its scale (Apple Super Resolution).
  func upscale(
    _ request: Request, frames: [CGImage],
    progress: @escaping @Sendable (Progress) -> Void
  ) async throws -> Output {
    guard let upscale = request.upscale, let first = frames.first else { throw ProjectError.badImage }
    await waitForTurn()
    defer { endTurn() }
    try Task.checkCancellation()
    progress(.state(.preparing))
    switch upscale.method {
    case .system:
      let images = try await SystemSuperResolution.run(
        count: frames.count, width: first.width, height: first.height, scale: upscale.scale,
        input: upscale.isImage == true ? .image : .video,
        frame: { frames[$0] }
      ) { done, total, image in
        guard let image else { return progress(.state(.preparing)) }
        progress(.state(.generating(step: done, totalSteps: total)))
        progress(.preview(image, step: done, totalSteps: total))
      }
      let tensors = images.compactMap(ImageTensor.tensor(from:))
      guard tensors.count == frames.count else { throw ProjectError.badImage }
      return Output(frames: tensors)
    case .flashVSR:
      guard let files = FlashVSRFiles.installed(upscale.variant ?? .turbo) else {
        throw FlashVSRFiles.Failure.missing
      }
      let upscaler = FlashVSRUpscaler(
        files: files, width: request.configuration.width, height: request.configuration.height,
        seed: UInt64(request.seed))
      return try await onEngineQueue { shouldContinue in
        var tensors: [Tensor<FloatType>] = []
        try upscaler.run(
          count: frames.count, frame: { frames[$0] },
          progress: { phase, done, total in
            progress(.state(phase == .loading ? .preparing : .generating(step: done, totalSteps: total)))
          },
          shouldContinue: shouldContinue
        ) { tensors.append($0) }
        return Output(frames: tensors)
      }
    }
  }

  /// Upscales a timeline into a video file as `TimelineComposition.exportUpscaled` wants it, in the
  /// engine's turn, so never alongside a generation.
  func writeUpscaledVideo(
    of composition: TimelineComposition, to url: URL, codec: VideoCodec, upscale: TimelineUpscale,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let frames = Double(max(composition.frameCount, 1))
    try await inTurn {
      switch upscale.method {
      case .system:
        try await composition.writeWithSystemSuperResolution(to: url, codec: codec, scale: upscale.scale) {
          progress(Double($0) / frames)
        }
      case .flashVSR:
        try await self.onEngineQueue { shouldContinue in
          try composition.writeWithFlashVSR(to: url, codec: codec, upscale: upscale, shouldContinue: shouldContinue) {
            progress(Double($0) / frames)
          }
        }
      }
    }
  }

  /// Runs `work` in the engine's turn, so it never runs alongside a generation.
  private func inTurn<T: Sendable>(_ work: @concurrent @Sendable () async throws -> T) async throws -> T {
    await waitForTurn()
    defer { endTurn() }
    try Task.checkCancellation()
    return try await work()
  }

  /// Runs `work`, which moves model files between the models folders, in the engine's turn with
  /// nothing loaded from them: the cached pipeline and the weights the engine keeps in memory go
  /// first, and the run after waits. Then points MGK at `directories` again, rereading their
  /// custom.json and custom_lora.json, which a move changes, before that run.
  func movingModelFiles<T: Sendable>(
    reloading directories: [String], _ work: @concurrent @Sendable () async throws -> T
  ) async throws -> T {
    await waitForTurn()
    defer { endTurn() }
    pipeline = nil
    // Applies the cache drop on the generation queue, where the preloader holds the weights.
    try await onEngineQueue { _ in }
    do {
      let result = try await work()
      await setModelsDirectories(directories)
      return result
    } catch {
      await setModelsDirectories(directories)
      throw error
    }
  }

  /// Runs `work` on the engine's queue after dropping the models the engine keeps loaded, which
  /// FlashVSR+ needs the memory of. Call it in the engine's turn. `work` checks `shouldContinue`,
  /// which turns false when the task is cancelled.
  private func onEngineQueue<T: Sendable>(
    _ work: @escaping @Sendable (_ shouldContinue: @escaping () -> Bool) throws -> T
  ) async throws -> T {
    if var dictionary = Self.engineWorkspace()?.dictionary {
      for key in ["total_weights_cache", "keep_model_in_memory"] {
        let value = dictionary[key, Int.self]
        dictionary[key, Int.self] = 0
        dictionary[key, Int.self] = value
      }
    }
    lastImageInputs = nil
    // The engine's queue, so this never runs alongside another model.
    let queue = Self.engineResources()?.queue ?? DispatchQueue(label: "Atelier.upscale")
    let cancellation = EngineCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            continuation.resume(returning: try work { !cancellation.isCancelled })
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
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
    guard let generator = resources.flatMap({ reflected($0, "generator", as: LocalImageGenerator.self) }),
          let queue = resources.flatMap({ reflected($0, "queue", as: DispatchQueue.self) })
    else { return nil }
    return (generator, queue)
  }

  /// The folder MGK made for this run's engine (`MediaGenerationLocalResources.tempDir`), once
  /// there is one.
  nonisolated static var temporaryDirectory: URL? {
    let storage = reflectedChild(MediaGenerationEnvironment.default, "storage")
    let resources = storage.flatMap { reflectedChild($0, "cachedLocalResources") }
    guard let path = resources.flatMap({ reflected($0, "tempDir", as: String.self) }) else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  #if os(iOS)
    /// Tells the engine a run is under way. MGK doesn't, and without it `ModelPreloader` answers
    /// going to the background by starting a UIKit background task that waits for the generation
    /// queue: with a run on that queue the task can't end, so iPadOS ends the app about 30 seconds
    /// later. False until the engine exists (MGK creates it on the first run).
    @MainActor static func setEngineGenerating(_ isGenerating: Bool) -> Bool {
      guard let generator = engineResources()?.generator else { return false }
      if isGenerating { generator.startGenerating() } else { generator.stopGenerating() }
      return true
    }
  #endif

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
    let images = [request.canvas].compactMap(\.self) + request.moodboard.map(\.image)
    let inputs = (
      model: request.model, canvas: request.canvas != nil, mask: request.mask != nil,
      sizes: images.map { [$0.width, $0.height] }
    )
    defer { lastImageInputs = inputs }
    guard let last = lastImageInputs, last.model == inputs.model,
          last.canvas != inputs.canvas || last.mask != inputs.mask || last.sizes != inputs.sizes,
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
    engineResources().flatMap { reflected($0.generator.modelPreloader, "workspace", as: Workspace.self) }
  }

  /// Engine fields reported missing so far, so each is logged once.
  private nonisolated static let reportedFields = Mutex<Set<String>>([])

  /// Logs once that a field read by reflection isn't what the engine has any more: previews,
  /// sound or Performance settings stop working without an error, until the code here is updated.
  private nonisolated static func reportMissing(_ field: String) {
    guard reportedFields.withLock({ $0.insert(field).inserted }) else { return }
    Log.engine.fault("Engine field \(field, privacy: .public) is missing or changed type. Run --engine-check.")
  }

  /// `reflectedChild` as a `T`. A value of another type is reported as missing.
  private nonisolated static func reflected<T>(_ value: Any, _ label: String, as _: T.Type) -> T? {
    guard let child = reflectedChild(value, label) else { return nil }
    if let typed = child as? T { return typed }
    reportMissing("\(type(of: value)).\(label) as \(T.self)")
    return nil
  }

  /// One reflected field, for `--engine-check`.
  struct ReflectedField: Sendable {
    var name: String
    var found: Bool
  }

  /// Runs `steps` steps of `model` and tries every field read by reflection, for `--engine-check`.
  func checkReflectedFields(model: String, steps: Int) async throws -> [ReflectedField] {
    await waitForTurn()
    defer { endTurn() }
    var pipeline = try await pipeline(for: model)
    await applyPerformanceSettings(using: pipeline)
    pipeline.configuration.steps = steps
    pipeline.configuration.seed = 1
    pipeline.configuration.batchCount = 1
    pipeline.configuration.batchSize = 1
    pipeline.configuration.width = 512
    pipeline.configuration.height = 512
    let previewFields = Mutex<[ReflectedField]?>(nil)
    _ = try await pipeline.generate(
      prompt: "a dot", negativePrompt: "", inputs: [],
      stateHandler: { _, preview in
        guard let preview else { return }
        let fields = [
          ReflectedField(
            name: "Preview.tensor", found: Self.reflected(preview, "tensor", as: Tensor<FloatType>.self) != nil),
          ReflectedField(
            name: "Preview.version", found: Self.reflected(preview, "version", as: ModelVersion.self) != nil),
        ]
        previewFields.withLock { if $0 == nil { $0 = fields } }
      })
    let storage = Self.reflectedChild(MediaGenerationEnvironment.default, "storage")
    let resources = storage.flatMap { Self.reflectedChild($0, "cachedLocalResources") }
    let generator = resources.flatMap { Self.reflected($0, "generator", as: LocalImageGenerator.self) }
    var fields = [
      ReflectedField(name: "MediaGenerationEnvironment.storage", found: storage != nil),
      ReflectedField(name: "storage.cachedLocalResources", found: resources != nil),
      ReflectedField(name: "resources.generator", found: generator != nil),
      ReflectedField(
        name: "resources.queue",
        found: resources.flatMap { Self.reflected($0, "queue", as: DispatchQueue.self) } != nil),
      ReflectedField(
        name: "resources.tempDir",
        found: resources.flatMap { Self.reflected($0, "tempDir", as: String.self) } != nil),
      ReflectedField(name: "modelPreloader.workspace", found: Self.engineWorkspace() != nil),
      ReflectedField(
        name: "pipeline.storage.recommendedTemplate",
        found: Self.reflectedChild(pipeline, "storage").flatMap {
          Self.reflected($0, "recommendedTemplate", as: GenerationConfiguration.self)
        } != nil),
    ]
    fields += previewFields.withLock { $0 } ?? [ReflectedField(name: "a preview arrived", found: false)]
    return fields
  }

  /// The stored property `label` of `value`, with an Optional unwrapped (nil when it's .none).
  /// A label that isn't there is reported; an Optional that's nil isn't: the engine's resources
  /// are nil until the first run.
  private nonisolated static func reflectedChild(_ value: Any, _ label: String) -> Any? {
    var mirror: Mirror? = Mirror(reflecting: value)
    while let current = mirror {
      if let child = current.children.first(where: { $0.label == label }) {
        let wrapped = Mirror(reflecting: child.value)
        return wrapped.displayStyle == .optional ? wrapped.children.first?.value : child.value
      }
      mirror = current.superclassMirror
    }
    reportMissing("\(type(of: value)).\(label)")
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
    guard let tensor = reflected(preview, "tensor", as: Tensor<FloatType>.self),
          let version = reflected(preview, "version", as: ModelVersion.self),
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

/// What a direct engine run returns, carried from the engine's queue back to the actor.
private nonisolated struct EngineResult: Sendable {
  var frames: [Tensor<FloatType>]?
  var audio: [Tensor<Float>]?
}

/// Decodes a direct run's step previews on a queue of their own, so the engine's step callback
/// returns at once. One decode runs at a time; a preview that arrives while one is decoding
/// replaces any still waiting, so a slow decode skips steps instead of queuing them up.
final nonisolated class PreviewDecoder: Sendable {
  private struct State {
    var waiting: (@Sendable () -> Void)?
    var decoding = false
    var closed = false
  }

  private let state = Mutex(State())
  private let queue = DispatchQueue(label: "Atelier.preview", qos: .userInitiated)

  func submit(_ work: @escaping @Sendable () -> Void) {
    let start = state.withLock {
      guard !$0.closed else { return false }
      $0.waiting = work
      guard !$0.decoding else { return false }
      $0.decoding = true
      return true
    }
    if start { queue.async { self.drain() } }
  }

  /// Runs `send` unless the run has ended, so no preview arrives after its result.
  /// (Sending under the lock keeps `close()` from slipping in between the check and the send.)
  func deliver(_ send: () -> Void) {
    state.withLock { if !$0.closed { send() } }
  }

  /// Drops any waiting preview and stops delivering; called when the run ends.
  func close() {
    state.withLock {
      $0.closed = true
      $0.waiting = nil
    }
  }

  private func drain() {
    while let work = state.withLock({ state -> (@Sendable () -> Void)? in
      let work = state.waiting
      state.waiting = nil
      if work == nil { state.decoding = false }
      return work
    }) {
      work()
    }
  }
}

/// Cancels a direct engine run (MGK's `MediaGenerationCancellationBridge`): the engine hands over
/// its cancel function once sampling starts, and the feedback callback stops it at the next step.
private final nonisolated class EngineCancellation: Sendable {
  private struct State {
    var cancelEngine: (@Sendable () -> Void)?
    var cancelled = false
    var finished = false
  }

  private let state = Mutex(State())

  var isCancelled: Bool { state.withLock { $0.cancelled } }

  func set(_ cancel: @escaping @Sendable () -> Void) {
    let cancelNow = state.withLock {
      $0.cancelEngine = cancel
      return $0.cancelled && !$0.finished
    }
    if cancelNow { cancel() }
  }

  func cancel() {
    let cancelEngine = state.withLock {
      $0.cancelled = true
      return $0.finished ? nil : $0.cancelEngine
    }
    cancelEngine?()
  }

  func finish() {
    state.withLock {
      $0.finished = true
      $0.cancelEngine = nil
    }
  }
}
