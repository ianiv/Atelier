#if os(macOS)
import CoreGraphics
import Foundation

extension Automation {
  /// What the Edit screen's tool checks change on the screen and in UserDefaults, as they are now;
  /// the closure puts them back exactly (a key that wasn't set stays unset), as
  /// `keepCanvasSettings` does for the Create canvas. Scripted runs share the user's UserDefaults.
  static func keepEditSettings(_ edit: EditModel) -> @MainActor () -> Void {
    let tool = edit.tool, compareMode = edit.compareMode, options = edit.options
    let defaults = UserDefaults.standard
    let stored = ["editOptions", "editCompareMode", "editSession", AppSettings.embedsSettingsKey].map { ($0, defaults.object(forKey: $0)) }
    return {
      edit.tool = tool
      edit.reset()
      edit.options = options
      edit.compareMode = compareMode
      for (key, value) in stored { defaults.set(value, forKey: key) }
    }
  }

  /// Checks the Edit screen's tools with no model run, and prints PASS/FAIL lines:
  ///
  /// - the Edit picker offers Move and Crop, and Create's canvas tools are as they were;
  /// - picking Crop while Side by Side is chosen goes to Hold for Original, and shows the whole
  ///   image (the working image is the source) with the crop drawn over it;
  /// - a crop set as the overlay sets it is one undo step named "Crop"; leaving Crop applies it
  ///   (the working image is the crop's size); undo puts the last crop back, Reset Crop is its
  ///   own step ("Reset Crop"), and Reset (the look's) leaves the crop alone;
  /// - a ratio holds through a corner drag made as the overlay makes it (`CropDrag`), and
  ///   Orientation turns it (4:5 to 5:4);
  /// - Save to History saves a step the crop's size whose record has the crop, and whose input is
  ///   the uncropped source; saving the same crop again queues nothing; reopening the step gives
  ///   back the uncropped source with the crop; Export PNG is the crop's size;
  /// - opening another image clears the crop and its undo steps;
  /// - `crop_image` (through `AgentTools`, as an agent calls it): a rectangle, a ratio, and
  ///   `clear`, each saved after the source, with bad rectangles refused; `edit_image_look` on a
  ///   cropped step keeps its crop.
  ///
  ///   Atelier --edit-tools-check --project NAME [--quit]
  ///
  /// Always pass a scratch `--project`: it adds steps to it. The Edit screen's tool, comparison,
  /// look and the Edit settings in UserDefaults are put back at the end (`keepEditSettings`).
  static func editToolsCheck(_ model: CreateModel, navigation: Navigation, presets: PresetStore) {
    let args = CommandLine.arguments
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      let sectionBefore = navigation.section
      let restore = editModel.map(keepEditSettings)
      @MainActor func finish() {
        restore?()
        navigation.section = sectionBefore
        print(failures == 0 ? "edit tools check: all passed" : "edit tools check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      guard let edit = editModel else {
        check(false, "the app has no Edit screen model")
        return finish()
      }
      navigation.section = .edit

      check(EditTool.allCases == [.move, .crop] && EditTool.allCases.map(\.title) == ["Move", "Crop"], "the Edit picker offers Move and Crop")
      check(CanvasTool.allCases == [.move, .brush, .eraser, .select], "Create's canvas tools are unchanged")

      var waited = 0
      while model.settings == nil || !model.history.isLoaded || model.isBusy, waited < 600 {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
      }
      let width = 1200, height = 900
      guard let settings = model.settings, let image = testImage(width: width, height: height), let tensor = ImageTensor.tensor(from: image) else {
        check(false, "the model list or project didn't load, or the test image couldn't be made")
        return finish()
      }
      let history = model.history
      var configuration = settings
      configuration.width = width
      configuration.height = height
      var request = GenerationEngine.Request(
        model: model.selectedModel ?? "", prompt: "edit tools check", negativePrompt: "", seed: 1, configuration: configuration)
      request.canvas = image
      request.canvasIsImported = true
      let source: HistoryItem
      do {
        source = try await history.save(GenerationEngine.Output(frames: [tensor]), request: request, startedAt: Date(), finishedAt: Date())
      } catch {
        check(false, "the test image couldn't be added to the project: \(error.localizedDescription)")
        return finish()
      }
      edit.tool = .move
      await edit.open(source)
      check(edit.item?.tensorId == source.tensorId && edit.retouch.crop == nil, "the appended step opens in Edit with no crop")
      var look = EditOptions.grainDefaults
      look.grain.seed = 7
      look.vignette.amount = 0.4
      edit.options = look.snapped

      // Crop picked while Side by Side is on: Hold, and the whole image.
      edit.compareMode = .sideBySide
      edit.tool = .crop
      check(edit.compareMode == .hold, "picking Crop while Side by Side is on goes to Hold for Original (\(edit.compareMode.rawValue))")
      check(edit.workingImage === edit.image, "with Crop the panes show the whole image")

      let undo = UndoManager()
      undo.groupsByEvent = false
      @MainActor func act(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
      }
      let first = Edit.Crop(x: 100, y: 50, width: 800, height: 600)
      act { edit.setCrop(first, undoManager: undo) }
      check(edit.retouch.crop == first && undo.undoActionName == "Crop", "a crop is one undo step named “\(undo.undoActionName)”")
      check(edit.workingImage?.width == width, "while Crop is the tool the image stays whole (\(edit.workingImage?.width ?? 0) wide)")
      edit.tool = .move
      check(
        edit.workingImage?.width == 800 && edit.workingImage?.height == 600 && edit.outputSize.map { $0 == (800, 600) } == true,
        "leaving Crop applies it: the working image is \(edit.workingImage?.width ?? 0)×\(edit.workingImage?.height ?? 0)")

      // A ratio held through a corner drag, as the overlay makes it.
      edit.tool = .crop
      act { edit.setCropAspect(.r4x5, undoManager: undo) }
      let held = edit.retouch.crop
      check(
        held?.aspect == .r4x5 && held.map { abs(Double($0.width) / Double($0.height) - 0.8) < 0.01 } == true && undo.undoActionName == "Crop",
        "choosing 4:5 holds the crop to it (\(held.map { "\($0.width)×\($0.height)" } ?? "none"))")
      let viewport = EditViewport(imageWidth: width, imageHeight: height, viewSize: CGSize(width: 600, height: 450), displayScale: 1)
      let drag = CropDrag()
      if let held {
        let corner = viewport.viewRect(held.rect)
        let start = CGPoint(x: corner.maxX, y: corner.maxY)
        drag.changed(from: start, to: CGPoint(x: start.x - 60, y: start.y - 10), crop: held, image: (width, height), viewport: viewport)
        let dragged = drag.ended(crop: held, image: (width, height))
        act { edit.setCrop(dragged, undoManager: undo) }
      }
      let afterDrag = edit.retouch.crop
      check(
        afterDrag != held && afterDrag?.x == held?.x && afterDrag?.y == held?.y && afterDrag?.aspect == .r4x5
          && afterDrag.map { abs(Double($0.width) / Double($0.height) - 0.8) < 0.01 } == true,
        "a corner drag keeps the opposite corner and 4:5 (\(afterDrag.map { "\($0.width)×\($0.height)" } ?? "none"))")
      act { edit.swapCropOrientation(undoManager: undo) }
      let turned = edit.retouch.crop
      check(
        turned?.swapped == true && turned.map { abs(Double($0.width) / Double($0.height) - 1.25) < 0.01 } == true,
        "Orientation turns it to 5:4 (\(turned.map { "\($0.width)×\($0.height)" } ?? "none"))")
      undo.undo()
      check(edit.retouch.crop == afterDrag && undo.undoActionName == "Crop", "undo puts the last crop back")

      // Reset Crop, its own step; Reset (the look) leaves the crop.
      act { edit.setCrop(first, undoManager: undo) }
      act { edit.resetCrop(undoManager: undo) }
      check(edit.retouch.crop == nil && undo.undoActionName == "Reset Crop", "Reset Crop takes it off, one step named “\(undo.undoActionName)”")
      undo.undo()
      check(edit.retouch.crop == first, "undoing Reset Crop brings it back")
      edit.reset()
      check(edit.retouch.crop == first, "Reset (the look's) leaves the crop alone")
      edit.options = look.snapped
      edit.tool = .move

      // Save to History: the crop's size, the record's crop, the uncropped input.
      let jobID: UUID
      do {
        jobID = try edit.save()
      } catch {
        check(false, "Save to History failed: \(error.localizedDescription)")
        return finish()
      }
      let again = try? edit.save()
      check(again == jobID && edit.saveProblem != nil, "the same crop saved twice queues once")
      guard let saved = await finished(jobID, in: model) else {
        check(false, "the cropped edit didn't save a step")
        return finish()
      }
      let savedImage = await history.project.read { $0.image(tensorId: saved.imageTensorId ?? saved.tensorId) }
      check(savedImage?.width == 800 && savedImage?.height == 600, "the saved step is the crop's size (\(savedImage?.width ?? 0)×\(savedImage?.height ?? 0))")
      check(saved.sidecar.edit?.crop?.rect == first.rect && saved.sidecar.edit?.version == 2, "the saved step's record has the crop (version 2)")
      let input = await model.originalImage(for: saved)
      check(input?.image.width == width && input?.image.height == height, "the saved step's input is the uncropped source")

      // Reopen: the source, uncropped, with the crop back.
      await edit.open(source)
      check(edit.retouch.crop == nil, "opening the source on its own has no crop")
      await edit.open(saved)
      check(
        edit.item?.tensorId == source.tensorId && edit.image?.width == width && edit.retouch.crop?.rect == first.rect
          && edit.workingImage?.width == 800,
        "reopening the cropped step gives back the uncropped source with its crop")
      do {
        let png = try await edit.exportPNG()
        let exported = ImageLoader.image(from: png)
        check(exported?.width == 800 && exported?.height == 600, "Export PNG is the crop's size (\(exported?.width ?? 0)×\(exported?.height ?? 0))")
      } catch {
        check(false, "Export PNG failed: \(error.localizedDescription)")
      }

      // Another image: no crop, and its undo steps gone.
      act { edit.setCrop(Edit.Crop(x: 0, y: 0, width: 600, height: 600), undoManager: undo) }
      if let other = testImage(width: 640, height: 480) { edit.open(image: other, name: "Edit tools check") }
      check(edit.retouch.crop == nil && undo.undoActionName == "", "another image opens with no crop, and the last one's crop steps are gone")

      await agentCropChecks(model, edit: edit, presets: presets, source: source, saved: saved, check: check)
      finish()
    }
  }

  /// The step Edit job `id` saved once it's done; nil if it didn't.
  private static func finished(_ id: UUID, in model: CreateModel) async -> HistoryItem? {
    var waited = 0
    while model.queue.recent.first(where: { $0.id == id }) == nil, waited < 600 {
      try? await Task.sleep(for: .milliseconds(100))
      waited += 1
    }
    guard case .finished(let tensorId)? = model.queue.recent.first(where: { $0.id == id })?.status else { return nil }
    return model.history.item(tensorId: tensorId)
  }

  /// crop_image and edit_image_look through `AgentTools`, as an agent calls them.
  private static func agentCropChecks(
    _ model: CreateModel, edit: EditModel, presets: PresetStore, source: HistoryItem, saved: HistoryItem, check: (Bool, String) -> Void
  ) async {
    let tools = AgentTools(create: model, presets: presets, grainProfiles: edit.profiles)
    /// The steps each call saved, by its answer's history_step: steps saved after the same source
    /// share a number on their branches, so the one this call added is the one meant.
    var added: [Int: HistoryItem] = [:]
    func call(_ name: String, _ arguments: [String: Any]) async -> (result: [String: Any], error: String?) {
      let before = Set(model.history.items.map(\.tensorId))
      do {
        let answer = try await tools.call(name, arguments: arguments) { _ in }
        let result = (answer["structuredContent"] as? [String: Any]) ?? [:]
        if let number = (result["history_step"] as? NSNumber)?.intValue {
          added[number] = model.history.items.first { $0.id.logicalTime == number && !before.contains($0.tensorId) }
        }
        return (result, nil)
      } catch {
        return ([:], error.localizedDescription)
      }
    }
    func step(_ result: [String: Any]) -> HistoryItem? {
      (result["history_step"] as? NSNumber).flatMap { added[$0.intValue] }
    }
    func size(_ item: HistoryItem?) async -> (Int, Int) {
      guard let item, let image = await model.history.project.read({ $0.image(tensorId: item.imageTensorId ?? item.tensorId) }) else { return (0, 0) }
      return (image.width, image.height)
    }

    // On a cropped step: its look stays, only the crop changes. Steps saved after the same
    // source share a number on their branches, and the tools take the first listed with it, so
    // the edit's base is that one: asked for before each call, and done first, while the
    // screen's cropped step is the only one.
    func base(_ number: Int64) -> HistoryItem? { model.history.items.first { $0.id.logicalTime == number } }
    let lookBase = base(saved.id.logicalTime)
    let look = await call("edit_image_look", ["history_step": saved.id.logicalTime, "options": ["vignette": ["amount": 0.1]]])
    let lookItem = step(look.result)
    let lookSize = await size(lookItem)
    let baseCrop = lookBase?.sidecar.edit?.crop
    check(
      look.error == nil && baseCrop != nil && lookItem?.sidecar.edit?.crop?.rect == baseCrop?.rect
        && lookSize == (baseCrop?.width ?? -1, baseCrop?.height ?? -1) && look.result["crop"] is [String: Any],
      "edit_image_look on a cropped step keeps its crop (\(lookSize.0)×\(lookSize.1))\(look.error.map { ": \($0)" } ?? "")")

    let squareBase = base(saved.id.logicalTime)
    let square = await call("crop_image", ["history_step": saved.id.logicalTime, "aspect": "1:1"])
    let squareItem = step(square.result)
    let squareSize = await size(squareItem)
    check(
      square.error == nil && squareSize == (900, 900) && squareItem?.sidecar.edit?.options == squareBase?.sidecar.edit?.options
        && squareItem?.sidecar.edit?.sourceTensorId == source.tensorId,
      "crop_image aspect 1:1 on a cropped step keeps its look and saves the largest square (\(squareSize.0)×\(squareSize.1))\(square.error.map { ": \($0)" } ?? "")")

    let rect = await call("crop_image", ["history_step": source.id.logicalTime, "x": 200, "y": 100, "width": 640, "height": 480])
    let rectItem = step(rect.result)
    let rectSize = await size(rectItem)
    check(
      rect.error == nil && rectItem?.sidecar.edit?.crop?.rect == CGRect(x: 200, y: 100, width: 640, height: 480) && rectSize == (640, 480)
        && rect.result["crop"] is [String: Any],
      "crop_image with a rectangle saves a \(rectSize.0)×\(rectSize.1) step\(rect.error.map { ": \($0)" } ?? "")")

    let cleared = await call("crop_image", ["history_step": saved.id.logicalTime, "clear": true])
    let clearedSize = await size(step(cleared.result))
    check(
      cleared.error == nil && step(cleared.result)?.sidecar.edit?.crop == nil && clearedSize == (1200, 900) && cleared.result["crop"] is NSNull,
      "crop_image clear saves the whole source with the look (\(clearedSize.0)×\(clearedSize.1))\(cleared.error.map { ": \($0)" } ?? "")")

    let outside = await call("crop_image", ["history_step": source.id.logicalTime, "x": 1000, "y": 0, "width": 400, "height": 400])
    let tiny = await call("crop_image", ["history_step": source.id.logicalTime, "x": 0, "y": 0, "width": 8, "height": 8])
    let both = await call("crop_image", ["history_step": source.id.logicalTime, "aspect": "1:1", "clear": true])
    let text = await call("crop_image", ["history_step": source.id.logicalTime, "x": "left", "y": 0, "width": 100, "height": 100])
    check(
      outside.error?.contains("1200×900") == true && tiny.error?.contains("16") == true && both.error != nil && text.error != nil,
      "crop_image refuses a crop outside the image, under 16 px, two kinds at once, or one not in numbers")
  }
}
#endif
