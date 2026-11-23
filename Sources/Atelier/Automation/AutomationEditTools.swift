#if os(macOS)
import CoreGraphics
import Foundation

extension Automation {
  /// What the Edit screen's tool checks change on the screen and in UserDefaults, as they are now;
  /// the closure puts them back exactly (a key that wasn't set stays unset), as
  /// `keepCanvasSettings` does for the Create canvas. Scripted runs share the user's UserDefaults.
  static func keepEditSettings(_ edit: EditModel) -> @MainActor () -> Void {
    let tool = edit.tool, compareMode = edit.compareMode, options = edit.options, healBrushSize = edit.healBrushSize
    let defaults = UserDefaults.standard
    let stored = ["editOptions", "editCompareMode", "editSession", EditModel.healBrushSizeKey, AppSettings.embedsSettingsKey]
      .map { ($0, defaults.object(forKey: $0)) }
    return {
      edit.tool = tool
      edit.reset()
      edit.options = options
      edit.compareMode = compareMode
      edit.healBrushSize = healBrushSize
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
  /// Heal, on a made-up flat noisy skin-like image with dark round spots (`healChecks`):
  ///
  /// - picking Heal while Side by Side is on goes to Hold for Original;
  /// - a stroke before any source is set changes nothing and adds no undo step;
  /// - Set Source (the model call the toggle's click and Option-click make) sets it and turns
  ///   itself off; a stroke over a spot is one undo step named "Heal", takes the spot's mean
  ///   brightness to within a few levels of its surroundings with their texture, and leaves every
  ///   pixel outside its box as it was; a second stroke keeps the first's offset (Aligned) and a
  ///   new source resets it; undo takes a stroke back; Clear Heal is its own step ("Clear Heal");
  /// - Hold for Original shows the unhealed source (`workingOriginal`) under the healed edit;
  /// - Save to History records the strokes as an `edit_heal_<id>` tensor (a record of 200 strokes
  ///   stays under 4 KB), the saved pixels match the screen's render within a level, reopening the
  ///   step brings the strokes back on the unhealed source, and two steps with the same strokes
  ///   share one tensor; heal and crop save together with the strokes where they were;
  /// - `heal_image` adds spots with their offsets, refuses a spot without a source or with a
  ///   radius past 256, and `crop_image` and `edit_image_look` keep a step's strokes;
  /// - opening another image drops the strokes and the source.
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

      check(
        EditTool.allCases == [.move, .crop, .heal] && EditTool.allCases.map(\.title) == ["Move", "Crop", "Heal"],
        "the Edit picker offers Move, Crop and Heal")
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
      check(saved.sidecar.edit?.crop?.rect == first.rect && saved.sidecar.edit?.version == Edit.Record.currentVersion, "the saved step's record has the crop (version \(Edit.Record.currentVersion))")
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
      await healChecks(model, edit: edit, presets: presets, settings: settings, check: check)
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
  /// A flat, noisy, skin-like image with dark round spots of `spotRadius` at `spots`: what the
  /// Heal checks take marks out of. The noise is a fixed sequence, so every run is the same.
  static func healTestImage(width: Int, height: Int, spots: [CGPoint], spotRadius: Double) -> CGImage? {
    var state: UInt32 = 12345
    func noise() -> Int {
      state = state &* 1_664_525 &+ 1_013_904_223
      return Int(state >> 24) % 25 - 12
    }
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let n = noise()
        var dark = 0
        for spot in spots where hypot(Double(x) + 0.5 - spot.x, Double(y) + 0.5 - spot.y) < spotRadius { dark = 80 }
        let base = [205, 160, 140]
        for c in 0..<3 { pixels[(y * width + x) * 4 + c] = UInt8(min(max(base[c] + n - dark, 0), 255)) }
      }
    }
    return ColorMatch.cgImage(rgba: pixels, width: width, height: height)
  }

  /// Mean and spread of the luminance of `rgba`'s pixels (`width` wide) whose centres are between
  /// `inner` and `outer` from `centre`.
  private static func luma(_ rgba: [UInt8], width: Int, centre: CGPoint, inner: Double, outer: Double) -> (mean: Double, std: Double) {
    var values: [Double] = []
    let height = rgba.count / 4 / max(width, 1)
    for y in max(0, Int(centre.y - outer))..<min(height, Int(centre.y + outer) + 1) {
      for x in max(0, Int(centre.x - outer))..<min(width, Int(centre.x + outer) + 1) {
        let d = hypot(Double(x) + 0.5 - centre.x, Double(y) + 0.5 - centre.y)
        guard d >= inner, d < outer else { continue }
        let i = (y * width + x) * 4
        values.append(0.299 * Double(rgba[i]) + 0.587 * Double(rgba[i + 1]) + 0.114 * Double(rgba[i + 2]))
      }
    }
    let mean = values.reduce(0, +) / Double(max(values.count, 1))
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(values.count, 1))
    return (mean, variance.squareRoot())
  }

  /// The Heal tool's checks (see `editToolsCheck`).
  private static func healChecks(
    _ model: CreateModel, edit: EditModel, presets: PresetStore, settings: PipelineConfiguration, check: (Bool, String) -> Void
  ) async {
    let width = 640, height = 480, spotRadius = 10.0
    let spotA = CGPoint(x: 200, y: 200), spotB = CGPoint(x: 440, y: 240)
    let history = model.history
    guard let image = healTestImage(width: width, height: height, spots: [spotA, spotB], spotRadius: spotRadius),
          let tensor = ImageTensor.tensor(from: image)
    else {
      check(false, "the heal test image couldn't be made")
      return
    }
    var configuration = settings
    configuration.width = width
    configuration.height = height
    var request = GenerationEngine.Request(
      model: model.selectedModel ?? "", prompt: "edit tools heal check", negativePrompt: "", seed: 1, configuration: configuration)
    request.canvas = image
    request.canvasIsImported = true
    let source: HistoryItem
    do {
      source = try await history.save(GenerationEngine.Output(frames: [tensor]), request: request, startedAt: Date(), finishedAt: Date())
    } catch {
      check(false, "the heal test image couldn't be added to the project: \(error.localizedDescription)")
      return
    }
    edit.tool = .move
    await edit.open(source)
    var look = EditOptions.grainDefaults
    look.grain.seed = 7
    edit.options = look.snapped
    edit.compareMode = .sideBySide
    edit.tool = .heal
    check(edit.compareMode == .hold && edit.tool == .heal, "picking Heal while Side by Side is on goes to Hold for Original (\(edit.compareMode.rawValue))")
    guard let sourcePixels = edit.image.flatMap(ColorMatch.rgba) else {
      check(false, "the heal test step couldn't be read back")
      return
    }

    let undo = UndoManager()
    undo.groupsByEvent = false
    @MainActor func act(_ body: () -> Void) {
      undo.beginUndoGrouping()
      body()
      undo.endUndoGrouping()
    }
    edit.healBrushSize = 24
    var painted = true
    act { painted = edit.addHealStroke(points: [spotA], undoManager: undo) }
    check(
      !painted && edit.retouch.heal.isEmpty && undo.undoActionName == "",
      "painting before a source is set does nothing and adds no undo step (“\(undo.undoActionName)”)")

    edit.isSettingHealSource = true
    edit.setHealSource(at: CGPoint(x: 200, y: 120))
    check(edit.healSource == .point(SIMD2(200, 120)) && !edit.isSettingHealSource, "Set Source sets the source and turns itself off")
    act { edit.addHealStroke(points: [spotA], undoManager: undo) }
    let first = edit.retouch.heal.strokes.first
    check(
      edit.retouch.heal.strokes.count == 1 && first?.offset == SIMD2(0, -80) && first?.radius == 24 && undo.undoActionName == "Heal",
      "a stroke is one undo step named “\(undo.undoActionName)”, copying from the source (offset \(first.map { "\($0.offset)" } ?? "none"))")
    await edit.settleHeal()
    if let healed = edit.workingImage.flatMap(ColorMatch.rgba), healed.count == sourcePixels.count, let first {
      let before = luma(sourcePixels, width: width, centre: spotA, inner: 0, outer: spotRadius - 2)
      let around = luma(sourcePixels, width: width, centre: spotA, inner: 30, outer: 45)
      let after = luma(healed, width: width, centre: spotA, inner: 0, outer: spotRadius - 2)
      check(
        abs(after.mean - around.mean) < 4 && abs(after.std - around.std) < around.std * 0.3 && around.mean - before.mean > 40,
        String(
          format: "the stroke takes the spot out: its brightness %.1f (was %.1f) against %.1f around, texture %.1f against %.1f",
          after.mean, before.mean, around.mean, after.std, around.std))
      var outsideSame = true
      if let box = HealBrush.region(of: first, width: width, height: height) {
        for y in 0..<height {
          for x in 0..<width where !(x >= box.x && x < box.x + box.width && y >= box.y && y < box.y + box.height) {
            let i = (y * width + x) * 4
            if healed[i] != sourcePixels[i] || healed[i + 1] != sourcePixels[i + 1] || healed[i + 2] != sourcePixels[i + 2] { outsideSame = false }
          }
        }
      }
      check(outsideSame, "every pixel outside the stroke's box is as it was")
    } else {
      check(false, "the healed picture couldn't be read")
    }

    act { edit.addHealStroke(points: [spotB], undoManager: undo) }
    let second = edit.retouch.heal.strokes.last
    check(edit.retouch.heal.strokes.count == 2 && second?.offset == first?.offset, "the next stroke keeps the first one's offset (Aligned)")
    edit.setHealSource(at: CGPoint(x: 500, y: 240))
    act { edit.addHealStroke(points: [CGPoint(x: 440, y: 300)], undoManager: undo) }
    check(edit.retouch.heal.strokes.last?.offset == SIMD2(60, -60), "a new source resets the offset (\(edit.retouch.heal.strokes.last.map { "\($0.offset)" } ?? "none"))")
    undo.undo()
    check(edit.retouch.heal.strokes.count == 2 && undo.undoActionName == "Heal", "undo takes the last stroke back; the next undo is “\(undo.undoActionName)”")
    act { edit.clearHeal(undoManager: undo) }
    check(edit.retouch.heal.isEmpty && undo.undoActionName == "Clear Heal", "Clear Heal takes them all off, one step named “\(undo.undoActionName)”")
    undo.undo()
    check(edit.retouch.heal.strokes.count == 2, "undoing Clear Heal brings the strokes back")
    edit.reset()
    edit.options = look.snapped
    check(edit.retouch.heal.strokes.count == 2, "Reset (the look's) leaves the strokes alone")
    await edit.settleHeal()

    // Hold for Original: the unhealed source, under the healed edit.
    func centre(_ image: CGImage?) -> Double {
      guard let pixels = image.flatMap(ColorMatch.rgba) else { return -1 }
      return luma(pixels, width: image?.width ?? 1, centre: spotA, inner: 0, outer: spotRadius - 2).mean
    }
    let originalSpot = centre(edit.workingOriginal), editedSpot = centre(edit.workingImage)
    check(
      originalSpot >= 0 && editedSpot - originalSpot > 40,
      String(format: "Hold for Original shows the spot unhealed (%.0f) under the healed edit (%.0f)", originalSpot, editedSpot))

    // Save to History: the strokes in the store, the pixels as the screen renders them.
    let strokes = edit.retouch.heal
    guard let jobID = try? edit.save(), let saved = await finished(jobID, in: model) else {
      check(false, "the healed edit didn't save a step")
      return
    }
    let record = saved.sidecar.edit
    check(
      record?.heal?.tensorName?.hasPrefix(Edit.StoredHeal.prefix) == true && record?.heal?.count == 2 && record?.heal?.digest == strokes.digest
        && record?.version == Edit.Record.currentVersion,
      "the saved step's record names its strokes as \(record?.heal?.tensorName ?? "no tensor")")
    let many = Edit.HealStrokes(strokes: (0..<200).map { i in
      Edit.HealStroke(points: (0..<30).map { SIMD2(Float($0), Float(i)) }, radius: 12, offset: SIMD2(5, 5))
    })
    let bigRecord = Edit.Job(project: "x", sourceTensorId: 1, options: look, retouch: Edit.Retouch(heal: many)).record
    let recordSize = (try? JSONEncoder().encode(bigRecord).count) ?? .max
    check(recordSize < 4096, "a record of 200 strokes stays small in profile_data (\(recordSize) bytes)")
    if let shown = edit.workingImage, let savedImage = await history.project.read({ $0.image(tensorId: saved.imageTensorId ?? saved.tensorId) }),
       let rendered = try? await EditRenderer().full(source: shown, options: edit.options, context: edit.context),
       let a = ColorMatch.rgba(rendered), let b = ColorMatch.rgba(savedImage), a.count == b.count
    {
      var total = 0
      for i in stride(from: 0, to: a.count, by: 4) { total += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) }
      let mean = Double(total) / Double(a.count / 4 * 3)
      check(mean <= 1, String(format: "the saved step matches the screen's render (mean difference %.2f levels)", mean))
    } else {
      check(false, "the saved step or the screen's render couldn't be read")
    }

    await edit.open(source)
    check(edit.retouch.heal.isEmpty && edit.healSource == nil, "opening the source on its own has no strokes and no source")
    await edit.open(saved)
    await edit.settleHeal()
    check(
      edit.item?.tensorId == source.tensorId && edit.retouch.heal == strokes && centre(edit.workingImage) - centre(edit.workingOriginal) > 40,
      "reopening the healed step gives back the unhealed source with its strokes healed in")

    // The same strokes with another look: one tensor for both steps.
    edit.options.vignette.amount = 0.3
    if let againID = try? edit.save(), let again = await finished(againID, in: model) {
      check(
        again.sidecar.edit?.heal?.id != nil && again.sidecar.edit?.heal?.id == record?.heal?.id,
        "two steps with the same strokes share one tensor (\(again.sidecar.edit?.heal?.tensorName ?? "none"))")
    } else {
      check(false, "the second healed edit didn't save a step")
    }

    // Heal and crop together: the strokes stay in the source's pixels.
    edit.setCrop(Edit.Crop(x: 100, y: 100, width: 400, height: 300), undoManager: nil)
    edit.tool = .move
    await edit.settleHeal()
    let croppedSpot = edit.workingImage.flatMap(ColorMatch.rgba).map { luma($0, width: 400, centre: CGPoint(x: 100, y: 100), inner: 0, outer: spotRadius - 2).mean } ?? -1
    check(edit.retouch.heal == strokes && croppedSpot > 150, String(format: "a crop leaves the strokes where they were (the spot, now at 100, 100, is %.0f)", croppedSpot))
    if let bothID = try? edit.save(), let both = await finished(bothID, in: model) {
      check(
        both.sidecar.edit?.crop?.rect == CGRect(x: 100, y: 100, width: 400, height: 300) && both.sidecar.edit?.heal?.count == 2,
        "heal and crop save together")
    } else {
      check(false, "the healed, cropped edit didn't save a step")
    }

    await agentHealChecks(model, edit: edit, presets: presets, source: source, saved: saved, check: check)

    if let other = testImage(width: 320, height: 240) { edit.open(image: other, name: "Edit tools heal check") }
    check(edit.retouch.heal.isEmpty && edit.healSource == nil, "another image opens with no strokes and no source")
  }

  /// heal_image, and crop_image and edit_image_look keeping strokes, through `AgentTools`.
  private static func agentHealChecks(
    _ model: CreateModel, edit: EditModel, presets: PresetStore, source: HistoryItem, saved: HistoryItem, check: (Bool, String) -> Void
  ) async {
    let tools = AgentTools(create: model, presets: presets, grainProfiles: edit.profiles)
    func call(_ name: String, _ arguments: [String: Any]) async -> (result: [String: Any], error: String?) {
      do {
        let answer = try await tools.call(name, arguments: arguments) { _ in }
        return ((answer["structuredContent"] as? [String: Any]) ?? [:], nil)
      } catch {
        return ([:], error.localizedDescription)
      }
    }
    func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    // Steps saved after the same source share a number on their branches, and the tools take the
    // first listed with it: so these come before any step with other strokes is saved there.
    let onHealed = await call("heal_image", [
      "history_step": saved.id.logicalTime, "strokes": [["points": [[440, 300], [450, 300]], "radius": 12, "source": [500, 300]]],
    ])
    check(onHealed.error == nil && number(onHealed.result["spots"]) == 3, "heal_image on a healed step adds after its strokes (\(number(onHealed.result["spots"]) ?? 0) spots)\(onHealed.error.map { ": \($0)" } ?? "")")
    let crop = await call("crop_image", ["history_step": saved.id.logicalTime, "aspect": "1:1"])
    let look = await call("edit_image_look", ["history_step": saved.id.logicalTime, "options": ["vignette": ["amount": 0.2]]])
    check(
      crop.error == nil && look.error == nil && (number(crop.result["heal_spots"]) ?? 0) >= 2 && (number(look.result["heal_spots"]) ?? 0) >= 2,
      "crop_image and edit_image_look keep a step's strokes (\(number(crop.result["heal_spots"]) ?? 0), \(number(look.result["heal_spots"]) ?? 0))\((crop.error ?? look.error).map { ": \($0)" } ?? "")")
    let spot = await call("heal_image", [
      "history_step": source.id.logicalTime, "spots": [["x": 200, "y": 200, "radius": 20, "source": [200, 120]]],
    ])
    let offsets = spot.result["offsets"] as? [[Double]]
    check(
      spot.error == nil && number(spot.result["spots"]) == 1 && offsets?.first == [0, -80],
      "heal_image heals a spot from its source (offsets \(offsets.map { "\($0)" } ?? "none"))\(spot.error.map { ": \($0)" } ?? "")")
    let noSource = await call("heal_image", ["history_step": source.id.logicalTime, "spots": [["x": 10, "y": 10, "radius": 5]]])
    let tooBig = await call("heal_image", ["history_step": source.id.logicalTime, "spots": [["x": 10, "y": 10, "radius": 1000, "source": [40, 40]]]])
    let outside = await call("heal_image", ["history_step": source.id.logicalTime, "spots": [["x": 10, "y": 10, "radius": 5, "source": [4000, 40]]]])
    check(
      noSource.error?.contains("spots[0]") == true && noSource.error?.contains("source") == true && tooBig.error?.contains("256") == true
        && outside.error?.contains("640×480") == true,
      "heal_image refuses a spot without a source, a radius past 256, or a source outside the image")
  }
}
#endif
