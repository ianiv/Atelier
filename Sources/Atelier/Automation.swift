import AppKit
import ImageIO
import SwiftUI

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
  static func runIfRequested(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore
  ) {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--show"), index + 1 < args.count,
      let section = ContentView.Section(rawValue: args[index + 1].capitalized)
    {
      navigation.section = section
    }
    if args.contains("--inspector-check") {
      inspectorCheck(model, navigation: navigation, layouts: layouts, presets: presets)
      return
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
      let editDuringRun = args.contains("--edit-during-run")
      let guidanceAtStart = settings.guidanceScale
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
        if editDuringRun, model.step >= 1, model.settings?.guidanceScale == guidanceAtStart {
          model.settings?.guidanceScale = guidanceAtStart + 1
          log("changed guidance to \(guidanceAtStart + 1) mid-run")
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
      if let url = model.lastSavedURL {
        log("saved \(url.path)")
        if editDuringRun, let item = model.history.items.first(where: { $0.imageURL == url }) {
          let saved = item.sidecar.guidanceScale
          log("\(saved == guidanceAtStart ? "PASS" : "FAIL") run used guidance \(saved) (start \(guidanceAtStart)); inspector now \(model.settings?.guidanceScale ?? -1)")
        }
      }
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
        let mismatched = registryMismatches(model, dump: item.sidecar.configuration)
        log("loaded: model \(model.selectedModel ?? "?") seed \(model.seed) locked \(model.seedLocked) registry fields differing from sidecar: \(mismatched)")
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

  /// Registry settings whose current value differs from a sidecar's configuration dump.
  private static func registryMismatches(_ model: CreateModel, dump: [String: JSONValue]) -> [String] {
    SettingsRegistry.all.compactMap { descriptor in
      guard let expected = descriptor.read(dump), let actual = model.value(descriptor) else {
        return "\(descriptor.id) (missing)"
      }
      // Round-trip the dump value through a configuration so float encodings compare equal.
      guard var probe = model.settings else { return nil }
      descriptor.set(&probe, expected)
      return descriptor.get(probe) == actual ? nil : "\(descriptor.id): \(actual) ≠ \(expected)"
    }
  }

  /// Scripted checks of the Phase 3 inspector, logged as PASS/FAIL lines:
  ///
  ///   Atelier --inspector-check [--model A] [--model-b B] [--snapshot-dir DIR] [--quit]
  ///   Atelier --inspector-check --expect-layout NAME [--snapshot-dir DIR] [--quit]
  ///
  /// The first form hides Shift in a custom layout, changes it as search would, round-trips the
  /// layout through export/import, applies a preset across models, checks undo and "Use settings".
  /// The second form, run after a relaunch, checks the custom layout was restored.
  private static func inspectorCheck(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore
  ) {
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
      func check(_ ok: Bool, _ message: String) { log((ok ? "PASS " : "FAIL ") + message) }
      @MainActor func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        while model.isBusy || model.settings == nil { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(300))
      }
      @MainActor func shot(_ name: String) async {
        try? await Task.sleep(for: .milliseconds(500))
        if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent(name)) }
      }
      func finish() { if args.contains("--quit") { NSApp.terminate(nil) } }
      var waited = 0
      while model.models.isEmpty || model.settings == nil || model.isBusy || !model.history.isLoaded {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
        if waited % 50 == 0 {
          log("waiting: models \(model.models.count) settings \(model.settings != nil) phase \(model.phase) history \(model.history.isLoaded) error \(model.errorMessage ?? "-")")
        }
      }
      try? await Task.sleep(for: .seconds(2))
      ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
      let shift = SettingsRegistry.byID["shift"]!
      let steps = SettingsRegistry.byID["steps"]!
      let guidance = SettingsRegistry.byID["guidanceScale"]!

      if let expected = value("--expect-layout") {
        check(layouts.current.name == expected, "layout after relaunch is “\(layouts.current.name)” (expected “\(expected)”)")
        check(!layouts.current.isShown("shift"), "Shift is still hidden after relaunch")
        await shot("relaunch.png")
        return finish()
      }

      let modelA = value("--model") ?? "moss_image_sft_i8x.ckpt"
      if model.selectedModel != modelA { model.selectedModel = modelA }
      await settle()
      model.prompt = "a lighthouse on a cliff at dusk"
      model.resetToModelDefaults(undoManager: nil)
      layouts.select(.standard)
      await shot("create.png")

      // Hide Shift, then change it the way a search result row does.
      layouts.setShown("shift", false)
      let customName = layouts.current.name
      check(!layouts.isBuiltIn(layouts.current) && !layouts.current.isShown("shift"),
        "hiding Shift made custom layout “\(customName)” without it")
      check(FileManager.default.fileExists(atPath: LayoutStore.url(for: customName).path),
        "layout saved to \(LayoutStore.url(for: customName).path)")
      layouts.searchText = "shift"
      let shiftValue = (model.value(shift)?.doubleValue ?? 1) + 1.5
      model.set(shift, to: .number(shiftValue), undoManager: nil)
      await shot("search.png")
      layouts.searchText = ""
      check(model.changedSettings.contains { $0.id == "shift" }, "Shift (hidden) appears in the Changed group")
      await shot("changed.png")

      // Undo, with event grouping done by hand since no events run during the script.
      let undoManager = UndoManager()
      undoManager.groupsByEvent = false
      let stepsBefore = model.settings?.steps ?? 0
      undoManager.beginUndoGrouping()
      model.set(steps, to: .number(Double(stepsBefore + 7)), undoManager: undoManager)
      undoManager.endUndoGrouping()
      check(undoManager.undoActionName == "Change Steps", "undo action is named “\(undoManager.undoActionName)”")
      undoManager.undo()
      check(model.settings?.steps == stepsBefore, "undo restored Steps to \(stepsBefore)")
      undoManager.redo()
      check(model.settings?.steps == stepsBefore + 7, "redo set Steps to \(stepsBefore + 7)")

      // Export, delete, import.
      let original = layouts.current
      let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-layout-check.json")
      do {
        try layouts.export(original, to: exportURL)
        layouts.delete(original)
        check(!layouts.custom.contains { $0.name == original.name }, "deleted “\(original.name)”")
        let imported = try layouts.importLayout(from: exportURL)
        check(imported == original, "export/import round-trip kept name, shown order and expanded sections")
      } catch {
        check(false, "export/import: \(error)")
      }

      // Preset across models.
      model.resetToModelDefaults(undoManager: nil)
      model.set(steps, to: .number(12), undoManager: nil)
      model.set(guidance, to: .number(2.5), undoManager: nil)
      let preset = Preset(name: "Inspector Check", values: model.values(for: ["steps", "guidanceScale"]))
      do { try presets.save(preset) } catch { check(false, "save preset: \(error)") }
      check(FileManager.default.fileExists(atPath: PresetStore.url(for: preset.name).path), "preset saved")
      let modelB = value("--model-b") ?? model.models.first { $0.file != modelA }?.file
      if let modelB {
        model.selectedModel = modelB
        await settle()
        model.apply(preset, undoManager: nil)
        check(model.settings?.steps == 12 && model.settings?.guidanceScale == 2.5,
          "preset on \(modelB) set Steps 12 and Guidance 2.5")
        let others = model.changedSettings.map(\.id).filter { $0 != "steps" && $0 != "guidanceScale" }
        check(others.isEmpty, "every other setting kept \(modelB)'s defaults (differing: \(others))")
        await shot("preset.png")
        model.selectedModel = modelA
        await settle()
      }
      presets.delete(preset)

      // Use settings restores every registry field.
      if let item = model.history.items.first(where: { model.canUse($0) }) {
        model.use(item)
        await settle()
        let mismatched = registryMismatches(model, dump: item.sidecar.configuration)
        check(mismatched.isEmpty,
          "Use settings on \(item.imageURL.lastPathComponent) restored all \(SettingsRegistry.all.count) registry fields \(mismatched)")
      } else {
        log("SKIP no usable history item for Use settings")
      }

      // Leave the hidden-Shift layout selected for the relaunch check.
      if let restored = layouts.all.first(where: { $0.name == original.name }) {
        layouts.select(restored)
      }
      model.resetToModelDefaults(undoManager: nil)
      log("layout for relaunch: \(layouts.current.name)")
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

  /// A window hosting the app's content when SwiftUI hasn't put one up (the screen is locked),
  /// so snapshots still show the UI. Rendered off screen; it has no toolbar.
  private static var offscreenWindow: NSWindow?

  private static func ensureWindow(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore
  ) {
    guard !NSApp.windows.contains(where: { $0.isVisible }), offscreenWindow == nil else { return }
    let content = ContentView()
      .environment(model)
      .environment(model.history)
      .environment(navigation)
      .environment(layouts)
      .environment(presets)
      .frame(width: 1280, height: 860)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: content)
    offscreenWindow = window
  }

  /// Renders the main window into a PNG; needs no screen-recording permission.
  private static func snapshot(to url: URL) {
    guard
      let view = (NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        ?? offscreenWindow)?.contentView?.superview,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}
