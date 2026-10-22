import AppKit
import _MediaGenerationKit

extension Automation {
  /// Checks the Draw Things project format end to end on a scratch project, as PASS/FAIL lines:
  /// append, list, settings round trip, image round trip, thumbnails, delete and renumbering.
  ///
  ///   Atelier --project-check [--keep DIR] [--quit]
  ///
  /// With `--keep DIR` the scratch project is left at DIR/Check.sqlite3 for other readers
  /// (DTDB Browser, sqlite3).
  static func projectCheck(_ model: CreateModel) {
    let args = CommandLine.arguments
    let keep = args.firstIndex(of: "--keep").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      while model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let base = model.settings, let modelFile = model.selectedModel else { return }

      let directory = keep.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "atelier-project-check-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("Check.sqlite3")
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
      let project = Project(url: url)

      // Three steps with different settings.
      var variants: [PipelineConfiguration] = [base]
      var second = base
      second.steps = base.steps + 3
      second.shift = base.shift + 0.5
      second.hiresFix = !base.hiresFix
      second.width = 768
      second.height = 512
      variants.append(second)
      var third = base
      third.guidanceScale = base.guidanceScale + 1
      third.loras = [LoRA(file: "example_lora_f16.ckpt", weight: 0.75, mode: .all)]
      third.tiledDecoding = true
      variants.append(third)

      guard let original = gradient(width: 320, height: 192),
        let tensor = ImageTensor.tensor(from: original)
      else {
        check(false, "couldn't build a test image")
        return
      }
      var appended: [HistoryItem] = []
      for (index, settings) in variants.enumerated() {
        var settings = settings
        settings.seed = UInt32(1000 + index)
        do {
          let item = try await project.append(
            tensor: tensor, model: modelFile, prompt: "check prompt \(index) “quoted” ✓",
            negativePrompt: index == 1 ? "blurry" : "", seed: settings.seed,
            settings: JSONValue.fields(of: settings), createdAt: Date(), duration: 1.5 + Double(index))
          appended.append(item)
        } catch {
          check(false, "append \(index): \(error.localizedDescription)")
        }
      }
      check(appended.map(\.id.logicalTime) == [0, 1, 2], "appended steps 0, 1, 2 on lineage 0")

      let items = project.items()
      check(items.map(\.id.logicalTime) == [2, 1, 0], "items lists the main line newest first")
      for (index, settings) in variants.enumerated() {
        guard let item = items.first(where: { $0.id.logicalTime == Int64(index) }) else { continue }
        var expected = JSONValue.fields(of: settings)
        expected["seed"] = .number(Double(1000 + index))
        let read = item.sidecar.configuration
        let differing = Set(expected.keys).union(read.keys).filter { expected[$0] != read[$0] }
          .sorted()
        check(differing.isEmpty, "step \(index): every configuration field round-trips \(differing.map { "\($0): \(expected[$0].map { "\($0)" } ?? "missing") → \(read[$0].map { "\($0)" } ?? "missing")" })")
        var restored = base
        SettingsRegistry.apply(dump: read, to: &restored)
        let registry = SettingsRegistry.all.filter { $0.get(restored) != $0.get(settings) }.map(\.id)
        check(registry.isEmpty, "step \(index): Use settings restores all registry fields \(registry)")
        check(
          item.sidecar.prompt == "check prompt \(index) “quoted” ✓"
            && item.sidecar.negativePrompt == (index == 1 ? "blurry" : "")
            && item.sidecar.seed == UInt32(1000 + index) && item.sidecar.model == modelFile,
          "step \(index): prompt, negative prompt, seed and model")
      }

      if let item = items.first, let image = project.image(for: item),
        let difference = pixelDifference(original, image)
      {
        check(difference.maxDelta == 0, "image round trip is exact (max channel delta \(difference.maxDelta))")
      } else {
        check(false, "image round trip: couldn't read the image back")
      }
      if let item = items.first {
        let full = project.thumbnail(previewId: item.previewId, half: false)
        let half = project.thumbnail(previewId: item.previewId, half: true)
        check(
          full?.width == 320 && half.map { $0.width < 320 } == true,
          "thumbnails: full \(full?.width ?? 0)×\(full?.height ?? 0), half \(half?.width ?? 0)×\(half?.height ?? 0)")
      }

      // Delete the middle step: the last one moves down to step 1.
      let middle = items.first { $0.id.logicalTime == 1 }
      if let middle {
        do {
          try await project.delete(middle.id)
          let after = project.items()
          check(after.map(\.id.logicalTime) == [1, 0], "deleting step 1 renumbers step 2 to 1")
          check(
            after.first?.sidecar.seed == 1002 && after.first.flatMap { project.image(for: $0) } != nil,
            "the moved step keeps its settings and image")
          check(
            project.thumbnail(previewId: middle.previewId, half: false) == nil
              && project.tensor(id: middle.tensorId) == nil,
            "the deleted step's thumbnail and tensor are gone")
        } catch {
          check(false, "delete: \(error.localizedDescription)")
        }
      }

      // Edit steps: a non-generated input step, then a step recording it as its input.
      if let base = project.items().first {
        do {
          let input = try await project.append(
            tensor: tensor, model: modelFile, prompt: "input", negativePrompt: "", seed: 0,
            settings: JSONValue.fields(of: variants[0]), createdAt: Date(), duration: 0,
            reason: .other, generated: false)
          let edit = try await project.append(
            tensor: tensor, model: modelFile, prompt: "edit", negativePrompt: "", seed: 7,
            settings: JSONValue.fields(of: variants[0]), createdAt: Date(), duration: 2,
            inputTensorId: input.tensorId)
          let iterate = try await project.append(
            tensor: tensor, model: modelFile, prompt: "iterate", negativePrompt: "", seed: 8,
            settings: JSONValue.fields(of: variants[0]), createdAt: Date(), duration: 2,
            inputTensorId: edit.tensorId)
          let listed = project.items()
          check(
            listed.map(\.id.logicalTime) == [4, 3, 1, 0],
            "History lists only generated steps (\(listed.map(\.id.logicalTime)))")
          check(
            listed.first?.inputTensorId == edit.tensorId && listed.last?.inputTensorId == nil,
            "the input tensor id round-trips through profile_data")
          check(
            project.input(of: edit.id, tensorId: input.tensorId)?.id == input.id
              && project.input(of: iterate.id, tensorId: edit.tensorId)?.id == edit.id,
            "an Edit step finds its input step")
          try await project.delete(input.id)
          let renumbered = project.items()
          let movedEdit = renumbered.first { $0.tensorId == edit.tensorId }
          let movedIterate = renumbered.first { $0.tensorId == iterate.tensorId }
          check(
            movedEdit.map { project.input(of: $0.id, tensorId: input.tensorId) == nil } == true,
            "deleting the input step: its Edit step falls back (parent is now step \(base.id.logicalTime))")
          check(
            movedIterate.flatMap { project.input(of: $0.id, tensorId: edit.tensorId) }?.id
              == movedEdit?.id,
            "renumbering keeps the link of a later Edit step")
        } catch {
          check(false, "edit steps: \(error.localizedDescription)")
        }
      }

      await project.close()
      let reopened = Project(url: url)
      check(reopened.items().count == 4, "a reopened project lists the same steps")
      await reopened.close()
      if keep == nil {
        try? FileManager.default.removeItem(at: directory)
      } else {
        print("kept \(url.path)")
      }
      print(failures == 0 ? "project check: all passed" : "project check: \(failures) failed")
      fflush(stdout)
      if args.contains("--quit") { NSApp.terminate(nil) }
    }
  }

  /// Use Settings on Edit steps, end to end with real runs (use a scratch `--project`):
  /// an Edit run from `--input`, then one iterating on its result; Use Settings on the second
  /// must put the first result back on the canvas in Edit mode and rerunning must reproduce the
  /// second; after deleting the first result, Use Settings falls back to the result with a note.
  ///
  ///   Atelier --edit-input-check --project NAME --input FILE [--model M] [--steps N]
  ///           [--width W --height H] [--strength S] [--seed N] [--quit]
  static func editInputCheck(_ model: CreateModel) {
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
      func finish() {
        print(failures == 0 ? "edit input check: all passed" : "edit input check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { NSApp.terminate(nil) }
      }
      @MainActor func idle() async {
        try? await Task.sleep(for: .milliseconds(200))
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      }
      @MainActor func run() async -> HistoryItem? {
        let previous = model.lastSavedStep
        model.generate()
        await idle()
        if let error = model.errorMessage { print("error: \(error)") }
        guard let step = model.lastSavedStep, step != previous else { return nil }
        return model.history.item(step)
      }
      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let path = value("--input"), let input = ImageLoader.image(at: URL(fileURLWithPath: path))
      else {
        check(false, "--input FILE is required and must be readable")
        return finish()
      }
      if let file = value("--model") {
        model.selectedModel = file
        await idle()
      }
      guard var settings = model.settings else { return finish() }
      settings.steps = value("--steps").flatMap(Int.init) ?? 4
      if let width = value("--width").flatMap(Int.init) { settings.width = width }
      if let height = value("--height").flatMap(Int.init) { settings.height = height }
      if let strength = value("--strength").flatMap(Float.init) { settings.strength = strength }
      model.settings = settings
      model.seed = value("--seed").flatMap(UInt32.init) ?? 42
      model.seedLocked = true
      model.prompt = "make it a watercolor painting"
      model.setCanvasImage(input)

      guard let first = await run() else {
        check(false, "first Edit run saved nothing")
        return finish()
      }
      check(first.inputTensorId != nil, "first Edit run records its input")
      model.prompt = "add a full moon in the sky"
      guard let second = await run() else {
        check(false, "second Edit run saved nothing")
        return finish()
      }
      check(
        second.inputTensorId == first.tensorId && second.id.logicalTime == first.id.logicalTime + 1,
        "iterating in place records the first result as input, with no extra step")
      guard let firstImage = await model.history.image(for: first),
        let secondImage = await model.history.image(for: second)
      else {
        check(false, "couldn't read the results back")
        return finish()
      }

      model.canvasMode = .generate
      model.prompt = ""
      model.use(second)
      await idle()
      try? await Task.sleep(for: .milliseconds(500))
      let restored = model.image.flatMap { pixelDifference($0, firstImage) }
      check(
        restored?.maxDelta == 0 && model.canvasMode == .edit && model.canvas.scale == nil,
        "Use Settings on the second step puts the first result on the canvas, fitted, in Edit mode")
      check(model.prompt == second.sidecar.prompt, "and loads the second step's prompt")
      if let rerun = await run(), let rerunImage = await model.history.image(for: rerun),
        let difference = pixelDifference(rerunImage, secondImage)
      {
        check(
          rerun.inputTensorId != nil && rerun.inputTensorId != first.tensorId,
          "the rerun records a copy of its input as a step of its own")
        check(
          difference.meanDelta < 2,
          "rerunning reproduces the second step (mean channel delta \(difference.meanDelta.formatted(.number.precision(.fractionLength(2)))), max \(difference.maxDelta))")
      } else {
        check(false, "rerun saved nothing")
      }

      do {
        try await model.history.delete([first])
      } catch {
        check(false, "delete: \(error.localizedDescription)")
      }
      guard let moved = model.history.items.first(where: { $0.tensorId == second.tensorId }) else {
        check(false, "the second step is gone after deleting the first")
        return finish()
      }
      model.canvasMode = .generate
      model.use(moved)
      await idle()
      try? await Task.sleep(for: .milliseconds(500))
      let fallback = model.image.flatMap { pixelDifference($0, secondImage) }
      check(
        fallback?.maxDelta == 0 && model.statusNote != nil && model.canvasMode == .generate,
        "with its input deleted, Use Settings shows the result and a note (\(model.statusNote ?? "no note"))")
      finish()
    }
  }

  /// A test image with distinct values in every channel.
  private static func gradient(width: Int, height: Int) -> CGImage? {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        bytes[i] = UInt8(x * 255 / (width - 1))
        bytes[i + 1] = UInt8(y * 255 / (height - 1))
        bytes[i + 2] = UInt8((x * 7 + y * 13) % 256)
      }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}
