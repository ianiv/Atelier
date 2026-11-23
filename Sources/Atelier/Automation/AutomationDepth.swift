#if os(macOS)
import SwiftUI

extension Automation {
  /// Checks Extract Depth Map end to end with the real depth model and no generation model: saves
  /// a picture (a sky over a receding checkered floor, or `--input-image FILE`) as a step, shows it
  /// on the canvas, chooses the canvas menu's command and prints PASS/FAIL lines: the command is a
  /// Queue job on this device for that step in its project, unavailable while it waits and not
  /// queued twice; the result is a new step whose parent and input are the source, records
  /// `depth_map`, is what the canvas shows, has the source's size, and is grey (R = G = B) across
  /// a real range (not constant), with the floor at the bottom (near) lighter than the sky (far);
  /// Match Colors is unavailable for it. The same for an image brought in from outside (an
  /// Imported entry). Then the agent tool: `extract_depth_map` on a step waits and returns the new
  /// step, in the background returns a job a second call joins, and fails clearly for a missing
  /// step or a bad argument. `--snapshot-dir DIR` saves the source and its depth map as PNGs.
  ///
  ///   Atelier --depth-check --project NAME [--input-image FILE] [--snapshot-dir DIR] [--quit]
  ///
  /// Always pass a scratch `--project`: it adds steps to it. It never downloads the model: when
  /// it isn't in a models folder the check fails and says so (Extract Depth Map in the canvas menu
  /// downloads it).
  static func depthCheck(_ model: CreateModel, presets: PresetStore) {
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
      let pausedBefore = model.queue.isPaused
      @MainActor func finish() {
        model.setQueuePaused(pausedBefore)
        print(failures == 0 ? "depth check: all passed" : "depth check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      while !model.history.isLoaded || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let settings = model.settings else { return finish() }
      let history = model.history
      let projectName = history.project.name
      guard DepthMap.isModelInstalled else {
        check(false, "the depth model \(DepthMap.modelFile) is in a models folder: it isn't. Choose Extract Depth Map in the canvas menu once to download it, then run the check again")
        return finish()
      }
      let snapshots = value("--snapshot-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
      if let snapshots { try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }

      // The picture: a file, or a pale sky over a checkered floor that recedes to the horizon,
      // whose depth plainly runs from near at the bottom to far at the top.
      var picture: CGImage?
      if let path = value("--input-image") {
        picture = ImageLoader.image(at: URL(fileURLWithPath: path))
      } else {
        let width = 768, height = 512, horizon = 200
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
          for x in 0..<width {
            let index = (y * width + x) * 4
            if y < horizon {
              let t = Double(y) / Double(horizon)
              pixels[index] = UInt8(120 + 80 * t)
              pixels[index + 1] = UInt8(170 + 60 * t)
              pixels[index + 2] = 235
            } else {
              // Floor coordinates under perspective: rows nearer the horizon are farther away.
              let distance = 4000 / Double(y - horizon + 8)
              let across = (Double(x) - Double(width) / 2) * distance / 400
              let light = (Int((distance / 3).rounded(.down)) + Int(across.rounded(.down))).isMultiple(of: 2)
              let shade = UInt8(min(255, 90 + Int(Double(y - horizon) * 0.4)))
              pixels[index] = light ? shade : shade / 3
              pixels[index + 1] = light ? shade : shade / 3
              pixels[index + 2] = light ? shade : shade / 3
            }
          }
        }
        picture = ColorMatch.cgImage(rgba: pixels, width: width, height: height)
      }
      guard let picture, let pictureTensor = ImageTensor.tensor(from: picture) else {
        check(false, "the source picture couldn't be made or read")
        return finish()
      }
      if let snapshots { try? ImageTensor.png(picture)?.write(to: snapshots.appending(path: "depth-source.png")) }

      /// Waits (up to 10 s) for the canvas to show `item`'s image.
      @MainActor func shown(_ tensorId: Int64) async -> Bool {
        for _ in 0..<100 {
          if model.canvasImageStep?.tensorId == tensorId, model.image != nil, !model.isLoadingCanvasImage { return true }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return false
      }
      /// Waits (up to 5 minutes, the first run loads the model) for job `id` to end.
      @MainActor func ended(_ id: UUID) async -> JobQueue.Job? {
        for _ in 0..<3000 {
          if let job = model.queue.recent.first(where: { $0.id == id }) { return job }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
      }
      /// The image's grey levels: whether R = G = B everywhere, the lowest and highest, and the
      /// mean of the top and bottom fifths.
      func levels(_ image: CGImage) -> (grey: Bool, low: Int, high: Int, top: Double, bottom: Double)? {
        guard let rgba = ColorMatch.rgba(image), rgba.count == image.width * image.height * 4 else { return nil }
        var grey = true, low = 255, high = 0
        var top = 0.0, bottom = 0.0, topCount = 0, bottomCount = 0
        for y in 0..<image.height {
          for x in 0..<image.width {
            let index = (y * image.width + x) * 4
            let r = Int(rgba[index]), g = Int(rgba[index + 1]), b = Int(rgba[index + 2])
            if r != g || g != b { grey = false }
            low = min(low, r)
            high = max(high, r)
            if y < image.height / 5 {
              top += Double(r)
              topCount += 1
            } else if y >= image.height * 4 / 5 {
              bottom += Double(r)
              bottomCount += 1
            }
          }
        }
        return (grey, low, high, top / Double(max(topCount, 1)), bottom / Double(max(bottomCount, 1)))
      }
      /// Runs the canvas menu's command for the step the canvas shows (`sourceTensorId`) and checks
      /// what it saves. Returns the saved step.
      @MainActor func extractFromCanvas(_ sourceTensorId: Int64, _ what: String) async -> HistoryItem? {
        guard await shown(sourceTensorId) else {
          check(false, "\(what): the canvas shows the source")
          return nil
        }
        check(model.canExtractCanvasDepthMap, "\(what): Extract Depth Map is available for the image on the canvas")
        // Held at first, so it can be seen waiting.
        model.setQueuePaused(true)
        model.extractCanvasDepthMap()
        guard let queued = model.queue.waiting.last, let depth = queued.request?.depthMap else {
          check(false, "\(what): the command joined the queue (\(model.errorMessage ?? "no error"))")
          model.setQueuePaused(false)
          return nil
        }
        check(
          depth.project == projectName && depth.sourceTensorId == sourceTensorId && queued.target == .local
            && queued.request?.parentTensorId == sourceTensorId,
          "\(what): the command joined the queue, on this device, for the image in its project, after it")
        check(!model.canExtractCanvasDepthMap, "\(what): the command is unavailable while its job waits")
        let waiting = model.queue.waiting.count
        if let item = model.canvasImageStep { _ = try? model.queueDepthMap(item) }
        check(model.queue.waiting.count == waiting, "\(what): the same image isn't queued twice")
        model.setQueuePaused(false)
        guard let job = await ended(queued.id), case .finished(let tensorId) = job.status else {
          check(false, "\(what): the job finished (\(model.queue.recent.first { $0.id == queued.id }.map { "\($0.status)" } ?? "still running"))")
          return nil
        }
        while model.isBusy { try? await Task.sleep(for: .milliseconds(50)) }
        guard let saved = history.item(tensorId: tensorId) else {
          check(false, "\(what): the result is a step of the project")
          return nil
        }
        let parent = history.parent(of: saved)
        check(
          parent?.tensorId == sourceTensorId && saved.inputTensorId != nil,
          "\(what): the result is a new step after the source, which is its input (parent \(parent.map { "\($0.tensorId)" } ?? "none"), input \(saved.inputTensorId.map { "\($0)" } ?? "none"))")
        check(saved.sidecar.depthMap?.model == DepthMap.modelFile, "\(what): the step records depth_map with the model")
        check(saved.accessibilityDescription.hasPrefix("Depth map"), "\(what): VoiceOver calls it a depth map (“\(saved.accessibilityDescription)”)")
        check(model.canvasImageStep?.tensorId == saved.tensorId && model.image != nil, "\(what): the canvas shows the depth map")
        check(!model.hasOriginal(saved) && !model.canOpenMatchColors, "\(what): Match Colors is unavailable for a depth map")
        guard let image = await history.image(tensorId: saved.tensorId, in: projectName), let level = levels(image) else {
          check(false, "\(what): the depth map reads back from the project")
          return saved
        }
        if let snapshots {
          try? ImageTensor.png(image)?.write(to: snapshots.appending(path: "depth-\(what.replacingOccurrences(of: " ", with: "-")).png"))
        }
        check(image.width == picture.width && image.height == picture.height, "\(what): the depth map is the source's size (\(image.width)×\(image.height))")
        check(level.grey, "\(what): the depth map is grey (R = G = B)")
        check(level.low <= 40 && level.high >= 215, "\(what): it spans the range, not constant (\(level.low)–\(level.high))")
        if value("--input-image") == nil {
          check(
            level.bottom > level.top + 40,
            "\(what): near is light and far dark: the floor at the bottom (\(Int(level.bottom))) is lighter than the sky (\(Int(level.top)))")
        }
        return saved
      }

      // A saved step, shown on the canvas as a click in History shows it.
      var configuration = settings
      configuration.width = picture.width
      configuration.height = picture.height
      let request = GenerationEngine.Request(
        model: model.selectedModel ?? "", prompt: "depth check: a floor under the sky", negativePrompt: "", seed: 3, configuration: configuration)
      let step: HistoryItem
      do {
        step = try await history.save(GenerationEngine.Output(frames: [pictureTensor]), request: request, startedAt: Date(), finishedAt: Date())
      } catch {
        check(false, "saving the source step: \(error.localizedDescription)")
        return finish()
      }
      model.show(step)
      guard let fromStep = await extractFromCanvas(step.tensorId, "a saved step") else { return finish() }

      // An image brought in from outside: an Imported entry, which the canvas adopts as its step.
      model.setCanvasImage(picture)
      var imported: Int64?
      for _ in 0..<100 {
        if let item = model.canvasImageStep, item.isEntry { imported = item.tensorId; break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      if let imported {
        _ = await extractFromCanvas(imported, "an imported image")
      } else {
        check(false, "an imported image: the canvas adopts its Imported entry")
      }

      // The agent tool.
      let tools = AgentTools(create: model, presets: presets)
      @MainActor func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        try? await Task.sleep(for: .milliseconds(20))
        let result = try await tools.call(name, arguments: arguments) { _ in }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
      }
      @MainActor func expectError(_ arguments: [String: Any], _ hint: String, _ what: String) async {
        do {
          _ = try await call("extract_depth_map", arguments)
          check(false, "\(what): extract_depth_map should fail")
        } catch {
          check(error.localizedDescription.contains(hint), "\(what): extract_depth_map fails (“\(error.localizedDescription)”)")
        }
      }
      let sourceStep = history.item(tensorId: step.tensorId)?.id.logicalTime ?? step.id.logicalTime
      do {
        let answer = try await call("extract_depth_map", ["history_step": sourceStep])
        let made = (answer["history_step"] as? NSNumber).flatMap { number in history.items.first { $0.id.logicalTime == number.int64Value && $0.sidecar.depthMap != nil } }
        check(
          made != nil && made?.tensorId != fromStep.tensorId && (answer["source_step"] as? NSNumber)?.int64Value == sourceStep
            && history.parent(of: made!)?.tensorId == step.tensorId,
          "extract_depth_map waits and returns a new depth map step after the source (\(answer))")
      } catch {
        check(false, "extract_depth_map on a step (\(error.localizedDescription))")
      }
      do {
        model.setQueuePaused(true)
        let first = try await call("extract_depth_map", ["history_step": sourceStep, "background": true])
        let second = try await call("extract_depth_map", ["history_step": sourceStep, "background": true])
        let id = first["job_id"] as? String
        check(id != nil && id == second["job_id"] as? String, "a second extract_depth_map call for the same image joins the first's job (\(id ?? "none"), \(second["job_id"] ?? "none"))")
        check(model.queue.waiting.count(where: { $0.request?.depthMap != nil }) == 1, "and the queue holds one job for it")
        model.setQueuePaused(false)
        let done = try await call("get_job", ["job_id": id ?? "", "wait_seconds": 60])
        // A finished job answers with its tool's result.
        let collected = (done["history_step"] as? NSNumber).flatMap { number in history.items.first { $0.id.logicalTime == number.int64Value } }
        check(
          collected?.sidecar.depthMap != nil && done["job_id"] as? String == id,
          "get_job collects the background depth map (\(done["history_step"] ?? done["status"] ?? "nothing"))")
      } catch {
        model.setQueuePaused(false)
        check(false, "extract_depth_map in the background (\(error.localizedDescription))")
      }
      await expectError(["history_step": 999_999], "list_history", "a missing step")
      await expectError(["history_step": "one"], "history step number", "a step that's no number")
      await expectError(["background": "yes"], "true or false", "a background that's no boolean")

      while model.isBusy || !model.queue.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
      finish()
    }
  }
}
#endif
