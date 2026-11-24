import CoreGraphics
import Foundation

/// The waiting jobs (and the one running) kept across a quit, in
/// ~/Library/Application Support/Atelier/Queue/: index.json plus each job's canvas and moodboard
/// images as PNG. They come back paused. Agents' jobs aren't kept: nobody waits for them anymore.
/// Each entry names its own project (`JobQueue.Job.project`), so it comes back into that project
/// with its step ids, whichever project is open at the next launch.
nonisolated enum SavedQueue {
  fileprivate struct Entry: Codable {
    var id: UUID
    var model: String
    var prompt: String
    var negativePrompt: String
    var seed: UInt32
    /// Every setting, in the history sidecar's dump format.
    var settings: [String: JSONValue]
    /// The project the job reads from and saves into, which the step ids below belong to.
    var project: String
    var parentTensorId: Int64?
    /// The line it was on (`JobQueue.Job.line`), when it followed one, and that line's latest step
    /// then: jobs of a line come back on one, after that step. Nil in queues saved before.
    var line: UUID?
    var lineTip: Int64?
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
    /// into.
    var colorMatch: ColorMatch.Job?
    /// An Edit screen job (`Edit.Job`): as `colorMatch`, it names its project. It carries the
    /// profile's real noise, the reference's histograms and the LUT it renders with in its
    /// `blobs`, embedded here (base64) rather than beside it: this file is temporary, removed when
    /// it's read back, and a job's data is bounded (a full profile's patches are about 830 KB, a
    /// 65³ LUT about 1.6 MB). Once saved, the step keeps them in its project's tensor store.
    var edit: Edit.Job?
    /// An Extract Depth Map job (`DepthMap.Job`): as `colorMatch`, it names its project.
    var depthMap: DepthMap.Job?
    /// H3 Ref2VA's reference video: the clip, a step of `project` (`Request.referenceVideo`). Its
    /// frames are read when the job starts.
    var referenceTensorId: Int64?
  }

  /// An entry, or nil for one that doesn't read (written by a later version, say), so one entry
  /// never loses the rest of the queue. An entry whose Match Colors or Edit job doesn't read is
  /// dropped rather than run as a generation.
  private struct LenientEntry: Decodable {
    var entry: Entry?
    init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
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

    var target: JobTarget { entry.target ?? .local }
    var colorMatch: ColorMatch.Job? { entry.colorMatch }
    var edit: Edit.Job? { entry.edit }
    var depthMap: DepthMap.Job? { entry.depthMap }
    /// The project it reads from and saves into.
    var project: String { entry.project }
    /// The line it was on, and that line's latest step (`Entry.line`); nil for a job naming its
    /// own step, and for queues saved before lines were kept.
    var line: (id: UUID, tip: Int64?)? { entry.line.map { ($0, entry.lineTip) } }

    /// The step it follows, one of its own project's.
    var parentTensorId: Int64? { entry.parentTensorId }

    /// The job's request, with `configuration` (the model's defaults with `settings` applied).
    func request(configuration: PipelineConfiguration) -> GenerationEngine.Request {
      var request = GenerationEngine.Request(
        model: entry.model, prompt: entry.prompt, negativePrompt: entry.negativePrompt,
        seed: entry.seed, configuration: configuration)
      request.parentTensorId = parentTensorId
      request.canvas = canvas
      if canvas != nil {
        request.canvasTensorId = entry.canvasTensorId
        request.canvasIsImported = entry.canvasIsImported
        request.mask = mask
        if let record = entry.merge, let mergeSource {
          request.merge = RefineMerge(record: record, source: mergeSource, sameProject: true)
          // With paint the input was the painted frame, saved anew (`RefineInputs.make`).
          request.canvasTensorId = request.merge?.painted == true ? nil : request.merge?.sourceTensorId
        }
        request.canvasSourceMask = entry.canvasSourceMask
      }
      request.moodboard = moodboard
      request.audio = entry.audio.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
      request.placement = entry.placement
      request.upscale = entry.upscale
      request.imageUpscale = entry.imageUpscale
      request.colorMatch = entry.colorMatch
      request.edit = entry.edit
      request.depthMap = entry.depthMap
      request.referenceVideo = entry.referenceTensorId.map { ReferenceVideo(sourceTensorId: $0, project: entry.project) }
      return request
    }
  }

  static var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Atelier/Queue", directoryHint: .isDirectory)
  }

  /// Keeps `jobs`, each with its own project. `lineTip` is the step a job on a line would follow
  /// now (`JobQueue.lineTip(of:)`), so its line comes back after it.
  static func save(_ jobs: [JobQueue.Job], lineTip: (JobQueue.Job) -> Int64?? = { _ in nil }, in folder: URL = folder) {
    let manager = FileManager.default
    try? manager.removeItem(at: folder)
    // Exports write where a save panel allowed for this session only, so they aren't kept, and
    // agent, paired device and style thumbnail jobs answer a caller that's gone after a quit.
    // A job for a server isn't kept here either: bringing it back would run it on this device.
    // Once sent, `RemoteClientJobs` keeps it. A detached job (an agent's, or one run again from
    // Recent) isn't kept: an entry doesn't say it's off the canvas. A job without a project
    // saves nowhere (`JobQueue.Job.project`).
    let jobs = jobs.filter {
      !$0.fromAgent && !$0.detached && $0.remoteDevice == nil && $0.styleThumbnail == nil && $0.request != nil
        && $0.target == .local && $0.project != nil
    }
    guard !jobs.isEmpty, (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
    else { return }
    var entries: [Entry] = []
    for job in jobs {
      guard let request = job.request, let project = job.project else { continue }
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
          canvasSourceMask: request.canvasSourceMask, colorMatch: request.colorMatch, edit: request.edit,
          depthMap: request.depthMap, referenceTensorId: request.referenceVideo?.sourceTensorId))
      if let line = job.line, request.parentTensorId == nil, let tip = lineTip(job) {
        entries[entries.count - 1].line = line
        entries[entries.count - 1].lineTip = tip
      }
    }
    if let data = try? JSONEncoder().encode(entries) {
      Log.attempt(Log.queue, "Saving the queue") {
        try data.write(to: folder.appending(path: "index.json"))
      }
    }
  }

  /// The saved jobs, then forgets them. Each keeps its own project and its step ids; one whose
  /// project is gone (deleted or renamed outside Atelier since, `projectExists`) is dropped,
  /// since its ids name nothing anywhere else.
  static func load(
    from folder: URL = folder,
    projectExists: (String) -> Bool = { FileManager.default.fileExists(atPath: HistoryStore.url(for: $0).path) }
  ) -> [Job] {
    guard let data = try? Data(contentsOf: folder.appending(path: "index.json")),
          let entries = (try? JSONDecoder().decode([LenientEntry].self, from: data))?.compactMap(\.entry)
    else { return [] }
    let jobs = entries.compactMap { entry -> Job? in
      // A name read from the file: one that couldn't be a project's names none.
      guard HistoryStore.isValidName(entry.project), projectExists(entry.project) else {
        Log.queue.notice("Dropped a saved job: its project “\(entry.project, privacy: .private)” is gone")
        return nil
      }
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
        mergeSource: mergeSource, moodboard: moodboard)
    }
    try? FileManager.default.removeItem(at: folder)
    return jobs
  }
}
