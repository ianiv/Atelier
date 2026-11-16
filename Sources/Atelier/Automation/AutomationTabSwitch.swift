#if os(macOS)
import Foundation

/// `--tab-switch-bench [--switches N] [--from history,loras,styles] [--max-ms MS] [--quit]`
/// switches the sidebar from each `--from` section (History by default) back to Create N times
/// (10 by default) and prints how long the main thread was blocked for each switch, then the
/// median and the max, and PASS when the max is under `--max-ms` (250 by default). A switch
/// rebuilds the screen it shows (`ContentView`'s `switch`), so everything its views do on appear
/// runs again; this measures that, as a person clicking back to Create sees it.
///
/// Blocking is measured two ways and the larger is reported: the time until the main queue
/// turns twice after the switch (the update and the render it starts), and the longest the main
/// queue took to run a block a background thread posts every few milliseconds during the next
/// 600 ms (`MainStallMonitor`), which also catches work that lands a little later.
///
/// To bench a synthetic models folder without touching the saved settings, pass the folders as
/// argument defaults, as `--model-folders-check` does. Create shows its inspector only once a
/// model has loaded, so put the synthetic folder first and a real models folder (read only) after
/// it:
///
///   Atelier --tab-switch-bench --project lora-bench -modelsDirectory DIR \
///     -additionalModelsDirectories '(MODELS)' --quit
extension Automation {
  static func tabSwitchBench(_ model: CreateModel, navigation: Navigation, library: ModelLibrary) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    let switches = value("--switches").flatMap(Int.init) ?? 10
    let limit = value("--max-ms").flatMap(Double.init) ?? 250
    let sections = (value("--from") ?? "history").split(separator: ",").compactMap { name in
      ContentView.Section.allCases.first {
        $0.rawValue.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame
          || "\($0)".caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame
      }
    }
    Task { @MainActor in
      func log(_ message: String) { print(message); fflush(stdout) }
      func finish() {
        if args.contains("--quit") { exit(0) }
      }
      guard !sections.isEmpty, !sections.contains(.create) else {
        log("FAIL --from takes sections other than Create")
        return finish()
      }
      // Let launch finish: the models folders and their LoRAs load once, after the first window.
      let deadline = Date().addingTimeInterval(30)
      while model.settings == nil || model.isBusy, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      try? await Task.sleep(for: .seconds(2))
      log("folders: \(model.availableModelsDirectories.joined(separator: ", "))")
      log("LoRAs: \(library.loras.count) (\(library.loras.filter(\.isDownloaded).count) downloaded)")
      // Create's inspector, and so its LoRAs section, is only there once a model has loaded.
      if model.settings == nil {
        log("note: no model loaded, so Create shows no inspector (its LoRAs section isn't measured)")
      } else {
        log("model: \(model.selectedModel)")
      }

      let monitor = MainStallMonitor()
      monitor.start()
      defer { monitor.stop() }
      /// Resumes after the main queue has run everything queued before it, twice.
      func mainTurns() async {
        for _ in 0..<2 {
          await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
          }
        }
      }
      @MainActor func measure(_ section: ContentView.Section) async -> Double {
        _ = monitor.takeWorst()
        let start = ContinuousClock.now
        navigation.section = section
        await mainTurns()
        let turns = start.duration(to: .now)
        try? await Task.sleep(for: .milliseconds(600))
        let turnsMs = Double(turns.components.attoseconds) / 1e15 + Double(turns.components.seconds) * 1000
        return max(turnsMs, monitor.takeWorst())
      }

      var results: [Double] = []
      for section in sections {
        for index in 1...switches {
          let away = await measure(section)
          let back = await measure(.create)
          results.append(back)
          log(String(format: "switch %d %@ → Create: %.1f ms (to %@: %.1f ms)", index, section.rawValue, back, section.rawValue, away))
        }
      }
      let sorted = results.sorted()
      let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
      let worst = sorted.last ?? 0
      log(String(format: "median %.1f ms, max %.1f ms over %d switches", median, worst, results.count))
      log(String(format: "%@ switching back to Create blocks the main thread at most %.1f ms (limit %.0f ms)", worst <= limit ? "PASS" : "FAIL", worst, limit))
      log("DONE tab switch bench")
      finish()
    }
  }
}

/// Measures how late the main queue runs: a background thread posts a block to it every couple of
/// milliseconds and keeps the longest wait seen since `takeWorst()` was last called.
final nonisolated class MainStallMonitor: @unchecked Sendable {
  private let lock = NSLock()
  private var worst: Double = 0
  private var running = false

  func start() {
    lock.withLock { running = true }
    Thread.detachNewThread { [self] in
      while lock.withLock({ running }) {
        let sent = DispatchTime.now().uptimeNanoseconds
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { done.signal() }
        done.wait()
        let waited = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
        lock.withLock { worst = max(worst, waited) }
        usleep(2000)
      }
    }
  }

  func stop() {
    lock.withLock { running = false }
  }

  /// The longest wait since the last call, in milliseconds.
  func takeWorst() -> Double {
    lock.withLock {
      defer { worst = 0 }
      return worst
    }
  }
}
#endif
