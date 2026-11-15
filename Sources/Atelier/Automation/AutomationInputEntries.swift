#if os(macOS)
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
  /// runs are listed. Prints PASS/FAIL lines.
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
        same(model.image, original) && model.moodboard.items.map(\.weight) == [1, 0] && model.canvasMode == .edit
      }
      check(used, "Use on the first run brings back the original image and the whole moodboard, weight 0 too")
      check(history.currentItem == moodboardEntry, "with its input entry current")

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
      let names = await history.project.read { $0.contents().tensorNames }
      check(
        names.contains("tensor_history_\(run1.tensorId)") && names.contains("tensor_history_\(run2.tensorId)")
          && !names.contains("tensor_history_\(originalTensor)"),
        "the runs' tensors stay, the imported image's goes with its entries")

      // Without Show Inputs only runs are listed.
      model.setCanvasImage(original)
      await model.flushEntries()
      let listed = history.items.filter { !$0.isEntry }
      check(
        history.items.contains(where: \.isEntry) && !listed.isEmpty && listed.allSatisfy { !$0.isEntry && $0.sidecar.steps > 0 },
        "with Show Inputs off, only the runs are listed (\(listed.count) of \(history.items.count))")
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
