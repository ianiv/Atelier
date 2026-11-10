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
  /// Then masks kept per image: set_canvas_image bringing a step's mask back (and `mask: false`),
  /// list_history's has_mask, get_canvas_mask on a step, and set_canvas_mask from_history_step
  /// (replace, add, subtract, invert, one ⌘Z step each, and its errors).
  /// The frame is set to the input's shape at about a quarter megapixel. Image models that edit at
  /// Strength below 1. Then auto_mask: its errors, Vision finding no subject in the input, and on
  /// `--subject-input` (an image with a subject at `--subject-point`, default 620,550) Vision's
  /// subject, with and without the point, one undo step, and SAM 2.1 Small on the point when it's
  /// installed (skipped otherwise). Prints PASS/FAIL lines.
  ///
  ///   Atelier --agent-canvas-check --project NAME --input FILE [--subject-input FILE]
  ///           [--subject-point x,y] [--model M] [--steps N] [--quit]
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
        // Let the run loop turn first, as it does between an MCP client's requests: the undo
        // manager closes each pass's event group then.
        try? await Task.sleep(for: .milliseconds(20))
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
      // One undo manager for the whole run, chosen now: the window's (which can come up after the
      // model list), or a stand-in when a launch with the screen locked opens no window.
      for _ in 0..<100 where AgentTools.mainWindowUndoManager == nil {
        try? await Task.sleep(for: .milliseconds(100))
      }
      let undoManager = AgentTools.mainWindowUndoManager ?? UndoManager()
      if AgentTools.mainWindowUndoManager == nil {
        print("note: no main window (is the screen locked?); undoing with a stand-in undo manager")
      }
      AgentTools.undoManagerForChecks = undoManager
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
      // A reset and the edits after it in one call are one ⌘Z step.
      _ = try? await call("set_create_screen", ["reset_settings": true, "steps": 3])
      let resetApplied = model.settings?.steps == 3 && model.settings?.width == model.recommended?.width
      try? await Task.sleep(for: .milliseconds(20))
      undoManager.undo()
      check(
        resetApplied && model.settings?.steps == Int(value("--steps") ?? "4") ?? 4 && model.settings?.width == Int(frame.width)
          && model.settings?.maskBlur == 4,
        "reset_settings with steps is one ⌘Z step")

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
      var placedBack: [String: Any]?
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
      check(undoManager.undoActionName == CreateModel.agentMaskActionName, "the change is an “Agent Mask” undo step (\(undoManager.undoActionName))")
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
      undoManager.undo()
      check(near(coverage(), 0.125), "⌘Z undoes the agent's invert (\(coverage()))")
      // Shapes and invert in one call: one undo step.
      _ = try? await call("set_canvas_mask", ["mode": "add", "shapes": [["shape": "polygon", "points": [[0, height], [width / 4, height], [0, height * 3 / 4]]]], "invert": true])
      undoManager.undo()
      check(near(coverage(), 0.125), "one call with a shape and invert is one undo step (\(coverage()))")
      summary = try? await call("set_canvas_mask", ["clear": true])
      check(summary?["has_mask"] as? Bool == false && model.canvasMask == nil, "clear clears it")

      // A user's change registered in the same run-loop pass as an agent call (no turn between),
      // so its event group is open when the agent's change comes. Closing that group from the
      // agent made the undo manager throw when it closed it itself; now the agent waits for it,
      // then joins it (AppKit closes it at the next event, so with none it stays open), and the
      // calls after it are steps of their own again.
      try? await Task.sleep(for: .milliseconds(50))
      var userUndone = false
      undoManager.registerUndo(withTarget: model) { _ in userUndone = true }
      undoManager.setActionName("User Change")
      let userGroupOpen = undoManager.groupingLevel == 1
      _ = try? await tools.call("set_canvas_mask", arguments: ["shapes": [rectShape]]) { _ in }
      let masked = near(coverage(), 0.25)
      // Run-loop passes end here; a group closed out from under the undo manager would throw now.
      try? await Task.sleep(for: .milliseconds(300))
      let joined = undoManager.groupingLevel == 1
      undoManager.undo()
      if !joined, !userUndone { undoManager.undo() }
      check(
        userGroupOpen && masked && userUndone && model.canvasMask == nil,
        "an agent mask while a user's change holds the group open waits, doesn't crash, and undoes (\(joined ? "joined the user's step" : "a step of its own"))")
      _ = try? await call("set_canvas_mask", ["shapes": [rectShape]])
      _ = try? await call("set_canvas_mask", ["invert": true])
      undoManager.undo()
      check(near(coverage(), 0.25) && undoManager.groupingLevel == 0, "after it, agent calls are steps of their own again (\(coverage()))")
      _ = try? await call("set_canvas_mask", ["clear": true])

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
      undoManager.undo()
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

      // The result remembers the mask: set_canvas_image brings it back, unless told not to.
      @MainActor func listed(_ step: Int64) async -> [String: Any]? {
        let text = (try? await tools.call("list_history", arguments: ["limit": 50]) { _ in })
          .flatMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
        let rows = text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]]
        return rows?.first { ($0["history_step"] as? NSNumber)?.int64Value == step }
      }
      check((await listed(step))?["has_mask"] as? Bool == true, "list_history says the masked run's result has a mask")
      _ = try? await call("set_canvas_image", ["image": "data:image/png;base64," + png.base64EncodedString()])
      placedBack = try? await call("set_canvas_image", ["history_step": step])
      check(
        placedBack?["mask_restored"] as? Bool == true && model.canvasMask == mask,
        "set_canvas_image on the result brings its mask back (mask_restored \(placedBack?["mask_restored"] ?? "?"))")
      placedBack = try? await call("set_canvas_image", ["history_step": step, "mask": false])
      check(
        placedBack?["mask_restored"] as? Bool == false && model.canvasMask == nil,
        "set_canvas_image with mask: false leaves it off")
      let stepMask = try? await call("get_canvas_mask", ["history_step": step, "view": "mask"])
      check(
        stepMask?["has_mask"] as? Bool == true && near(stepMask?["coverage"] as? Double ?? 0, 0.25) && model.canvasMask == nil,
        "get_canvas_mask with history_step shows the step's mask (coverage \(stepMask?["coverage"] ?? "?")), leaving the canvas alone")
      await expectError("set_canvas_image", ["history_step": step, "mask": "yes"], "true or false", "a mask that isn't a boolean")
      await expectError("get_canvas_mask", ["history_step": 999_999], "list_history", "a missing step's mask")

      // Zoom, then edit, from that History step: the run follows it.
      let quadrant = CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
      _ = try? await call("set_canvas_image", ["history_step": step, "mask": false])
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
      check((await listed(step))?["has_mask"] as? Bool == true, "leaving the result with mask: false didn't clear the mask it remembers")

      // set_canvas_mask from_history_step, on the zoomed result (which has no mask of its own).
      check((await listed(zoomedStep))?["has_mask"] as? Bool == false, "list_history says the zoomed result has no mask")
      await expectError("set_canvas_mask", ["from_history_step": zoomedStep], "has no mask", "a step with no mask")
      await expectError("set_canvas_mask", ["from_history_step": 999_999], "list_history", "a missing step")
      await expectError("set_canvas_mask", ["from_history_step": "one"], "history step number", "a step that isn't a number")
      _ = try? await call("set_canvas_region", ["fit": true])
      summary = try? await call("set_canvas_mask", ["from_history_step": step])
      check(
        near(summary?["coverage"] as? Double ?? 0, 0.25) && same(rect(summary?["bounds"]), center)
          && undoManager.undoActionName == CreateModel.agentMaskActionName,
        "from_history_step replaces the mask with that step's (\(summary?["coverage"] ?? "?")), one “Agent Mask” step")
      let leftStrip: [String: Any] = ["shape": "rect", "x": 0, "y": 0, "width": width / 4, "height": height]
      _ = try? await call("set_canvas_mask", ["shapes": [leftStrip]])
      summary = try? await call("set_canvas_mask", ["from_history_step": step, "mode": "add"])
      check(near(summary?["coverage"] as? Double ?? 0, 0.5), "from_history_step mode add adds it (\(summary?["coverage"] ?? "?"))")
      summary = try? await call("set_canvas_mask", ["from_history_step": step, "mode": "subtract"])
      check(near(summary?["coverage"] as? Double ?? 0, 0.25), "from_history_step mode subtract takes it away (\(summary?["coverage"] ?? "?"))")
      summary = try? await call("set_canvas_mask", ["from_history_step": step, "invert": true])
      check(near(summary?["coverage"] as? Double ?? 0, 0.75), "from_history_step with invert flips it (\(summary?["coverage"] ?? "?"))")
      undoManager.undo()
      check(near(coverage(), 0.25), "⌘Z undoes the whole call (\(coverage()))")
      _ = try? await call("set_canvas_mask", ["clear": true])

      // auto_mask: errors first, on the input (which has no subject Vision finds).
      _ = try? await call("set_canvas_image", ["image": "data:image/png;base64," + png.base64EncodedString()])
      await expectError("auto_mask", ["text": "the sky"], "text prompt", "a text prompt")
      await expectError("auto_mask", [:], "subject", "nothing to select with")
      await expectError("auto_mask", ["subject": true, "box": ["x": 0, "y": 0, "width": 10, "height": 10]], "no box", "subject with a box")
      await expectError("auto_mask", ["points": [["x": width + 5, "y": 5]]], "outside", "a point off the image")
      await expectError("auto_mask", ["subject": true, "mode": "subtract"], "no mask to subtract", "subtract with no mask")
      await expectError("auto_mask", ["subject": true, "size": "huge"], "size", "an unknown size")
      await expectError(
        "auto_mask", ["points": (0..<13).map { ["x": 10 + $0, "y": 10] }, "box": ["x": 0, "y": 0, "width": 50, "height": 50]],
        "at most 12", "too many points with a box")
      // Vision finds nothing in a scene with no clear subject; an input that has one can't test it.
      do {
        _ = try await call("auto_mask", ["subject": true])
        print("SKIP no subject in the input: Vision found one in --input")
        _ = try? await call("set_canvas_mask", ["clear": true])
      } catch {
        let message = error.localizedDescription
        check(message.contains("No subject"), "no subject in the input: auto_mask fails (“\(message)”)")
      }
      _ = try? await call("set_create_screen", ["canvas_mode": "generate"])
      await expectError("auto_mask", ["subject": true], "canvas_mode", "Generate mode")
      _ = try? await call("set_create_screen", ["canvas_mode": "edit"])
      model.clearCanvas()
      await expectError("auto_mask", ["subject": true], "set_canvas_image", "empty canvas")

      // Vision's subject and SAM on an image with one.
      let subjectPoint = value("--subject-point").map { $0.split(separator: ",").compactMap { Double($0) } }
        .flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } ?? CGPoint(x: 620, y: 550)
      guard let subjectPath = value("--subject-input"), let subjectImage = ImageLoader.image(at: URL(fileURLWithPath: subjectPath)),
            let subjectPNG = ImageTensor.png(subjectImage)
      else {
        print("SKIP auto_mask on a subject: no --subject-input")
        return finish()
      }
      guard CGRect(x: 0, y: 0, width: subjectImage.width, height: subjectImage.height).contains(subjectPoint) else {
        print("SKIP auto_mask on a subject: --subject-point \(subjectPoint) is outside the \(subjectImage.width)×\(subjectImage.height) image")
        return finish()
      }
      _ = try? await call("set_canvas_image", ["image": "data:image/png;base64," + subjectPNG.base64EncodedString()])
      @MainActor func paintedAtPoint() -> Bool {
        guard let mask = model.canvasMask, let image = model.image,
              CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(subjectPoint)
        else { return false }
        return mask.coverage(width: image.width, height: image.height)[Int(subjectPoint.y) * image.width + Int(subjectPoint.x)] != 0
      }
      var selected = try? await call("auto_mask", ["subject": true])
      let selectedPixels = (selected?["selected_pixels"] as? NSNumber)?.intValue ?? 0
      check(
        selected?["has_mask"] as? Bool == true && selectedPixels > 0 && paintedAtPoint() && selected?["decode_ms"] is NSNumber,
        "auto_mask subject masks the subject (\(selectedPixels) px, coverage \(selected?["coverage"] ?? "?"), \(selected?["decode_ms"] ?? "?") ms)")
      check(undoManager.undoActionName == CreateModel.agentMaskActionName, "it's an “Agent Mask” undo step")
      undoManager.undo()
      check(model.canvasMask == nil, "⌘Z takes the auto mask away")
      selected = try? await call("auto_mask", ["subject": true, "points": [["x": subjectPoint.x, "y": subjectPoint.y]]])
      check(selected?["has_mask"] as? Bool == true && paintedAtPoint(), "auto_mask subject with a point masks the subject under it")
      if SAMFiles.installed(.small) != nil {
        selected = try? await call("auto_mask", ["points": [["x": subjectPoint.x, "y": subjectPoint.y]], "size": "small"])
        let samPixels = (selected?["selected_pixels"] as? NSNumber)?.intValue ?? 0
        check(
          samPixels > 0 && paintedAtPoint() && selected?["score"] is NSNumber && selected?["selected_with"] as? String == "sam 2.1 small",
          "auto_mask with SAM 2.1 Small on the point replaces the mask with its selection (\(samPixels) px, score \(selected?["score"] ?? "?"), encode \(selected?["encode_ms"] ?? "?") ms, decode \(selected?["decode_ms"] ?? "?") ms)")
        selected = try? await call("auto_mask", ["points": [["x": subjectPoint.x, "y": subjectPoint.y]], "size": "small", "mode": "subtract"])
        check(
          !paintedAtPoint() && selected?["encode_ms"] is NSNull,
          "subtracting the same selection takes it out, without encoding the image again (coverage \(selected?["coverage"] ?? "?"))")
      } else {
        print("SKIP auto_mask with SAM 2.1 Small: not installed")
        await expectError("auto_mask", ["points": [["x": subjectPoint.x, "y": subjectPoint.y]], "size": "small"], "Select tool", "SAM not downloaded")
      }
      finish()
    }
  }
}
#endif
