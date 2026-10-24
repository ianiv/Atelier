import Foundation
import Observation

/// Generations waiting to run, the one running and the recent ones, in order. Each job holds its
/// own snapshot of the prompt, settings, seed, canvas and moodboard, taken when it was queued.
/// CreateModel runs them one at a time.
@MainActor
@Observable
final class JobQueue {
  struct Job: Identifiable {
    enum Status: Equatable {
      case waiting, running
      case finished(tensorId: Int64)
      case failed(String)
      case cancelled
    }

    var id = UUID()
    var request: GenerationEngine.Request
    var status = Status.waiting
    let queuedAt = Date()
    var finishedAt: Date?
    /// Queued by an agent over MCP.
    var fromAgent = false
    /// Jobs queued one after another, while you didn't pick another step, form a line: each
    /// follows the line's latest result when it starts, whatever order they end up running in.
    var line: UUID?
  }

  private(set) var waiting: [Job] = []
  private(set) var running: Job?
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

  var isEmpty: Bool { waiting.isEmpty && running == nil }

  /// Whether a waiting or running job uses `model`.
  func uses(_ model: String) -> Bool {
    running?.request.model == model || waiting.contains { $0.request.model == model }
  }

  /// Adds jobs at the end. Ones without a step to follow go on the line being queued, or start
  /// a new line after the current step when you picked another step since. Returns their ids.
  @discardableResult
  func append(
    _ requests: [GenerationEngine.Request], currentTensorId: Int64?, fromAgent: Bool = false
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
      var job = Job(request: request, fromAgent: fromAgent)
      if request.parentTensorId == nil { job.line = line }
      waiting.append(job)
    }
    return waiting.suffix(requests.count).map(\.id)
  }

  /// Takes the first waiting job and marks it running, unless paused or one is running.
  func startNext() -> Job? {
    guard running == nil, !isPaused, !waiting.isEmpty else { return nil }
    var job = waiting.removeFirst()
    if let line = job.line, let tip = lineTips[line] { job.request.parentTensorId = tip }
    if job.request.canvas != nil, job.request.canvasTensorId == nil, let key = job.request.canvasKey {
      job.request.canvasTensorId = savedInputs[key]
    }
    job.status = .running
    running = job
    return job
  }

  /// Ends the running job. A finished one's result is its line's latest step (and the input step
  /// it saved is reused by later jobs from the same canvas).
  func finishRunning(_ status: Job.Status, inputTensorId: Int64? = nil) {
    guard var job = running else { return }
    running = nil
    job.status = status
    job.finishedAt = Date()
    if case .finished(let tensorId) = status {
      // Saving a result makes it the current step.
      expectedCurrent = tensorId
      if let line = job.line { lineTips[line] = tensorId }
    }
    if let inputTensorId, job.request.canvasTensorId == nil, let key = job.request.canvasKey {
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
    waiting.append(Job(request: job.request))
  }

  /// Takes every waiting job out of the queue; returns their ids.
  func removeAllWaiting() -> [UUID] {
    let ids = waiting.map(\.id)
    for id in ids { removeWaiting(id) }
    return ids
  }

  func clearRecent() {
    recent = []
  }

  func removeRecent(_ id: UUID) {
    recent.removeAll { $0.id == id }
  }

  private func record(_ job: Job) {
    recent.insert(job, at: 0)
    if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
  }
}
