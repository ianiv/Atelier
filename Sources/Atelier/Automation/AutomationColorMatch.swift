#if os(macOS)
import SwiftUI

extension Automation {
  /// Checks Match Colors to Original end to end, with no model run: appends an original (a
  /// gradient, or `--input-image FILE`) and a copy of it shifted warmer as an Edit step after it,
  /// puts the copy on the canvas, matches it from the canvas menu's action, and prints PASS/FAIL
  /// lines: the match is a Queue job (with progress, then in Recent with its time), the action is
  /// unavailable and a second match isn't queued while it's pending, the result is a new step
  /// after the edit, the reported Δb is the shift put in, the result's colors are the original's,
  /// the canvas shows it, matching it again goes back to the same original, a match left waiting
  /// while another project opens saves into its own project and leaves the open one and the
  /// canvas alone, and the action is unavailable for a step with no original, for a video, and
  /// for a step whose moodboard images all have weight 0.
  ///
  ///   Atelier --color-match-check --project NAME [--input-image FILE] [--quit]
  ///
  /// Always pass a scratch `--project`: it adds steps to it, and opens (creating it) the project
  /// "NAME other" for the other-project case.
  static func colorMatchCheck(_ model: CreateModel) {
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
        print(failures == 0 ? "color match check: all passed" : "color match check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      /// Waits (up to 10 s) for the canvas to show `item`'s image.
      @MainActor func shown(_ item: HistoryItem) async -> Bool {
        for _ in 0..<100 {
          if model.imageItem == item, model.image != nil, !model.isLoadingCanvasImage { return true }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return false
      }
      while !model.history.isLoaded || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let settings = model.settings else { return finish() }
      let history = model.history
      let projectName = history.project.name

      // The original: a file, or a smooth gradient of mid tones.
      var source: CGImage?
      if let path = value("--input-image") {
        source = ImageLoader.image(at: URL(fileURLWithPath: path))
      } else {
        // Large enough that the match takes a moment, so its progress can be seen.
        let width = 1536
        let height = 1152
        var pixels: [UInt8] = []
        for y in 0..<height {
          for x in 0..<width {
            pixels += [UInt8(50 + x * 150 / width), UInt8(60 + y * 130 / height), UInt8(80 + (x + 2 * y) % 100), 255]
          }
        }
        source = ColorMatch.cgImage(rgba: pixels, width: width, height: height)
      }
      guard let source else {
        check(false, "the original image couldn't be read")
        return finish()
      }
      // As read back from the project (8-bit RGB), so the comparisons see what the action sees.
      guard let originalTensor = ImageTensor.tensor(from: source), let original = ImageTensor.cgImage(from: originalTensor),
            let originalPixels = ColorMatch.rgba(original)
      else { return finish() }
      // The edit: the original shifted warmer (b +6) and a little magenta (a +1).
      let injected = SIMD3<Double>(0, 1, 6)
      var planes = ColorMatch.lab(rgba: originalPixels)
      planes.a = planes.a.map { $0 + injected.y }
      planes.b = planes.b.map { $0 + injected.z }
      let warmPixels = ColorMatch.encoded(lab: planes, alpha: [UInt8](repeating: 255, count: planes.l.count))
      guard let warm = ColorMatch.cgImage(rgba: warmPixels, width: original.width, height: original.height),
            let warmTensor = ImageTensor.tensor(from: warm)
      else { return finish() }

      // The original goes in as an Imported step, the warm copy as an Edit step after it.
      var configuration = settings
      configuration.width = original.width
      configuration.height = original.height
      let modelFile = model.selectedModel ?? ""
      var request = GenerationEngine.Request(
        model: modelFile, prompt: "color match check: warmer", negativePrompt: "", seed: 1, configuration: configuration)
      request.canvas = original
      request.canvasIsImported = true
      let edit: HistoryItem
      let plain: HistoryItem
      let video: HistoryItem
      var unweighted: HistoryItem
      var weighted: HistoryItem
      do {
        edit = try await history.save(
          GenerationEngine.Output(frames: [warmTensor]), request: request, startedAt: Date(), finishedAt: Date())
        // A step made from the prompt alone, and a two-frame video: neither has an original.
        let generated = GenerationEngine.Request(
          model: modelFile, prompt: "color match check: no original", negativePrompt: "", seed: 2, configuration: configuration)
        plain = try await history.save(
          GenerationEngine.Output(frames: [originalTensor]), request: generated, startedAt: Date(), finishedAt: Date())
        var clip = GenerationEngine.Output(frames: [originalTensor, warmTensor])
        clip.framesPerSecond = 8
        video = try await history.save(clip, request: generated, startedAt: Date(), finishedAt: Date())
        // Steps made from a moodboard image alone: at weight 0 the model didn't take it.
        var moodboarded = generated
        moodboarded.moodboard = [GenerationEngine.Reference(image: original, weight: 0)]
        unweighted = try await history.save(
          GenerationEngine.Output(frames: [warmTensor]), request: moodboarded, startedAt: Date(), finishedAt: Date())
        moodboarded.moodboard = [GenerationEngine.Reference(image: original, weight: 1)]
        weighted = try await history.save(
          GenerationEngine.Output(frames: [warmTensor]), request: moodboarded, startedAt: Date(), finishedAt: Date())
      } catch {
        check(false, "saving the check's steps: \(error.localizedDescription)")
        return finish()
      }
      guard let originalTensorId = edit.inputTensorId else {
        check(false, "the edit step records its original as its input")
        return finish()
      }
      print("project \(projectName): original \(originalTensorId), edit \(edit.tensorId)")

      // Unavailable without an original, and for a video.
      model.show(plain)
      check(await shown(plain) && !model.canMatchCanvasColors, "unavailable for a step with no original")
      model.show(video)
      try? await Task.sleep(for: .seconds(1))
      check(!model.hasOriginal(video) && !model.canMatchCanvasColors, "unavailable for a video")
      check(!model.hasOriginal(unweighted) && model.hasOriginal(weighted), "a moodboard counts only with weight above 0, as saved")
      // As read back from the project, as History lists them after opening it.
      await history.reload()
      if let listed = history.items.first(where: { $0.tensorId == unweighted.tensorId }) { unweighted = listed }
      if let listed = history.items.first(where: { $0.tensorId == weighted.tensorId }) { weighted = listed }
      check(
        unweighted.moodboardCount == 1 && !model.hasOriginal(unweighted) && model.hasOriginal(weighted),
        "a moodboard counts only with weight above 0, as read back")
      model.show(unweighted)
      check(await shown(unweighted) && !model.canMatchCanvasColors, "unavailable when every moodboard image has weight 0")

      // From the canvas, as the menu item does.
      model.show(edit)
      guard await shown(edit), model.canMatchCanvasColors else {
        check(false, "available for the edited image on the canvas")
        return finish()
      }
      check(true, "available for the edited image on the canvas")
      /// Waits (up to 60 s) for job `id` to show in Recent, noting the most progress seen.
      @MainActor func ended(_ id: UUID) async -> (job: JobQueue.Job?, step: Int) {
        var most = 0
        for _ in 0..<60_000 {
          if let job = model.queue.recent.first(where: { $0.id == id }) { return (job, most) }
          if let running = model.queue.running, running.id == id { most = max(most, model.runProgress(of: running)?.step ?? 0) }
          try? await Task.sleep(for: .milliseconds(1))
        }
        return (nil, most)
      }
      // Held at first, so it can be seen waiting.
      model.setQueuePaused(true)
      let before = Set(history.items.map(\.tensorId))
      model.matchCanvasColors()
      guard let queued = model.queue.waiting.last, let match = queued.request?.colorMatch else {
        check(false, "the match joined the queue (\(model.errorMessage ?? "no error"))")
        return finish()
      }
      check(
        match.project == projectName && match.sourceTensorId == edit.tensorId && queued.target == .local,
        "the match joined the queue, on this device, for the edit in its project")
      check(!model.canMatchCanvasColors, "the menu item is disabled while the match is waiting")
      let again = try? model.queueColorMatch(edit)
      check(
        again == queued.id && model.queue.waiting.count(where: { $0.request?.colorMatch != nil }) == 1,
        "a second match of the same step isn't queued")
      check(!model.queue.uses(edit.sidecar.model), "the match doesn't count as using its step's model")
      model.setQueuePaused(false)
      let (endedJob, most) = await ended(queued.id)
      guard let endedJob, case .finished(let resultTensorId) = endedJob.status else {
        check(false, "the match finished (\(endedJob.map { "\($0.status)" } ?? "still running"), \(model.errorMessage ?? "no error"))")
        return finish()
      }
      check(most > 0, "the running match showed progress (step \(most) of 1000)")
      check(endedJob.elapsed != nil, "Recent lists the match with how long it took (\(endedJob.elapsed.map { GenerationTime.text($0) } ?? "none"))")
      check(endedJob.request?.colorMatch?.record?.shift != nil, "the Recent entry keeps the shift taken out")
      check(model.canMatchCanvasColors || model.imageItem?.tensorId != edit.tensorId, "matching is available again once it's done")
      try? await Task.sleep(for: .milliseconds(200))
      guard let result = history.items.first(where: { !before.contains($0.tensorId) }), result.tensorId == resultTensorId else {
        check(false, "a result was saved (\(model.errorMessage ?? "no error"))")
        return finish()
      }
      check(
        history.parent(of: result)?.tensorId == edit.tensorId && result.inputTensorId == edit.tensorId,
        "the result is a new step after the edit")
      check(
        result.sidecar.colorMatch.map { $0.strength == 1 && !$0.luminance && $0.originalTensorId == originalTensorId && $0.shift != nil } == true,
        "the result records the match and its original (\(result.sidecar.colorMatch.map { "\($0)" } ?? "none"))")
      check(result.sidecar.prompt == edit.sidecar.prompt && result.sidecar.seed == edit.sidecar.seed, "the result keeps the edit's settings")
      let note = model.statusNote ?? ""
      let reported = note.range(of: "Δb ").flatMap { range in
        Double(note[range.upperBound...].prefix { "+-.0123456789".contains($0) })
      }
      check(
        reported.map { abs($0 - injected.z) < 0.5 } == true && note.contains("warmer"),
        "the status bar reports the shift put in, Δb +\(injected.z): “\(note)”")
      guard let made = await history.image(tensorId: result.tensorId, in: projectName), let madePixels = ColorMatch.rgba(made)
      else {
        check(false, "the result can be read back")
        return finish()
      }
      let originalStats = ColorMatch.stats(rgba: ColorMatch.downsampled(originalPixels, width: original.width, height: original.height))
      let madeStats = ColorMatch.stats(rgba: ColorMatch.downsampled(madePixels, width: made.width, height: made.height))
      let difference = madeStats.mean - originalStats.mean
      check(
        abs(difference.y) < 0.3 && abs(difference.z) < 0.3,
        String(format: "the result's colors are the original's (mean a %+.2f, b %+.2f off)", difference.y, difference.z))
      check(abs(difference.x) < 0.5, String(format: "lightness is left alone (mean L %+.2f off)", difference.x))
      check(await shown(result) && model.image?.width == made.width, "the canvas shows the result")

      // Matching the result again goes back to the same original, so there's nothing left to take out.
      do {
        let again = try await model.matchColors(forAgent: result, options: ColorMatch.Options()) { _, _ in }
        let shift = again.sidecar.colorMatch?.shift ?? ColorMatch.Shift(l: 99, a: 99, b: 99)
        check(
          again.sidecar.colorMatch?.originalTensorId == originalTensorId && abs(shift.b) < 0.3 && abs(shift.a) < 0.3,
          String(format: "matching the result again uses the same original (Δa %+.2f, Δb %+.2f)", shift.a, shift.b))
      } catch {
        check(false, "matching the result again: \(error.localizedDescription)")
      }

      // Left waiting while another project opens: it saves into its own, not the open one, and
      // leaves the canvas alone.
      model.setQueuePaused(true)
      guard let otherID = try? model.queueColorMatch(edit) else {
        check(false, "a match of the edit could be queued again once the first was done")
        return finish()
      }
      let otherName = "\(projectName) other"
      await history.open(otherName)
      while !history.isLoaded { try? await Task.sleep(for: .milliseconds(50)) }
      try? await Task.sleep(for: .milliseconds(500))
      let otherBefore = Set(history.items.map(\.tensorId))
      let canvasBefore = model.image
      model.setQueuePaused(false)
      let (otherJob, _) = await ended(otherID)
      guard let otherJob, case .finished(let otherTensorId) = otherJob.status else {
        check(false, "the match left waiting finished after another project opened (\(otherJob.map { "\($0.status)" } ?? "still running"), \(model.errorMessage ?? "no error"))")
        return finish()
      }
      check(true, "the match left waiting finished after another project opened")
      await history.reload()
      check(
        history.project.name == otherName && Set(history.items.map(\.tensorId)) == otherBefore,
        "the open project (\(history.project.name)) is untouched")
      check(model.image === canvasBefore, "the canvas is untouched")
      guard let own = history.project(named: projectName) else {
        check(false, "the match's project is still there")
        return finish()
      }
      let ownTree = await own.read { $0.tree() }
      let saved = ownTree.step(tensorId: otherTensorId).flatMap { ownTree.items[$0] }
      check(
        saved?.inputTensorId == edit.tensorId && saved?.sidecar.colorMatch?.originalTensorId == originalTensorId,
        "the result was saved into the match's own project, after the edit")
      await history.open(projectName)
      while !history.isLoaded { try? await Task.sleep(for: .milliseconds(50)) }
      check(history.item(tensorId: otherTensorId) != nil, "the result is in History once its project is open again")
      finish()
    }
  }
}
#endif
