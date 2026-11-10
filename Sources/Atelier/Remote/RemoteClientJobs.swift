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
  /// The canvas mask's codes, beside it as `-mask.png`.
  var hasMask: Bool? = nil
  /// How the result merges into its source image, beside it as `-source.png`.
  var merge: RefineMerge.Record? = nil
  /// The mask the canvas image remembers (`Request.canvasSourceMask`).
  var canvasSourceMask: CanvasSourceMask? = nil
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
      placement: request.placement, hasMask: request.mask != nil, merge: request.merge?.record,
      canvasSourceMask: request.canvasSourceMask)
    Log.attempt(Log.remote, "Keeping a remote job") {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      if let canvas = request.canvas { try ImageTensor.png(canvas)?.write(to: url(job, "-canvas.png")) }
      if let mask = request.mask { try mask.write(to: url(job, "-mask.png")) }
      if let source = request.merge?.source { try ImageTensor.png(source)?.write(to: url(job, "-source.png")) }
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

  func mask(of job: RemoteClientJob) -> Data? {
    job.hasMask == true ? try? Data(contentsOf: url(job.jobID, "-mask.png")) : nil
  }

  func mergeSource(of job: RemoteClientJob) -> CGImage? {
    job.merge != nil ? ImageLoader.image(at: url(job.jobID, "-source.png")) : nil
  }

  func moodboard(of job: RemoteClientJob) -> [GenerationEngine.Reference] {
    job.moodboardWeights.enumerated().compactMap { index, weight in
      ImageLoader.image(at: url(job.jobID, "-moodboard-\(index).png"))
        .map { GenerationEngine.Reference(image: $0, weight: weight) }
    }
  }

  // Which server made which clip here, so upscaling it there can skip sending its frames.

  private struct ClipRecord: Codable, Hashable {
    var tensorId: Int64
    var project: String
    var server: UUID
    var job: UUID
    var savedAt: Date
  }

  private var clipIndex: URL { folder.deletingLastPathComponent().appending(path: "ClipIndex.json") }

  private func clipRecords() -> [ClipRecord] {
    (try? Data(contentsOf: clipIndex)).flatMap { try? JSONDecoder().decode([ClipRecord].self, from: $0) } ?? []
  }

  func rememberClip(tensorId: Int64, project: String, server: UUID, job: UUID) {
    // Past its retention the server won't have it either.
    let cutoff = Date().addingTimeInterval(-RemoteProtocol.retention)
    var records = clipRecords().filter { $0.savedAt > cutoff }
    records.append(ClipRecord(tensorId: tensorId, project: project, server: server, job: job, savedAt: Date()))
    Log.attempt(Log.remote, "Remembering a clip's server") {
      try FileManager.default.createDirectory(at: clipIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(records).write(to: clipIndex, options: .atomic)
    }
  }

  /// The job that made this clip on `server`, if it did.
  func clip(tensorId: Int64, project: String, server: UUID) -> UUID? {
    clipRecords().last { $0.tensorId == tensorId && $0.project == project && $0.server == server }?.job
  }

  func remove(_ job: UUID) {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.lastPathComponent.hasPrefix(job.uuidString) {
      try? FileManager.default.removeItem(at: file)
    }
  }
}
