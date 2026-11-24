import Foundation
import Observation

/// Generations (with image and clip upscales and Match Colors to Original, which are
/// generation jobs too) and upscaled timeline exports waiting to run, the one running and the
/// recent ones, in order. Each generation holds its own snapshot of the prompt, settings, seed, canvas
/// and moodboard, taken when it was queued. CreateModel runs them one at a time.
@MainActor
@Observable
final class JobQueue {
  nonisolated struct Job: Identifiable {
    enum Status: Equatable {
      case waiting, running
      case finished(tensorId: Int64)
      /// A style thumbnail made; it isn't saved to the project.
      case madeThumbnail
      /// An export written to this file.
      case exported(URL)
      /// Ran for a paired device (`remoteDevice`); the result waits for it, not in the project.
      case ranForDevice
      case failed(String)
      case cancelled
    }

    /// What the job does.
    enum Work {
      case generation(GenerationEngine.Request)
      /// Export Upscaled Video… on a timeline.
      case export(TimelineExportJob)
    }

    var id = UUID()
    var work: Work
    /// Where it runs.
    var target: JobTarget
    var status = Status.waiting
    let queuedAt = Date()
    /// When it started running; nil while waiting, and for a job cancelled before it ran.
    var startedAt: Date?
    var finishedAt: Date?
    /// How long each phase took (local generations that finished).
    var timings: GenerationTimings?
    /// Queued by an agent over MCP.
    var fromAgent = false
    /// The name of the paired device this runs for (`RemoteServer`).
    var remoteDevice: String?
    /// Sent to its server before this launch: it picks up from there instead of being sent again.
    /// Its id is the id the server knows it by.
    var resumesRemoteJob = false
    /// Makes the thumbnail of the style with this name (Styles screen); not kept across quits.
    var styleThumbnail: String?
    /// Off-canvas: saved to the project, never shown. Its previews and result stay off the canvas
    /// and the current step stays where it is (`CreateModel.run`); it's on no line, following the
    /// step its request names.
    var detached = false
    /// The project the job reads from and saves into, whichever project is open when it runs or
    /// ends: every step and tensor id it holds is one of that project's. Set for every job that
    /// touches a project (`append` requires it); nil only for a paired device's job and a style
    /// thumbnail, which save nowhere. Kept current by `renameProject`.
    var project: String?
    /// Jobs queued one after another, while you didn't pick another step, form a line: each
    /// follows the line's latest result when it starts, whatever order they end up running in.
    var line: UUID?

    init(work: Work, target: JobTarget = .local, fromAgent: Bool = false) {
      self.work = work
      self.target = target
      self.fromAgent = fromAgent
    }

    init(request: GenerationEngine.Request, target: JobTarget = .local, fromAgent: Bool = false) {
      self.init(work: .generation(request), target: target, fromAgent: fromAgent)
    }

    /// The generation's request; nil for an export.
    var request: GenerationEngine.Request? {
      guard case .generation(let request) = work else { return nil }
      return request
    }

    /// How long it ran, once it's done (and if it ran).
    var elapsed: TimeInterval? {
      guard let startedAt, let finishedAt else { return nil }
      return finishedAt.timeIntervalSince(startedAt)
    }

    var export: TimelineExportJob? {
      guard case .export(let export) = work else { return nil }
      return export
    }
  }

  private(set) var waiting: [Job] = []
  /// The job running on this device: one at a time.
  private(set) var running: Job?
  /// Jobs running on servers, at most one per server. They don't hold this device's slot, since
  /// all they use here is the wait: a server runs its own jobs one at a time, whoever they're from.
  private(set) var runningRemote: [Job] = []
  /// Finished, failed and cancelled jobs, newest first.
  private(set) var recent: [Job] = []
  /// Holds the waiting jobs; the running one finishes.
  var isPaused = false
  /// Holds every waiting job, resumes too, without changing `isPaused`: the current project is
  /// being compacted (`CreateModel.compactProject`), and jobs save into it.
  var isHeld = false
  /// Input steps saved by finished Edit runs, by the canvas they were rendered from, so later
  /// jobs from the same canvas reuse the step instead of saving the canvas again.
  private var savedInputs: [String: Int64] = [:]
  /// The current step as the queue last left it: when queuing, or a result just saved. A
  /// different current step when queuing means you picked one, which starts a new line.
  private var expectedCurrent: Int64?
  /// The line jobs were last queued on, and each line's latest step.
  private var lastLine: UUID?
  private var lineTips: [UUID: Int64?] = [:]
  /// Each line's project: a line never continues into another project, since its tip is a step
  /// of its own.
  private var lineProject: [UUID: String?] = [:]
  /// The project `expectedCurrent` is a step of.
  private var expectedProject: String?
  /// Whether a project's jobs may be queued: not one being deleted (`HistoryStore.isBeingDeleted`),
  /// whose file would go from under them. Set by `CreateModel`.
  @ObservationIgnored var acceptsProject: (String) -> Bool = { _ in true }

  private static let recentLimit = 100

  var isEmpty: Bool { waiting.isEmpty && running == nil && runningRemote.isEmpty }

  /// Whether a waiting or running job uses `model`. A Match Colors to Original, Edit or Extract
  /// Depth Map job only names the model its step was made with; it never loads it.
  func uses(_ model: String) -> Bool {
    func uses(_ job: Job) -> Bool {
      job.request?.model == model && job.request?.colorMatch == nil && job.request?.edit == nil && job.request?.depthMap == nil
    }
    return running.map(uses) == true || waiting.contains(where: uses)
  }

  /// The waiting or running Match Colors to Original job for the same step and settings as
  /// `match`, if any.
  func pendingColorMatch(_ match: ColorMatch.Job) -> Job? {
    ((running.map { [$0] } ?? []) + waiting).first { $0.request?.colorMatch?.isSameMatch(as: match) == true }
  }

  /// The waiting or running Edit job for the same step and look as `edit` (`Edit.Job.isSameEdit`),
  /// if any.
  func pendingEdit(_ edit: Edit.Job) -> Job? {
    ((running.map { [$0] } ?? []) + waiting).first { $0.request?.edit?.isSameEdit(as: edit) == true }
  }

  /// The waiting or running Extract Depth Map job for the same image as `job`, if any.
  func pendingDepthMap(_ job: DepthMap.Job) -> Job? {
    ((running.map { [$0] } ?? []) + waiting).first { $0.request?.depthMap?.isSameJob(as: job) == true }
  }

  /// Every job of the project renamed from `old` follows it to `name`: waiting, running (here
  /// and on servers) and recent ones (their rows, Show in History, Run Again), with the project
  /// their request names inside (Match Colors, Edit, Extract Depth Map, a timeline placement, a
  /// reference video), and the lines and inputs kept for it.
  func renameProject(from old: String, to name: String) {
    guard old != name else { return }
    func relabel(_ job: inout Job) {
      guard job.project == old else { return }
      job.project = name
      guard case .generation(var request) = job.work else { return }
      if request.colorMatch?.project == old { request.colorMatch?.project = name }
      if request.edit?.project == old { request.edit?.project = name }
      if request.depthMap?.project == old { request.depthMap?.project = name }
      if request.placement?.project == old { request.placement?.project = name }
      if request.referenceVideo?.project == old { request.referenceVideo?.project = name }
      job.work = .generation(request)
    }
    for index in waiting.indices { relabel(&waiting[index]) }
    if running != nil { relabel(&running!) }
    for index in runningRemote.indices { relabel(&runningRemote[index]) }
    for index in recent.indices { relabel(&recent[index]) }
    for (line, project) in lineProject where project == old { lineProject[line] = name }
    if expectedProject == old { expectedProject = name }
    let prefix = Self.inputKey(project: old, canvas: "")
    for (key, value) in savedInputs where key.hasPrefix(prefix) {
      savedInputs[key] = nil
      savedInputs[Self.inputKey(project: name, canvas: String(key.dropFirst(prefix.count)))] = value
    }
  }

  /// The project job `id` reads from and saves into now (`Job.project`), renamed or not: a run
  /// holds a copy of its job from when it started, which a rename since doesn't reach.
  func projectName(of id: UUID) -> String? {
    if running?.id == id { return running?.project }
    if let job = runningRemote.first(where: { $0.id == id }) ?? waiting.first(where: { $0.id == id })
      ?? recent.first(where: { $0.id == id })
    {
      return job.project
    }
    return nil
  }

  /// The jobs yet to end (running here or on a server, or waiting) that read from and save into
  /// the project called `name`, of every kind, exports included.
  func jobs(in name: String) -> [Job] {
    unfinished.filter { $0.project == name }
  }

  /// `savedInputs`' key: an input step is one of its own project's.
  private static func inputKey(project: String?, canvas: String) -> String {
    "\(project ?? "")\u{0}\(canvas)"
  }

  /// The step a waiting job on a line follows when it starts, as the line stands now.
  func lineTip(of job: Job) -> Int64?? {
    job.line.flatMap { lineTips[$0] }
  }

  /// Records what a running Match Colors to Original job saved, so its row can say so whichever
  /// project is open.
  func setColorMatchRecord(_ record: ColorMatch.Record, id: UUID) {
    guard running?.id == id, case .generation(var request)? = running?.work else { return }
    request.colorMatch?.record = record
    running?.work = .generation(request)
  }

  /// Records what a running Edit job saved, as `setColorMatchRecord(_:id:)` does.
  func setEditRecord(_ record: Edit.Record, id: UUID) {
    guard running?.id == id, case .generation(var request)? = running?.work else { return }
    request.edit?.record = record
    running?.work = .generation(request)
  }

  /// Adds jobs at the end. Ones without a step to follow go on the line being queued, or start
  /// a new line after the current step when you picked another step since, or the line being
  /// queued is another project's. Returns their ids. `detached` jobs (`Job.detached`) are apart
  /// from the lines: they neither join one nor change what the next jobs queued follow.
  /// `project` is the one they read from and save into (`Job.project`), and `currentTensorId`
  /// that project's current step; nil only for a style thumbnail. None are added, and no ids
  /// returned, for a project being deleted (`acceptsProject`).
  @discardableResult
  func append(
    _ requests: [GenerationEngine.Request], currentTensorId: Int64?, target: JobTarget = .local,
    fromAgent: Bool = false, styleThumbnail: String? = nil, detached: Bool = false, project: String?
  ) -> [UUID] {
    if let project, !acceptsProject(project) { return [] }
    // Match Colors to Original, Edit and Extract Depth Map jobs read and save their own project's
    // steps, which only this device has: they always run here.
    func runsOn(_ request: GenerationEngine.Request) -> JobTarget {
      request.colorMatch != nil || request.edit != nil || request.depthMap != nil ? .local : target
    }
    if detached {
      for request in requests {
        var job = Job(request: request, target: runsOn(request), fromAgent: fromAgent)
        job.detached = true
        job.project = project
        waiting.append(job)
      }
      return waiting.suffix(requests.count).map(\.id)
    }
    // Jobs that each name the step they follow join no line, and leave the lines as they are: they
    // may be another project's than the open one, whose current step `currentTensorId` is.
    guard requests.contains(where: { $0.parentTensorId == nil }) else {
      for request in requests {
        var job = Job(request: request, target: runsOn(request), fromAgent: fromAgent)
        job.styleThumbnail = styleThumbnail
        job.project = project
        waiting.append(job)
      }
      return waiting.suffix(requests.count).map(\.id)
    }
    let line: UUID
    if let lastLine, !isEmpty, currentTensorId == expectedCurrent, project == expectedProject,
       lineProject[lastLine] == .some(project)
    {
      line = lastLine
    } else {
      line = UUID()
      lineTips[line] = currentTensorId
      lineProject[line] = project
      lastLine = line
    }
    expectedCurrent = currentTensorId
    expectedProject = project
    for request in requests {
      var job = Job(request: request, target: runsOn(request), fromAgent: fromAgent)
      job.styleThumbnail = styleThumbnail
      job.project = project
      if request.parentTensorId == nil { job.line = line }
      waiting.append(job)
    }
    return waiting.suffix(requests.count).map(\.id)
  }

  /// Adds a paired device's job at the end; returns its id. It isn't on a line: its result goes
  /// back to the device and never becomes a step here.
  func append(_ request: GenerationEngine.Request, remoteDevice: String) -> UUID {
    var job = Job(request: request)
    job.remoteDevice = remoteDevice
    waiting.append(job)
    return job.id
  }

  /// Adds a job sent to a server before this launch, unless it's already here. `project` is the
  /// one it was queued in, which its result is saved into.
  func appendResumed(_ request: GenerationEngine.Request, id: UUID, server: UUID, project: String) {
    guard running?.id != id, !runningRemote.contains(where: { $0.id == id }),
          !waiting.contains(where: { $0.id == id }), !recent.contains(where: { $0.id == id })
    else { return }
    var job = Job(request: request, target: .remote(serverID: server))
    job.id = id
    job.resumesRemoteJob = true
    job.project = project
    waiting.append(job)
  }

  /// Adds an export of a timeline of `project` at the end; returns its id, nil for a project
  /// being deleted (`acceptsProject`). It reads that project's clips (their cached videos).
  @discardableResult
  func append(_ export: TimelineExportJob, target: JobTarget = .local, project: String) -> UUID? {
    guard acceptsProject(project) else { return nil }
    var job = Job(work: .export(export), target: target)
    job.project = project
    waiting.append(job)
    return job.id
  }

  /// Takes the first job waiting for this device and marks it running, unless paused or one is
  /// running.
  func startNext() -> Job? {
    guard running == nil, !isPaused, !isHeld, let index = waiting.firstIndex(where: { $0.target == .local }) else { return nil }
    let job = started(waiting.remove(at: index))
    running = job
    return job
  }

  /// For each server not running a job of this device's, takes the first one waiting for it. Pause
  /// holds work yet to start; a job resuming at its server has started, so it goes ahead.
  func startRemote() -> [Job] {
    var busy = Set(runningRemote.map(\.target))
    var jobs: [Job] = []
    var index = 0
    while index < waiting.count {
      let job = waiting[index]
      if job.target != .local, !busy.contains(job.target), !isHeld, !isPaused || job.resumesRemoteJob {
        busy.insert(job.target)
        jobs.append(started(waiting.remove(at: index)))
      } else {
        index += 1
      }
    }
    runningRemote += jobs
    return jobs
  }

  private func started(_ job: Job) -> Job {
    var job = job
    if case .generation(var request) = job.work {
      if let line = job.line, let tip = lineTips[line] { request.parentTensorId = tip }
      if request.canvas != nil, request.canvasTensorId == nil, let key = request.canvasKey {
        request.canvasTensorId = savedInputs[Self.inputKey(project: job.project, canvas: key)]
      }
      job.work = .generation(request)
    }
    job.status = .running
    job.startedAt = Date()
    return job
  }

  /// Ends the running job. A finished one's result is its line's latest step (and the input step
  /// it saved is reused by later jobs from the same canvas). A clip's latest step is its last
  /// frame (`tipTensorId`), which the next run follows.
  /// Records a running job's phase timings, kept with it in Recent.
  func setTimings(_ timings: GenerationTimings?, id: UUID) {
    if running?.id == id { running?.timings = timings }
  }

  /// `inOpenProject` false: the result was saved into its project while another was open. It's
  /// still its line's latest step (the line is that project's), but not the current step here.
  func finishRunning(
    _ status: Job.Status, id: UUID, inputTensorId: Int64? = nil, tipTensorId: Int64? = nil, inOpenProject: Bool = true
  ) {
    guard var job = running?.id == id ? running : runningRemote.first(where: { $0.id == id }) else { return }
    if running?.id == id {
      running = nil
    } else {
      runningRemote.removeAll { $0.id == id }
    }
    job.status = status
    job.finishedAt = Date()
    // A detached job's result isn't made current, and no line follows it.
    if case .finished(let tensorId) = status, !job.detached {
      let tip = tipTensorId ?? tensorId
      // Saving a result into the open project makes it the current step.
      if inOpenProject, expectedProject == job.project { expectedCurrent = tip }
      if let line = job.line { lineTips[line] = tip }
    }
    if let inputTensorId, let request = job.request, request.canvasTensorId == nil,
       let key = request.canvasKey
    {
      savedInputs[Self.inputKey(project: job.project, canvas: key)] = inputTensorId
    }
    forgetIfEmpty()
    record(job)
  }

  private func forgetIfEmpty() {
    guard isEmpty else { return }
    savedInputs = [:]
    lineTips = [:]
    lineProject = [:]
    lastLine = nil
  }

  /// Puts the running generation back at the front of the queue, to run again from the start, for
  /// when the system stops it. False when it can't be run again later: thumbnails, agents' and
  /// paired devices' jobs answer a caller, and an export's placeholder file goes when it's stopped.
  @discardableResult
  func returnRunningToFront() -> Bool {
    guard var job = running, job.request != nil, !job.fromAgent, job.remoteDevice == nil, job.styleThumbnail == nil
    else { return false }
    running = nil
    job.status = .waiting
    job.startedAt = nil
    waiting.insert(job, at: 0)
    return true
  }

  /// Takes a waiting job out of the queue; returns it if it was there.
  @discardableResult
  func removeWaiting(_ id: UUID) -> Job? {
    guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
    var job = waiting.remove(at: index)
    forgetIfEmpty()
    job.status = .cancelled
    job.finishedAt = Date()
    record(job)
    return job
  }

  func moveWaiting(fromOffsets source: IndexSet, toOffset destination: Int) {
    waiting.move(fromOffsets: source, toOffset: destination)
  }

  /// Moves a waiting job to the front, to run next.
  func runNext(_ id: UUID) {
    guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
    waiting.insert(waiting.remove(at: index), at: 0)
  }

  /// Queues a finished, failed or cancelled job again with the same settings and seed, after the
  /// same step.
  func retry(_ id: UUID) {
    guard let job = recent.first(where: { $0.id == id }) else { return }
    var again = Job(work: job.work, target: job.target)
    // Run again off the canvas and into its own project, as it ran. It answers no caller now,
    // but stays a job that isn't kept across a quit (`SavedQueue.save`): brought back it would
    // be an ordinary job, showing on the canvas.
    again.detached = job.detached
    again.project = job.project
    waiting.append(again)
  }

  /// Takes every waiting job out of the queue; returns their ids.
  func removeAllWaiting() -> [UUID] {
    let ids = waiting.map(\.id)
    for id in ids { removeWaiting(id) }
    return ids
  }

  func clearRecent() {
    let removed = recent
    recent = []
    releaseAudio(of: removed)
  }

  func removeRecent(_ id: UUID) {
    let removed = recent.filter { $0.id == id }
    recent.removeAll { $0.id == id }
    releaseAudio(of: removed)
  }

  private func record(_ job: Job) {
    recent.insert(job, at: 0)
    if recent.count > Self.recentLimit {
      let removed = Array(recent.suffix(recent.count - Self.recentLimit))
      recent.removeLast(recent.count - Self.recentLimit)
      releaseAudio(of: removed)
    }
  }

  /// Every job here that's yet to end, for what's kept across a quit.
  var unfinished: [Job] { (running.map { [$0] } ?? []) + runningRemote + waiting }

  /// Removes the audio copies of jobs that left the list, once no job is using them. Finished
  /// jobs keep theirs while they're listed, for Run Again; `Job(work:)` in `retry` shares the copy.
  private func releaseAudio(of removed: [Job]) {
    let inUse = Set((unfinished + recent).compactMap { $0.request?.audio })
    for url in Set(removed.compactMap { $0.request?.audio }) where !inUse.contains(url) {
      AudioClip.removeSnapshot(url)
    }
  }
}
