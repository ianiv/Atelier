#if os(macOS)
import SwiftUI

extension Automation {
  /// Refining part of an image, end to end with real runs (use a scratch `--project`): the input,
  /// filled into a square at the output size, goes on the canvas, then
  ///   (a) a rectangle mask: the result is the image's size, and pixels the feathered mask
  ///       doesn't reach are the input's exactly; the step keeps its mask and region;
  ///   (b) zoomed 2× on the top-left quadrant, no mask: the image's size, only that quadrant
  ///       (and its feathered edge) changes;
  ///   (c) the frame past the image's right edge: the result grows to hold both;
  ///   (d) Use Settings on (b) and (a) brings back the input, the zoom and the mask;
  ///   (e) a queued masked, merging job survives saving and loading the queue;
  ///   (f) after a masked run from a History image, showing it again brings its mask back, and
  ///       so does the result (moved as the image grew) and the session restore after a relaunch;
  ///   (g) a mask painted without a run comes back when the image does, and a cleared one stays
  ///       cleared;
  ///   (h) Replace Canvas Mask and Add to Canvas Mask from a step of another size stretch its
  ///       mask to fill, each one undo step;
  ///   (i) with Merge into Image off, a masked run still leaves its input remembering the mask.
  /// Image models only; one that edits at Strength below 1 (any SD/FLUX-style model) or an
  /// inpainting model. Prints PASS/FAIL lines.
  ///
  ///   Atelier --refine-check --project NAME --input FILE [--model M] [--steps N] [--size S]
  ///           [--strength S] [--quit]
  static func refineCheck(_ model: CreateModel) {
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
        print(failures == 0 ? "refine check: all passed" : "refine check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
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
      let size = value("--size").flatMap(Int.init) ?? 512
      guard let path = value("--input"), let input = ImageLoader.image(at: URL(fileURLWithPath: path)),
            let source = filled(input, size: size)
      else {
        check(false, "--input FILE is required and must be readable")
        return finish()
      }
      if let file = value("--model") {
        model.selectedModel = file
        await idle()
        model.resetToModelDefaults(undoManager: nil)
      }
      guard var settings = model.settings else { return finish() }
      settings.steps = value("--steps").flatMap(Int.init) ?? 4
      settings.width = size
      settings.height = size
      settings.strength = value("--strength").flatMap(Float.init) ?? 0.7
      settings.maskBlur = 4
      settings.maskBlurOutset = 0
      model.settings = settings
      model.seed = 42
      model.seedLocked = true
      model.mergeIntoImage = true
      model.canvasTool = .move
      let half = Double(size) / 2

      // (a) A rectangle mask, fitted.
      model.prompt = "a bright red flower"
      model.placeOnCanvas(source)
      let maskRect = CGRect(x: half / 2, y: half / 2, width: half, height: half)
      check(model.addMaskStrokes([.rect(maskRect)], actionName: Self.agentMaskName, undoManager: nil), "a mask can be painted on the canvas")
      let maskA = model.canvasMask
      check(model.canMergeIntoImage, "Merge into Image is enabled with a mask")
      if let request = model.screenRequest() {
        check(request.mask != nil && request.merge != nil, "the run carries the mask and merges")
      }
      guard let a = await run(), let imageA = await model.history.image(for: a) else {
        check(false, "(a) the masked run saved nothing")
        return finish()
      }
      check(imageA.width == size && imageA.height == size, "(a) the result is the image's size (\(imageA.width)×\(imageA.height))")
      // Mask Blur 4 reaches about 3 sigma; leave a margin.
      let far = maskRect.insetBy(dx: -24, dy: -24)
      let outside = difference(imageA, source) { !far.contains($0) }
      let inside = difference(imageA, source) { maskRect.insetBy(dx: 8, dy: 8).contains($0) }
      check(outside?.maxDelta == 0, "(a) pixels away from the mask are the input's exactly (max delta \(outside?.maxDelta ?? -1))")
      check((inside?.meanDelta ?? 0) > 1, "(a) the masked area changed (mean delta \(String(format: "%.1f", inside?.meanDelta ?? 0)))")
      check(a.sidecar.refine?.mask == maskA && a.inputTensorId != nil, "(a) the step keeps its mask and region, after its input")
      let layersA = await model.history.project.read { $0.layerSummary(tensorId: a.tensorId) }
      check(
        layersA.count == 2 && layersA[0].maskId > 0 && layersA[0].tensorId == a.inputTensorId,
        "(a) it's stored as two layers, the input's own tensor with the mask under the frame (\(layersA.map { "\($0.tensorId)/\($0.maskId)@\($0.x),\($0.y)" }))")
      check(model.canvasMask != nil, "(a) the mask stays on the canvas after the run")

      // (b) Zoomed 2× on the top-left quadrant, no mask.
      model.prompt = "a watercolor painting"
      model.placeOnCanvas(source)
      check(model.canvasMask == nil, "(b) a new image on the canvas has no mask")
      let shown = model.showRegion(CGRect(x: 0, y: 0, width: half, height: half))
      check(
        shown == CGRect(x: 0, y: 0, width: half, height: half) && model.canvas.scale == 2 && model.canMergeIntoImage,
        "(b) the frame shows the quadrant at 2×, merge enabled (shows \(shown.map { "\($0)" } ?? "nothing"))")
      guard let b = await run(), let imageB = await model.history.image(for: b) else {
        check(false, "(b) the zoomed run saved nothing")
        return finish()
      }
      check(imageB.width == size && imageB.height == size, "(b) the result is the image's size")
      let rest = difference(imageB, source) { $0.x >= half + 8 || $0.y >= half + 8 }
      let quadrant = difference(imageB, source) { $0.x < half - 8 && $0.y < half - 8 }
      check(rest?.maxDelta == 0, "(b) outside the quadrant nothing changed (max delta \(rest?.maxDelta ?? -1))")
      check((quadrant?.meanDelta ?? 0) > 1, "(b) the quadrant changed")
      check(
        model.canvas.scale.map { abs($0 - 2) < 0.01 } == true, "(b) the canvas still shows the quadrant after the run")

      // (c) The frame past the right edge and above the top, at 1×: the image grows right and up,
      // leaving two corners neither covers.
      model.placeOnCanvas(source)
      model.canvas.scale = 1
      model.canvas.offset = CGSize(width: -half, height: half / 2)
      guard let c = await run(), let imageC = await model.history.image(for: c) else {
        check(false, "(c) the outpainting run saved nothing")
        return finish()
      }
      let grownHeight = size + size / 4
      check(
        imageC.width == size + size / 2 && imageC.height == grownHeight,
        "(c) the result grows to hold the image and the frame (\(imageC.width)×\(imageC.height))")
      // Read back from a fresh opening of the project file, as after a relaunch.
      let reopened = Project(url: model.history.project.url)
      let reread = await reopened.read { $0.image(tensorId: c.tensorId) }
      await reopened.close()
      let alpha = reread.flatMap { CanvasMask.alpha(of: $0, width: $0.width, height: $0.height) }
      if let reread, let alpha {
        let width = reread.width
        let topLeft = alpha[10 * width + 10], bottomRight = alpha[(reread.height - 10) * width + width - 10]
        let middle = alpha[(reread.height / 2) * width + width / 2]
        check(
          topLeft == 0 && bottomRight == 0 && middle == 255,
          "(c) reopened, the corners neither covers are transparent (alpha \(topLeft), \(bottomRight); middle \(middle))")
      } else {
        check(false, "(c) the grown step couldn't be read back")
      }
      // A masked Edit on it outpaints those corners: code 1 there in the frame's mask.
      if await model.placeOnCanvas(c), let image = model.image {
        model.addMaskStrokes(
          [.rect(CGRect(x: 0, y: 0, width: image.width, height: image.height))], actionName: Self.agentMaskName,
          undoManager: nil)
        if let request = model.screenRequest(), let png = request.mask, let placement = model.canvasPlacement,
           let decoded = ImageLoader.image(from: png)
        {
          // The mask's red channel is its code (`CanvasMask.grayPNG`).
          let bytes = CanvasRefineBytes.rgba(decoded)
          let codes = stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
          let rect = placement.imageRect
          let corner = CGPoint(x: rect.minX + 10 * placement.zoom.x, y: rect.minY + 10 * placement.zoom.y)
          let code = codes[Int(corner.y) * decoded.width + Int(corner.x)]
          let center = codes[Int(rect.midY) * decoded.width + Int(rect.midX)]
          check(code == CanvasMask.Code.empty && center == CanvasMask.Code.painted, "(c) a masked Edit sends code 1 in the empty corner (\(code)), 2 where painted (\(center))")
        } else {
          check(false, "(c) no masked request from the grown image")
        }
        model.clearMask(undoManager: nil)
      } else {
        check(false, "(c) the grown step didn't go on the canvas")
      }

      // (d) Use Settings.
      model.clearCanvas()
      model.use(b)
      await idle()
      try? await Task.sleep(for: .seconds(1))
      let restoredB = model.image.flatMap { pixelDifference($0, source) }
      let imageBack = restoredB?.maxDelta == 0
      let zoomBack = model.canvas.scale.map { abs($0 - 2) < 0.01 } == true
      let modeBack = model.canvasMode == .edit
      check(
        imageBack && zoomBack && modeBack,
        "(d) Use Settings on (b) puts the input back zoomed on the quadrant (image \(imageBack ? "ok" : "differs, max delta \(restoredB?.maxDelta ?? -1)"), zoom \(model.canvas.scale.map { "\($0)" } ?? "fit"), mode \(model.canvasMode.rawValue))")
      model.use(a)
      await idle()
      try? await Task.sleep(for: .seconds(1))
      check(model.canvasMask == maskA && model.canvas.scale == nil, "(d) Use Settings on (a) brings back its mask, fitted")

      // (e) A queued masked job survives the queue being saved.
      if let request = model.screenRequest() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-refine-check-\(UUID().uuidString)")
        SavedQueue.save([JobQueue.Job(request: request)], project: model.history.project.name, in: folder)
        let restored = await model.savedRequests(SavedQueue.load(project: model.history.project.name, from: folder))
        let back = restored.first
        check(
          back?.mask == request.mask && back?.merge?.record == request.merge?.record
            && back?.merge?.source.width == source.width && back?.canvasTensorId == request.canvasTensorId,
          "(e) a queued masked job keeps its mask and merge across a saved queue")
        try? FileManager.default.removeItem(at: folder)
      } else {
        check(false, "(e) no request from the screen")
      }

      /// Shows a History image as a click does, and waits for it and its mask to land.
      @MainActor func show(_ item: HistoryItem) async {
        let expected = await model.history.image(for: item).map { CGSize(width: $0.width, height: $0.height) }
        model.show(item)
        try? await Task.sleep(for: .milliseconds(100))
        for _ in 0..<100
        where model.imageItem != item || model.isLoadingCanvasImage
          || model.image.map({ CGSize(width: $0.width, height: $0.height) }) != expected
        {
          try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
      }
      @MainActor func painted(_ mask: CanvasMask?, _ size: CGSize) -> [UInt8] {
        (mask ?? CanvasMask()).coverage(width: Int(size.width), height: Int(size.height))
      }
      let square = CGSize(width: size, height: size)

      // (f) A masked run from History image (b): showing (b) again brings its mask back.
      model.mergeIntoImage = true
      model.prompt = "a bright red flower"
      await show(b)
      check(model.canvasMask == nil, "(f) (b) had no mask: none comes back")
      let maskF = CanvasMask(strokes: [.ellipse(in: CGRect(x: half / 4, y: half / 4, width: half, height: half / 2))])
      model.addMaskStrokes(maskF.strokes, actionName: Self.agentMaskName, undoManager: nil)
      guard let f = await run() else {
        check(false, "(f) the masked run from (b) saved nothing")
        return finish()
      }
      check(model.history.hasStoredMask(tensorId: b.tensorId), "(f) (b) remembers its mask once the run is saved")
      check(model.canvasMask == maskF, "(f) the result shows with the mask")
      await show(c)
      await show(b)
      check(model.canvasMask == maskF, "(f) showing (b) again brings its mask back")
      await show(f)
      check(model.canvasMask == maskF, "(f) the result opens with the mask too")
      if let imageB = await model.history.image(for: b) {
        model.clearCanvas()
        await model.restoreSessionImage(imageB, tensorId: b.tensorId, project: model.history.project.name)
        check(model.canvasMask == maskF, "(f) after a relaunch the session's canvas image comes back with its mask")
      }
      // A fresh read of the project file (as after a relaunch) has it too.
      let reopenedF = Project(url: model.history.project.url)
      let storedF = await reopenedF.read { $0.storedMask(forImage: b.tensorId) }
      await reopenedF.close()
      check(storedF == maskF, "(f) the mask is in the project file, under (b)'s image")

      // (g) Painted without a run: switch away and back. Then cleared: it stays cleared.
      await show(c)
      guard let imageC = model.image else { return finish() }
      let sizeC = CGSize(width: imageC.width, height: imageC.height)
      let maskG = CanvasMask(rects: [CGRect(x: 0, y: 0, width: sizeC.width / 2, height: sizeC.height / 4)])
      model.addMaskStrokes(maskG.strokes, actionName: Self.agentMaskName, undoManager: nil)
      await show(b)
      await show(c)
      check(model.canvasMask == maskG, "(g) a mask painted without a run comes back with its image")

      // (h) From (c), another size, onto (b): stretched to fill, each one undo step.
      await show(b)
      let undo = UndoManager()
      undo.groupsByEvent = false
      @MainActor func step(_ how: CreateModel.MaskApplication) async -> Bool {
        undo.beginUndoGrouping()
        let applied = await model.applyMask(from: c, how: how, undoManager: undo)
        undo.endUndoGrouping()
        return applied
      }
      let stretched = maskG.scaled(from: sizeC, to: square)
      check(model.canApplyMask(from: c), "(h) (c) offers its mask")
      let replaced = await step(.replace)
      check(
        replaced && painted(model.canvasMask, square) == painted(stretched, square) && undo.undoActionName == "Use Mask",
        "(h) Replace Canvas Mask puts (c)'s \(Int(sizeC.width))×\(Int(sizeC.height)) mask on (b), stretched to \(size)×\(size) (“\(undo.undoActionName)”)")
      undo.undo()
      check(model.canvasMask == maskF, "(h) ⌘Z puts (b)'s own mask back")
      let added = await step(.add)
      var union = maskF
      union.strokes += stretched.strokes
      check(
        added && painted(model.canvasMask, square) == painted(union, square) && undo.undoActionName == "Use Mask",
        "(h) Add to Canvas Mask adds (c)'s, stretched, to (b)'s")
      undo.undo()
      check(model.canvasMask == maskF, "(h) ⌘Z takes the add back")
      // A mask with an invert adds only what it paints.
      model.clearMask(undoManager: nil)
      model.addMaskStrokes([.rect(CGRect(x: 0, y: 0, width: 8, height: 8))], actionName: Self.agentMaskName, undoManager: nil)
      let inverted = CanvasMask(strokes: [.rect(CGRect(x: 0, y: 0, width: half, height: Double(size))), .invert])
      model.applyMask(inverted, from: square, how: .add, undoManager: nil)
      let rightHalf = CanvasMask(rects: [CGRect(x: half, y: 0, width: half, height: Double(size)), CGRect(x: 0, y: 0, width: 8, height: 8)])
      check(painted(model.canvasMask, square) == painted(rightHalf, square), "(h) adding an inverted mask adds what it paints, keeping what was there")
      model.setMask(maskF, actionName: Self.agentMaskName, undoManager: nil)

      // (g) continued: cleared, it stays cleared, though older records would say otherwise.
      await show(c)
      model.clearMask(undoManager: nil)
      await show(b)
      await show(c)
      check(model.canvasMask == nil && !model.history.hasStoredMask(tensorId: c.tensorId), "(g) a cleared mask stays cleared")

      // (i) Merge into Image off: the masked run's input still remembers the mask.
      model.mergeIntoImage = false
      let maskI = CanvasMask(rects: [CGRect(x: half, y: half, width: half / 2, height: half / 2)])
      model.setMask(maskI, actionName: Self.agentMaskName, undoManager: nil)
      if let request = model.screenRequest() {
        check(request.merge == nil && request.mask != nil, "(i) with Merge off the run carries the mask and doesn't merge")
      }
      model.prompt = "a watercolor painting"
      check(model.screenRequest()?.canvasSourceMask == CanvasSourceMask(tensorId: c.tensorId, width: sizeC.width, height: sizeC.height, mask: maskI), "(i) the run carries the mask for its input to remember")
      guard await run() != nil else {
        check(false, "(i) the run with Merge off saved nothing")
        return finish()
      }
      let storedI = await model.history.storedMask(tensorId: c.tensorId)
      check(storedI == maskI, "(i) the run's input remembers the mask the run had")
      model.mergeIntoImage = true
      finish()
    }
  }

  private static let agentMaskName = CreateModel.agentMaskActionName

  /// `image` scaled to fill a `size` square, cropped in the middle.
  private static func filled(_ image: CGImage, size: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    let scale = max(Double(size) / Double(image.width), Double(size) / Double(image.height))
    let width = Double(image.width) * scale, height = Double(image.height) * scale
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (Double(size) - width) / 2, y: (Double(size) - height) / 2, width: width, height: height))
    return context.makeImage()
  }

  /// The channel differences of two same-sized images over the pixels (top-left based) `where`
  /// picks. Also for `--agent-canvas-check`.
  static func difference(_ a: CGImage, _ b: CGImage, where include: (CGPoint) -> Bool)
    -> (maxDelta: Int, meanDelta: Double)?
  {
    guard a.width == b.width, a.height == b.height else { return nil }
    let pa = CanvasRefineBytes.rgba(a), pb = CanvasRefineBytes.rgba(b)
    var maxDelta = 0, sum = 0, count = 0
    for y in 0..<a.height {
      for x in 0..<a.width where include(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
        let index = (y * a.width + x) * 4
        for c in 0..<3 {
          let delta = abs(Int(pa[index + c]) - Int(pb[index + c]))
          maxDelta = max(maxDelta, delta)
          sum += delta
        }
        count += 3
      }
    }
    return (maxDelta, count > 0 ? Double(sum) / Double(count) : 0)
  }
}

enum CanvasRefineBytes {
  static func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { raw in
      let context = CGContext(
        data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }
}
#endif
