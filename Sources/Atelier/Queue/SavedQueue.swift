import CoreGraphics
import Foundation

/// The waiting jobs (and the one running) kept across a quit, in
/// ~/Library/Application Support/Atelier/Queue/: index.json plus each job's canvas and moodboard
/// images as PNG. They come back paused. Agents' jobs aren't kept: nobody waits for them anymore.
nonisolated enum SavedQueue {
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
    /// An upscale job's method, scale and source clip.
    var upscale: ClipUpscale?
    /// An image upscale job's model and scale; its image is the canvas.
    var imageUpscale: ImageUpscale?
    /// Where it runs. Optional because queues saved before there was a choice don't have it.
    var target: JobTarget?
    /// The canvas mask's codes, beside it as `-mask.png` (`Request.mask`).
    var hasMask: Bool?
    /// How the result merges back into its source image, which is beside it as `-source.png`.
    var merge: RefineMerge.Record?
    /// The mask the canvas image remembers (`Request.canvasSourceMask`).
    var canvasSourceMask: CanvasSourceMask?
    /// A Match Colors to Original job: the step and its project, which it reads from and saves
    /// into whichever project is open.
    var colorMatch: ColorMatch.Job?
  }

  /// A saved job, before its settings are put back on its model's defaults.
  struct Job {
    var model: String
    var settings: [String: JSONValue]
    fileprivate var entry: Entry
    fileprivate var canvas: CGImage?
    fileprivate var mask: Data?
    fileprivate var mergeSource: CGImage?
    fileprivate var moodboard: [GenerationEngine.Reference]
    fileprivate var sameProject: Bool

    var target: JobTarget { entry.target ?? .local }
    var colorMatch: ColorMatch.Job? { entry.colorMatch }

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
        request.mask = mask
        if let record = entry.merge, let mergeSource {
          request.merge = RefineMerge(record: record, source: mergeSource, sameProject: sameProject)
          request.canvasTensorId = request.merge?.sourceTensorId
        }
        request.canvasSourceMask = entry.canvasSourceMask.map { mask in
          var mask = mask
          if !sameProject { mask.tensorId = nil }
          return mask
        }
      }
      request.moodboard = moodboard
      request.audio = entry.audio.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
      request.placement = sameProject ? entry.placement : nil
      request.upscale = entry.upscale
      request.imageUpscale = entry.imageUpscale
      // It names its own project, so its step follows it there whichever project this is.
      request.colorMatch = entry.colorMatch
      if entry.colorMatch != nil { request.parentTensorId = entry.parentTensorId }
      return request
    }
  }

  static var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Atelier/Queue", directoryHint: .isDirectory)
  }

  static func save(_ jobs: [JobQueue.Job], project: String, in folder: URL = folder) {
    let manager = FileManager.default
    try? manager.removeItem(at: folder)
    // Exports write where a save panel allowed for this session only, so they aren't kept, and
    // agent, paired device and style thumbnail jobs answer a caller that's gone after a quit.
    // A job for a server isn't kept here either: bringing it back would run it on this device.
    // Once sent, `RemoteClientJobs` keeps it.
    let jobs = jobs.filter {
      !$0.fromAgent && $0.remoteDevice == nil && $0.styleThumbnail == nil && $0.request != nil && $0.target == .local
    }
    guard !jobs.isEmpty, (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
    else { return }
    var entries: [Entry] = []
    for job in jobs {
      guard let request = job.request else { continue }
      var settings = request.configuration
      settings.seed = request.seed
      if let canvas = request.canvas {
        guard let png = ImageTensor.png(canvas) else { continue }
        Log.attempt(Log.queue, "Saving a queued job's canvas") {
          try png.write(to: folder.appending(path: "\(job.id)-canvas.png"))
        }
      }
      if let mask = request.mask {
        Log.attempt(Log.queue, "Saving a queued job's mask") {
          try mask.write(to: folder.appending(path: "\(job.id)-mask.png"))
        }
      }
      // Without its source image the job still runs; its result just isn't merged back.
      var mergeRecord: RefineMerge.Record?
      if let merge = request.merge, let png = ImageTensor.png(merge.source) {
        let failure = Log.attempt(Log.queue, "Saving a queued job's source image") {
          try png.write(to: folder.appending(path: "\(job.id)-source.png"))
        }
        if failure == nil { mergeRecord = merge.record }
      }
      for (index, reference) in request.moodboard.enumerated() {
        Log.attempt(Log.queue, "Saving a queued job's moodboard") {
          try ImageTensor.png(reference.image)?.write(to: folder.appending(path: "\(job.id)-moodboard-\(index).png"))
        }
      }
      entries.append(
        Entry(
          id: job.id, model: request.model, prompt: request.prompt,
          negativePrompt: request.negativePrompt, seed: request.seed,
          settings: JSONValue.fields(of: settings), project: project,
          parentTensorId: request.parentTensorId, hasCanvas: request.canvas != nil,
          canvasTensorId: request.canvasTensorId, canvasIsImported: request.canvasIsImported,
          moodboardWeights: request.moodboard.map(\.weight), audio: request.audio,
          placement: request.placement, upscale: request.upscale, imageUpscale: request.imageUpscale,
          target: job.target, hasMask: request.mask != nil, merge: mergeRecord,
          canvasSourceMask: request.canvasSourceMask, colorMatch: request.colorMatch))
    }
    if let data = try? JSONEncoder().encode(entries) {
      Log.attempt(Log.queue, "Saving the queue") {
        try data.write(to: folder.appending(path: "index.json"))
      }
    }
  }

  /// The saved jobs, then forgets them. Step ids only carry over in the same project.
  static func load(project: String, from folder: URL = folder) -> [Job] {
    guard let data = try? Data(contentsOf: folder.appending(path: "index.json")),
          let entries = try? JSONDecoder().decode([Entry].self, from: data)
    else { return [] }
    let jobs = entries.compactMap { entry -> Job? in
      // An upscale's source clip is a step of its own project. A Match Colors job names its
      // project, so it comes back in any.
      if entry.upscale != nil, entry.project != project { return nil }
      var canvas: CGImage?
      if entry.hasCanvas {
        canvas = ImageLoader.image(at: folder.appending(path: "\(entry.id)-canvas.png"))
        if canvas == nil { return nil }
      }
      let mask = entry.hasMask == true ? try? Data(contentsOf: folder.appending(path: "\(entry.id)-mask.png")) : nil
      if entry.hasMask == true, mask == nil { return nil }
      let mergeSource = entry.merge != nil ? ImageLoader.image(at: folder.appending(path: "\(entry.id)-source.png")) : nil
      if entry.merge != nil, mergeSource == nil { return nil }
      let moodboard = entry.moodboardWeights.enumerated().compactMap { index, weight in
        ImageLoader.image(at: folder.appending(path: "\(entry.id)-moodboard-\(index).png"))
          .map { GenerationEngine.Reference(image: $0, weight: weight) }
      }
      return Job(
        model: entry.model, settings: entry.settings, entry: entry, canvas: canvas, mask: mask,
        mergeSource: mergeSource, moodboard: moodboard, sameProject: entry.project == project)
    }
    try? FileManager.default.removeItem(at: folder)
    return jobs
  }
}
