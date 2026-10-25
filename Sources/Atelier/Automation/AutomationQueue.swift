import SwiftUI

extension Automation {
  /// Checks the queue with real runs, as PASS/FAIL lines: a count of three with counting seeds,
  /// Pause holding after the running image, reordering, cancelling a waiting job, results lining
  /// up one after another, Stop moving on to the next, Pause then Stop holding, Cancel All, and
  /// saving and restoring jobs.
  ///
  ///   Atelier --queue-check --project NAME [--model M] [--steps N] [--quit]
  static func queueCheck(_ model: CreateModel) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      @MainActor func finish() {
        print(failures == 0 ? "queue check: all passed" : "queue check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func wait(until condition: () -> Bool, seconds: Double = 600) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
          if Date() > deadline { return false }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return true
      }
      let queue = model.queue
      @MainActor func finished() -> [JobQueue.Job] {
        queue.recent.filter { if case .finished = $0.status { true } else { false } }.reversed()
      }

      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if let file = value("--model") {
        model.selectedModel = file
        _ = await wait(until: { !model.isLoadingModel })
        model.resetToModelDefaults(undoManager: nil)
      }
      guard var settings = model.settings else { return finish() }
      settings.steps = value("--steps").flatMap(Int.init) ?? 2
      settings.width = 512
      settings.height = 512
      model.settings = settings
      model.canvasMode = .generate
      model.seedLocked = true
      model.seed = 100
      model.count = 3
      model.prompt = "a red apple on a table"

      // A count of three: one runs, two wait, seeds count up.
      model.generate()
      check(
        queue.running != nil && queue.waiting.count == 2,
        "a count of 3 runs one and queues two (running \(queue.running != nil), waiting \(queue.waiting.count))")
      let seeds = ([queue.running].compactMap { $0 } + queue.waiting).map(\.request.seed)
      check(seeds == [100, 101, 102], "a set seed counts up: \(seeds)")
      check(model.seed == 100 && model.seedLocked, "the seed field and Random are left alone")

      // Queue two more while running, pause, move the last to the front, cancel one.
      model.count = 2
      model.prompt = "a blue cup"
      model.seed = 200
      model.generate()
      check(queue.waiting.count == 4, "Generate while running queues (waiting \(queue.waiting.count))")
      model.setQueuePaused(true)
      let moved = queue.waiting[3]
      queue.runNext(moved.id)
      check(queue.waiting.first?.id == moved.id, "Run Next moves a job to the front")
      let cancelled = queue.waiting[2]
      model.cancel(cancelled.id)
      check(
        queue.waiting.count == 3 && queue.recent.first?.id == cancelled.id
          && queue.recent.first?.status == .cancelled,
        "cancelling a waiting job takes it out")

      // Pause holds once the running one is done.
      _ = await wait(until: { queue.running == nil })
      try? await Task.sleep(for: .seconds(1))
      check(
        queue.running == nil && queue.waiting.count == 3 && !model.isRunning,
        "paused: the running image finished and nothing else started")
      model.setQueuePaused(false)
      _ = await wait(until: { queue.isEmpty })
      let done = finished()
      check(done.count == 4, "four images finished (\(done.count))")
      check(
        done.map(\.request.seed) == [100, 201, 101, 200],
        "they ran in queue order after the move and cancel: \(done.map(\.request.seed))")
      let items = done.compactMap { job -> HistoryItem? in
        if case .finished(let tensorId) = job.status { return model.history.item(tensorId: tensorId) }
        return nil
      }
      check(items.count == 4, "all four are in History")
      let linked = zip(items.dropFirst(), items).allSatisfy {
        model.history.parent(of: $0)?.tensorId == $1.tensorId
      }
      check(linked, "each result follows the one that ran before it, in one line")

      // Stop moves on to the next.
      model.count = 2
      model.prompt = "a green pear"
      model.generate()
      _ = await wait(until: { model.step >= 1 })
      let stopped = queue.running?.id
      model.cancel()
      _ = await wait(until: { queue.running != nil && queue.running?.id != stopped }, seconds: 60)
      check(
        queue.recent.first { $0.id == stopped }?.status == .cancelled && queue.running != nil,
        "Stop cancels the running image and the next one starts")
      _ = await wait(until: { queue.isEmpty })

      // Pause, then Stop: nothing runs after.
      model.generate()
      _ = await wait(until: { model.step >= 1 })
      model.setQueuePaused(true)
      model.cancel()
      _ = await wait(until: { queue.running == nil })
      try? await Task.sleep(for: .seconds(1))
      check(queue.running == nil && queue.waiting.count == 1, "Pause then Stop holds the rest")

      // Saving and restoring keeps the waiting jobs.
      let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-queue-check-\(UUID())")
      SavedQueue.save(queue.waiting, project: model.history.project.name, in: folder)
      let restored = await model.savedRequests(SavedQueue.load(project: model.history.project.name, from: folder))
      let original = queue.waiting.map(\.request)
      check(
        restored.count == original.count
          && zip(restored, original).allSatisfy {
            $0.prompt == $1.prompt && $0.seed == $1.seed && $0.model == $1.model
              && $0.configuration.steps == $1.configuration.steps
              && $0.configuration.width == $1.configuration.width
              && $0.parentTensorId == $1.parentTensorId
          },
        "saved jobs come back with their prompt, seed, model, settings and place")
      try? FileManager.default.removeItem(at: folder)

      model.cancelAll()
      model.setQueuePaused(false)
      check(queue.isEmpty, "Cancel All empties the queue")
      finish()
    }
  }
}
