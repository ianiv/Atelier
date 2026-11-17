#if os(macOS)
import SwiftUI

extension Automation {
  /// The canvas tools' remembered settings as they are now (the layer, the paint colour and recent
  /// colours, both brush sizes, Mask Opacity), and a closure that puts them back: a check changes
  /// them while it runs, and the user's own must be there afterwards.
  static func keepCanvasSettings(_ model: CreateModel) -> @MainActor () -> Void {
    let layer = model.canvasLayer, color = model.paintColor, recent = model.recentPaintColors
    let paintSize = model.paintBrushSize, maskSize = model.brushSize, opacity = model.maskOpacity
    let defaults = UserDefaults.standard
    let stored = ["canvasLayer", "paintColor", "recentPaintColors", "paintBrushSize", "brushSize", "maskOpacity"]
      .map { ($0, defaults.object(forKey: $0)) }
    return {
      model.canvasLayer = layer
      model.paintColor = color
      model.recentPaintColors = recent
      model.paintBrushSize = paintSize
      model.brushSize = maskSize
      model.maskOpacity = opacity
      // Exactly as they were: a key that wasn't set stays unset (the app's default).
      for (key, value) in stored { defaults.set(value, forKey: key) }
    }
  }

  /// Checks painting colours on the canvas end to end (use a scratch `--project` and a fast image
  /// model with few steps): New Sketch puts an opaque white image the frame's size on the canvas as
  /// an Imported entry, in Edit mode, with Brush on the Color layer; paint strokes and mask strokes made in
  /// turn are one undo step each and undo and redo in that order, each changing only its own
  /// layer, as do Clear Paint and Fill Mask with Color; the paint goes with the image: another
  /// image on the canvas has none, and coming back brings it back; Mask Opacity changes only what
  /// shows (the run's mask bytes stay the same); the run's input has the paint drawn in; before a
  /// run a Draw entry holding the painted image and the mask is recorded once (not again while it's
  /// current and nothing changed); a masked Edit run with Merge into Image, with paint reaching
  /// past the mask's edge, follows it, and paint being only its input, its result has none of it
  /// outside the mask, and the stored source layer is the unpainted image, and it keeps the mask,
  /// hidden. Along the way: Mask Colored Areas adds the paint's coverage to the mask in one undo
  /// step; a hidden mask (Show/Hide Mask) is kept but the request has none, and a stroke shows it.
  /// Prints PASS/FAIL lines.
  ///
  ///   Atelier --paint-check --project NAME --model M [--steps N] [--size S] [--quit]
  ///
  /// `--size` is the frame's side (default 512), `--steps` the run's (default 4). Always pass a
  /// scratch `--project`: it adds steps to it.
  static func paintCheck(_ model: CreateModel) {
    let restoreSettings = keepCanvasSettings(model)
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
        restoreSettings()
        print(failures == 0 ? "paint check: all passed" : "paint check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func idle() async {
        try? await Task.sleep(for: .milliseconds(200))
        while model.isBusy || model.waitsForEntries { try? await Task.sleep(for: .milliseconds(100)) }
      }
      /// Waits (up to 10 s) for `condition`.
      @MainActor func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
          if condition() { return true }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
      }
      /// RGBA (premultiplied sRGB) at an image pixel, from the top left; empty outside it.
      func pixel(_ image: CGImage?, _ x: Int, _ y: Int) -> [UInt8] {
        guard let image, (0..<image.width).contains(x), (0..<image.height).contains(y) else { return [] }
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
          let context = CGContext(
            data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
          context?.draw(image, in: CGRect(x: -x, y: y + 1 - image.height, width: image.width, height: image.height))
        }
        return bytes
      }
      /// Near enough to pure red (stored tensors round).
      func isRed(_ rgba: [UInt8]) -> Bool { rgba.count == 4 && rgba[0] > 230 && rgba[1] < 25 && rgba[2] < 25 }
      func isWhite(_ rgba: [UInt8]) -> Bool { rgba.count == 4 && rgba.allSatisfy { $0 > 240 } }

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
      settings.strength = 0.7
      model.settings = settings
      model.seed = 7
      model.seedLocked = true
      model.count = 1
      model.mergeIntoImage = true
      model.prompt = "a red ball on a white table, watercolor"
      model.layout = nil
      model.moodboard.removeAll()
      await model.flushEntries()
      let history = model.history
      let red = CanvasPaint.Color(red: 1, green: 0, blue: 0)
      let s = Double(size)

      // New Sketch.
      model.newSketch()
      await model.flushEntries()
      let sketch = history.currentItem
      check(
        model.image?.width == size && model.image?.height == size && isWhite(pixel(model.image, size / 2, size / 2))
          && sketch?.entryReason == .imported && model.canvasMode == .edit && model.canvasTool == .brush && model.canvasLayer == .color,
        "New Sketch: a white \(size)×\(size) image, an Imported entry, Edit mode, Brush on the Color layer (\(sketch?.entryReason?.rawValue ?? "none"))")
      check(await settled { model.canPaintColor && model.canvasUndoImage === model.image }, "the sketch can be painted")
      check(UserDefaults.standard.string(forKey: "canvasLayer") == "color", "the Color layer is remembered")
      guard let sketchTensor = sketch?.canvasTensorId else { return finish() }

      // Paint and mask strokes in turn, one undo step each.
      let undo = UndoManager()
      undo.groupsByEvent = false
      @MainActor func act(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
      }
      model.paintColor = red
      let paintA = CanvasPaint.Stroke(
        kind: .brush, points: [CGPoint(x: s * 0.1, y: s * 0.1), CGPoint(x: s * 0.4, y: s * 0.1)], radius: s * 0.04, color: red)
      // Reaching into the mask (0.5–0.8): a masked run takes only the part it regenerates.
      let paintB = CanvasPaint.Stroke.rect(CGRect(x: s * 0.1, y: s * 0.6, width: s * 0.6, height: s * 0.15), color: red)
      let maskA = CanvasMask.Stroke.rect(CGRect(x: s * 0.5, y: s * 0.5, width: s * 0.3, height: s * 0.3))
      act { model.addPaintStrokes([paintA], undoManager: undo) }
      act { model.addMaskStrokes([maskA], undoManager: undo) }
      act { model.addPaintStrokes([paintB], undoManager: undo) }
      let full = model.canvasPaint
      check(
        full?.strokes == [paintA, paintB] && model.canvasMask?.strokes == [maskA] && undo.undoActionName == "Paint"
          && model.recentPaintColors.first == red,
        "two paint strokes and a mask stroke between them, each in its own layer (\(undo.undoActionName)); red is the latest color")
      // The same colour again, a hair off as a picker gives it back, moves to the front once.
      model.noteRecentPaintColor(CanvasPaint.Color(red: 0, green: 0, blue: 1))
      model.noteRecentPaintColor(CanvasPaint.Color(red: 0.0001, green: 0, blue: 0.9999))
      check(
        model.recentPaintColors.prefix(2).map(\.hex) == ["#0000FF", "#FF0000"] && model.recentPaintColors.count(where: { $0.hex == "#0000FF" }) == 1,
        "a recent color picked again moves to the front instead of coming in twice")
      undo.undo()
      check(model.canvasPaint?.strokes == [paintA] && model.canvasMask?.strokes == [maskA], "undo 1 takes the second paint stroke away")
      undo.undo()
      check(model.canvasPaint?.strokes == [paintA] && model.canvasMask == nil, "undo 2 takes the mask stroke away, the paint unchanged")
      undo.undo()
      check(model.canvasPaint == nil && model.canvasMask == nil, "undo 3 takes the first paint stroke away")
      undo.redo()
      undo.redo()
      check(model.canvasPaint?.strokes == [paintA] && model.canvasMask?.strokes == [maskA], "redo 1 and 2 put the paint stroke and the mask back")
      undo.redo()
      check(model.canvasPaint == full && !undo.canRedo, "redo 3 puts the second paint stroke back, and that's the end")
      act { model.clearPaint(undoManager: undo) }
      check(model.canvasPaint == nil && model.canvasMask != nil && undo.undoActionName == "Clear Paint", "Clear Paint is one step and leaves the mask")
      undo.undo()
      check(model.canvasPaint == full, "undoing it brings the paint back")
      act { model.fillMask(with: CanvasPaint.Color(red: 0, green: 0, blue: 1), undoManager: undo) }
      let filled = model.canvasPaint
      check(
        filled?.strokes.count == 3 && filled?.strokes.last?.kind == .fill && model.canvasMask?.strokes == [maskA]
          && undo.undoActionName == "Fill Mask",
        "Fill Mask with Color adds one fill stroke, the mask left as it is")
      let filledLayer = filled?.layer(width: size, height: size)
      let outside = pixel(filledLayer, Int(s * 0.9), Int(s * 0.9))
      check(
        pixel(filledLayer, Int(s * 0.65), Int(s * 0.65)) == [0, 0, 255, 255] && outside.count == 4 && outside[3] == 0,
        "the fill covers the mask and nothing else")
      undo.undo()
      check(model.canvasPaint == full, "undoing the fill takes it away")

      // Mask Colored Areas: the paint's coverage into the mask, one step.
      act { model.maskColoredAreas(undoManager: undo) }
      let coloredMask = model.canvasMask?.coverage(width: size, height: size) ?? []
      check(
        undo.undoActionName == "Mask Colored Areas" && coloredMask.count == size * size
          && coloredMask[Int(s * 0.7) * size + Int(s * 0.2)] != 0 && coloredMask[Int(s * 0.65) * size + Int(s * 0.65)] != 0
          && coloredMask[Int(s * 0.3) * size + Int(s * 0.9)] == 0,
        "Mask Colored Areas adds the painted areas to the mask, one step (\(undo.undoActionName))")
      undo.undo()
      check(model.canvasMask?.strokes == [maskA], "one ⌘Z takes Mask Colored Areas back")

      // Show/Hide Mask: hidden, the mask stays but runs go without it.
      act { model.setMaskHidden(true, undoManager: undo) }
      check(
        model.maskHidden && model.canvasMask?.strokes == [maskA] && model.screenRequest()?.mask == nil
          && undo.undoActionName == "Hide Mask",
        "a hidden mask is kept, and the run's request has no mask (\(undo.undoActionName))")
      undo.undo()
      check(!model.maskHidden && model.screenRequest()?.mask != nil, "undoing Hide Mask shows it, and runs take it again")
      act { model.setMaskHidden(true, undoManager: undo) }
      act { model.addMaskStrokes([.rect(CGRect(x: s * 0.85, y: s * 0.85, width: 8, height: 8))], undoManager: undo) }
      check(!model.maskHidden && model.canvasMask?.strokes.count == 2, "a mask stroke while it's hidden shows it")
      undo.undo()
      check(model.maskHidden && model.canvasMask?.strokes == [maskA], "undoing that stroke hides it again")
      undo.undo()
      check(!model.maskHidden, "and undoing Hide Mask shows it")

      // Mask Opacity: only what shows.
      let opacity = model.maskOpacity
      model.maskOpacity = 0.25
      let quarter = model.screenRequest()?.mask
      model.maskOpacity = 1
      let whole = model.screenRequest()?.mask
      model.maskOpacity = opacity
      check(quarter != nil && quarter == whole, "Mask Opacity leaves the run's mask bytes the same")
      let request = model.screenRequest()
      check(
        isRed(pixel(request?.canvas, Int(s * 0.65), Int(s * 0.65))) && isWhite(pixel(request?.canvas, Int(s * 0.2), Int(s * 0.7)))
          && isWhite(pixel(request?.canvas, Int(s * 0.9), Int(s * 0.3))) && request?.canvasTensorId == nil,
        "the masked run's input has the paint inside the mask and the original outside, and isn't the sketch's own step")
      // At the mask's soft edge (Mask Blur), paint only as far as the run regenerates: just inside
      // it's faded, deeper in it's whole (`CanvasPaint.Fade`).
      if (model.settings?.maskBlur ?? 0) > 0 {
        let edge = pixel(request?.canvas, Int(s * 0.5), Int(s * 0.65)), inner = pixel(request?.canvas, Int(s * 0.5) + 8, Int(s * 0.65))
        check(
          edge.count == 4 && inner.count == 4 && edge[1] > 40 && isRed(inner),
          "paint at the mask's soft edge is faded into the image (edge \(edge), deeper \(inner))")
      }

      // The paint goes with the image.
      @MainActor func backToSketch() async -> Bool {
        guard let entry = history.items.first(where: { $0.isEntry && $0.canvasTensorId == sketchTensor && $0.entryReason == .imported })
        else { return false }
        model.restore(entry: entry)
        return await settled { model.canvasShowsImage && model.canvasPaint == full }
      }
      if let blank = CreateModel.blankImage(width: size, height: size) {
        model.setCanvasImage(blank)
        await model.flushEntries()
        check(model.canvasPaint == nil && !undo.canUndo, "another image on the canvas has no paint, and the sketch's steps leave the history")
        check(await backToSketch(), "back on the sketch, its paint comes back")
      }

      // The Draw entry, recorded once.
      if model.canvasMask == nil { model.addMaskStrokes([maskA], undoManager: nil) }
      await model.recordEntriesBeforeRun()
      let draw = history.currentItem
      check(
        draw?.entryReason == .draw && draw?.entryMask?.strokes == [maskA] && model.drawEntryInput() == nil,
        "before a run a Draw entry holds the mask, and while it's current nothing new is recorded (\(draw?.entryReason?.rawValue ?? "none"))")
      if let canvasTensor = draw?.canvasTensorId {
        let drawn = await history.image(tensorId: canvasTensor, in: history.project.name)
        check(
          isRed(pixel(drawn, Int(s * 0.65), Int(s * 0.65))) && isWhite(pixel(drawn, Int(s * 0.2), Int(s * 0.7)))
            && isWhite(pixel(drawn, Int(s * 0.9), Int(s * 0.3))),
          "the Draw entry's image is the run's input: the sketch with the paint the mask takes")
      }
      // Reopened, the Draw entry shows the picture underneath with its paint as a layer again,
      // which Eraser on the Color layer can take away.
      if let draw, let blank = CreateModel.blankImage(width: size, height: size) {
        model.setCanvasImage(blank)
        await model.flushEntries()
        model.restore(entry: draw)
        let reopened = await settled { model.canvasShowsImage && model.canvasPaint == full }
        check(
          reopened && isWhite(pixel(model.image, Int(s * 0.2), Int(s * 0.7))) && model.canvasMask?.strokes == [maskA]
            && history.currentItem == draw && model.drawEntryInput() == nil,
          "a Draw entry reopened shows the unpainted picture, its paint as a layer and its mask, and writes no new Draw entry")
        let eraser = CanvasPaint.Stroke(kind: .erase, points: [CGPoint(x: s * 0.65, y: s * 0.65)], radius: s * 0.05)
        model.addPaintStrokes([eraser], actionName: "Erase Paint", undoManager: nil)
        let erased = model.screenRequest()?.canvas
        check(isWhite(pixel(erased, Int(s * 0.65), Int(s * 0.65))), "erasing the reopened entry's paint takes it away")
        model.setPaint(full, actionName: "Paint", undoManager: nil)
      }
      model.addPaintStrokes([.rect(CGRect(x: 0, y: s * 0.9, width: s * 0.1, height: s * 0.1), color: red)], undoManager: nil)
      check(model.drawEntryInput() != nil, "more paint makes a new Draw entry due")
      model.setPaint(full, actionName: "Paint", undoManager: nil)

      // A masked Edit run with Merge into Image, with paint reaching past the mask's left edge.
      let crossing = CanvasPaint.Stroke.rect(CGRect(x: s * 0.4, y: s * 0.6, width: s * 0.2, height: s * 0.1), color: red)
      model.addPaintStrokes([crossing], undoManager: nil)
      let previous = model.lastSavedStep
      model.generate()
      await idle()
      if let error = model.errorMessage { print("error: \(error)") }
      guard let step = model.lastSavedStep, step != previous, let result = history.item(step) else {
        check(false, "the run saved nothing")
        return finish()
      }
      var ancestor = history.parent(of: result)
      while let item = ancestor, !item.isEntry { ancestor = history.parent(of: item) }
      check(
        ancestor?.entryReason == .draw && ancestor?.entryMask?.strokes == [maskA] && result.inputTensorId == ancestor?.tensorId,
        "the run follows a Draw entry holding the mask, its input (\(ancestor?.entryReason?.rawValue ?? "none"))")
      let merged = await history.image(tensorId: result.tensorId, in: history.project.name)
      // Outside the mask (and a margin for Mask Blur), the sketch as it was: white, no paint.
      let masked = CGRect(x: s * 0.5, y: s * 0.5, width: s * 0.3, height: s * 0.3).insetBy(dx: -16, dy: -16)
      var painted = 0
      if let merged {
        let width = merged.width, height = merged.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
          CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )?.draw(merged, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for y in 0..<height {
          for x in 0..<width where !masked.contains(CGPoint(x: x, y: y)) {
            let index = (y * width + x) * 4
            if !isWhite(Array(bytes[index..<index + 4])) { painted += 1 }
          }
        }
      }
      check(
        merged != nil && painted == 0 && isWhite(pixel(merged, Int(s * 0.45), Int(s * 0.65))),
        "the merged result has no paint outside the mask, even where it reached past its edge (\(painted) pixels not white)")
      let layers = await history.project.read { $0.layerSummary(tensorId: result.tensorId) }
      if let bottom = layers.first {
        let source = await history.image(tensorId: bottom.tensorId, in: history.project.name)
        check(
          layers.count >= 2 && isWhite(pixel(source, Int(s * 0.2), Int(s * 0.7)))
            && isWhite(pixel(source, Int(s * 0.55), Int(s * 0.65))),
          "the stored source layer is the unpainted sketch (\(layers.count) layers)")
      } else {
        check(false, "the merged result is stored as layers")
      }
      check(model.canvasPaint == nil, "the result on the canvas has no paint of its own")
      check(
        model.canvasMask != nil && model.maskHidden && model.screenRequest()?.mask == nil,
        "the result keeps the mask it was made with, hidden, and the next run takes none")
      finish()
    }
  }
}
#endif
