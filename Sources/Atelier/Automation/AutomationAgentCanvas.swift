#if os(macOS)
import SwiftUI

extension Automation {
  /// The agent canvas tools end to end, called in-process through `AgentTools.call` as an MCP
  /// client's calls arrive (use a scratch `--project`): set_canvas_image, set_canvas_mask
  /// (replace, add, subtract, invert, clear, an image mask, one ⌘Z step each), get_canvas_mask,
  /// set_canvas_region (region, fit, actual size, scale, the region returned and clamping,
  /// size_to_region), the `canvas` object in get_create_screen and its set_create_screen
  /// fields, the errors each gives, and one `generate` with use_canvas: a masked run that merges,
  /// follows the input step, is stored as two layers and leaves pixels away from the mask alone.
  /// The frame is set to the input's shape at about a quarter megapixel. Image models that edit at
  /// Strength below 1. Prints PASS/FAIL lines.
  ///
  ///   Atelier --agent-canvas-check --project NAME --input FILE [--model M] [--steps N] [--quit]
  static func agentCanvasCheck(_ model: CreateModel, presets: PresetStore) {
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
        print(failures == 0 ? "agent canvas check: all passed" : "agent canvas check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func idle() async {
        try? await Task.sleep(for: .milliseconds(200))
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      }
      let tools = AgentTools(create: model, presets: presets)
      /// A tool's answer: its structured content, else its text parsed as JSON.
      @MainActor func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let result = try await tools.call(name, arguments: arguments) { _ in }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
      }
      /// Expects `name` to fail with a message containing `hint`.
      @MainActor func expectError(_ name: String, _ arguments: [String: Any], _ hint: String, _ what: String) async {
        do {
          _ = try await call(name, arguments)
          check(false, "\(what): \(name) should fail")
        } catch {
          let message = error.localizedDescription
          check(message.contains(hint), "\(what): \(name) fails (“\(message)”)")
        }
      }
      @MainActor func coverage() -> Double {
        model.canvasMaskStats?.paintedFraction ?? -1
      }
      func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.002) -> Bool { abs(a - b) <= tolerance }
      func rect(_ value: Any?) -> CGRect? {
        guard let object = value as? [String: Any], let x = object["x"] as? Double, let y = object["y"] as? Double,
              let width = object["width"] as? Double, let height = object["height"] as? Double
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
      }
      /// Within a pixel and a half: the image lands on whole frame pixels (`CanvasPlacement`), so
      /// the region shown can differ from the one asked for by a fraction of a zoomed pixel.
      func same(_ a: CGRect?, _ b: CGRect) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5 && abs(a.width - b.width) < 1.5
          && abs(a.height - b.height) < 1.5
      }

      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let path = value("--input"), let input = ImageLoader.image(at: URL(fileURLWithPath: path)) else {
        check(false, "--input FILE is required and must be readable")
        return finish()
      }
      if let file = value("--model") {
        model.selectedModel = file
        await idle()
        model.resetToModelDefaults(undoManager: nil)
      }
      // The input's shape at about a quarter megapixel, so a fitted image fills the frame.
      let frame = CanvasPlacement.frameSize(forRegion: CGSize(width: input.width, height: input.height), pixelCount: 512 * 512)
      do {
        _ = try await call(
          "set_create_screen",
          [
            "width": Int(frame.width), "height": Int(frame.height), "steps": Int(value("--steps") ?? "4") ?? 4,
            "strength": 0.7, "seed": 42, "prompt": "a bright red flower",
            "settings": ["maskBlur": 4, "maskBlurOutset": 0], "merge_into_image": true,
          ])
      } catch {
        check(false, "set_create_screen sets up the run (\(error.localizedDescription))")
        return finish()
      }
      check(
        model.settings?.maskBlur == 4 && model.mergeIntoImage && model.settings?.width == Int(frame.width),
        "set_create_screen sets the size, mask blur and Merge into Image")
      // The window can come up after the model list.
      for _ in 0..<100 where AgentTools.mainWindowUndoManager == nil {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if AgentTools.mainWindowUndoManager == nil {
        // A launch while the screen is locked opens no window: undo as the window would.
        print("note: no main window (is the screen locked?); undoing with a stand-in undo manager")
        AgentTools.undoManagerWithoutWindow = UndoManager()
      }
      let undoManager = AgentTools.mainWindowUndoManager

      // Errors on an empty canvas, each naming set_canvas_image.
      model.clearCanvas()
      await expectError("set_canvas_mask", ["shapes": [["shape": "rect", "x": 0, "y": 0, "width": 10, "height": 10]]], "set_canvas_image", "empty canvas")
      await expectError("get_canvas_mask", [:], "set_canvas_image", "empty canvas")
      await expectError("set_canvas_region", ["fit": true], "set_canvas_image", "empty canvas")
      await expectError("generate", ["use_app_settings": true, "use_canvas": true], "set_canvas_image", "empty canvas")
      await expectError("set_canvas_image", [:], "history_step", "no image named")
      await expectError("set_canvas_image", ["history_step": 999_999], "list_history", "a missing step")

      // set_canvas_image, from a data: URL.
      guard let png = ImageTensor.png(input) else { return finish() }
      let placed = try? await call("set_canvas_image", ["image": "data:image/png;base64," + png.base64EncodedString()])
      let source = model.image
      let width = Double(input.width), height = Double(input.height)
      let sourceSize = placed?["source_size"] as? [String: Any]
      check(
        placed?["has_image"] as? Bool == true && sourceSize?["width"] as? Int == input.width
          && placed?["canvas_mode"] as? String == "edit" && (placed?["mask"] as? [String: Any])?["has_mask"] as? Bool == false
          && same(rect(placed?["region"]), CGRect(x: 0, y: 0, width: width, height: height)),
        "set_canvas_image puts the image on the canvas fitted, in Edit, with no mask (\(placed.map { "\($0["region"] ?? "")" } ?? "nothing"))")
      guard let source else { return finish() }

      // Masks: replace, add, replace again, subtract, invert, undo, clear.
      let center = CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2)
      let rectShape: [String: Any] = ["shape": "rect", "x": center.minX, "y": center.minY, "width": center.width, "height": center.height]
      var summary = try? await call("set_canvas_mask", ["shapes": [rectShape]])
      check(
        near(summary?["coverage"] as? Double ?? 0, 0.25) && same(rect(summary?["bounds"]), center)
          && summary?["sent_with_next_run"] as? Bool == true,
        "replace: a centered rect covers a quarter (\(summary?["coverage"] ?? "?")), bounds match, the next run sends it")
      check(undoManager?.undoActionName == CreateModel.agentMaskActionName, "the change is an “Agent Mask” undo step (\(undoManager?.undoActionName ?? "none"))")
      summary = try? await call("set_canvas_mask", ["mode": "add", "shapes": [["shape": "ellipse", "x": 0, "y": 0, "width": width / 8, "height": height / 8]]])
      let added = summary?["coverage"] as? Double ?? 0
      check(added > 0.25 + 0.005, "add: an ellipse in the corner adds to it (\(added))")
      summary = try? await call("set_canvas_mask", ["shapes": [rectShape]])
      check(near(summary?["coverage"] as? Double ?? 0, 0.25), "replace (the default) replaces what was there")
      summary = try? await call(
        "set_canvas_mask", ["mode": "subtract", "shapes": [["shape": "rect", "x": center.minX, "y": center.minY, "width": center.width / 2, "height": center.height]]])
      check(near(summary?["coverage"] as? Double ?? 0, 0.125), "subtract: half the rect taken away (\(summary?["coverage"] ?? "?"))")
      summary = try? await call("set_canvas_mask", ["invert": true])
      check(near(summary?["coverage"] as? Double ?? 0, 0.875), "invert flips it (\(summary?["coverage"] ?? "?"))")
      undoManager?.undo()
      check(near(coverage(), 0.125), "⌘Z undoes the agent's invert (\(coverage()))")
      // Shapes and invert in one call: one undo step.
      _ = try? await call("set_canvas_mask", ["mode": "add", "shapes": [["shape": "polygon", "points": [[0, height], [width / 4, height], [0, height * 3 / 4]]]], "invert": true])
      undoManager?.undo()
      check(near(coverage(), 0.125), "one call with a shape and invert is one undo step (\(coverage()))")
      summary = try? await call("set_canvas_mask", ["clear": true])
      check(summary?["has_mask"] as? Bool == false && model.canvasMask == nil, "clear clears it")

      // An image mask, white on the left half.
      let leftHalf = CanvasMask(rects: [CGRect(x: 0, y: 0, width: width / 2, height: height)]).image(sourceSize: CGSize(width: width, height: height))
      if let leftHalf, let maskPNG = ImageTensor.png(leftHalf) {
        summary = try? await call("set_canvas_mask", ["image": "data:image/png;base64," + maskPNG.base64EncodedString()])
        check(near(summary?["coverage"] as? Double ?? 0, 0.5), "an image mask paints its white half (\(summary?["coverage"] ?? "?"))")
      } else {
        check(false, "couldn't draw the mask image")
      }
      // get_canvas_mask: both views, saved.
      let folder = FileManager.default.temporaryDirectory.appending(path: "atelier-agent-canvas-\(UUID().uuidString)")
      if let result = try? await tools.call("get_canvas_mask", arguments: ["view": "both", "save_to": folder.path + "/"], progress: { _ in }) {
        let images = (result["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image" }.count ?? 0
        let saved = (result["structuredContent"] as? [String: Any])?["saved"] as? [String: String]
        let mask = saved?["mask"].flatMap { ImageLoader.image(at: URL(fileURLWithPath: $0)) }
        let white = mask.map { image in
          let bytes = CanvasRefineBytes.rgba(image)
          return Double(stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 128 }.count) / Double(image.width * image.height)
        }
        check(
          images == 2 && saved?["overlay"] != nil && mask?.width == input.width && near(white ?? 0, 0.5),
          "get_canvas_mask returns the overlay and the mask, and saves the mask white on black at the image's size (\(white ?? -1))")
      } else {
        check(false, "get_canvas_mask failed")
      }
      try? FileManager.default.removeItem(at: folder)
      // Mask errors.
      await expectError("set_canvas_mask", ["shapes": [["shape": "polygon", "points": [[0, 0], [10, 10]]]]], "at least 3", "a two-point polygon")
      await expectError("set_canvas_mask", ["shapes": [["shape": "rect", "x": 0, "y": 0, "width": 0, "height": 10]]], "no size", "a zero-width rect")
      await expectError("set_canvas_mask", ["shapes": [["shape": "rect", "x": width + 10, "y": 0, "width": 10, "height": 10]]], "outside", "a shape off the image")
      await expectError("set_canvas_mask", ["image": "data:image/png;base64," + png.base64EncodedString(), "mode": "bogus"], "mode", "an unknown mode")
      if let small = CanvasMask(rects: [CGRect(x: 0, y: 0, width: 8, height: 8)]).image(sourceSize: CGSize(width: 16, height: 16)),
         let smallPNG = ImageTensor.png(small)
      {
        await expectError("set_canvas_mask", ["image": "data:image/png;base64," + smallPNG.base64EncodedString()], "\(input.width)×\(input.height)", "a mask of the wrong size")
      }
      await expectError("set_canvas_mask", [:], "shapes", "nothing to do")

      // Regions.
      var state = try? await call("set_canvas_region", ["region": ["x": 0, "y": 0, "width": width / 2, "height": height / 2]])
      check(
        same(rect(state?["region"]), CGRect(x: 0, y: 0, width: width / 2, height: height / 2)) && state?["clamped"] as? Bool == false
          && near(state?["scale"] as? Double ?? 0, frame.width / (width / 2), 0.02),
        "a region of the frame's shape is shown as is (\(state?["region"] ?? "?"), scale \(state?["scale"] ?? "?"))")
      state = try? await call("set_canvas_region", ["region": ["x": 0, "y": 0, "width": width / 4, "height": height / 2]])
      let grown = CanvasPlacement.grown(CGRect(x: 0, y: 0, width: width / 4, height: height / 2), toShapeOf: frame)
      check(
        same(rect(state?["region"]), grown) && state?["extends_past_image"] as? Bool == true,
        "a narrower region grows about its center to the frame's shape, past the image's edge (\(state?["region"] ?? "?"))")
      state = try? await call("set_canvas_region", ["region": ["x": 100, "y": 100, "width": 4, "height": 4]])
      let shown = rect(state?["region"])
      check(
        state?["clamped"] as? Bool == true && near(state?["scale"] as? Double ?? 0, 32, 0.01)
          && (shown.map { abs($0.width - frame.width / 32) < 1 && abs($0.midX - 102) < 1 } ?? false),
        "a tiny region clamps at 32× and returns the larger region shown (\(state?["region"] ?? "?"))")
      state = try? await call("set_canvas_region", ["actual_size": true])
      check(
        near(state?["scale"] as? Double ?? 0, 1, 0.01)
          && (rect(state?["region"]).map { abs($0.width - frame.width) < 1 } ?? false),
        "actual_size shows the image at 1× (\(state?["region"] ?? "?"))")
      state = try? await call("set_canvas_region", ["scale": 2, "center": [width / 4, height / 4]])
      let quarter = CGRect(x: width / 4 - frame.width / 4, y: height / 4 - frame.height / 4, width: frame.width / 2, height: frame.height / 2)
      check(same(rect(state?["region"]), quarter), "scale 2 centered on a point shows the region around it (\(state?["region"] ?? "?"))")
      state = try? await call("set_canvas_region", ["fit": true])
      check(
        state?["fitted"] as? Bool == true && same(rect(state?["region"]), CGRect(x: 0, y: 0, width: width, height: height)),
        "fit shows the whole image")
      // size_to_region: a square region makes the output square, one undo step.
      state = try? await call("set_canvas_region", ["region": ["x": 0, "y": 0, "width": height, "height": height], "size_to_region": true])
      let square = model.settings.map { $0.width == $0.height } ?? false
      check(
        square && same(rect(state?["region"]), CGRect(x: 0, y: 0, width: height, height: height)),
        "size_to_region makes the output square and shows the square region (\(model.settings?.width ?? 0)×\(model.settings?.height ?? 0))")
      undoManager?.undo()
      check(model.settings?.width == Int(frame.width) && model.settings?.height == Int(frame.height), "⌘Z puts the output size back")
      _ = try? await call("set_canvas_region", ["fit": true])
      await expectError("set_canvas_region", ["scale": 100], "0.05", "a scale out of range")
      await expectError("set_canvas_region", ["region": ["x": width + 50, "y": 0, "width": 10, "height": 10]], "overlap", "a region off the image")
      await expectError("set_canvas_region", ["fit": true, "actual_size": true], "one of", "two choices")
      await expectError("set_canvas_region", ["actual_size": true, "size_to_region": true], "size_to_region", "size_to_region without a region")

      // get_create_screen's canvas, and set_create_screen's canvas fields.
      _ = try? await call("set_create_screen", ["merge_into_image": false, "canvas_mode": "generate"])
      var screen = (try? await call("get_create_screen"))?["canvas"] as? [String: Any]
      check(
        screen?["merge_into_image"] as? Bool == false && screen?["canvas_mode"] as? String == "generate"
          && !model.mergeIntoImage && model.canvasMode == .generate,
        "set_create_screen changes Merge into Image and the canvas mode")
      await expectError("set_canvas_mask", ["shapes": [rectShape]], "canvas_mode", "Generate mode")
      await expectError("generate", ["use_app_settings": true, "use_canvas": true], "canvas_mode", "Generate mode")
      _ = try? await call("set_create_screen", ["merge_into_image": true, "canvas_mode": "edit"])
      _ = try? await call("set_canvas_mask", ["shapes": [rectShape]])
      screen = (try? await call("get_create_screen"))?["canvas"] as? [String: Any]
      let frameJSON = screen?["frame"] as? [String: Any]
      check(
        screen?["has_image"] as? Bool == true && frameJSON?["width"] as? Int == Int(frame.width)
          && same(rect(screen?["region"]), CGRect(x: 0, y: 0, width: width, height: height))
          && screen?["fitted"] as? Bool == true && screen?["extends_past_image"] as? Bool == false
          && screen?["canvas_mode_in_effect"] as? String == "edit" && screen?["merge_applies"] as? Bool == true
          && near((screen?["mask"] as? [String: Any])?["coverage_in_region"] as? Double ?? 0, 0.25),
        "get_create_screen's canvas has the frame, region, mode, mask and merge")

      // generate with use_canvas: errors, then one masked, merging run.
      await expectError("generate", ["use_canvas": true], "use_app_settings", "use_canvas alone")
      await expectError("generate", ["use_app_settings": true, "use_canvas": true, "prompt": "x"], "set_create_screen", "use_canvas with a prompt")
      await expectError("generate", ["use_app_settings": true, "use_canvas": true, "input_image": path], "set_canvas_image", "use_canvas with input_image")
      let expected = model.screenRequest()
      let mask = model.canvasMask
      let result: [String: Any]
      do {
        result = try await call("generate", ["use_app_settings": true, "use_canvas": true])
      } catch {
        check(false, "generate use_canvas ran (\(error.localizedDescription))")
        return finish()
      }
      let size = result["canvas_size"] as? [String: Any]
      check(
        result["merged"] as? Bool == true && size?["width"] as? Int == input.width && size?["height"] as? Int == input.height
          && expected?.merge != nil && expected?.mask != nil,
        "generate use_canvas merges the masked run into the whole image (\(size ?? [:]))")
      guard let step = (result["history_step"] as? NSNumber)?.int64Value,
            let item = model.history.items.first(where: { $0.id.logicalTime == step }),
            let image = await model.history.image(for: item)
      else {
        check(false, "the run's step isn't in History")
        return finish()
      }
      // An imported image is stored as the step's first layer, not as a History step of its own.
      check(
        result["parent_history_step"] is NSNull && item.inputTensorId != nil,
        "from an imported image, there's no parent step, and the input is kept with the step")
      let layers = await model.history.project.read { $0.layerSummary(tensorId: item.tensorId) }
      check(
        layers.count == 2 && layers[0].maskId > 0 && layers[0].tensorId == item.inputTensorId,
        "it's stored as two layers, the input with the mask under the frame (\(layers.map { "\($0.tensorId)/\($0.maskId)@\($0.x),\($0.y)" }))")
      check(item.sidecar.refine?.mask == mask, "the step keeps the agent's mask")
      // Mask Blur 4 frame pixels is about 12 at 3 sigma; in image pixels at this zoom, with a margin.
      let margin = 24 * width / frame.width
      let far = center.insetBy(dx: -margin, dy: -margin)
      let outside = difference(image, source) { !far.contains($0) }
      let inside = difference(image, source) { center.insetBy(dx: margin, dy: margin).contains($0) }
      check(outside?.maxDelta == 0, "pixels away from the mask are the input's exactly (max delta \(outside?.maxDelta ?? -1))")
      check((inside?.meanDelta ?? 0) > 1, "the masked area changed (mean delta \(String(format: "%.1f", inside?.meanDelta ?? 0)))")
      check(model.canvasMask == mask, "the mask stays on the canvas after the run")

      // Zoom, then edit, from that History step: the run follows it.
      let quadrant = CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
      _ = try? await call("set_canvas_image", ["history_step": step])
      _ = try? await call("set_create_screen", ["prompt": "a watercolor painting"])
      state = try? await call("set_canvas_region", ["region": ["x": 0, "y": 0, "width": width / 2, "height": height / 2]])
      check(model.imageItem == item && same(rect(state?["region"]), quadrant), "set_canvas_image puts the History step on the canvas, and the region zooms onto its quadrant")
      guard let zoomed = try? await call("generate", ["use_app_settings": true, "use_canvas": true]),
            let zoomedStep = (zoomed["history_step"] as? NSNumber)?.int64Value,
            let zoomedItem = model.history.items.first(where: { $0.id.logicalTime == zoomedStep }),
            let zoomedImage = await model.history.image(for: zoomedItem)
      else {
        check(false, "the zoomed run saved nothing")
        return finish()
      }
      check(
        (zoomed["parent_history_step"] as? NSNumber)?.int64Value == step && zoomed["merged"] as? Bool == true
          && same(rect(zoomed["region"]), quadrant),
        "a zoomed run merges and follows the step it refined (parent \(zoomed["parent_history_step"] ?? "none"), step \(step))")
      let rest = difference(zoomedImage, image) { $0.x >= width / 2 + margin || $0.y >= height / 2 + margin }
      let changed = difference(zoomedImage, image) { $0.x < width / 2 - margin && $0.y < height / 2 - margin }
      check(rest?.maxDelta == 0, "outside the region nothing changed (max delta \(rest?.maxDelta ?? -1))")
      check((changed?.meanDelta ?? 0) > 1, "the region changed (mean delta \(String(format: "%.1f", changed?.meanDelta ?? 0)))")
      finish()
    }
  }
}
#endif
