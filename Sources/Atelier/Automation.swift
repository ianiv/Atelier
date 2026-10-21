import AppKit
import ImageIO

/// Launch-argument driver for scripted checks: fills the Create screen, presses Generate, logs
/// progress to stdout and snapshots the window. Does nothing unless `--generate` is passed.
///
///   Atelier --generate --model moss_image_sft_i8x.ckpt --prompt "…" --width 1152 --height 896
///           [--seed N] [--steps N] [--cancel-at-step N] [--snapshot-dir DIR] [--quit]
///
/// `--show history` opens that sidebar section at launch.
///
/// `--reuse latest|PNG [--new-seed]` instead loads a history item through "Use settings" (or
/// "Rerun with new seed"), generates, and compares the new PNG's pixels with the original.
@MainActor
enum Automation {
  static func runIfRequested(_ model: CreateModel, navigation: Navigation) {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--show"), index + 1 < args.count,
      let section = ContentView.Section(rawValue: args[index + 1].capitalized)
    {
      navigation.section = section
    }
    if args.contains("--reuse") {
      reuse(model, navigation: navigation)
      return
    }
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

  private static func reuse(_ model: CreateModel, navigation: Navigation) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    let snapshotDir = value("--snapshot-dir").map { URL(fileURLWithPath: $0) }
    Task { @MainActor in
      let started = Date()
      func log(_ message: String) {
        print(String(format: "[%7.2fs] ", Date().timeIntervalSince(started)) + message)
        fflush(stdout)
      }
      func finish() { if args.contains("--quit") { NSApp.terminate(nil) } }
      while !model.history.isLoaded || model.models.isEmpty || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      log("history: \(model.history.items.count) items")
      let target = value("--reuse") ?? "latest"
      guard
        let item = target == "latest"
          ? model.history.items.first
          : model.history.items.first(where: { $0.imageURL.path == target })
      else {
        log("no history item \(target)")
        return finish()
      }
      navigation.section = .history
      try? await Task.sleep(for: .milliseconds(800))
      if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent("history.png")) }

      let newSeed = args.contains("--new-seed")
      log(
        "\(newSeed ? "rerun" : "use settings") \(item.imageURL.lastPathComponent): \(item.sidecar.model) seed \(item.sidecar.seed) steps \(item.sidecar.steps)"
      )
      guard model.canUse(item) else {
        log("item can't be used (model not downloaded?)")
        return finish()
      }
      let previous = model.lastSavedURL
      model.use(item, newSeed: newSeed)
      navigation.section = .create
      if !newSeed {
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        log("loaded: model \(model.selectedModel ?? "?") seed \(model.seed) locked \(model.seedLocked) settings match \(model.settings == item.sidecar.settings)")
        model.generate()
      }
      while !model.isBusy && model.lastSavedURL == previous && model.errorMessage == nil {
        try? await Task.sleep(for: .milliseconds(50))
      }
      while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      if let error = model.errorMessage { log("error: \(error)") }
      guard let url = model.lastSavedURL, url != previous else {
        log("no new image")
        return finish()
      }
      log("saved \(url.path) seed \(model.seed)")
      if let difference = pixelDifference(item.imageURL, url) {
        log("pixels differing from original: \(difference.count) of \(difference.total), max channel delta \(difference.maxDelta)")
      }
      if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent("create.png")) }
      finish()
    }
  }

  private static func pixelDifference(_ a: URL, _ b: URL) -> (count: Int, total: Int, maxDelta: Int)? {
    func rgba(_ url: URL) -> (Int, Int, [UInt8])? {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }
      let (width, height) = (image.width, image.height)
      var bytes = [UInt8](repeating: 0, count: width * height * 4)
      guard let context = CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return (width, height, bytes)
    }
    guard let (w1, h1, p1) = rgba(a), let (w2, h2, p2) = rgba(b), w1 == w2, h1 == h2 else {
      return nil
    }
    var count = 0
    var maxDelta = 0
    for pixel in 0..<(w1 * h1) {
      var differs = false
      for channel in 0..<3 {
        let delta = abs(Int(p1[pixel * 4 + channel]) - Int(p2[pixel * 4 + channel]))
        if delta > 0 { differs = true }
        maxDelta = max(maxDelta, delta)
      }
      if differs { count += 1 }
    }
    return (count, w1 * h1, maxDelta)
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
