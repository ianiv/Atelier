import AppKit

/// Launch-argument driver for scripted checks: fills the Create screen, presses Generate, logs
/// progress to stdout and snapshots the window. Does nothing unless `--generate` is passed.
///
///   Atelier --generate --model moss_image_sft_i8x.ckpt --prompt "…" --width 1152 --height 896
///           [--seed N] [--steps N] [--cancel-at-step N] [--snapshot-dir DIR] [--quit]
@MainActor
enum Automation {
  static func runIfRequested(_ model: CreateModel) {
    let args = CommandLine.arguments
    guard args.contains("--generate") else { return }
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    Task { @MainActor in
      let started = Date()
      func log(_ message: String) {
        print(String(format: "[%7.2fs] ", Date().timeIntervalSince(started)) + message)
        fflush(stdout)
      }
      let snapshotDir = value("--snapshot-dir").map { URL(fileURLWithPath: $0) }

      while model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      log("models: \(model.models.count) downloaded")
      if let file = value("--model") {
        guard model.models.contains(where: { $0.file == file }) else {
          log("model \(file) not in downloaded list")
          if args.contains("--quit") { NSApp.terminate(nil) }
          return
        }
        model.selectedModel = file
        try? await Task.sleep(for: .milliseconds(200))
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      }
      guard var settings = model.settings else { return }
      log(
        "defaults for \(model.selectedModel ?? "?"): steps \(settings.steps), guidance \(settings.guidanceScale), shift \(settings.shift), rds \(settings.resolutionDependentShift), sampler \(settings.sampler), hires \(settings.hiresFix), size \(settings.width)x\(settings.height)"
      )
      if let width = value("--width").flatMap(Int.init) { settings.width = width }
      if let height = value("--height").flatMap(Int.init) { settings.height = height }
      if let steps = value("--steps").flatMap(Int.init) { settings.steps = steps }
      model.settings = settings
      if let seed = value("--seed").flatMap(UInt32.init) {
        model.seed = seed
        model.seedLocked = true
      }
      model.prompt = value("--prompt") ?? "a lighthouse on a cliff at dusk"
      let cancelAt = value("--cancel-at-step").flatMap(Int.init)

      log("generate \(settings.width)x\(settings.height) seed \(model.seed)")
      model.generate()
      var lastStatus = ""
      var cancelRequestedAt: Date?
      var snapshotted = false
      while model.isBusy {
        let status: String
        switch model.phase {
        case .running(let message): status = message
        case .cancelling: status = "Cancelling…"
        case .loadingModel: status = "Loading model…"
        case .idle: status = "Idle"
        }
        if status != lastStatus {
          log(status + (model.image != nil ? " (preview)" : ""))
          lastStatus = status
        }
        if !snapshotted, model.step >= max(model.totalSteps / 2, 1), model.image != nil,
          let snapshotDir
        {
          snapshot(to: snapshotDir.appendingPathComponent("midway.png"))
          snapshotted = true
        }
        if let cancelAt, cancelRequestedAt == nil, model.step >= cancelAt {
          log("cancel at step \(model.step)")
          cancelRequestedAt = Date()
          model.cancel()
        }
        try? await Task.sleep(for: .milliseconds(20))
      }
      if let cancelRequestedAt {
        log(String(format: "stopped %.2fs after cancel", Date().timeIntervalSince(cancelRequestedAt)))
      }
      if let error = model.errorMessage { log("error: \(error)") }
      if let url = model.lastSavedURL { log("saved \(url.path)") }
      if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent("final.png")) }
      if args.contains("--quit") { NSApp.terminate(nil) }
    }
  }

  /// Renders the main window into a PNG; needs no screen-recording permission.
  private static func snapshot(to url: URL) {
    guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?
      .contentView?.superview,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}
