#if os(iOS)
import BackgroundTasks
import Foundation

/// Keeps the queue's GPU work going while the app is in the background, with iPadOS's continued
/// processing task. The system shows its own progress display for the task and can end it at any
/// time: GPU pressure, the user stopping it from that display, or too little progress. Everything
/// about BackgroundTasks stays here. `CreateModel` decides when one should run.
///
/// A request can only be submitted from the foreground, so one is made as the app is leaving it. It
/// ends when the app comes back, so the display only shows while the app is away.
@MainActor
final class BackgroundQueueTask {
  private enum State {
    /// Nothing asked for yet.
    case idle
    /// Asked for; the system hasn't started it.
    case pending
    case running(BGContinuedProcessingTask)
    /// Turned down, so not asked for again until the queue stops. Otherwise each job would ask.
    case declined
  }

  private var state = State.idle

  /// The system started the task, which may be after the app went to the background.
  var onStart: (() -> Void)?
  /// The system ended the task. It's already marked complete: stop the work.
  var onExpire: (() -> Void)?

  /// Whether work carries on in the background right now.
  var isRunning: Bool {
    if case .running = state { return true }
    return false
  }

  /// Asks for a task, unless there already is one or the device can't run GPU work in the
  /// background. Without one, the queue pauses in the background as it always has.
  func begin(title: String, subtitle: String) {
    guard case .idle = state else { return }
    guard BGTaskScheduler.supportedResources.contains(.gpu) else {
      Log.queue.info("Background GPU work isn't supported on this device")
      state = .declined
      return
    }
    // Each identifier can be registered only once, and a second registration ends the app.
    let identifier = "\(Bundle.main.bundleIdentifier ?? "").queue.\(UUID().uuidString)"
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) {
      [weak self] task in
      // On the main queue, as asked for above.
      nonisolated(unsafe) let task = task
      MainActor.assumeIsolated { self?.started(task) }
    }
    guard registered else {
      Log.queue.error("Couldn't register the background task")
      state = .declined
      return
    }
    let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
    request.requiredResources = .gpu
    // Now or not at all: a queued request could start long after the app went to the background.
    request.strategy = .fail
    state = .pending
    Task { [weak self] in
      do {
        try await BGTaskScheduler.shared.submitTaskRequest(request)
      } catch {
        Log.queue.error("The background task was turned down: \(error.localizedDescription, privacy: .public)")
        guard let self, case .pending = state else { return }
        state = .declined
      }
    }
  }

  private func started(_ task: BGTask) {
    guard let task = task as? BGContinuedProcessingTask else {
      task.setTaskCompleted(success: false)
      return
    }
    // The queue stopped while the system was starting it.
    guard case .pending = state else {
      task.setTaskCompleted(success: true)
      return
    }
    Log.queue.info("The background task started")
    state = .running(task)
    task.progress.totalUnitCount = 1_000
    task.expirationHandler = { [weak self] in
      Task { @MainActor in self?.expired() }
    }
    onStart?()
  }

  private func expired() {
    guard case .running(let task) = state else { return }
    Log.queue.info("The background task expired")
    task.setTaskCompleted(success: false)
    state = .declined
    onExpire?()
  }

  /// Reports how far along the work is. A task that seems stalled gets ended.
  func update(completed: Double, title: String, subtitle: String) {
    guard case .running(let task) = state else { return }
    task.progress.completedUnitCount = Int64(max(min(completed, 1), 0) * 1_000)
    if task.title != title || task.subtitle != subtitle {
      task.updateTitle(title, subtitle: subtitle)
    }
  }

  /// The app came back, or the queue stopped: it ran out of jobs, or was paused and the running
  /// one ended.
  func end() {
    if case .running(let task) = state {
      // The work is done, though a job's last step can leave the count short of its total.
      task.progress.completedUnitCount = task.progress.totalUnitCount
      task.setTaskCompleted(success: true)
    }
    state = .idle
  }
}
#endif
