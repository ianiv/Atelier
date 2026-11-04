import CoreGraphics
import Foundation

/// A job this device sent to a server, kept on disk from before it's submitted until its result is
/// saved in the project, so a quit or crash in between doesn't lose it: the job carries on at the
/// server, and the next launch collects it. Everything a local run needs to save its result is
/// here, in one JSON file per job, with its canvas and moodboard beside it as PNGs.
nonisolated struct RemoteClientJob: Codable, Hashable, Sendable {
  var jobID: UUID
  var serverID: UUID
  /// The project the step ids below belong to.
  var project: String
  var model: String
  var prompt: String
  var negativePrompt: String
  var seed: UInt32
  /// Every setting, in the history sidecar's dump format.
  var settings: [String: JSONValue]
  var parentTensorId: Int64?
  var hasCanvas = false
  var canvasTensorId: Int64?
  var canvasIsImported = false
  var moodboardWeights: [Float] = []
  /// Where a run from a timeline frame goes.
  var placement: TimelinePlacement?
}

nonisolated struct RemoteClientJobs: Sendable {
  let folder: URL

  init(folder: URL = RemotePaths.root.appending(path: "ClientJobs", directoryHint: .isDirectory)) {
    self.folder = folder
  }

  private func url(_ job: UUID, _ suffix: String) -> URL { folder.appending(path: "\(job.uuidString)\(suffix)") }

  /// Saves what it takes to collect `request`'s result later. It's written before the job is
  /// submitted: the worst case is a record the server answers for by not knowing the job.
  @concurrent func add(_ request: GenerationEngine.Request, job: UUID, server: UUID, project: String) async {
    var settings = request.configuration
    settings.seed = request.seed
    let record = RemoteClientJob(
      jobID: job, serverID: server, project: project, model: request.model, prompt: request.prompt,
      negativePrompt: request.negativePrompt, seed: request.seed, settings: JSONValue.fields(of: settings),
      parentTensorId: request.parentTensorId, hasCanvas: request.canvas != nil, canvasTensorId: request.canvasTensorId,
      canvasIsImported: request.canvasIsImported, moodboardWeights: request.moodboard.map(\.weight),
      placement: request.placement)
    Log.attempt(Log.remote, "Keeping a remote job") {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      if let canvas = request.canvas { try ImageTensor.png(canvas)?.write(to: url(job, "-canvas.png")) }
      for (index, reference) in request.moodboard.enumerated() {
        try ImageTensor.png(reference.image)?.write(to: url(job, "-moodboard-\(index).png"))
      }
      // Last, so a record on disk always has its images.
      try JSONEncoder().encode(record).write(to: url(job, ".json"), options: .atomic)
    }
  }

  func all() -> [RemoteClientJob] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap {
      (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(RemoteClientJob.self, from: $0) }
    }
  }

  func canvas(of job: RemoteClientJob) -> CGImage? {
    job.hasCanvas ? ImageLoader.image(at: url(job.jobID, "-canvas.png")) : nil
  }

  func moodboard(of job: RemoteClientJob) -> [GenerationEngine.Reference] {
    job.moodboardWeights.enumerated().compactMap { index, weight in
      ImageLoader.image(at: url(job.jobID, "-moodboard-\(index).png"))
        .map { GenerationEngine.Reference(image: $0, weight: weight) }
    }
  }

  func remove(_ job: UUID) {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.lastPathComponent.hasPrefix(job.uuidString) {
      try? FileManager.default.removeItem(at: file)
    }
  }
}
