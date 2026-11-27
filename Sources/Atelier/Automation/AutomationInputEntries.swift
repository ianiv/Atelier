#if os(macOS)
import AVFoundation
import SwiftUI

extension Automation {
  /// Checks input entries end to end with real runs (use a scratch `--project` and a fast image
  /// model with few steps): an image put on the canvas is an Imported entry, and the canvas's step;
  /// two moodboard images, one at weight 0, are one Moodboard entry holding both; an Edit run
  /// (Strength 0.6) from there takes that entry as its input; a mask painted on the result makes
  /// the next run write a Mask entry first, which it follows; painting over the mask afterwards and
  /// Using that result brings back the run's mask; the line reads Imported → Moodboard → run →
  /// Mask → run; restoring the Moodboard entry brings back the original image and both moodboard
  /// images with their weights, with nothing new recorded; Using the first run brings back the same
  /// state; Clear is a Cleared entry, and a second Clear repeats it, so it isn't recorded; deleting
  /// the entries leaves both runs with their images and tensors; and without Show Inputs only the
  /// runs are listed; Paste in the moodboard column adds two copied images as one Moodboard entry,
  /// leaves out a copied WAV file with an image model, and, when a model that takes audio is
  /// downloaded, puts it in the Audio box with that model selected (no run). Copies go to the
  /// private pasteboard of scripted runs (`Clipboard.pasteboard`). Prints PASS/FAIL (and SKIP) lines.
  ///
  ///   Atelier --input-entries-check --project NAME --model M [--steps N] [--size S] [--quit]
  ///
  /// `--size` is the frame's side (default 512), `--steps` the run's (default 4). Always pass a
  /// scratch `--project`: it adds steps to it.
  static func inputEntriesCheck(_ model: CreateModel) {
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
        print(failures == 0 ? "input entries check: all passed" : "input entries check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func idle() async {
        try? await Task.sleep(for: .milliseconds(200))
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      }
      /// Waits (up to 10 s) for `condition`.
      @MainActor func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
          if condition() { return true }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
      }
      @MainActor func run() async -> HistoryItem? {
        let previous = model.lastSavedStep
        model.generate()
        await idle()
        if let error = model.errorMessage { print("error: \(error)") }
        if let note = model.statusNote { print("note: \(note)") }
        guard let step = model.lastSavedStep, step != previous else { return nil }
        return model.history.item(step)
      }
      @MainActor func same(_ a: CGImage?, _ b: CGImage) -> Bool {
        a.flatMap { pixelDifference($0, b) }?.maxDelta == 0
      }
      /// A pattern of `size`, `seed` choosing its colors.
      func pattern(_ width: Int, _ height: Int, seed: Int) -> CGImage? {
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context else { return nil }
        for y in stride(from: 0, to: height, by: 16) {
          for x in stride(from: 0, to: width, by: 16) {
            let r = Double((x * 7 + seed * 50) % 256) / 255, g = Double((y * 5 + seed * 90) % 256) / 255
            context.setFillColor(CGColor(srgbRed: r, green: g, blue: Double(seed * 60 % 256) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 16, height: 16))
          }
        }
        return context.makeImage()
      }

      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let file = value("--model"), model.models.contains(where: { $0.file == file }) else {
        check(false, "--model M is required and must be downloaded")
        return finish()
      }
      if model.selectedModel != file {
        model.selectedModel = file
        await idle()
      }
      model.resetToModelDefaults(undoManager: nil)
      let size = value("--size").flatMap(Int.init) ?? 512
      guard var settings = model.settings else { return finish() }
      settings.steps = value("--steps").flatMap(Int.init) ?? 4
      settings.width = size
      settings.height = size
      settings.strength = 0.6
      model.settings = settings
      model.seed = 42
      model.seedLocked = true
      model.count = 1
      model.mergeIntoImage = true
      model.prompt = "a watercolor painting"
      model.canvasMode = .edit
      guard let original = pattern(size, size, seed: 1), let first = pattern(256, 256, seed: 2),
            let second = pattern(256, 256, seed: 3)
      else { return finish() }
      // Start from an empty board, recorded like any change.
      model.moodboard.removeAll()
      await model.flushEntries()
      let history = model.history

      // An image brought in.
      model.setCanvasImage(original)
      await model.flushEntries()
      let imported = history.currentItem
      check(
        imported?.entryReason == .imported && imported?.canvasTensorId != nil && imported?.entryMoodboard.isEmpty == true,
        "an image put on the canvas is an Imported entry, current (\(imported?.entryReason?.rawValue ?? "none"))")
      check(
        await settled { model.canvasShowsImage && model.imageItem == nil && model.canPaintMask },
        "the canvas keeps the image, now its entry's step, with no settings of its own")
      guard let imported, let originalTensor = imported.canvasTensorId else { return finish() }

      // Two moodboard images, the second at weight 0: one entry.
      model.moodboard.add(first)
      model.moodboard.add(second)
      if let id = model.moodboard.items.last?.id { model.moodboard.setWeight(0, for: id) }
      await model.flushEntries()
      let moodboardEntry = history.currentItem
      check(
        moodboardEntry?.entryReason == .moodboard && moodboardEntry?.canvasTensorId == originalTensor
          && moodboardEntry?.entryMoodboard.map(\.weight) == [1, 0],
        "two moodboard changes are one Moodboard entry with the canvas and both images (weights \(moodboardEntry?.entryMoodboard.map(\.weight) ?? []))")
      check(history.parent(of: moodboardEntry ?? imported) == imported, "the Moodboard entry follows the Imported one")
      guard let moodboardEntry else { return finish() }

      // An Edit run takes the entry as its input.
      guard let run1 = await run() else {
        check(false, "the first run saved nothing")
        return finish()
      }
      check(
        run1.inputTensorId == moodboardEntry.tensorId && history.parent(of: run1) == moodboardEntry,
        "an Edit run follows the Moodboard entry and records it as its input")
      check(history.inputEntry(of: run1) == moodboardEntry, "the run's input entry is the Moodboard entry")

      // A mask on the result: the next run writes a Mask entry first.
      _ = await settled { model.imageItem == run1 && model.canvasShowsImage }
      let mask1 = CanvasMask(strokes: [.ellipse(in: CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 3))])
      model.canvasMask = mask1
      guard let run2 = await run() else {
        check(false, "the masked run saved nothing")
        return finish()
      }
      let maskEntry = history.parent(of: run2)
      check(
        maskEntry?.entryReason == .mask && maskEntry?.canvasTensorId == run1.tensorId && maskEntry?.entryMask == mask1
          && run2.inputTensorId == maskEntry?.tensorId,
        "a run with a new mask follows a Mask entry holding it (\(maskEntry?.entryReason?.rawValue ?? "none"))")
      check(history.parent(of: maskEntry ?? run2) == run1, "the Mask entry follows the first run")

      // Painting over the mask afterwards, then Use: the run's mask comes back.
      _ = await settled { model.imageItem == run2 && model.canvasShowsImage }
      let mask2 = CanvasMask(strokes: [.rect(CGRect(x: 0, y: 0, width: size / 3, height: size / 3))])
      model.canvasMask = mask2
      model.use(run2)
      await idle()
      let run1Image = await history.image(for: run1)
      check(
        await settled { model.canvasMask == mask1 && run1Image.map { same(model.image, $0) } == true },
        "Use on the masked run brings back its input with the run's mask, not the one painted since")

      // The line, oldest first: Imported, Moodboard, run, Mask, run.
      history.setCurrent(tensorId: run2.tensorId)
      let line = Array(history.currentLineage.reversed().map(\.tensorId).suffix(5))
      let expected = [imported, moodboardEntry, run1, maskEntry ?? run2, run2].map(\.tensorId)
      check(
        line == expected,
        "the strip's line reads Imported → Moodboard → run → Mask → run")

      // Restoring the Moodboard entry: the original image and both images with their weights.
      let entriesBefore = history.items.count(where: \.isEntry)
      model.restore(entry: moodboardEntry)
      let restored = await settled {
        same(model.image, original) && model.moodboard.items.map(\.weight) == [1, 0]
          && same(model.moodboard.items.first?.image, first) && same(model.moodboard.items.last?.image, second)
      }
      check(restored, "restoring the Moodboard entry brings back the original image and both moodboard images with their weights")
      check(history.currentItem == moodboardEntry, "and makes it the current step")
      await model.flushEntries()
      check(history.items.count(where: \.isEntry) == entriesBefore, "restoring records nothing")

      // Use on the first run: the same state.
      model.moodboard.removeAll()
      await model.flushEntries()
      model.use(run1)
      await idle()
      let used = await settled {
        !model.isLoadingCanvasImage && history.currentItem == moodboardEntry
          && same(model.image, original) && model.moodboard.items.map(\.weight) == [1, 0] && model.canvasMode == .edit
          && same(model.moodboard.items.first?.image, first) && same(model.moodboard.items.last?.image, second)
      }
      check(used, "Use on the first run brings back the original image and the whole moodboard, weight 0 too")
      check(
        history.currentItem == moodboardEntry,
        "with its input entry current (current: \(history.currentItem.map { "\($0.entryReason?.rawValue ?? "run") \($0.tensorId)" } ?? "none"), entry \(moodboardEntry.tensorId), run \(run1.tensorId))")

      // A moodboard change still settling when an entry is restored: it's recorded, but what was
      // restored stays current and on the screen.
      model.moodboard.add(second)
      model.restore(entry: moodboardEntry)
      await model.flushEntries()
      _ = await settled { model.moodboard.items.count == 2 }
      let settledEntry = history.items.first
      check(
        history.currentItem == moodboardEntry && model.moodboard.items.map(\.weight) == [1, 0]
          && settledEntry?.entryReason == .moodboard && settledEntry != moodboardEntry
          && settledEntry?.entryMoodboard.count == 3,
        "a moodboard change made just before a restore is recorded, but the restored entry stays current")

      // Reopening the project: the entry is current, not the image it shows.
      let projectName = history.project.name
      await history.open(projectName + " other")
      await history.open(projectName)
      check(
        history.currentTensorId == moodboardEntry.tensorId && history.currentItem == moodboardEntry,
        "reopened, the project's current step is the entry, by its key")
      model.restore(entry: moodboardEntry)
      _ = await settled { same(model.image, original) }

      // Deleting the entry a run was made from: the run's input is the Imported entry, which shows
      // the same image, and Use and Match Colors still find it.
      do {
        try await history.delete([moodboardEntry])
      } catch {
        check(false, "delete: \(error.localizedDescription)")
      }
      let orphan = history.item(tensorId: run1.tensorId)
      check(
        orphan?.inputTensorId == imported.tensorId && orphan.map { history.parent(of: $0) } == imported,
        "deleting its input entry hands a run the Imported entry before it, as input and parent")
      if let orphan {
        let found = await model.originalImage(for: orphan)
        check(found?.tensorId == originalTensor && found.map { same($0.image, original) } == true, "Match Colors still finds its original")
        model.use(orphan)
        await idle()
        check(
          await settled {
            !model.isLoadingCanvasImage && history.currentTensorId == imported.tensorId && same(model.image, original)
              && model.statusNote == nil
          },
          "and Use still brings back its input, current")
      }

      // An Imported step written before entries (no marker): it isn't listed, and Use on a run made
      // from it brings back the run's own moodboard and the mask its input image remembers.
      if let oldTensor = ImageTensor.tensor(from: original), let moodTensor = ImageTensor.tensor(from: first) {
        let project = history.project
        let settingsDump = model.settings.map(JSONValue.fields(of:)) ?? [:]
        let old = try? await project.append(
          tensor: oldTensor, model: file, prompt: "", negativePrompt: "", seed: 0, settings: settingsDump,
          createdAt: Date(), duration: 0, reason: .imported, generated: false, after: history.currentTensorId)
        let oldRun = try? await project.append(
          tensor: oldTensor, model: file, prompt: "old run", negativePrompt: "", seed: 5, settings: settingsDump,
          createdAt: Date(), duration: 1, moodboard: [Project.MoodboardTensor(tensor: moodTensor, weight: 0.5)],
          inputTensorId: old?.tensorId, after: old?.tensorId)
        await history.reload()
        let oldMask = CanvasMask(strokes: [.rect(CGRect(x: 10, y: 10, width: 40, height: 40))])
        if let old { history.setMask(oldMask, forImage: old.tensorId, size: CGSize(width: size, height: size)) }
        check(old.map { history.item(tensorId: $0.tensorId) == nil } == true, "an unmarked Imported step isn't listed")
        if let oldRun = oldRun.flatMap({ history.item(tensorId: $0.tensorId) }) {
          check(history.inputEntry(of: oldRun) == nil, "a run from it has no input entry")
          model.use(oldRun)
          await idle()
          check(
            await settled { !model.isLoadingCanvasImage && model.moodboard.items.map(\.weight) == [0.5] && model.canvasMask == oldMask },
            "Use on that run brings back its own moodboard and its input's mask")
        } else {
          check(false, "the old-style run wasn't listed")
        }
      }

      // Use Settings brings back another run's moodboard: a run after it follows that board, and
      // Use on that run brings it back, not the board of the entry current before.
      model.restore(entry: imported)
      // The image it loads, not the same pixels the canvas showed before.
      _ = await settled { model.canvasImageIsCurrent && same(model.image, original) }
      model.moodboard.replace(with: [(second, 1)])
      model.moodboard.setWeight(0.75, for: model.moodboard.items[0].id)
      await model.flushEntries()
      if let run3 = await run() {
        model.restore(entry: imported)
        _ = await settled { model.canvasImageIsCurrent && model.moodboard.items.isEmpty }
        let boardOf = { (items: [MoodboardItem]) in items.map(\.weight) }
        model.use(run3, loadImage: false)
        _ = await settled { boardOf(model.moodboard.items) == [0.75] }
        await model.flushEntries()
        let afterUseSettings = history.currentItem
        check(
          afterUseSettings?.entryReason == .moodboard && afterUseSettings?.entryMoodboard.map(\.weight) == [0.75],
          "Use Settings records the board it brings back as a Moodboard entry, current (current: \(afterUseSettings?.entryReason?.rawValue ?? "run"), \(afterUseSettings?.entryMoodboard.map(\.weight) ?? []))")
        if let run4 = await run() {
          model.moodboard.removeAll()
          await model.flushEntries()
          model.use(run4)
          await idle()
          check(
            await settled {
              !model.isLoadingCanvasImage && boardOf(model.moodboard.items) == [0.75]
                && same(model.moodboard.items.first?.image, second)
            },
            "after Use Settings and Generate, Use brings back the board the run used")
        } else {
          check(false, "the run after Use Settings saved nothing")
        }
      } else {
        check(false, "the run with a new board saved nothing")
      }

      // Generate mode: a new mask on the canvas image is a Mask entry too, which the run follows.
      _ = await settled { model.canvasImageIsCurrent && model.canvasShowsImage }
      let mask3 = CanvasMask(strokes: [.rect(CGRect(x: size / 2, y: size / 2, width: size / 4, height: size / 4))])
      model.canvasMask = mask3
      model.canvasMode = .generate
      let shownTensor = history.currentItem?.imageTensorId
      if let run5 = await run() {
        let entry = history.parent(of: run5)
        check(
          entry?.entryReason == .mask && entry?.entryMask == mask3 && entry?.canvasTensorId != nil
            && entry?.canvasTensorId == shownTensor && run5.inputTensorId == nil,
          "a Generate-mode run with a new mask follows a Mask entry holding it (\(entry?.entryReason?.rawValue ?? "run"))")
      } else {
        check(false, "the Generate-mode run saved nothing")
      }
      model.canvasMode = .edit

      // Clear: a Cleared entry; clearing again repeats it.
      model.clearCanvas()
      await model.flushEntries()
      let cleared = history.currentItem
      check(cleared?.entryReason == .cleared && cleared?.hasImage == false, "Clear is a Cleared entry with no image")
      let count = history.items.count
      model.clearCanvas()
      await model.flushEntries()
      check(history.items.count == count, "clearing an empty canvas again records nothing")

      // Deleting the entries leaves the runs, their images and tensors.
      let run2Image = await history.image(for: run2)
      let entries = history.items.filter(\.isEntry)
      do {
        try await history.delete(entries)
      } catch {
        check(false, "delete: \(error.localizedDescription)")
      }
      let left1 = history.item(tensorId: run1.tensorId), left2 = history.item(tensorId: run2.tensorId)
      let image1 = await left1.asyncMap { await history.image(for: $0) } ?? nil
      let image2 = await left2.asyncMap { await history.image(for: $0) } ?? nil
      check(
        !history.items.contains(where: \.isEntry) && left1 != nil && left2 != nil
          && run1Image.map { same(image1, $0) } == true && run2Image.map { same(image2, $0) } == true,
        "deleting every entry leaves both runs with their images")
      // `Project.contents()` is Debug-only, so Release builds skip this one.
      #if DEBUG
        let names = await history.project.read { $0.contents().tensorNames }
        check(
          names.contains("tensor_history_\(run1.tensorId)") && names.contains("tensor_history_\(run2.tensorId)")
            && !names.contains("tensor_history_\(originalTensor)"),
          "the runs' tensors stay, the imported image's goes with its entries")
      #endif

      // Without Show Inputs only runs are listed.
      model.setCanvasImage(original)
      await model.flushEntries()
      // History's filter and the Create strip's list, both modes, with Show Inputs on and off.
      let shown = history.items.filter { EntryBadge.isListed($0, showsEntries: true) }
      let hidden = history.items.filter { EntryBadge.isListed($0, showsEntries: false) }
      check(
        shown.count == history.items.count && shown.contains(where: \.isEntry),
        "with Show Inputs on, History lists the entries too (\(shown.count(where: \.isEntry)) entries)")
      check(
        !hidden.isEmpty && hidden.allSatisfy { !$0.isEntry },
        "with Show Inputs off, History lists only the runs (\(hidden.count) of \(history.items.count))")
      for lineage in [false, true] {
        let on = RecentStrip.items(history, lineage: lineage, showsEntries: true)
        let off = RecentStrip.items(history, lineage: lineage, showsEntries: false)
        check(
          on.contains(where: \.isEntry) && !off.contains(where: \.isEntry)
            && (lineage
              ? off == on.filter { !$0.isEntry }
              : on == Array(history.items.prefix(24)) && off == Array(history.items.filter { !$0.isEntry }.prefix(24))),
          "the strip (\(lineage ? "Current Lineage" : "Chronological")) lists entries with Show Inputs on and only runs with it off")
      }

      // Paste in the moodboard column: the clipboard's images (a private one in scripted runs)
      // join the board as one Moodboard entry; audio fills the Audio box only for a model that
      // takes it.
      model.moodboard.removeAll()
      await model.flushEntries()
      let pasteBefore = history.items.count(where: \.isEntry)
      Clipboard.copyImages([first, second].map { (ImageTensor.png($0), nil) })
      check(await Clipboard.pastableKinds() == [.image], "two copied images are pastable as images")
      model.pasteIntoMoodboard(await PastedMedia.load(Clipboard.items, takesAudio: false))
      await model.flushEntries()
      let pasted = history.currentItem
      check(
        model.moodboard.items.count == 2 && same(model.moodboard.items.first?.image, first)
          && same(model.moodboard.items.last?.image, second),
        "Paste adds both clipboard images to the moodboard, in order")
      check(
        pasted?.entryReason == .moodboard && pasted?.entryMoodboard.count == 2
          && history.items.count(where: \.isEntry) == pasteBefore + 1,
        "and they're one Moodboard entry holding both")
      let audioFolder = FileManager.default.temporaryDirectory.appending(path: "Atelier-Automation-Paste-\(UUID().uuidString)")
      try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: audioFolder) }
      let wav = audioFolder.appending(path: "paste check.wav")
      if let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
         let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)
      {
        buffer.frameLength = 4800
        try? AVAudioFile(forWriting: wav, settings: format.settings).write(from: buffer)
      }
      Clipboard.copyFiles([wav])
      check(await Clipboard.pastableKinds() == [.audio], "a copied WAV file is pastable as audio")
      model.errorMessage = nil
      let boardCount = model.moodboard.items.count
      model.pasteIntoMoodboard(await PastedMedia.load(Clipboard.items, takesAudio: model.videoModel?.takesAudio == true))
      check(
        model.audio.url == nil && model.errorMessage != nil && model.moodboard.items.count == boardCount,
        "with an image model, pasting audio alone adds nothing and says why (\(model.errorMessage ?? "no message"))")
      // A model that takes audio, if one is downloaded: selected without running it.
      if let audioModel = model.models.first(where: { VideoModel(model: $0.file, loras: [])?.takesAudio == true }) {
        model.selectedModel = audioModel.file
        await idle()
        model.pasteIntoMoodboard(await PastedMedia.load(Clipboard.items, takesAudio: model.videoModel?.takesAudio == true))
        check(
          model.audio.url != nil && model.audio.name == "paste check.wav" && model.audio.duration > 0.09,
          "with \(audioModel.file), pasting a WAV file fills the Audio box (\(model.audio.name))")
        model.audio.clear()
        model.selectedModel = file
        await idle()
      } else {
        print("SKIP no downloaded model takes audio, so pasting audio into the Audio box wasn't checked")
      }
      Clipboard.copy("")
      finish()
    }
  }
}

extension Automation {
  /// Regression check for a freeze reported after moodboard changes, Clear and Generate-mode runs,
  /// then clicking tiles in the Create strip (use a scratch `--project` and a fast image model with
  /// few steps). Each round adds moodboard images, clears the canvas and generates in Generate
  /// mode: even rounds one run at a time, odd ones three queued back to back while strip tiles are
  /// picked and the moodboard changes meanwhile. Then it picks up every strip tile, in both
  /// Chronological and Current Lineage, as the strip does (an entry restored, a run used without its
  /// input), sometimes with a moodboard change still settling; makes 30 quick picks; and reopens
  /// the project. After each step it checks History's parent and child links have no loop, which
  /// the strip's Current Lineage would walk. A main-actor stall over a second prints a `STALL`
  /// line, and each action prints a timestamped `STEP` line, for a watchdog to sample the process
  /// by when the output stops. Prints PASS/FAIL lines.
  ///
  ///   Atelier --entries-freeze-check --project NAME --model M [--steps N] [--rounds R] [--quit]
  ///
  /// `--steps` is each run's (default 4), `--rounds` how many rounds (default 3). Always pass a
  /// scratch `--project`: it adds steps to it.
  static func entriesFreezeCheck(_ model: CreateModel) {
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
      func step(_ message: String) {
        print("STEP \(Date().timeIntervalSince1970) \(message)")
        fflush(stdout)
      }
      @MainActor func finish() {
        print(failures == 0 ? "entries freeze check: all passed" : "entries freeze check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func idle() async {
        try? await Task.sleep(for: .milliseconds(200))
        while model.isBusy || model.isLoadingCanvasImage { try? await Task.sleep(for: .milliseconds(100)) }
      }
      func pattern(_ side: Int, seed: Int) -> CGImage? {
        let context = CGContext(
          data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context else { return nil }
        context.setFillColor(CGColor(srgbRed: Double(seed * 37 % 256) / 255, green: Double(seed * 91 % 256) / 255, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
      }
      /// A cycle in the visible parent links, which `currentLineage` would loop on forever.
      @MainActor func cycle() -> [Int64]? {
        let history = model.history
        for item in history.items {
          var seen: [Int64] = [item.tensorId]
          var next = history.parent(of: item)
          while let parent = next {
            if seen.contains(parent.tensorId) { return seen + [parent.tensorId] }
            seen.append(parent.tensorId)
            next = history.parent(of: parent)
          }
          var below: [Int64] = [item.tensorId]
          var child = history.children(of: item).first
          while let c = child {
            if below.contains(c.tensorId) { return below + [c.tensorId] }
            below.append(c.tensorId)
            child = history.children(of: c).first
          }
        }
        return nil
      }
      @MainActor func describe() -> String {
        let history = model.history
        return history.items.map { item in
          let step = history.tree.steps[item.id]
          return "\(item.entryReason?.rawValue ?? "run") key \(item.tensorId) id \(item.id.lineage)/\(item.id.logicalTime) parent \(step?.parent.map { "\($0.lineage)/\($0.logicalTime)" } ?? "-") visible \(history.parent(of: item)?.tensorId ?? 0) input \(item.inputTensorId ?? 0)"
        }.joined(separator: "\n  ")
      }
      var cycleReported = false
      @MainActor func checkTree(_ after: String) -> Bool {
        if let cycle = cycle() {
          if !cycleReported {
            check(false, "no cycle in the parent links after \(after): \(cycle)\n  \(describe())")
            cycleReported = true
          }
          return false
        }
        return true
      }

      Task { @MainActor in
        var last = Date()
        while true {
          try? await Task.sleep(for: .milliseconds(50))
          let gap = Date().timeIntervalSince(last)
          if gap > 1 { print("STALL main actor \(String(format: "%.1f", gap)) s"); fflush(stdout) }
          last = Date()
        }
      }
      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let file = value("--model"), model.models.contains(where: { $0.file == file }) else {
        check(false, "--model M is required and must be downloaded")
        return finish()
      }
      if model.selectedModel != file {
        model.selectedModel = file
        await idle()
      }
      model.resetToModelDefaults(undoManager: nil)
      guard var settings = model.settings else { return finish() }
      settings.steps = value("--steps").flatMap(Int.init) ?? 4
      settings.width = 512
      settings.height = 512
      model.settings = settings
      model.count = 1
      model.prompt = "a lighthouse at dusk"
      let rounds = value("--rounds").flatMap(Int.init) ?? 3
      let history = model.history
      var seed = 10
      for round in 0..<rounds {
        // Moodboard images, then Clear, then runs in Generate mode.
        for _ in 0..<(2 + round % 2) {
          seed += 1
          if let image = pattern(256, seed: seed) {
            step("round \(round): add moodboard image")
            model.moodboard.add(image)
          }
        }
        if round % 2 == 1 { try? await Task.sleep(for: .seconds(2)) }
        step("round \(round): clear canvas")
        model.clearCanvas()
        model.canvasMode = .generate
        if round % 2 == 0 {
          for run in 0..<3 {
            step("round \(round): generate \(run)")
            model.generate()
            await idle()
            if let error = model.errorMessage { print("error: \(error)"); model.errorMessage = nil }
            guard checkTree("generate \(run) in round \(round)") else { return finish() }
          }
        } else {
          // Queued back to back, with tiles picked and the moodboard changed while they run.
          for run in 0..<3 {
            step("round \(round): queue \(run)")
            while model.waitsForEntries { try? await Task.sleep(for: .milliseconds(50)) }
            model.generate()
            try? await Task.sleep(for: .milliseconds(300))
          }
          while model.isRunning {
            let tiles = RecentStrip.items(history, lineage: false, showsEntries: true)
            if let tile = tiles.randomElement() {
              step("round \(round): pick up while running \(tile.entryReason?.rawValue ?? "run") \(tile.tensorId)")
              if tile.isEntry { model.restore(entry: tile) } else { model.use(tile, restoreInput: false) }
            }
            seed += 1
            if let image = pattern(256, seed: seed), Bool.random() {
              step("round \(round): add moodboard image while running")
              model.moodboard.add(image)
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 200...2500)))
            guard checkTree("picks while running in round \(round)") else { return finish() }
            if !model.isRunning, !model.queue.waiting.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
          }
          await idle()
          await model.flushEntries()
          if let error = model.errorMessage { print("error: \(error)"); model.errorMessage = nil }
          guard checkTree("queued runs in round \(round)") else { return finish() }
          model.clearCanvas()
          model.canvasMode = .generate
          step("round \(round): generate after clear")
          model.generate()
          await idle()
        }
        // Every strip tile, both modes, picked up as the strip does.
        for lineage in [false, true] {
          let tiles = RecentStrip.items(history, lineage: lineage, showsEntries: true)
          for tile in tiles {
            guard let item = history.item(tensorId: tile.tensorId) else { continue }
            step("round \(round): pick up \(lineage ? "lineage" : "recent") \(item.entryReason?.rawValue ?? "run") \(item.tensorId)")
            if Int.random(in: 0..<3) == 0 {
              seed += 1
              if let image = pattern(256, seed: seed) { model.moodboard.add(image) }
            }
            if item.isEntry {
              model.restore(entry: item)
            } else if model.canUse(item) {
              model.use(item, restoreInput: false)
            } else {
              model.show(item)
            }
            await idle()
            await model.flushEntries()
            guard checkTree("picking up \(item.entryReason?.rawValue ?? "run") \(item.tensorId) in round \(round)") else {
              return finish()
            }
            // What the strip's body works out after a click.
            step("round \(round): strip lists")
            _ = history.currentItem
            _ = RecentStrip.items(history, lineage: true, showsEntries: true)
            _ = RecentStrip.items(history, lineage: false, showsEntries: true)
          }
        }
        // Rapid clicks, as someone going through the strip quickly.
        for click in 0..<30 {
          let lineage = click % 3 == 0
          let tiles = RecentStrip.items(history, lineage: lineage, showsEntries: true)
          guard let tile = tiles.randomElement() else { break }
          step("round \(round): rapid pick \(click) \(tile.entryReason?.rawValue ?? "run") \(tile.tensorId)")
          if tile.isEntry { model.restore(entry: tile) } else if model.canUse(tile) { model.use(tile, restoreInput: false) } else { model.show(tile) }
          _ = history.currentItem
          _ = RecentStrip.items(history, lineage: true, showsEntries: true)
          try? await Task.sleep(for: .milliseconds(Int.random(in: 0...150)))
        }
        await idle()
        await model.flushEntries()
        guard checkTree("rapid picks in round \(round)") else { return finish() }
        step("round \(round): reopen project")
        let name = history.project.name
        await history.open(name + " other")
        await history.open(name)
        guard checkTree("reopening in round \(round)") else { return finish() }
      }
      check(true, "\(rounds) rounds of moodboard, Clear, Generate and strip picks with no cycle (\(history.items.count) items)")
      finish()
    }
  }
}

fileprivate extension Optional {
  func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
    guard let self else { return nil }
    return await transform(self)
  }
}
#endif
