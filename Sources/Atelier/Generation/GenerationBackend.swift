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
/// the turn an upscaled timeline export takes on the engine) stays on `GenerationEngine`.
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

  /// The models that can run here.
  func downloadedModels() async -> [MediaGenerationResolvedModel]
}

extension GenerationEngine: GenerationBackend {}
