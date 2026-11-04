@preconcurrency import _MediaGenerationKit
import CoreGraphics
import Foundation

/// Where a job runs. Saved with queued jobs, so what's queued for a server stays queued for it.
nonisolated enum JobTarget: Codable, Hashable, Sendable {
  /// This device's `GenerationEngine`.
  case local
  /// A paired server.
  case remote(serverID: UUID)
}

/// What Create, the Queue and agents ask of whatever runs a job. `GenerationEngine` is the local
/// one. What belongs to the machine rather than the job (its models folders, the engine check,
/// its turn and queue) stays on `GenerationEngine`.
nonisolated protocol GenerationBackend: Sendable {
  func generate(
    _ request: GenerationEngine.Request,
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output

  /// Upscales a clip's `frames` as `request.upscale` says.
  func upscale(
    _ request: GenerationEngine.Request, frames: [CGImage],
    progress: @escaping @Sendable (GenerationEngine.Progress) -> Void
  ) async throws -> GenerationEngine.Output

  /// The model's default settings.
  func loadPipeline(for model: String) async throws -> PipelineConfiguration

  /// Writes `composition`'s frames, upscaled, into a video at `url`, without its sound; `progress`
  /// runs from 0 to 1. Encoding happens on this device wherever the upscaling does. Cancelling the
  /// task stops it.
  func writeUpscaledVideo(
    of composition: TimelineComposition, to url: URL, codec: VideoCodec, upscale: TimelineUpscale,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws

  /// The models that can run here.
  func downloadedModels() async -> [MediaGenerationResolvedModel]
}

extension GenerationEngine: GenerationBackend {}
