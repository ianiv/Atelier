import Foundation
import Observation

/// Generations (and upscaled timeline exports) waiting to run, the one running and the recent
/// ones, in order. Each generation holds its own snapshot of the prompt, settings, seed, canvas
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
  /// Input steps saved by finished Edit runs, by the canvas they were rendered from, so later
  /// jobs from the same canvas reuse the step instead of saving the canvas again.
  private var savedInputs: [String: Int64] = [:]
  /// The current step as the queue last left it: when queuing, or a result just saved. A
  /// different current step when queuing means you picked one, which starts a new line.
  private var expectedCurrent: Int64?
  /// The line jobs were last queued on, and each line's latest step.
  private var lastLine: UUID?
  private var lineTips: [UUID: Int64?] = [:]

  private static let recentLimit = 100

  var isEmpty: Bool { waiting.isEmpty && running == nil && runningRemote.isEmpty }

  /// Whether a waiting or running job uses `model`.
  func uses(_ model: String) -> Bool {
    running?.request?.model == model || waiting.contains { $0.request?.model == model }
  }

  /// Adds jobs at the end. Ones without a step to follow go on the line being queued, or start
  /// a new line after the current step when you picked another step since. Returns their ids.
  @discardableResult
  func append(
    _ requests: [GenerationEngine.Request], currentTensorId: Int64?, target: JobTarget = .local,
    fromAgent: Bool = false, styleThumbnail: String? = nil
  ) -> [UUID] {
    let line: UUID
    if let lastLine, !isEmpty, currentTensorId == expectedCurrent {
      line = lastLine
    } else {
      line = UUID()
      lineTips[line] = currentTensorId
      lastLine = line
    }
    expectedCurrent = currentTensorId
    for request in requests {
      var job = Job(request: request, target: target, fromAgent: fromAgent)
      job.styleThumbnail = styleThumbnail
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

  /// Adds a job sent to a server before this launch, unless it's already here.
  func appendResumed(_ request: GenerationEngine.Request, id: UUID, server: UUID) {
    guard running?.id != id, !runningRemote.contains(where: { $0.id == id }),
          !waiting.contains(where: { $0.id == id }), !recent.contains(where: { $0.id == id })
    else { return }
    var job = Job(request: request, target: .remote(serverID: server))
    job.id = id
    job.resumesRemoteJob = true
    waiting.append(job)
  }

  /// Adds an export at the end; returns its id.
  @discardableResult
  func append(_ export: TimelineExportJob, target: JobTarget = .local) -> UUID {
    let job = Job(work: .export(export), target: target)
    waiting.append(job)
    return job.id
  }

  /// Takes the first job waiting for this device and marks it running, unless paused or one is
  /// running.
  func startNext() -> Job? {
    guard running == nil, !isPaused, let index = waiting.firstIndex(where: { $0.target == .local }) else { return nil }
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
      if job.target != .local, !busy.contains(job.target), !isPaused || job.resumesRemoteJob {
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
        request.canvasTensorId = savedInputs[key]
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

  func finishRunning(_ status: Job.Status, id: UUID, inputTensorId: Int64? = nil, tipTensorId: Int64? = nil) {
    guard var job = running?.id == id ? running : runningRemote.first(where: { $0.id == id }) else { return }
    if running?.id == id {
      running = nil
    } else {
      runningRemote.removeAll { $0.id == id }
    }
    job.status = status
    job.finishedAt = Date()
    if case .finished(let tensorId) = status {
      // Saving a result makes it the current step.
      let tip = tipTensorId ?? tensorId
      expectedCurrent = tip
      if let line = job.line { lineTips[line] = tip }
    }
    if let inputTensorId, let request = job.request, request.canvasTensorId == nil,
       let key = request.canvasKey
    {
      savedInputs[key] = inputTensorId
    }
    forgetIfEmpty()
    record(job)
  }

  private func forgetIfEmpty() {
    guard isEmpty else { return }
    savedInputs = [:]
    lineTips = [:]
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
    waiting.append(Job(work: job.work, target: job.target))
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
