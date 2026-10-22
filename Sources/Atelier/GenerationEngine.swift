import CoreGraphics
import Foundation
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
  }

  enum Progress: Sendable {
    case state(MediaGenerationPipeline.State)
    case preview(CGImage, step: Int, totalSteps: Int)
  }

  private var pipeline: MediaGenerationPipeline?

  /// Points MGK's default environment at `directory` and drops any cached pipeline.
  func setModelsDirectory(_ directory: String) {
    MediaGenerationEnvironment.default.externalUrls = [
      URL(fileURLWithPath: directory, isDirectory: true)
    ]
    pipeline = nil
  }

  /// Models from the catalog (built-in plus custom.json) whose files are in the models directory.
  func downloadedModels() -> [MediaGenerationResolvedModel] {
    let models =
      (try? MediaGenerationEnvironment.default.downloadableModels(
        includeDownloaded: true, offline: true)) ?? []
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
    pipeline.configuration = request.configuration
    pipeline.configuration.seed = request.seed
    pipeline.configuration.batchCount = 1
    pipeline.configuration.batchSize = 1
    let results = try await pipeline.generate(
      prompt: request.prompt,
      negativePrompt: request.negativePrompt,
      stateHandler: Self.stateHandler(forwardingTo: progress)
    )
    guard let result = results.first else {
      throw MediaGenerationKitError.generationFailed("No image was returned")
    }
    return result
  }

  /// Tiny-autoencoder archives the engine force-loads from Bundle.main to decode previews
  /// (`ImageConverter+CoreML.swift`). Decoding a preview without them traps, so previews are
  /// only requested when every archive is bundled (Scripts/package_app.sh copies them).
  private static let taeArchives = [
    "flux_1_tae", "flux_2_tae", "ltx_2.3_tae", "ltx_2_tae", "minimax_h3_tae",
    "qwen_image_2.1_tae", "qwenimage_tae", "sd3_tae", "sd_tae", "sdxl_tae", "wan_2.1_tae",
  ]

  nonisolated static let previewsAvailable = taeArchives.allSatisfy {
    Bundle.main.url(forResource: $0, withExtension: "zip") != nil
  }

  /// MGK calls the state handler on its own generation queue, so build it outside the actor.
  private nonisolated static func stateHandler(
    forwardingTo progress: @escaping @Sendable (Progress) -> Void
  ) -> @Sendable (MediaGenerationPipeline.State, MediaGenerationPipeline.Preview?) -> Void {
    { state, preview in
      progress(.state(state))
      if previewsAvailable, let preview, !preview.isEmpty,
        case .generating(let step, let total) = state
      {
        progress(.preview(preview[0], step: step, totalSteps: total))
      }
    }
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
