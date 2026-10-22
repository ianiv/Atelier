import AppKit
import ImageIO
import SwiftUI
import _MediaGenerationKit

/// Launch-argument driver for scripted checks: fills the Create screen, presses Generate, logs
/// progress to stdout and snapshots the window. Does nothing unless `--generate` is passed.
///
///   Atelier --generate --model moss_image_sft_i8x.ckpt --prompt "…" --width 1152 --height 896
///           [--seed N] [--steps N] [--cancel-at-step N] [--snapshot-dir DIR] [--quit]
///
/// `--show history` opens that sidebar section at launch. `--project NAME` saves to (and reads
/// history from) that project instead of the user's current one.
///
/// `--reuse latest|STEP [--new-seed]` instead loads a history item (the newest, or a step number
/// in the current project) through "Use settings" (or "Rerun with new seed"), generates, and
/// compares the new image's pixels with the original.
///
/// `--project-check` exercises the project format on a scratch project (AutomationProject.swift).
@MainActor
enum Automation {
  /// Whether this launch is a scripted run (any of the flags `runIfRequested` acts on).
  nonisolated static var isRequested: Bool {
    let flags = [
      "--show", "--resize-bench", "--inspector-check", "--library-check", "--project-check",
      "--reuse", "--generate",
    ]
    return CommandLine.arguments.contains { flags.contains($0) }
  }

  static func runIfRequested(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore,
    library: ModelLibrary
  ) {
    self.library = library
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--show"), index + 1 < args.count,
      let section = ContentView.Section(rawValue: args[index + 1].capitalized)
    {
      navigation.section = section
    }
    if args.contains("--resize-bench") {
      resizeBench(model)
      return
    }
    if args.contains("--inspector-check") {
      inspectorCheck(model, navigation: navigation, layouts: layouts, presets: presets)
      return
    }
    if args.contains("--library-check") {
      libraryCheck(model, navigation: navigation, layouts: layouts, presets: presets, library: library)
      return
    }
    if args.contains("--project-check") {
      projectCheck(model)
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
      if let step = model.lastSavedStep {
        log("saved step \(step.logicalTime) in \(model.history.project.url.path)")
        if editDuringRun, let item = model.history.item(step) {
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
      @MainActor func finish() { if args.contains("--quit") { NSApp.terminate(nil) } }
      while !model.history.isLoaded || model.models.isEmpty || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      log("history: \(model.history.items.count) items")
      let target = value("--reuse") ?? "latest"
      guard
        let item = target == "latest"
          ? model.history.items.first
          : model.history.items.first(where: { "\($0.id.logicalTime)" == target })
      else {
        log("no history item \(target)")
        return finish()
      }
      navigation.section = .history
      try? await Task.sleep(for: .milliseconds(800))
      if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent("history.png")) }

      let newSeed = args.contains("--new-seed")
      log(
        "\(newSeed ? "rerun" : "use settings") step \(item.id.logicalTime): \(item.sidecar.model) seed \(item.sidecar.seed) steps \(item.sidecar.steps)"
      )
      guard model.canUse(item) else {
        log("item can't be used (model not downloaded?)")
        return finish()
      }
      let previous = model.lastSavedStep
      model.use(item, newSeed: newSeed)
      navigation.section = .create
      if !newSeed {
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        let mismatched = registryMismatches(model, dump: item.sidecar.configuration)
        log("loaded: model \(model.selectedModel ?? "?") seed \(model.seed) locked \(model.seedLocked) registry fields differing from sidecar: \(mismatched)")
        model.generate()
      }
      while !model.isBusy && model.lastSavedStep == previous && model.errorMessage == nil {
        try? await Task.sleep(for: .milliseconds(50))
      }
      while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      if let error = model.errorMessage { log("error: \(error)") }
      guard let step = model.lastSavedStep, step != previous, let saved = model.history.item(step)
      else {
        log("no new image")
        return finish()
      }
      log("saved step \(step.logicalTime) seed \(model.seed)")
      if let original = await model.history.image(for: item),
        let rerun = await model.history.image(for: saved),
        let difference = pixelDifference(original, rerun)
      {
        log("pixels differing from original: \(difference.count) of \(difference.total), max channel delta \(difference.maxDelta)")
      }
      if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent("create.png")) }
      finish()
    }
  }

  /// Resizes the main window back and forth and logs the average time per frame.
  ///
  ///   Atelier --resize-bench [--frames N] [--quit]
  private static func resizeBench(_ model: CreateModel) {
    let args = CommandLine.arguments
    let frames = args.firstIndex(of: "--frames").flatMap { Int(args[$0 + 1]) } ?? 120
    Task { @MainActor in
      while model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      try? await Task.sleep(for: .seconds(2))
      guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
        print("resize bench: no visible window (screen locked?)")
        if args.contains("--quit") { NSApp.terminate(nil) }
        return
      }
      let origin = window.frame.origin
      let start = Date()
      var worst = 0.0
      for frame in 0..<frames {
        let t = Date()
        let width = 1100 + 500 * abs(sin(Double(frame) / 15))
        window.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: 860), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        worst = max(worst, Date().timeIntervalSince(t))
      }
      let average = Date().timeIntervalSince(start) / Double(frames)
      print(String(format: "resize bench: %d frames, %.1f ms average, %.1f ms worst", frames, average * 1000, worst * 1000))
      fflush(stdout)
      if args.contains("--quit") { NSApp.terminate(nil) }
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

  /// Scripted checks of the Phase 4 library, logged as PASS/FAIL lines:
  ///
  ///   Atelier --library-check [--import-lora FILE [--lora-name NAME]]
  ///           [--generate-with-lora MODEL [--steps N] [--seed N] [--lora-weight W]]
  ///           [--delete-lora FILE] [--download MODEL [--cancel-after-bytes N]]
  ///           [--import-model FILE [--model-name NAME]] [--generate-model [MODEL] [--steps N]]
  ///           [--delete-model MODEL]
  ///           [--snapshot-dir DIR] [--quit]
  ///
  /// Loads the catalog, imports a LoRA and checks it's registered and offered only for models of
  /// its family, generates with it in the same session, deletes a LoRA, starts (and optionally
  /// cancels) a model download, and imports a model checkpoint and generates with it.
  private static func libraryCheck(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore,
    library: ModelLibrary
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
      @MainActor func shot(_ name: String) async {
        try? await Task.sleep(for: .seconds(1))
        if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent(name)) }
      }
      @MainActor func finish() { if args.contains("--quit") { NSApp.terminate(nil) } }
      while model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)

      await library.refresh()
      let downloaded = library.catalog.filter(\.isDownloaded)
      log("catalog: \(library.catalog.count) models, \(downloaded.count) downloaded (\(ModelsView.bytes(library.downloadedSize))), free \(library.freeSpace.map(ModelsView.bytes) ?? "?"), LoRAs \(library.loras.count)")
      check(library.catalog.count > downloaded.count, "catalog lists models that aren't downloaded")
      let pickerFiles = Set(model.models.map(\.file))
      let libraryFiles = Set(downloaded.map(\.file))
      check(
        pickerFiles == libraryFiles,
        "downloaded models match Create's model picker (only in library: \(libraryFiles.subtracting(pickerFiles).sorted()), only in picker: \(pickerFiles.subtracting(libraryFiles).sorted()))")
      navigation.section = .models
      await shot("models.png")

      var importedFile: String?
      if let path = value("--import-lora") {
        let source = URL(fileURLWithPath: path)
        let before = Set(library.loras.map(\.file))
        library.prepareImport([source])
        if let name = value("--lora-name"), let item = library.importing.first {
          library.updateImport(item.id, name: name)
        }
        navigation.section = .loras
        await shot("import-sheet.png")
        let importStart = Date()
        library.runImports(version: nil)
        while library.isImporting { try? await Task.sleep(for: .milliseconds(100)) }
        if let error = library.errorMessage { log("error: \(error)") }
        let added = library.loras.filter { !before.contains($0.file) }
        importedFile = added.first?.file
        check(added.count == 1, String(format: "imported %@ in %.1fs: %@", source.lastPathComponent, Date().timeIntervalSince(importStart), added.map { "\($0.file) (\($0.name), \($0.family), \($0.size.map(ModelsView.bytes) ?? "missing"))" }.joined()))
        if let lora = added.first {
          check(lora.isDownloaded, "converted file is in the models folder")
          for candidate in model.models {
            let fits = ModelLibrary.loraFamilies(forModel: candidate.version).contains(lora.family)
            if fits || candidate.file.hasPrefix("moss") || candidate.file.hasPrefix("krea") {
              log("  offered for \(candidate.file) (\(candidate.version ?? "?")): \(fits)")
            }
          }
          let offered = model.models.filter {
            ModelLibrary.loraFamilies(forModel: $0.version).contains(lora.family)
          }
          check(
            !offered.isEmpty && offered.allSatisfy { $0.version == lora.family },
            "offered for \(offered.count) \(lora.family) model(s) and no others")
        }
        await shot("loras.png")
      }

      if let target = value("--generate-with-lora") {
        let file = value("--lora-file") ?? importedFile
        let lora = library.loras.first { $0.file == file }
        guard let lora else {
          log("no LoRA to generate with")
          return finish()
        }
        model.selectedModel = target
        try? await Task.sleep(for: .milliseconds(300))
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        guard var settings = model.settings, model.selectedModel == target else {
          log("model \(target) didn't load")
          return finish()
        }
        let weight = value("--lora-weight").flatMap(Float.init) ?? 1
        settings.loras = [LoRA(file: lora.file, weight: weight, mode: .all)]
        if let steps = value("--steps").flatMap(Int.init) { settings.steps = steps }
        settings.width = 512
        settings.height = 512
        model.settings = settings
        model.seed = value("--seed").flatMap(UInt32.init) ?? 42
        model.seedLocked = true
        model.prompt = value("--prompt") ?? "portrait photo of a woman in a garden"
        navigation.section = .create
        let previous = model.lastSavedStep
        log("generate with \(lora.file) weight \(weight) on \(target), \(settings.steps) steps")
        model.generate()
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        if let error = model.errorMessage { log("error: \(error)") }
        if let step = model.lastSavedStep, step != previous {
          let saved = model.history.item(step)
          let savedLoRAs = saved?.sidecar.configuration["loras"].map { "\($0)" } ?? "none"
          check(true, "saved step \(step.logicalTime), project loras \(savedLoRAs)")
        } else {
          check(false, "no image saved")
        }
        await shot("create-with-lora.png")
      }

      if let file = value("--delete-lora"), let lora = library.loras.first(where: { $0.file == file }) {
        library.delete(lora)
        let registry = (try? String(contentsOfFile: model.modelsDirectory + "/custom_lora.json", encoding: .utf8)) ?? ""
        check(!library.loras.contains { $0.file == file } && !registry.contains(file), "deleted \(file) and its custom_lora.json entry")
        check(!FileManager.default.fileExists(atPath: model.modelsDirectory + "/" + file), "file moved to the Trash")
      }

      if let file = value("--download"), let entry = library.catalog.first(where: { $0.file == file }) {
        let cancelAfter = value("--cancel-after-bytes").flatMap(Int64.init)
        library.download(entry)
        var last = ""
        var loggedTenth = -1
        while let progress = library.downloads[file] {
          let line = ModelStatus.describe(progress)
          last = line
          let tenth = Int((progress.fraction ?? 0) * 10)
          if tenth != loggedTenth {
            log("progress: \(line)")
            loggedTenth = tenth
          }
          if let cancelAfter, progress.bytesWritten >= cancelAfter {
            log("progress: \(line); cancelling")
            library.cancelDownload(file)
            break
          }
          try? await Task.sleep(for: .milliseconds(250))
        }
        while library.downloads[file] != nil { try? await Task.sleep(for: .milliseconds(100)) }
        if let error = library.errorMessage { log("error: \(error)") }
        let isDownloaded = library.catalog.first { $0.file == file }?.isDownloaded ?? false
        log("last progress: \(last)")
        check(cancelAfter == nil ? isDownloaded : !isDownloaded, "download \(cancelAfter == nil ? "finished" : "cancelled"): downloaded \(isDownloaded), in Create's picker \(model.models.contains { $0.file == file })")
      }
      var importedModel: String?
      if let path = value("--import-model") {
        let source = URL(fileURLWithPath: path)
        let before = Set(library.catalog.map(\.file))
        library.prepareModelImport([source])
        while library.importingModels.contains(where: \.isInspecting) {
          try? await Task.sleep(for: .milliseconds(100))
        }
        if let item = library.importingModels.first {
          log("inspected \(source.lastPathComponent): \(item.family ?? "?") \(item.problem ?? "")")
          if let name = value("--model-name") { library.updateModelImport(item.id, name: name) }
        }
        navigation.section = .models
        await shot("model-import-sheet.png")
        let importStart = Date()
        let canImport = library.importingModels.contains(where: \.canImport)
        library.runModelImports()
        if !canImport { library.cancelModelImports() }
        var loggedTenth = -1
        while library.isImportingModels {
          if let progress = library.importingModels.first?.progress, Int(progress * 10) != loggedTenth {
            loggedTenth = Int(progress * 10)
            log(String(format: "import progress: %.0f%%", progress * 100))
          }
          try? await Task.sleep(for: .milliseconds(250))
        }
        if let error = library.errorMessage { log("error: \(error)") }
        let added = library.catalog.filter { !before.contains($0.file) }
        check(
          canImport ? added.count == 1 : added.isEmpty,
          String(format: "import of %@ in %.1fs: %@", source.lastPathComponent, Date().timeIntervalSince(importStart), added.map { "\($0.file) (\($0.name), \($0.version ?? "?"))" }.joined()))
        if let entry = added.first {
          let registry = (try? String(contentsOfFile: model.modelsDirectory + "/custom.json", encoding: .utf8)) ?? ""
          check(library.isCustom(entry) && registry.contains(entry.file), "registered in custom.json as Imported")
          while library.downloads[entry.file] != nil {
            if let progress = library.downloads[entry.file] { log("dependencies: \(ModelStatus.describe(progress))") }
            try? await Task.sleep(for: .seconds(2))
          }
          let ready = library.catalog.first { $0.file == entry.file }?.isDownloaded ?? false
          check(ready && model.models.contains { $0.file == entry.file }, "ready (dependencies present) and in Create's model picker")
          await shot("models-imported.png")
          importedModel = entry.file
        }
      }

      if args.contains("--generate-model") {
        let named = value("--generate-model").flatMap { $0.hasPrefix("--") ? nil : $0 }
        if let file = named ?? importedModel {
          model.selectedModel = file
          try? await Task.sleep(for: .milliseconds(300))
          while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
          if var settings = model.settings, model.selectedModel == file {
            if let steps = value("--steps").flatMap(Int.init) { settings.steps = steps }
            settings.width = 512
            settings.height = 512
            model.settings = settings
            model.seed = value("--seed").flatMap(UInt32.init) ?? 42
            model.seedLocked = true
            model.prompt = value("--prompt") ?? "a lighthouse on a cliff at sunset"
            navigation.section = .create
            let previous = model.lastSavedStep
            log("generate with \(file), \(settings.steps) steps")
            model.generate()
            while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            if let error = model.errorMessage { log("error: \(error)") }
            check(model.lastSavedStep != nil && model.lastSavedStep != previous, "generated with \(file)")
            await shot("create-model.png")
          } else {
            check(false, "model \(file) didn't load")
          }
        } else {
          log("no model to generate with")
        }
      }

      if let file = value("--delete-model"),
        let entry = library.catalog.first(where: { $0.file == file })
      {
        await library.delete(entry)
        let isDownloaded = library.catalog.first { $0.file == file }?.isDownloaded ?? false
        check(
          !isDownloaded && !model.models.contains { $0.file == file }
            && !FileManager.default.fileExists(atPath: model.modelsDirectory + "/" + file),
          "deleted model \(file); Create now selects \(model.selectedModel ?? "nothing")")
      }
      finish()
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
      @MainActor func finish() { if args.contains("--quit") { NSApp.terminate(nil) } }
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

      if args.contains("--show-customize") {
        layouts.customizing = true
        try? await Task.sleep(for: .seconds(2))
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }),
          let view = sheet.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
          let snapshotDir
        {
          view.cacheDisplay(in: view.bounds, to: rep)
          try? rep.representation(using: .png, properties: [:])?.write(
            to: snapshotDir.appendingPathComponent("customize.png"))
          log("customize sheet snapshotted")
        } else {
          log("no customize sheet window")
        }
        layouts.customizing = false
        try? await Task.sleep(for: .seconds(1))
        return finish()
      }
      if let expected = value("--expect-layout") {
        check(layouts.current.name == expected, "layout after relaunch is “\(layouts.current.name)” (expected “\(expected)”)")
        check(!layouts.current.isShown("shift"), "Shift is still hidden after relaunch")
        check(layouts.current.sections.first == .loras, "LoRAs section is still first after relaunch")
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

      // Section order: move LoRAs above Essentials.
      layouts.moveSection(.loras, by: -1)
      layouts.moveSection(.loras, by: -1)
      check(layouts.current.sections.first == .loras, "moved LoRAs to the top (order: \(layouts.current.sections.prefix(3).map(\.title)))")

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

      // A per-model default preset: applied when switching to that model only.
      model.selectedModel = modelA
      await settle()
      model.resetToModelDefaults(undoManager: nil)
      model.set(steps, to: .number(9), undoManager: nil)
      let own = Preset(name: "Inspector Check Default", values: model.values(for: ["steps"]), model: modelA)
      try? presets.save(own)
      model.setDefaultPreset(own)
      check(!model.changedSettings.contains { $0.id == "steps" }, "Steps 9 counts as unchanged once it's the default")
      if let modelB {
        model.selectedModel = modelB
        await settle()
        check(model.settings?.steps != 9 && presets.presets(for: modelB).own.isEmpty,
          "\(modelB) doesn't get \(modelA)'s preset (steps \(model.settings?.steps ?? -1))")
        model.selectedModel = modelA
        await settle()
      }
      check(model.settings?.steps == 9, "switching back to \(modelA) applied its default preset (steps \(model.settings?.steps ?? -1))")
      presets.delete(own)
      check(presets.defaultPreset(for: modelA) == nil, "deleting the preset cleared the default")

      // Use settings restores every registry field.
      if let item = model.history.items.first(where: { model.canUse($0) }) {
        model.use(item)
        await settle()
        let mismatched = registryMismatches(model, dump: item.sidecar.configuration)
        check(mismatched.isEmpty,
          "Use settings on step \(item.id.logicalTime) restored all \(SettingsRegistry.all.count) registry fields \(mismatched)")
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

  static func pixelDifference(_ a: CGImage, _ b: CGImage) -> (count: Int, total: Int, maxDelta: Int)? {
    func rgba(_ image: CGImage) -> (Int, Int, [UInt8])? {
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
  private static var library: ModelLibrary?

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
      .environment(library ?? ModelLibrary(create: model))
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
