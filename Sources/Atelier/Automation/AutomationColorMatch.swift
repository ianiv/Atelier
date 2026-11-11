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
  /// for a step whose moodboard images all have weight 0. For Match Colors… (the sheet's
  /// settings): the one-click match records the default settings whatever the sheet last used, a
  /// match at half tint and saturation records that and leaves about half the shift, a match
  /// with other settings queues beside one that's waiting while the same settings don't, and the
  /// sheet can open while a match is pending (`--snapshot-dir DIR` saves a picture of it in each
  /// comparison mode, color-match-sheet-side.png and color-match-sheet-slider.png, and one of the
  /// Slider mode for a step whose original has another shape, color-match-sheet-slider-shape.png,
  /// where the bands beside the original must be plain, not the match). For a second edit, the warm copy with a green block pasted over a
  /// fifth of it: matched from its unchanged areas only, the step records how much of the image
  /// that was and the background's colors are the original's; matched with tint alone, the
  /// colors' mean is the original's and their spread the edit's. The sheet's remembered values
  /// are never written: the run's are set over them for this launch only, its size among them,
  /// so the pictures come out at the default 1000×800 whatever size the sheet was last dragged
  /// to. For that size: a remembered one is what the sheet opens at, one larger than the screen
  /// opens fitted to it, and neither is written to the settings. It also prints how
  /// long the sheet's preview takes to make and to draw once on the check's image (plain lines,
  /// neither PASS nor FAIL), for measuring it in a Release build.
  ///
  ///   Atelier --color-match-check --project NAME [--input-image FILE] [--snapshot-dir DIR] [--quit]
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
      // What the sheet last used, set away from the defaults for the run: the one-click match
      // mustn't read them. They go in the launch arguments' domain, which is read ahead of the
      // saved values and is never saved itself, so the user's own are untouched however the run
      // ends, a crash included.
      let defaults = UserDefaults.standard
      let launchValues = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      var runValues = launchValues
      for key in ["colorMatchTint", "colorMatchSaturation", "colorMatchBrightness", "colorMatchContrast"] { runValues[key] = 0.5 }
      runValues["colorMatchUnchangedOnly"] = true
      runValues["colorMatchCompareMode"] = ColorMatchSheet.CompareMode.sideBySide.rawValue
      // The sheet's size too, at its default: one the user dragged it to mustn't size the pictures.
      let sizeKeys = [RememberedSheetSize.widthKey(ColorMatchSheet.sizeKey), RememberedSheetSize.heightKey(ColorMatchSheet.sizeKey)]
      runValues[sizeKeys[0]] = Double(ColorMatchSheet.defaultSize.width)
      runValues[sizeKeys[1]] = Double(ColorMatchSheet.defaultSize.height)
      defaults.setVolatileDomain(runValues, forName: UserDefaults.argumentDomain)
      /// What the settings file holds for the sheet's size, which the run must leave as it is.
      func savedSize() -> [Double?] {
        let saved = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        return sizeKeys.map { saved[$0] as? Double }
      }
      let savedSizeBefore = savedSize()
      @MainActor func finish() {
        defaults.setVolatileDomain(launchValues, forName: UserDefaults.argumentDomain)
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

      // How long the sheet's preview takes: reading and measuring both images, then one draw.
      let clock = ContinuousClock()
      func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
      }
      let makeStart = clock.now
      let timed = await ColorMatch.Preview.make(edited: warm, original: original)
      let makeTime = clock.now - makeStart
      if let timed {
        let renderTime = clock.measure { _ = timed.render(ColorMatch.Options(unchangedOnly: true)) }
        print("timing: Preview.make \(milliseconds(makeTime)) for \(warm.width)×\(warm.height); render \(milliseconds(renderTime)) at \(timed.width)×\(timed.height)")
      } else {
        print("timing: the preview couldn't be made")
      }
      fflush(stdout)

      // The original goes in as an Imported step, the warm copy as an Edit step after it.
      var configuration = settings
      configuration.width = original.width
      configuration.height = original.height
      let modelFile = model.selectedModel ?? ""
      var request = GenerationEngine.Request(
        model: modelFile, prompt: "color match check: warmer", negativePrompt: "", seed: 1, configuration: configuration)
      request.canvas = original
      request.canvasIsImported = true
      // A second edit: the warm copy with a saturated green block pasted over a fifth of it, as an
      // edit that added something. Measured whole, the block reads as a shift of the whole image.
      let blockX = original.width / 10..<original.width * 6 / 10
      let blockY = original.height * 2 / 10..<original.height * 6 / 10
      var pastedPixels = warmPixels
      var background = [Bool](repeating: true, count: original.width * original.height)
      for y in blockY {
        for x in blockX {
          let index = y * original.width + x
          pastedPixels.replaceSubrange(index * 4..<index * 4 + 3, with: [20, 220, 40])
          background[index] = false
        }
      }
      guard let pastedImage = ColorMatch.cgImage(rgba: pastedPixels, width: original.width, height: original.height),
            let pastedTensor = ImageTensor.tensor(from: pastedImage)
      else { return finish() }
      let edit: HistoryItem
      let pasted: HistoryItem
      let plain: HistoryItem
      let video: HistoryItem
      var unweighted: HistoryItem
      var weighted: HistoryItem
      /// Made from a moodboard image of another shape (a square out of the original's middle).
      let reshaped: HistoryItem
      do {
        edit = try await history.save(
          GenerationEngine.Output(frames: [warmTensor]), request: request, startedAt: Date(), finishedAt: Date())
        var pastedRequest = request
        pastedRequest.prompt = "color match check: warmer, with a block added"
        pasted = try await history.save(
          GenerationEngine.Output(frames: [pastedTensor]), request: pastedRequest, startedAt: Date(), finishedAt: Date())
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
        let side = min(original.width, original.height)
        let square = original.cropping(to: CGRect(x: (original.width - side) / 2, y: (original.height - side) / 2, width: side, height: side))
        moodboarded.prompt = "color match check: an original of another shape"
        moodboarded.moodboard = [GenerationEngine.Reference(image: square ?? original, weight: 1)]
        reshaped = try await history.save(
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
      check(
        match.options == ColorMatch.Options() && !match.options.unchangedOnly,
        "the one-click match uses the default settings and the whole image, not what the sheet last used (\(match.options))")
      check(!model.canMatchCanvasColors, "the menu item is disabled while the match is waiting")
      check(model.canOpenMatchColors, "Match Colors… can still open while the match is waiting")
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
        result.sidecar.colorMatch.map {
          $0.options == ColorMatch.Options() && $0.counted == nil && $0.originalTensorId == originalTensorId && $0.shift != nil
        } == true,
        "the result records the match with the default settings and its original (\(result.sidecar.colorMatch.map { "\($0)" } ?? "none"))")
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

      // Match Colors…: other settings queue beside a match that's waiting, the same ones don't.
      model.setQueuePaused(true)
      let half = ColorMatch.Options(tint: 0.5, saturation: 0.5)
      guard let fullID = try? model.queueColorMatch(edit), let halfID = try? model.queueColorMatch(edit, options: half) else {
        check(false, "matches of the edit could be queued again once the first was done")
        return finish()
      }
      let halfAgain = try? model.queueColorMatch(edit, options: ColorMatch.Options(tint: 0.1 + 0.4, saturation: 0.5))
      check(
        halfID != fullID && model.queue.waiting.count(where: { $0.request?.colorMatch?.sourceTensorId == edit.tensorId }) == 2,
        "a match with other settings queues beside the one waiting")
      check(halfAgain == halfID, "a match with the same settings as one waiting isn't queued again")
      check(
        model.pendingColorMatch(for: edit, options: half)?.id == halfID && model.pendingColorMatch(for: edit)?.id == fullID
          && model.pendingColorMatch(for: edit, options: ColorMatch.Options(tint: 0.5, saturation: 0.5, brightness: 0.25)) == nil
          && model.pendingColorMatch(for: edit, options: ColorMatch.Options(tint: 0.5)) == nil
          && model.pendingColorMatch(for: edit, options: ColorMatch.Options(unchangedOnly: true)) == nil,
        "a pending match is found by its settings")
      model.show(edit)
      check(
        await shown(edit) && model.canOpenMatchColors && !model.canMatchCanvasColors,
        "while they wait, Match Colors… can open and the one-click item can't be chosen")
      // The sheet opens for the canvas image, as its menu item does, and keeps its step.
      model.colorMatchSheetItem = model.imageItem
      try? await Task.sleep(for: .seconds(1))
      check(model.colorMatchSheetItem?.tensorId == edit.tensorId, "the Match Colors… sheet opens for the canvas image")
      if let folder = value("--snapshot-dir") {
        // One picture per comparison mode. The sheet reads the mode when it opens, so it's opened
        // again for the second, with the mode set where the run's other values are.
        for mode in ColorMatchSheet.CompareMode.allCases {
          if mode != .sideBySide {
            model.colorMatchSheetItem = nil
            try? await Task.sleep(for: .seconds(1))
            runValues["colorMatchCompareMode"] = mode.rawValue
            defaults.setVolatileDomain(runValues, forName: UserDefaults.argumentDomain)
            model.colorMatchSheetItem = edit
          }
          // Once its preview is drawn.
          try? await Task.sleep(for: .seconds(8))
          let url = URL(fileURLWithPath: folder).appendingPathComponent("color-match-sheet-\(mode.rawValue).png")
          try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          print("\(AutomationWindows.snapshotSheet(to: url) ? "saved" : "couldn't save") \(url.path)")
        }
        // The Slider mode once more, for the step whose original has another shape: left of the
        // divider, the bands beside the original are a plain fill and not the match.
        model.colorMatchSheetItem = nil
        try? await Task.sleep(for: .seconds(1))
        model.colorMatchSheetItem = reshaped
        try? await Task.sleep(for: .seconds(8))
        let url = URL(fileURLWithPath: folder).appendingPathComponent("color-match-sheet-slider-shape.png")
        print("\(AutomationWindows.snapshotSheet(to: url) ? "saved" : "couldn't save") \(url.path)")
      }
      // The sheet's size. It opens at the remembered one, read as it opens; nothing in the run
      // drags it, so nothing is remembered anew.
      @MainActor func sizeOpened(remembering size: CGSize) async -> CGSize? {
        model.colorMatchSheetItem = nil
        try? await Task.sleep(for: .seconds(1))
        runValues[sizeKeys[0]] = Double(size.width)
        runValues[sizeKeys[1]] = Double(size.height)
        defaults.setVolatileDomain(runValues, forName: UserDefaults.argumentDomain)
        model.colorMatchSheetItem = edit
        try? await Task.sleep(for: .seconds(2))
        return AutomationWindows.sheetSize
      }
      func text(_ size: CGSize?) -> String { size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "no sheet" }
      if let screen = ScreenSpace.visibleSize {
        let room = CGSize(width: screen.width - RememberedSheetSize.screenMargin, height: screen.height - RememberedSheetSize.screenMargin)
        // One that fits any screen the default does.
        let small = CGSize(width: ColorMatchSheet.minSize.width + 60, height: ColorMatchSheet.minSize.height + 40)
        if small.width <= room.width, small.height <= room.height {
          let opened = await sizeOpened(remembering: small)
          check(opened == small, "the sheet opens at the size remembered (\(text(small))): \(text(opened))")
        } else {
          print("skipped: the screen (\(text(screen))) has no room for a sheet of \(text(small))")
        }
        let huge = CGSize(width: screen.width + 2000, height: screen.height + 2000)
        let expected = RememberedSheetSize.fitted(huge, minSize: ColorMatchSheet.minSize, screen: screen)
        let opened = await sizeOpened(remembering: huge)
        // No larger than the fit asked for, and no smaller than the minimum: the system may take
        // a little more off, for where the window is on the screen.
        let fits = opened.map {
          $0.width <= expected.width && $0.height <= expected.height
            && $0.width >= ColorMatchSheet.minSize.width && $0.height >= ColorMatchSheet.minSize.height
        } ?? false
        check(
          fits && (expected.width <= room.width || expected.width == ColorMatchSheet.minSize.width)
            && (expected.height <= room.height || expected.height == ColorMatchSheet.minSize.height),
          "a remembered size larger than the screen (\(text(huge)) on \(text(screen))) opens fitted to it: \(text(opened))")
        check(
          defaults.double(forKey: sizeKeys[0]) == Double(huge.width) && defaults.double(forKey: sizeKeys[1]) == Double(huge.height),
          "and the remembered size is still what it was")
      } else {
        print("skipped: no screen to fit the sheet to")
      }
      check(savedSize() == savedSizeBefore, "the sheet's size in the settings is untouched by the run")
      model.colorMatchSheetItem = nil
      try? await Task.sleep(for: .milliseconds(500))
      model.setQueuePaused(false)
      _ = await ended(fullID)
      let (halfJob, _) = await ended(halfID)
      guard let halfJob, case .finished(let halfTensorId) = halfJob.status,
            let halfResult = history.item(tensorId: halfTensorId),
            let halfImage = await history.image(tensorId: halfTensorId, in: projectName), let halfPixels = ColorMatch.rgba(halfImage)
      else {
        check(false, "the match at half tint and saturation finished (\(halfJob.map { "\($0.status)" } ?? "still running"), \(model.errorMessage ?? "no error"))")
        return finish()
      }
      check(
        halfResult.sidecar.colorMatch.map { $0.options == half && $0.originalTensorId == originalTensorId } == true,
        "the match at half tint and saturation records it (\(halfResult.sidecar.colorMatch.map { "\($0)" } ?? "none"))")
      let halfStats = ColorMatch.stats(rgba: ColorMatch.downsampled(halfPixels, width: halfImage.width, height: halfImage.height))
      let left = halfStats.mean - originalStats.mean
      check(
        abs(left.z - injected.z / 2) < 0.4 && abs(left.y - injected.y / 2) < 0.4,
        String(format: "the match at half tint and saturation leaves about half the shift (mean a %+.2f, b %+.2f off)", left.y, left.z))

      // The edit that added a block. From its unchanged areas only, the shift measured is the one
      // put in and the background goes back to the original's colors; measured whole it doesn't.
      func backgroundOff(_ pixels: [UInt8]) -> SIMD3<Double> {
        ColorMatch.stats(rgba: pixels, where: background).mean - ColorMatch.stats(rgba: originalPixels, where: background).mean
      }
      do {
        let saved = try await model.matchColors(forAgent: pasted, options: ColorMatch.Options(unchangedOnly: true)) { _, _ in }
        let record = saved.sidecar.colorMatch
        let counted = record?.counted ?? -1
        check(
          record?.options.unchangedOnly == true && counted > ColorMatch.minimumUnchangedFraction && counted < 1,
          String(format: "a match from the unchanged areas records how much of the image they are (%.1f%%)", counted * 100))
        let shift = record?.shift ?? ColorMatch.Shift(l: 99, a: 99, b: 99)
        check(
          abs(shift.b - injected.z) < 0.5 && abs(shift.a - injected.y) < 0.5,
          String(format: "its shift is the one put in, not the block's (Δa %+.2f, Δb %+.2f)", shift.a, shift.b))
        if let image = await history.image(tensorId: saved.tensorId, in: projectName), let pixels = ColorMatch.rgba(image) {
          let off = backgroundOff(pixels)
          check(
            abs(off.y) < 0.5 && abs(off.z) < 0.5,
            String(format: "the background's colors are the original's (mean a %+.2f, b %+.2f off)", off.y, off.z))
        } else {
          check(false, "the match from the unchanged areas can be read back")
        }
        let whole = try await model.matchColors(forAgent: pasted, options: ColorMatch.Options()) { _, _ in }
        if let image = await history.image(tensorId: whole.tensorId, in: projectName), let pixels = ColorMatch.rgba(image) {
          let off = backgroundOff(pixels)
          check(
            whole.sidecar.colorMatch?.counted == nil && max(abs(off.y), abs(off.z)) > 2,
            String(format: "measured whole, the block throws the background's colors off (mean a %+.2f, b %+.2f off)", off.y, off.z))
        } else {
          check(false, "the whole-image match of the same edit can be read back")
        }
        // Tint alone: the colors' mean goes to the original's, their spread stays the edit's.
        let tinted = try await model.matchColors(forAgent: pasted, options: ColorMatch.Options(saturation: 0)) { _, _ in }
        if let image = await history.image(tensorId: tinted.tensorId, in: projectName), let pixels = ColorMatch.rgba(image) {
          let made = ColorMatch.stats(rgba: ColorMatch.downsampled(pixels, width: image.width, height: image.height))
          let before = ColorMatch.stats(rgba: ColorMatch.downsampled(pastedPixels, width: original.width, height: original.height))
          let mean = made.mean - originalStats.mean
          let spread = made.std - before.std
          check(
            tinted.sidecar.colorMatch?.options == ColorMatch.Options(saturation: 0) && abs(mean.y) < 0.5 && abs(mean.z) < 0.5,
            String(format: "a tint-only match moves the colors' mean to the original's (a %+.2f, b %+.2f off)", mean.y, mean.z))
          check(
            abs(spread.y) < 0.5 && abs(spread.z) < 0.5 && max(abs(before.std.y - originalStats.std.y), abs(before.std.z - originalStats.std.z)) > 2,
            String(format: "and leaves their spread the edit's (a %+.2f, b %+.2f off it)", spread.y, spread.z))
        } else {
          check(false, "the tint-only match can be read back")
        }
      } catch {
        check(false, "matching the edit with a block added: \(error.localizedDescription)")
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
