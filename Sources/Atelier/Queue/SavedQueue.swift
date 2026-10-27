import CoreGraphics
import Foundation

/// The waiting jobs (and the one running) kept across a quit, in
/// ~/Library/Application Support/Atelier/Queue/: index.json plus each job's canvas and moodboard
/// images as PNG. They come back paused. Agents' jobs aren't kept: nobody waits for them anymore.
enum SavedQueue {
  fileprivate struct Entry: Codable {
    var id: UUID
    var model: String
    var prompt: String
    var negativePrompt: String
    var seed: UInt32
    /// Every setting, in the history sidecar's dump format.
    var settings: [String: JSONValue]
    /// The project the step ids below belong to.
    var project: String
    var parentTensorId: Int64?
    var hasCanvas: Bool
    var canvasTensorId: Int64?
    var canvasIsImported: Bool
    var moodboardWeights: [Float]
    /// The audio file's copy (`AudioClip.snapshot`), kept where it is.
    var audio: URL?
    /// Where a run from a timeline frame goes (`TimelinePlacement`).
    var placement: TimelinePlacement?
  }

  /// A saved job, before its settings are put back on its model's defaults.
  struct Job {
    var model: String
    var settings: [String: JSONValue]
    fileprivate var entry: Entry
    fileprivate var canvas: CGImage?
    fileprivate var moodboard: [GenerationEngine.Reference]
    fileprivate var sameProject: Bool

    /// The job's request, with `configuration` (the model's defaults with `settings` applied).
    func request(configuration: PipelineConfiguration) -> GenerationEngine.Request {
      var request = GenerationEngine.Request(
        model: entry.model, prompt: entry.prompt, negativePrompt: entry.negativePrompt,
        seed: entry.seed, configuration: configuration)
      request.parentTensorId = sameProject ? entry.parentTensorId : nil
      request.canvas = canvas
      if canvas != nil {
        request.canvasTensorId = sameProject ? entry.canvasTensorId : nil
        request.canvasIsImported = entry.canvasIsImported
      }
      request.moodboard = moodboard
      request.audio = entry.audio.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
      request.placement = sameProject ? entry.placement : nil
      return request
    }
  }

  static var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Atelier/Queue", directoryHint: .isDirectory)
  }

  static func save(_ jobs: [JobQueue.Job], project: String, in folder: URL = folder) {
    let manager = FileManager.default
    try? manager.removeItem(at: folder)
    let jobs = jobs.filter { !$0.fromAgent }
    guard !jobs.isEmpty, (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
    else { return }
    var entries: [Entry] = []
    for job in jobs {
      let request = job.request
      var settings = request.configuration
      settings.seed = request.seed
      if let canvas = request.canvas {
        guard let png = ImageTensor.png(canvas) else { continue }
        try? png.write(to: folder.appending(path: "\(job.id)-canvas.png"))
      }
      for (index, reference) in request.moodboard.enumerated() {
        try? ImageTensor.png(reference.image)?.write(to: folder.appending(path: "\(job.id)-moodboard-\(index).png"))
      }
      entries.append(
        Entry(
          id: job.id, model: request.model, prompt: request.prompt,
          negativePrompt: request.negativePrompt, seed: request.seed,
          settings: JSONValue.fields(of: settings), project: project,
          parentTensorId: request.parentTensorId, hasCanvas: request.canvas != nil,
          canvasTensorId: request.canvasTensorId, canvasIsImported: request.canvasIsImported,
          moodboardWeights: request.moodboard.map(\.weight), audio: request.audio,
          placement: request.placement))
    }
    if let data = try? JSONEncoder().encode(entries) {
      try? data.write(to: folder.appending(path: "index.json"))
    }
  }

  /// The saved jobs, then forgets them. Step ids only carry over in the same project.
  static func load(project: String, from folder: URL = folder) -> [Job] {
    guard let data = try? Data(contentsOf: folder.appending(path: "index.json")),
      let entries = try? JSONDecoder().decode([Entry].self, from: data)
    else { return [] }
    let jobs = entries.compactMap { entry -> Job? in
      var canvas: CGImage?
      if entry.hasCanvas {
        canvas = ImageLoader.image(at: folder.appending(path: "\(entry.id)-canvas.png"))
        if canvas == nil { return nil }
      }
      let moodboard = entry.moodboardWeights.enumerated().compactMap { index, weight in
        ImageLoader.image(at: folder.appending(path: "\(entry.id)-moodboard-\(index).png"))
          .map { GenerationEngine.Reference(image: $0, weight: weight) }
      }
      return Job(
        model: entry.model, settings: entry.settings, entry: entry, canvas: canvas,
        moodboard: moodboard, sameProject: entry.project == project)
    }
    try? FileManager.default.removeItem(at: folder)
    return jobs
  }
}
