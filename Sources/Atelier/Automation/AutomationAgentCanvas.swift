#if os(macOS)
import SwiftUI

extension Automation {
  /// The agent canvas tools end to end, called in-process through `AgentTools.call` as an MCP
  /// client's calls arrive (use a scratch `--project`): set_canvas_image, set_canvas_mask
  /// (replace, add, subtract, invert, clear, an image mask, one ⌘Z step each), get_canvas_mask,
  /// set_canvas_region (region, fit, actual size, scale, the region returned and clamping,
  /// size_to_region), the `canvas` object in get_create_screen and its set_create_screen
  /// fields, the errors each gives, and one `generate` with use_canvas: a masked run that merges,
  /// follows the input step, is stored as two layers and leaves pixels away from the mask alone;
  /// a zoomed run's frame kept at its density, and get_image full_detail.
  /// Then masks kept per image: set_canvas_image bringing a step's mask back (and `mask: false`),
  /// list_history's has_mask, get_canvas_mask on a step, and set_canvas_mask from_history_step
  /// (replace, add, subtract, invert, one ⌘Z step each, and its errors).
  /// The frame is set to the input's shape at about a quarter megapixel. Image models that edit at
  /// Strength below 1. Then auto_mask: its errors, Vision finding no subject in the input, and on
  /// `--subject-input` (an image with a subject at `--subject-point`, default 620,550) Vision's
  /// subject, with and without the point, one undo step, and SAM 2.1 Small on the point when it's
  /// installed (skipped otherwise). Before auto_mask, the edit tools: grow_canvas_mask (grow,
  /// shrink, one “Agent Mask” step, its errors), set_canvas_frame (the mask's bounds padded, a box
  /// at a scale sizing the output as one “Agent Settings” step, staying inside the image or not,
  /// its errors) and find_faces (its errors, and on `--face-input`, an image with a face, the
  /// face's box and landmarks, and the same face found in a region), and the moodboard:
  /// get_moodboard and set_moodboard (add, weights, order, remove, clear, one “Agent Moodboard”
  /// step a call, the Picture numbers, its errors) and get_create_screen's listing. Then
  /// edit_image, which must leave the Create screen alone: with a History image on the canvas,
  /// zoomed, masked and painted, and an image on the moodboard, the screen is captured
  /// (get_create_screen but `busy`, the canvas image by identity, its mask, paint and zoom, the
  /// moodboard, History's current step, the next undo step, Merge into Image and the canvas mode)
  /// before and after a masked edit of another region of that step, and compared; the canvas must
  /// show its own image at every progress report and all through the run. The edit is a new step
  /// after its source, the source's size, unchanged away from the mask. Again in the background
  /// with the mask filled with paint (get_job, list_jobs), and from an image file; its errors;
  /// match_colors with original_history_step on the painted edit. With `--edit-model` (a model
  /// that takes reference images) and `--face-input`, the face-fix shape: a region around the face
  /// at `--edit-scale` (default 2), masked, filled green, with the face as Picture 2, at
  /// `--edit-steps` (default 6), its result written to `--edit-save` when given. The region is
  /// whatever lies inside the image and comes to at most 1536×2048 at that scale (the face and
  /// room around it when that fits, else the middle of the face), so any scale is a run of a
  /// sensible size that merges at the image's size. It notes which models list_models says take
  /// reference images. Then, a region reaching past the image: edit_image says the result grew.
  /// While an edit_image runs, a History step shown and Generate pressed: the user's run still
  /// shows on the canvas and becomes current. A History step shown during a run of the user's
  /// with an edit_image and another run of theirs queued behind it: that next run stays off the
  /// canvas too. The project renamed while an edit_image and a generate wait: both answer with
  /// the new name and their step there (it's renamed back after). And with `--edit-model` and `--face-input` again,
  /// the same face fix on the canvas, a tool call at a time as an agent would make them
  /// (set_canvas_image, find_faces, set_canvas_frame, set_canvas_mask, grow_canvas_mask,
  /// set_canvas_paint, set_moodboard, set_create_screen, generate with use_canvas, match_colors
  /// with original_history_step), after which the model, settings and prompt are put back.
  /// Prints PASS/FAIL lines.
  ///
  /// The canvas tools' remembered settings, Merge into Image, the canvas mode, the moodboard and
  /// the recent prompts are put back as they were when it ends.
  ///
  ///   Atelier --agent-canvas-check --project NAME --input FILE [--subject-input FILE]
  ///           [--subject-point x,y] [--face-input FILE] [--edit-model M] [--edit-scale S]
  ///           [--edit-steps N] [--edit-save FILE] [--model M] [--steps N] [--quit]
  static func agentCanvasCheck(_ model: CreateModel, presets: PresetStore) {
    // What the check changes that outlives it (the settings are UserDefaults'), as it is now.
    let restoreCanvasSettings = keepCanvasSettings(model)
    let mergeBefore = model.mergeIntoImage, modeBefore = model.canvasMode
    let moodboardBefore = model.moodboard.items
    let recentPromptsBefore = model.recentPrompts
    let storedBefore = ["mergeIntoImage", "canvasMode"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
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
        restoreCanvasSettings()
        model.mergeIntoImage = mergeBefore
        model.canvasMode = modeBefore
        // Exactly as they were: a key that wasn't set stays unset (the app's default).
        for (key, value) in storedBefore { UserDefaults.standard.set(value, forKey: key) }
        model.moodboard.replace(with: moodboardBefore.map { ($0.image, $0.weight) })
        // Its own Generate presses would otherwise stay in ⌘↑'s list.
        model.restoreRecentPrompts(recentPromptsBefore)
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
      // Zoomed in, the frame is kept at its own density (`CanvasMerge.frameDensity`).
      let zoomedDensity = model.canvasPlacement.map { CanvasMerge.frameDensity(zoom: ($0.zoom.x + $0.zoom.y) / 2) } ?? 120
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
      // Its detail: a layer at the zoom's density, and get_image full_detail at that density.
      @MainActor func imageText(_ arguments: [String: Any]) async -> String {
        let answer = try? await tools.call("get_image", arguments: arguments) { _ in }
        return (answer?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
      }
      let zoomedLayers = await model.history.project.read { $0.layerSummary(tensorId: zoomedItem.tensorId) }
      if zoomedDensity > 120 {
        let fullWidth = Int((width * Double(zoomedDensity) / 120).rounded(.up))
        let fullHeight = Int((height * Double(zoomedDensity) / 120).rounded(.up))
        check(
          zoomedLayers.count >= 2 && zoomedLayers.last?.scale == Int32(zoomedDensity),
          "the zoomed run's frame is a layer at \(zoomedDensity) (\(zoomedLayers.map { "\($0.width)×\($0.height)@\($0.scale)" }))")
        let text = await imageText(["history_step": zoomedStep, "full_detail": true])
        check(
          text.contains("At full detail: \(fullWidth)×\(fullHeight)"),
          "get_image full_detail returns it at \(fullWidth)×\(fullHeight) (\(text.split(separator: "\n").last ?? ""))")
        let plain = await imageText(["history_step": zoomedStep])
        check(!plain.contains("At full detail"), "get_image without full_detail is the image's own size")
      } else {
        check(zoomedLayers.last.map { $0.scale == 120 } ?? true, "at or below 1× the zoomed run stays at the image's pixels")
      }
      if layers.last?.scale == 120 {
        check(
          await imageText(["history_step": step, "full_detail": true]).contains("no finer detail"),
          "get_image full_detail on a step with no finer layers says so")
      }
      await expectError("get_image", ["full_detail": "yes"], "true or false", "a full_detail that isn't a boolean")

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

      // grow_canvas_mask, on the input with the centered rect: out by 8, back, in by 8.
      _ = try? await call("set_canvas_image", ["image": "data:image/png;base64," + png.base64EncodedString()])
      await expectError("grow_canvas_mask", ["pixels": 8], "mask is empty", "growing no mask")
      _ = try? await call("set_canvas_mask", ["shapes": [rectShape]])
      let rectPixels = model.canvasMaskStats?.paintedPixels ?? 0
      summary = try? await call("grow_canvas_mask", ["pixels": 8])
      let grownPixels = (summary?["painted_pixels"] as? NSNumber)?.intValue ?? 0
      // A rect grown by a disc: 8 more on every side, less the four rounded corners.
      let grownArea = Double(rectPixels) + 16 * (center.width + center.height) + Double.pi * 64
      check(
        same(rect(summary?["bounds"]), center.insetBy(dx: -8, dy: -8)) && abs(Double(grownPixels) - grownArea) < grownArea * 0.01
          && (summary?["grown_by"] as? NSNumber)?.intValue == 8,
        "grow_canvas_mask by 8 moves the edge out 8 px, corners rounded (\(grownPixels) px, expected about \(Int(grownArea)); bounds \(summary?["bounds"] ?? "?"))")
      check(undoManager.undoActionName == CreateModel.agentMaskActionName, "growing is an “Agent Mask” undo step (\(undoManager.undoActionName))")
      undoManager.undo()
      check(model.canvasMaskStats?.paintedPixels == rectPixels, "⌘Z puts the mask back as it was (\(model.canvasMaskStats?.paintedPixels ?? -1) px)")
      summary = try? await call("grow_canvas_mask", ["pixels": -8])
      check(
        same(rect(summary?["bounds"]), center.insetBy(dx: 8, dy: 8)) && (summary?["grown_by"] as? NSNumber)?.intValue == -8,
        "a negative amount shrinks it (bounds \(summary?["bounds"] ?? "?"))")
      await expectError("grow_canvas_mask", ["pixels": 0], "1 to 512", "growing by nothing")
      await expectError("grow_canvas_mask", ["pixels": 600], "1 to 512", "growing by too much")
      await expectError("grow_canvas_mask", [:], "pixels", "no amount")
      _ = try? await call("set_canvas_mask", ["shapes": [["shape": "rect", "x": 20, "y": 20, "width": 10, "height": 10]]])
      await expectError("grow_canvas_mask", ["pixels": -20], "leaves nothing", "shrinking a small mask away")

      // set_canvas_frame: the mask's bounds, padded, at the output's shape and size.
      _ = try? await call("set_canvas_mask", ["shapes": [rectShape]])
      state = try? await call("set_canvas_frame")
      let framePadding = 0.25 * max(center.width, center.height)
      var framed = rect(state?["region"])
      check(
        (framed.map { $0.insetBy(dx: -1.5, dy: -1.5).contains(center.insetBy(dx: -framePadding, dy: -framePadding).intersection(CGRect(x: 0, y: 0, width: width, height: height))) } ?? false)
          && same(rect(state?["requested_box"]), center) && same(rect(state?["padded_box"]), center.insetBy(dx: -framePadding, dy: -framePadding))
          && state?["clamped"] as? Bool == false && model.settings?.width == Int(frame.width) && model.settings?.height == Int(frame.height),
        "set_canvas_frame frames the mask's bounds with a quarter's padding, keeping the output size (\(state?["region"] ?? "?"))")
      // A box at a scale: the output is sized to the region, one “Agent Settings” step.
      let side = (min(width, height) / 8).rounded()
      state = try? await call(
        "set_canvas_frame", ["box": ["x": width / 2, "y": height / 2, "width": side, "height": side], "padding": 0, "aspect_ratio": "1:1", "scale": 2])
      framed = rect(state?["region"])
      let sized = max((side * 2 / 64).rounded(), 1) * 64
      check(
        model.settings?.width == Int(sized) && model.settings?.height == Int(sized) && near(state?["scale"] as? Double ?? 0, 2, 0.001)
          && (framed.map { abs($0.width - sized / 2) < 1 && abs($0.midX - (width / 2 + side / 2)) < 1.5 } ?? false),
        "a box at scale 2 sizes the output to the region at exactly 2× (\(model.settings?.width ?? 0)×\(model.settings?.height ?? 0), scale \(state?["scale"] ?? "?"), region \(state?["region"] ?? "?"))")
      check(undoManager.undoActionName == "Agent Settings", "the size change is an “Agent Settings” undo step (\(undoManager.undoActionName))")
      undoManager.undo()
      check(model.settings?.width == Int(frame.width) && model.settings?.height == Int(frame.height), "⌘Z puts the output size back")
      // A box in the corner: moved inside the image, or left centered on the box.
      let corner: [String: Any] = ["x": 0, "y": 0, "width": side, "height": side]
      state = try? await call("set_canvas_frame", ["box": corner, "padding": side])
      framed = rect(state?["region"])
      check(
        state?["extends_past_image"] as? Bool == false && (framed.map { $0.minX > -1 && $0.minY > -1 } ?? false),
        "a box in the corner is framed inside the image (\(state?["region"] ?? "?"))")
      state = try? await call("set_canvas_frame", ["box": corner, "padding": side, "stay_inside_image": false])
      framed = rect(state?["region"])
      check(
        state?["extends_past_image"] as? Bool == true && (framed.map { abs($0.midX - side / 2) < 1.5 } ?? false),
        "with stay_inside_image false it stays centered on the box, past the edge (\(state?["region"] ?? "?"))")
      await expectError("set_canvas_frame", ["width": 512, "height": 512, "scale": 2], "not both", "a size and a scale")
      await expectError("set_canvas_frame", ["box": ["x": width + 50, "y": 0, "width": 10, "height": 10]], "overlap", "a box off the image")
      await expectError("set_canvas_frame", ["aspect_ratio": "wide"], "aspect_ratio", "a shape that isn't one")
      await expectError("set_canvas_frame", ["width": true, "height": true], "output size", "true for width and height")
      _ = try? await call("set_canvas_mask", ["clear": true])
      await expectError("set_canvas_frame", [:], "nothing to frame", "no mask and no box")
      _ = try? await call("set_canvas_region", ["fit": true])

      // The moodboard: listed, changed one ⌘Z step a call, numbered as a prompt names the pictures.
      model.moodboard.removeAll()
      var board = try? await call("get_moodboard")
      check(
        (board?["images"] as? [[String: Any]])?.isEmpty == true && board?["model_takes_references"] as? Bool == model.usesReferences
          && (board?["note"] != nil) == !model.usesReferences,
        "get_moodboard lists an empty board, and says whether the model takes references (\(board?["model_takes_references"] ?? "?"))")
      @MainActor func images(_ board: [String: Any]?) -> [[String: Any]] { board?["images"] as? [[String: Any]] ?? [] }
      board = try? await call(
        "set_moodboard", ["add": [["image": "data:image/png;base64," + png.base64EncodedString()], ["history_step": step, "weight": 0.5]]])
      // The canvas, in Edit with an image, is the first picture; the board's follow it.
      let firstPicture = model.effectiveCanvasMode == .edit && model.image != nil ? 2 : 1
      var listedImages = images(board)
      check(
        listedImages.count == 2 && model.moodboard.items.count == 2 && listedImages.first?["position"] as? Int == 1
          && near(listedImages.last?["weight"] as? Double ?? 0, 0.5) && listedImages.first?["picture"] as? Int == firstPicture
          && listedImages.last?["picture"] as? Int == firstPicture + 1 && listedImages.last?["width"] as? Int == model.moodboard.items.last?.image.width
          && board?["canvas_is_picture_1"] as? Bool == (firstPicture == 2),
        "set_moodboard adds an image and a History step, in order, numbered from Picture \(firstPicture) (\(listedImages.map { "\($0["position"] ?? "?"):\($0["picture"] ?? "?")@\($0["weight"] ?? "?")" }))")
      check(undoManager.undoActionName == CreateModel.agentMoodboardActionName, "the change is an “Agent Moodboard” undo step (\(undoManager.undoActionName))")
      undoManager.undo()
      check(model.moodboard.items.isEmpty, "⌘Z takes both images off again")
      undoManager.redo()
      let boardIDs = model.moodboard.items.map(\.id.uuidString)
      check(boardIDs.count == 2 && boardIDs == listedImages.compactMap { $0["id"] as? String }, "redo brings back the very images, with their ids")
      // A weight of 0 keeps an image on the board but out of the run: the next one moves up.
      board = try? await call("set_moodboard", ["weights": [["position": 1, "weight": 0]]])
      listedImages = images(board)
      check(
        listedImages.first?["sent"] as? Bool == false && listedImages.first?["picture"] is NSNull
          && listedImages.last?["picture"] as? Int == firstPicture && model.moodboard.references.count == 1,
        "a weight of 0 leaves the image out, and the next takes its number")
      board = try? await call("set_moodboard", ["order": Array(boardIDs.reversed())])
      check(
        images(board).compactMap { $0["id"] as? String } == Array(boardIDs.reversed()) && model.moodboard.items.map(\.id.uuidString) == Array(boardIDs.reversed()),
        "order puts the images in the order given")
      // One call that removes, adds at a position and sets a weight is one step.
      board = try? await call(
        "set_moodboard",
        [
          "remove": [1], "add": [["image": "data:image/png;base64," + png.base64EncodedString(), "position": 1, "weight": 0.25]],
          "weights": [["id": boardIDs[0], "weight": 1]],
        ])
      listedImages = images(board)
      check(
        listedImages.count == 2 && near(listedImages.first?["weight"] as? Double ?? 0, 0.25) && listedImages.last?["id"] as? String == boardIDs[0]
          && near(listedImages.last?["weight"] as? Double ?? 0, 1),
        "remove, add at a position and a weight in one call (\(listedImages.map { "\($0["position"] ?? "?")@\($0["weight"] ?? "?")" }))")
      undoManager.undo()
      check(
        model.moodboard.items.map(\.id.uuidString) == Array(boardIDs.reversed()) && model.moodboard.items.last?.weight == 0,
        "⌘Z undoes the whole call")
      let screenBoard = (try? await call("get_create_screen"))
      check(
        images(screenBoard?["moodboard"] as? [String: Any]).count == 2 && screenBoard?["reference_images"] as? Int == 2,
        "get_create_screen lists the moodboard, and still counts it")
      let withImages = try? await tools.call("get_moodboard", arguments: ["include_images": true]) { _ in }
      check(
        (withImages?["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image" }.count == 2,
        "get_moodboard with include_images returns a thumbnail of each")
      await expectError("set_moodboard", [:], "Pass `add`", "nothing to do")
      await expectError("set_moodboard", ["remove": [9]], "No moodboard image 9 (there are 2)", "a position past the end")
      await expectError("set_moodboard", ["weights": [["position": 1, "weight": 2]]], "`weight` is 0-1", "a weight out of range")
      await expectError("set_moodboard", ["order": [boardIDs[0]]], "every image once", "an order that leaves one out")
      await expectError("set_moodboard", ["add": [["history_step": 999_999]]], "list_history", "a missing step")
      await expectError("set_moodboard", ["add": [["weight": 1]]], "history_step", "an image with no source")
      check(model.moodboard.items.map(\.id.uuidString) == Array(boardIDs.reversed()), "a call that fails changes nothing")
      board = try? await call("set_moodboard", ["clear": true])
      check(images(board).isEmpty && model.moodboard.items.isEmpty, "clear empties the board")

      // find_faces: errors, then a face when the run has an image with one.
      await expectError("find_faces", ["history_step": 999_999], "list_history", "a missing step")
      await expectError("find_faces", ["region": ["x": width + 50, "y": 0, "width": 10, "height": 10]], "overlap", "a region off the image")
      if let facePath = value("--face-input"), let faceImage = ImageLoader.image(at: URL(fileURLWithPath: facePath)),
         let facePNG = ImageTensor.png(faceImage)
      {
        _ = try? await call("set_canvas_image", ["image": "data:image/png;base64," + facePNG.base64EncodedString()])
        let found = try? await call("find_faces")
        let faces = found?["faces"] as? [[String: Any]] ?? []
        let faceBox = rect(faces.first?["box"])
        let faceCenter = faces.first?["center"] as? [Double] ?? []
        let landmarks = faces.first?["landmarks"] as? [String: Any] ?? [:]
        let imageRect = CGRect(x: 0, y: 0, width: faceImage.width, height: faceImage.height)
        check(
          !faces.isEmpty && (faceBox.map { imageRect.contains($0) && $0.width > 8 } ?? false) && faceCenter.count == 2
            && (faceBox.map { $0.contains(CGPoint(x: faceCenter.first ?? -1, y: faceCenter.last ?? -1)) } ?? false)
            && landmarks["left_eye"] != nil && (found?["source_size"] as? [String: Any])?["width"] as? Int == faceImage.width,
          "find_faces finds a face on the canvas image, with its box, center and landmarks (\(faces.count) found, box \(faces.first?["box"] ?? "none"))")
        if let faceBox {
          // The same face, searched for only around it.
          let around = faceBox.insetBy(dx: -faceBox.width / 2, dy: -faceBox.height / 2).intersection(imageRect)
          let again = try? await call(
            "find_faces", ["region": ["x": around.minX, "y": around.minY, "width": around.width, "height": around.height], "max_faces": 1])
          let nearBox = rect((again?["faces"] as? [[String: Any]])?.first?["box"])
          check(
            (again?["faces"] as? [[String: Any]])?.count == 1 && (nearBox.map { abs($0.midX - faceBox.midX) < faceBox.width / 4 && abs($0.midY - faceBox.midY) < faceBox.height / 4 } ?? false),
            "find_faces in a region gives the face in the whole image's pixels (\((again?["faces"] as? [[String: Any]])?.first?["box"] ?? "none"))")
          // The face's box frames it: set_canvas_frame around it holds the whole box.
          state = try? await call(
            "set_canvas_frame", ["box": ["x": faceBox.minX, "y": faceBox.minY, "width": faceBox.width, "height": faceBox.height]])
          check(
            rect(state?["region"]).map { $0.insetBy(dx: -1.5, dy: -1.5).contains(faceBox) } ?? false,
            "set_canvas_frame on the face's box shows the whole face (\(state?["region"] ?? "?"))")
        }
      } else {
        print("SKIP find_faces on a face: no --face-input")
      }

      // edit_image, which edits off the canvas. First, what has to stay: a History image on the
      // canvas, zoomed, with a mask and paint, and an image on the moodboard.
      let sourceStep = model.history.item(tensorId: item.tensorId)?.id.logicalTime ?? step
      _ = try? await call("set_canvas_image", ["history_step": sourceStep, "mask": false])
      _ = try? await call("set_canvas_mask", ["shapes": [rectShape]])
      _ = try? await call(
        "set_canvas_paint",
        ["shapes": [["shape": "ellipse", "x": width * 0.6, "y": height * 0.6, "width": width / 8, "height": height / 8, "color": "#3366FF"]]])
      _ = try? await call("set_canvas_region", ["region": ["x": width / 2, "y": height / 2, "width": width / 2, "height": height / 2]])
      _ = try? await call("set_moodboard", ["add": [["image": "data:image/png;base64," + png.base64EncodedString(), "weight": 0.5]]])
      _ = try? await call("set_create_screen", ["prompt": "a prompt edit_image must leave alone", "seed": 4242])
      // The moodboard change goes into History a moment later (an input entry): after that,
      // nothing of the screen's is still on its way.
      @MainActor func settled() async {
        try? await Task.sleep(for: CreateModel.moodboardSettle + .milliseconds(500))
        while model.waitsForEntries || model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      }
      await settled()
      /// What an edit off the canvas must leave as it is.
      struct ScreenState {
        var screen = ""
        var image: ObjectIdentifier?
        var imageTensor: Int64?
        var showsImage = false
        var mask: CanvasMask?
        var paint: CanvasPaint?
        var layersHidden = false
        var scale: Double?
        var offset = CGSize.zero
        var moodboard: [String] = []
        var current: Int64?
        var undo = ""
        var merge = false
        var mode = ""

        func differences(from other: ScreenState) -> [String] {
          var names: [String] = []
          if screen != other.screen { names.append("get_create_screen") }
          if image != other.image { names.append("canvas image") }
          if imageTensor != other.imageTensor { names.append("canvas step") }
          if showsImage != other.showsImage { names.append("canvas shows its image") }
          if mask != other.mask { names.append("mask") }
          if paint != other.paint { names.append("paint") }
          if layersHidden != other.layersHidden { names.append("layers hidden") }
          if scale != other.scale || offset != other.offset { names.append("zoom") }
          if moodboard != other.moodboard { names.append("moodboard") }
          if current != other.current { names.append("History's current step") }
          if undo != other.undo { names.append("next undo step") }
          if merge != other.merge { names.append("Merge into Image") }
          if mode != other.mode { names.append("canvas mode") }
          return names
        }
      }
      @MainActor func screenState() async -> ScreenState {
        var state = ScreenState()
        // get_create_screen but `busy` (the queue's own) and the canvas step's number, which a
        // fork in History may change: the step itself is compared by its image.
        if var screen = try? await call("get_create_screen") {
          screen["busy"] = nil
          if var canvas = screen["canvas"] as? [String: Any] {
            canvas["source_step"] = nil
            screen["canvas"] = canvas
          }
          let data = try? JSONSerialization.data(withJSONObject: screen, options: [.sortedKeys])
          state.screen = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        state.image = model.image.map { ObjectIdentifier($0) }
        state.imageTensor = model.imageItem?.tensorId
        state.showsImage = model.canvasShowsImage
        state.mask = model.canvasMask
        state.paint = model.canvasPaint
        state.layersHidden = model.layersHidden
        state.scale = model.canvas.scale
        state.offset = model.canvas.offset
        state.moodboard = model.moodboard.items.map { "\($0.id.uuidString)@\($0.weight)" }
        state.current = model.history.currentTensorId
        state.undo = undoManager.canUndo ? undoManager.undoActionName : "(nothing to undo)"
        state.merge = model.mergeIntoImage
        state.mode = model.canvasMode.rawValue
        return state
      }
      let screenBefore = await screenState()
      let beneath = model.image
      check(
        screenBefore.imageTensor == item.tensorId && screenBefore.mask != nil && screenBefore.paint != nil && screenBefore.scale != nil
          && screenBefore.moodboard.count == 1 && !screenBefore.screen.isEmpty,
        "before edit_image the canvas holds step \(sourceStep) zoomed, with a mask, paint and a moodboard image")
      // Watched all through the run, and at every progress report: the canvas keeps its own image.
      var reports = 0, strayed = 0
      let watcher = Task { @MainActor in
        while !Task.isCancelled {
          if !(model.canvasShowsImage && model.image === beneath && model.canvasMask == screenBefore.mask) { strayed += 1 }
          try? await Task.sleep(for: .milliseconds(30))
        }
      }
      // Another part of the same step: its top left quadrant, masked in the middle.
      let editRegion = CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
      let editMask = CGRect(x: width / 8, y: height / 8, width: width / 4, height: height / 4)
      let editMaskShape: [String: Any] = ["shape": "rect", "x": editMask.minX, "y": editMask.minY, "width": editMask.width, "height": editMask.height]
      let runSteps = Int(value("--steps") ?? "4") ?? 4
      var editArguments: [String: Any] = [
        "history_step": sourceStep, "prompt": "a bright blue flower",
        "region": ["x": editRegion.minX, "y": editRegion.minY, "width": editRegion.width, "height": editRegion.height],
        "width": Int(frame.width), "height": Int(frame.height), "mask": ["shapes": [editMaskShape], "grow": 4],
        "steps": runSteps, "strength": 0.7, "seed": 7, "settings": ["maskBlur": 4, "maskBlurOutset": 0], "include_image": false,
      ]
      if let file = value("--model") { editArguments["model"] = file }
      var edited: [String: Any]?
      do {
        let answer = try await tools.call("edit_image", arguments: editArguments) { _ in
          reports += 1
          if !(model.canvasShowsImage && model.image === beneath) { strayed += 1 }
        }
        edited = answer["structuredContent"] as? [String: Any]
      } catch {
        check(false, "edit_image ran (\(error.localizedDescription))")
      }
      watcher.cancel()
      await settled()
      var screenAfter = await screenState()
      check(
        reports > 0 && strayed == 0,
        "the canvas showed its own image at every progress report (\(reports)) and all through the edit (\(strayed) times it didn't)")
      check(
        screenAfter.differences(from: screenBefore).isEmpty,
        "the Create screen is as it was after edit_image: screen JSON, canvas image, mask, paint, zoom, moodboard, current step, undo, merge, mode (changed: \(screenAfter.differences(from: screenBefore)))")
      let sourceNow = model.history.item(tensorId: item.tensorId)
      let editedSize = edited?["canvas_size"] as? [String: Any]
      let editedMask = edited?["mask"] as? [String: Any]
      check(
        edited?["merged"] as? Bool == true && editedSize?["width"] as? Int == input.width && editedSize?["height"] as? Int == input.height
          && (edited?["parent_history_step"] as? NSNumber)?.int64Value == sourceNow?.id.logicalTime && same(rect(edited?["region"]), editRegion)
          && same(rect(editedMask?["bounds"]), editMask.insetBy(dx: -4, dy: -4)) && edited?["has_paint"] as? Bool == false
          && edited?["references"] as? Int == 0 && edited?["job_id"] is String,
        "edit_image merges into the whole image and says what it did (parent \(edited?["parent_history_step"] ?? "none"), region \(edited?["region"] ?? "?"), mask \(editedMask?["bounds"] ?? "?"))")
      if let editedStep = (edited?["history_step"] as? NSNumber)?.int64Value,
         let found = model.history.items.first(where: { $0.id.logicalTime == editedStep }), let editedImage = await model.history.image(for: found)
      {
        check(found.inputTensorId == item.tensorId && found.tensorId != item.tensorId, "the edit is a new step whose input is the source step")
        let away = difference(editedImage, image) { !editMask.insetBy(dx: -(4 + margin), dy: -(4 + margin)).contains($0) }
        let within = difference(editedImage, image) { editMask.insetBy(dx: margin, dy: margin).contains($0) }
        check(away?.maxDelta == 0, "away from the mask the edit is the source's pixels exactly (max delta \(away?.maxDelta ?? -1))")
        check((within?.meanDelta ?? 0) > 1, "inside the mask it changed (mean delta \(String(format: "%.1f", within?.meanDelta ?? 0)))")
      } else {
        check(false, "edit_image's step isn't in History")
      }

      // In the background, with the mask filled with paint: get_job collects it, list_jobs shows it.
      var paintedStep: Int64?
      do {
        var arguments = editArguments
        arguments["paint"] = ["fill_mask": true, "color": "#00FF00"]
        arguments["prompt"] = "replace the green area with a bright blue flower"
        arguments["seed"] = 8
        arguments["background"] = true
        let started = try await call("edit_image", arguments)
        var ran = started
        if let job = started["job_id"] as? String {
          for _ in 0..<10 where ran["history_step"] == nil {
            ran = (try? await call("get_job", ["job_id": job, "wait_seconds": 30])) ?? ran
          }
        }
        let jobsText = (try? await tools.call("list_jobs", arguments: [:]) { _ in })
          .flatMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
        let jobs = jobsText.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]]
        let listedJob = jobs?.first { $0["job_id"] as? String == started["job_id"] as? String }
        check(
          started["job_id"] is String && started["history_step"] == nil && ran["has_paint"] as? Bool == true && ran["merged"] as? Bool == true
            && listedJob?["tool"] as? String == "edit_image" && (listedJob?["prompt"] as? String)?.contains("green area") == true,
          "edit_image in the background returns a job_id, get_job collects the painted edit and list_jobs lists it (\(listedJob?["tool"] ?? "not listed"))")
        paintedStep = (ran["history_step"] as? NSNumber)?.int64Value
        if let paintedStep, let found = model.history.items.first(where: { $0.id.logicalTime == paintedStep }),
           let paintedImage = await model.history.image(for: found)
        {
          // Paint is only the run's input: outside the mask the result has none of it.
          let away = difference(paintedImage, image) { !editMask.insetBy(dx: -(4 + margin), dy: -(4 + margin)).contains($0) }
          check(away?.maxDelta == 0, "a painted edit is the source's pixels away from the mask too (max delta \(away?.maxDelta ?? -1))")
        } else {
          check(false, "the painted edit's step isn't in History")
        }
      } catch {
        check(false, "edit_image in the background (\(error.localizedDescription))")
      }
      // From a file: the whole image at the frame's size, masked.
      do {
        var arguments = editArguments
        arguments["history_step"] = nil
        arguments["region"] = nil
        arguments["image"] = path
        arguments["mask"] = ["shapes": [rectShape]]
        let fromFile = try await call("edit_image", arguments)
        let size = fromFile["canvas_size"] as? [String: Any]
        check(
          fromFile["merged"] as? Bool == true && size?["width"] as? Int == input.width && size?["height"] as? Int == input.height
            && same(rect(fromFile["region"]), CGRect(x: 0, y: 0, width: width, height: height)),
          "edit_image on an image file edits the whole image and merges at its size (\(size ?? [:]), region \(fromFile["region"] ?? "?"))")
      } catch {
        check(false, "edit_image on an image file (\(error.localizedDescription))")
      }
      // A region reaching past the image: the merged result grows to hold it, and says so.
      do {
        var arguments = editArguments
        arguments["region"] = ["x": -width / 8, "y": -height / 8, "width": width / 2, "height": height / 2]
        arguments["seed"] = 10
        let past = try await call("edit_image", arguments)
        let size = past["canvas_size"] as? [String: Any], sourceSize = past["source_size"] as? [String: Any]
        let pastRegion = rect(past["region"])
        // Whole pixels: the image and the part of the region outside it.
        let grownWidth = pastRegion.map { Int(max($0.maxX, width).rounded(.up) - min($0.minX, 0).rounded(.down)) }
        let grownHeight = pastRegion.map { Int(max($0.maxY, height).rounded(.up) - min($0.minY, 0).rounded(.down)) }
        let text = (past["notes"] as? [String])?.joined(separator: " ") ?? ""
        check(
          past["extends_past_image"] as? Bool == true && past["merged"] as? Bool == true && size?["width"] as? Int == grownWidth
            && size?["height"] as? Int == grownHeight && (grownWidth ?? 0) > input.width && sourceSize?["width"] as? Int == input.width
            && sourceSize?["height"] as? Int == input.height,
          "edit_image on a region past the image's edges says so, and that the result grew to hold it (extends_past_image \(past["extends_past_image"] ?? "missing"), canvas_size \(size ?? [:]) for region \(past["region"] ?? "?"), source_size \(sourceSize ?? [:])\(text.isEmpty ? "" : ", notes given"))")
      } catch {
        check(false, "edit_image on a region past the image (\(error.localizedDescription))")
      }
      await settled()
      screenAfter = await screenState()
      check(
        screenAfter.differences(from: screenBefore).isEmpty,
        "the Create screen is still as it was after a background edit and one from a file (changed: \(screenAfter.differences(from: screenBefore)))")

      // Its errors: each says what's missing.
      await expectError("edit_image", ["prompt": "x"], "`image` or `history_step`", "no image")
      await expectError("edit_image", ["history_step": 999_999, "prompt": "x", "strength": 0.5], "list_history", "a missing step")
      await expectError("edit_image", ["history_step": sourceStep, "prompt": "x", "strength": 1], "Strength 100% with no mask", "nothing to edit from")
      if !model.usesReferences {
        await expectError(
          "edit_image", ["history_step": sourceStep, "prompt": "x", "strength": 0.5, "reference_images": [path]], "doesn't take reference images",
          "references for a model that takes none")
      }
      await expectError(
        "edit_image",
        [
          "history_step": sourceStep, "prompt": "x", "region": ["x": 0, "y": 0, "width": width / 4, "height": height / 4],
          "mask": ["shapes": [["shape": "rect", "x": width * 0.75, "y": height * 0.75, "width": 20, "height": 20]]],
        ], "mask is empty", "a mask outside the region")
      await expectError(
        "edit_image", ["history_step": sourceStep, "prompt": "x", "strength": 0.5, "paint": ["fill_mask": true, "color": "#00FF00"]],
        "needs a `mask`", "filling no mask")
      await expectError(
        "edit_image",
        ["history_step": sourceStep, "prompt": "x", "strength": 0.5, "region": ["x": 10, "y": 10, "width": 2, "height": 2], "width": 2048, "height": 2048],
        "needs a zoom", "a region too small for the size")
      await expectError(
        "edit_image", ["history_step": sourceStep, "prompt": "x", "strength": 0.5, "region": ["x": width + 50, "y": 0, "width": 10, "height": 10]],
        "overlap", "a region off the image")
      await expectError(
        "edit_image", ["history_step": sourceStep, "prompt": "x", "strength": 0.5, "width": 512, "height": 512, "scale": 2], "not both",
        "a size and a scale")

      // Which models read reference images, as list_models says (the face fix needs one that does).
      let modelsText = (try? await tools.call("list_models", arguments: [:]) { _ in })
        .flatMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
      let modelList = modelsText.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]] ?? []
      let referenceModels = modelList.filter { $0["takes_reference_images"] as? Bool == true }.compactMap { $0["file"] as? String }
      print("note: list_models says these take reference images: \(referenceModels.sorted().joined(separator: ", "))")
      for entry in modelList where (entry["name"] as? String)?.localizedCaseInsensitiveContains("H3 Image") == true {
        print("note: list_models: \(entry["name"] ?? "?") (\(entry["file"] ?? "?")) takes_reference_images \(entry["takes_reference_images"] ?? "?"), video \(entry["video"] ?? "?")")
      }

      /// The face fix's frame for any `--edit-scale`. The region wanted is the face's box with half
      /// its longer side around it, 3:4. It's held to the image (a region larger than the image
      /// makes the merge grow it) and to an output of at most 1536×2048 (a face filling a
      /// portrait at 8× would be a run of tens of megapixels), each side whole 64s at the scale
      /// exactly, about the face's center and moved inside the image. The mask is an ellipse on
      /// the face's box when the region holds it with room to spare, else on the region's middle
      /// half; `grow` moves its edge out, and `margin` is how far beyond that the Mask Blur may
      /// reach (96 frame pixels), both in the image's pixels. Nil when no such region fits.
      func faceFixFrame(_ box: CGRect, in size: CGSize, scale: Double)
        -> (region: CGRect, output: CGSize, ellipse: CGRect, grow: Int, margin: Double)?
      {
        var wanted = FrameSelection.region(around: box, padding: 0.5 * max(box.width, box.height), aspect: 0.75, inside: nil).size
        let fit = min(1, size.width / wanted.width, size.height / wanted.height)
        wanted = CGSize(width: wanted.width * fit, height: wanted.height * fit)
        func side(_ length: Double, _ most: Double) -> Double { min(max((length * scale / 64).rounded(.down), 1) * 64, most) }
        let output = CGSize(width: side(wanted.width, 1536), height: side(wanted.height, 2048))
        let shown = CGSize(width: output.width / scale, height: output.height / scale)
        guard shown.width <= size.width, shown.height <= size.height else { return nil }
        let centered = CGRect(
          x: (box.midX - shown.width / 2).rounded(), y: (box.midY - shown.height / 2).rounded(), width: shown.width, height: shown.height)
        let region = FrameSelection.region(around: centered, padding: 0, aspect: 0, inside: size)
        let ellipse =
          region.insetBy(dx: region.width / 8, dy: region.height / 8).contains(box)
          ? box : region.insetBy(dx: region.width / 4, dy: region.height / 4)
        let grow = max(1, Int(min(box.width / 4, region.width / 16).rounded()))
        return (region, output, ellipse, grow, max(8, 96 / scale))
      }
      func json(_ rect: CGRect) -> [String: Any] { ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height] }
      let editScale = Double(value("--edit-scale") ?? "2") ?? 2
      let editSteps = Int(value("--edit-steps") ?? "6") ?? 6
      let faceFixPrompt =
        "Replace the green area in Picture 1 with the face of the person in Picture 2, same expression, natural skin, matching the lighting of the scene. Keep everything else unchanged."

      // The face fix, with a model that takes references: a region around the face, masked,
      // filled green, with the face itself as Picture 2.
      if let editModel = value("--edit-model"), let facePath = value("--face-input"),
         let faceImage = ImageLoader.image(at: URL(fileURLWithPath: facePath)),
         let face = (try? FaceFinder.faces(in: faceImage))?.first,
         let fix = faceFixFrame(face.box, in: CGSize(width: faceImage.width, height: faceImage.height), scale: editScale)
      {
        let faceRegion = fix.region
        let grow = fix.grow
        do {
          let fixed = try await call(
            "edit_image",
            [
              "image": facePath, "model": editModel, "prompt": faceFixPrompt, "region": json(faceRegion), "scale": editScale,
              "mask": ["shapes": [["shape": "ellipse"].merging(json(fix.ellipse)) { first, _ in first }], "grow": grow],
              "paint": ["fill_mask": true, "color": "#00FF00"], "reference_images": [facePath],
              "steps": editSteps, "guidance_scale": 1, "include_image": false,
            ])
          let size = fixed["canvas_size"] as? [String: Any]
          let fixedStep = (fixed["history_step"] as? NSNumber)?.int64Value
          let fixedItem = model.history.items.first { $0.id.logicalTime == fixedStep }
          let fixedImage: CGImage? = if let fixedItem { await model.history.image(for: fixedItem) } else { nil }
          let grownBox = fix.ellipse.insetBy(dx: -Double(grow) - fix.margin, dy: -Double(grow) - fix.margin)
          let away = fixedImage.flatMap { difference($0, faceImage) { !grownBox.contains($0) } }
          let within = fixedImage.flatMap { difference($0, faceImage) { fix.ellipse.insetBy(dx: fix.ellipse.width / 4, dy: fix.ellipse.height / 4).contains($0) } }
          check(
            fixed["merged"] as? Bool == true && size?["width"] as? Int == faceImage.width && size?["height"] as? Int == faceImage.height
              && fixed["references"] as? Int == 1 && fixed["has_paint"] as? Bool == true && fixed["extends_past_image"] as? Bool == false
              && fixed["width"] as? Int == Int(fix.output.width) && fixed["height"] as? Int == Int(fix.output.height) && same(rect(fixed["region"]), faceRegion),
            "the face fix with \(editModel): the face's region \(fixed["region"] ?? "?") at \(fixed["width"] ?? "?")×\(fixed["height"] ?? "?") (scale \(fixed["scale"] ?? "?")), inside the image, merged at the image's size (\(size ?? [:])), one reference, painted (\(fixed["duration_seconds"] ?? "?") s)")
          check(
            away?.maxDelta == 0 && (within?.meanDelta ?? 0) > 0.5,
            "it changed the face and nothing away from it (max delta away \(away?.maxDelta ?? -1), mean delta on the face \(String(format: "%.1f", within?.meanDelta ?? 0)))")
          if let saveTo = value("--edit-save"), let fixedImage, let data = ImageTensor.png(fixedImage) {
            try? data.write(to: URL(fileURLWithPath: saveTo))
          }
        } catch {
          check(false, "the face fix with \(editModel) (\(error.localizedDescription))")
        }
        await settled()
        screenAfter = await screenState()
        check(
          screenAfter.differences(from: screenBefore).isEmpty,
          "the Create screen is as it was after the face fix (changed: \(screenAfter.differences(from: screenBefore)))")
      } else {
        print("SKIP the face fix with a reference: needs --edit-model (one that takes reference images) and --face-input with a face a region fits around at --edit-scale")
      }

      // match_colors after a painted edit: its recorded input is the painted frame, so the source
      // is named. (These land on the canvas, as match_colors does: the screen checks are done.)
      if let paintedStep {
        let recorded = try? await call("match_colors", ["history_step": paintedStep, "unchanged_only": true])
        print(
          "note: match_colors on a painted edit against its recorded input (the painted frame): unchanged_fraction \(recorded?["unchanged_fraction"] ?? "none (measured the whole image: another shape, or too little unchanged)"), delta_a \(recorded?["delta_a"] ?? "?"), delta_b \(recorded?["delta_b"] ?? "?")")
        let sourceStepNow = model.history.item(tensorId: item.tensorId)?.id.logicalTime ?? sourceStep
        let paintedNow = model.history.items.first { $0.id.logicalTime == paintedStep }
        let named = try? await call(
          "match_colors", ["history_step": paintedNow?.id.logicalTime ?? paintedStep, "original_history_step": sourceStepNow, "unchanged_only": true])
        let matched = (named?["history_step"] as? NSNumber).flatMap { step in model.history.items.first { $0.id.logicalTime == step.int64Value } }
        check(
          (named?["original_history_step"] as? NSNumber)?.int64Value == sourceStepNow && named?["unchanged_fraction"] is NSNumber
            && matched?.sidecar.colorMatch?.originalTensorId == item.tensorId,
          "match_colors with original_history_step measures the painted edit against the source, where it's unchanged (unchanged_fraction \(named?["unchanged_fraction"] ?? "none"), delta_a \(named?["delta_a"] ?? "?"), delta_b \(named?["delta_b"] ?? "?"))")
        await expectError(
          "match_colors", ["history_step": paintedStep, "original_history_step": 999_999], "list_history", "a missing original")
        await expectError(
          "match_colors", ["history_step": paintedStep, "original_history_step": paintedStep], "edited from", "itself as the original")
      }

      // While an agent's edit runs off the canvas, the user looks at a History step and presses
      // Generate: looking away from a run the canvas never followed must not keep their own run
      // off it. It shows there (its previews, when it sends any) and its result becomes current.
      do {
        var arguments = editArguments
        arguments["seed"] = 11
        arguments["background"] = true
        // Long enough to still be running when Generate is pressed.
        arguments["steps"] = max(runSteps, 12)
        let started = try await call("edit_image", arguments)
        for _ in 0..<2400 where !model.foregroundRunIsDetached { try? await Task.sleep(for: .milliseconds(25)) }
        let editInFront = model.foregroundRunIsDetached
        if let shown = model.history.item(tensorId: item.tensorId) { model.show(shown) }
        for _ in 0..<200 where !(model.canvasShowsImage && model.imageItem?.tensorId == item.tensorId) {
          try? await Task.sleep(for: .milliseconds(10))
        }
        let followsAfterLooking = model.canvasFollowsRun
        let finishedBefore = Set(model.queue.recent.map(\.id))
        let editStillRunning = model.foregroundRunIsDetached
        model.generate()
        // The user's run: on the canvas whenever it has a preview to show.
        var sawOwnRun = false, previews = 0, previewsOffCanvas = 0, followedAtStart: Bool?
        for _ in 0..<6000 {
          try? await Task.sleep(for: .milliseconds(20))
          if model.foregroundJobID != nil, !model.foregroundRunIsDetached {
            sawOwnRun = true
            if followedAtStart == nil { followedAtStart = model.canvasFollowsRun }
            if model.livePreview != nil {
              previews += 1
              if model.canvasShowsImage { previewsOffCanvas += 1 }
            }
          }
          if sawOwnRun, !model.isBusy, model.queue.isEmpty { break }
        }
        await idle()
        let own = model.queue.recent.first { !finishedBefore.contains($0.id) && !$0.detached }
        var ownTensor: Int64?
        if case .finished(let tensorId)? = own?.status { ownTensor = tensorId }
        check(
          editInFront && editStillRunning && model.queue.recent.contains { !finishedBefore.contains($0.id) && $0.detached },
          "edit_image was running, in the status bar, when a History step was shown and Generate pressed (job \(started["job_id"] ?? "none"))")
        check(
          followsAfterLooking && followedAtStart == true && model.canvasFollowsRun,
          "showing a History step during edit_image leaves the canvas following runs (after looking \(followsAfterLooking), as the user's run started \(followedAtStart.map { "\($0)" } ?? "never started"))")
        check(previewsOffCanvas == 0, "the user's run showed its previews on the canvas (\(previews) seen, \(previewsOffCanvas) not on it)")
        check(
          ownTensor != nil && model.imageItem?.tensorId == ownTensor && model.history.currentTensorId == ownTensor && model.canvasShowsImage,
          "the user's result landed on the canvas and is the current step (\(own.map { "\($0.status)" } ?? "no run"))")
      } catch {
        check(false, "Generate during an edit_image run (\(error.localizedDescription))")
      }

      // Your run, an agent's edit_image behind it and another run of yours behind that. Looking
      // at a History step during the first keeps the canvas off the second too: the edit taking
      // the front between them mustn't turn following back on (`finish`).
      let stepsBefore = model.settings?.steps
      do {
        // Long enough for the first run to still be in front when the rest is queued.
        model.settings?.steps = max(runSteps, 12)
        let finishedBefore = Set(model.queue.recent.map(\.id))
        model.generate()
        for _ in 0..<2400 where !(model.foregroundJobID != nil && !model.foregroundRunIsDetached) {
          try? await Task.sleep(for: .milliseconds(25))
        }
        let firstID = model.foregroundJobID
        var arguments = editArguments
        arguments["seed"] = 12
        arguments["background"] = true
        let started = try await call("edit_image", arguments)
        model.generate()
        let firstInFront = firstID != nil && model.foregroundJobID == firstID && !model.foregroundRunIsDetached
        if let shown = model.history.item(tensorId: item.tensorId) { model.show(shown) }
        for _ in 0..<200 where !(model.canvasShowsImage && model.imageItem?.tensorId == item.tensorId) {
          try? await Task.sleep(for: .milliseconds(10))
        }
        let followsAfterLooking = model.canvasFollowsRun
        var sawEdit = false, secondFollowedAtStart: Bool?, covered = 0
        for _ in 0..<9000 {
          try? await Task.sleep(for: .milliseconds(20))
          if model.foregroundRunIsDetached { sawEdit = true }
          if let id = model.foregroundJobID, id != firstID, !model.foregroundRunIsDetached {
            if secondFollowedAtStart == nil { secondFollowedAtStart = model.canvasFollowsRun }
            if !(model.canvasShowsImage && model.imageItem?.tensorId == item.tensorId) { covered += 1 }
          }
          if secondFollowedAtStart != nil, !model.isBusy, model.queue.isEmpty { break }
        }
        await idle()
        // Newest first: the second run of yours, then the first.
        let own = model.queue.recent.filter { !finishedBefore.contains($0.id) && !$0.detached }
        var secondTensor: Int64?
        if own.count == 2, case .finished(let tensorId) = own[0].status { secondTensor = tensorId }
        check(
          firstInFront && sawEdit && model.queue.recent.contains { !finishedBefore.contains($0.id) && $0.detached },
          "your run was in front, then edit_image, then your second run (job \(started["job_id"] ?? "none"))")
        check(
          !followsAfterLooking && secondFollowedAtStart == false,
          "showing a History step during your run keeps the canvas off your next run, edit_image between them or not (after looking \(followsAfterLooking), as it started \(secondFollowedAtStart.map { "\($0)" } ?? "never started"))")
        check(
          covered == 0 && secondTensor != nil && model.imageItem?.tensorId == item.tensorId && model.imageItem?.tensorId != secondTensor,
          "your second run didn't cover the shown step, and its result didn't take its place (\(covered) polls covered, \(own.first.map { "\($0.status)" } ?? "no run"))")
        check(model.canvasFollowsRun, "once the queue is empty, the canvas follows runs again")
      } catch {
        check(false, "edit_image between two of your runs (\(error.localizedDescription))")
      }
      if let stepsBefore { model.settings?.steps = stepsBefore }

      // The project renamed while edit_image and generate wait: each saves into it and answers
      // with its new name, the step there (`generate(forAgent:)` hands the project back).
      do {
        model.settings?.steps = max(runSteps, 12)
        let oldName = model.history.project.name
        let newName = model.history.availableName("\(oldName) renamed")
        model.generate()
        for _ in 0..<2400 where !(model.foregroundJobID != nil && !model.foregroundRunIsDetached) {
          try? await Task.sleep(for: .milliseconds(25))
        }
        if let stepsBefore { model.settings?.steps = stepsBefore }
        var arguments = editArguments
        arguments["seed"] = 13
        let waitingBefore = model.queue.waiting.count
        // What the answer says, as Sendable values to leave its task with.
        @MainActor func answered(_ name: String, _ arguments: [String: Any]) -> Task<(project: String?, step: Int64?, text: String), Error> {
          Task { @MainActor in
            let answer = try await tools.call(name, arguments: arguments) { _ in }
            let structured = answer["structuredContent"] as? [String: Any]
            let text = (answer["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            return (structured?["project"] as? String, (structured?["history_step"] as? NSNumber)?.int64Value, text)
          }
        }
        let edit = answered("edit_image", arguments)
        let generate = answered(
          "generate",
          [
            "model": model.selectedModel ?? "", "use_app_settings": true, "prompt": "a paper boat on a pond", "steps": runSteps,
            "include_image": false,
          ])
        for _ in 0..<2400 where model.queue.waiting.count < waitingBefore + 2 { try? await Task.sleep(for: .milliseconds(25)) }
        let bothWaiting = model.queue.waiting.contains { $0.detached } && model.queue.waiting.contains { $0.fromAgent && !$0.detached }
        try await model.history.renameCurrent(to: newName)
        model.projectRenamed(from: oldName, to: model.history.project.name)
        for (name, task) in [("edit_image", edit), ("generate", generate)] {
          do {
            let answer = try await task.value
            let saved = model.history.items.first { $0.id.logicalTime == answer.step }
            let image: CGImage? = if let saved { await model.history.image(for: saved) } else { nil }
            check(
              bothWaiting && answer.project == newName && image != nil && !answer.text.contains("isn't the open one now"),
              "\(name) waiting through a rename answers with the new name and its step there (project \(answer.project ?? "?"), step \(answer.step.map { "\($0)" } ?? "none"))")
          } catch {
            check(false, "\(name) waiting through a rename returns its result (\(error.localizedDescription))")
          }
        }
        await idle()
        let renamed = model.history.project.name
        try await model.history.renameCurrent(to: oldName)
        model.projectRenamed(from: renamed, to: model.history.project.name)
      } catch {
        check(false, "a rename while agent runs wait (\(error.localizedDescription))")
      }
      if let stepsBefore { model.settings?.steps = stepsBefore }

      // The face fix on the canvas, a tool call at a time, as an agent following MCP.md makes them.
      if let editModel = value("--edit-model"), let facePath = value("--face-input"),
         let faceImage = ImageLoader.image(at: URL(fileURLWithPath: facePath))
      {
        // Put back afterwards: the rest of the check runs the first model at its small size.
        let modelBefore = model.selectedModel, settingsBefore = model.settings, promptBefore = model.prompt
        do {
          _ = try await call(
            "set_create_screen",
            ["model": editModel, "steps": editSteps, "guidance_scale": 1, "merge_into_image": true, "canvas_mode": "edit"])
          await idle()
          _ = try await call("set_canvas_image", ["image": facePath])
          let found = try await call("find_faces")
          guard let box = rect((found["faces"] as? [[String: Any]])?.first?["box"]),
                let fix = faceFixFrame(box, in: CGSize(width: faceImage.width, height: faceImage.height), scale: editScale)
          else { throw AgentTools.ToolError("find_faces found no face a region fits around at scale \(editScale)") }
          let framed = try await call(
            "set_canvas_frame", ["box": json(fix.region), "padding": 0, "aspect_ratio": fix.region.width / fix.region.height, "scale": editScale])
          let framedSize = framed["frame"] as? [String: Any]
          check(
            (framedSize?["width"] as? NSNumber)?.intValue == Int(fix.output.width) && (framedSize?["height"] as? NSNumber)?.intValue == Int(fix.output.height)
              && same(rect(framed["region"]), fix.region) && framed["extends_past_image"] as? Bool == false
              && undoManager.undoActionName == "Agent Settings",
            "on the canvas: set_canvas_frame puts the frame around the face at scale \(editScale), inside the image, one “Agent Settings” step (frame \(framedSize ?? [:]), region \(framed["region"] ?? "?"), “\(undoManager.undoActionName)”)")
          _ = try await call("set_canvas_mask", ["shapes": [["shape": "ellipse"].merging(json(fix.ellipse)) { first, _ in first }]])
          let grown = try await call("grow_canvas_mask", ["pixels": fix.grow])
          check(
            grown["grown_by"] as? Int == fix.grow && undoManager.undoActionName == CreateModel.agentMaskActionName,
            "on the canvas: the face is masked and the mask grown, an “Agent Mask” step (“\(undoManager.undoActionName)”)")
          let painted = try await call("set_canvas_paint", ["fill_from_mask": true, "color": "#00FF00"])
          check(
            painted["has_paint"] as? Bool == true && undoManager.undoActionName == CreateModel.agentPaintActionName,
            "on the canvas: the mask is filled green, an “Agent Paint” step (“\(undoManager.undoActionName)”)")
          let board = try await call("set_moodboard", ["clear": true, "add": [["image": facePath]]])
          check(
            images(board).count == 1 && images(board).first?["picture"] as? Int == 2 && board["model_takes_references"] as? Bool == true
              && undoManager.undoActionName == CreateModel.agentMoodboardActionName,
            "on the canvas: the reference is the moodboard's one image, Picture 2, an “Agent Moodboard” step (“\(undoManager.undoActionName)”)")
          _ = try await call("set_create_screen", ["prompt": faceFixPrompt])
          let ran = try await call("generate", ["use_app_settings": true, "use_canvas": true, "include_image": false])
          let size = ran["canvas_size"] as? [String: Any]
          let ranStep = (ran["history_step"] as? NSNumber)?.int64Value
          let ranItem = model.history.items.first { $0.id.logicalTime == ranStep }
          let ranImage: CGImage? = if let ranItem { await model.history.image(for: ranItem) } else { nil }
          let grownBox = fix.ellipse.insetBy(dx: -Double(fix.grow) - fix.margin, dy: -Double(fix.grow) - fix.margin)
          let away = ranImage.flatMap { difference($0, faceImage) { !grownBox.contains($0) } }
          let within = ranImage.flatMap { difference($0, faceImage) { fix.ellipse.insetBy(dx: fix.ellipse.width / 4, dy: fix.ellipse.height / 4).contains($0) } }
          check(
            ran["merged"] as? Bool == true && size?["width"] as? Int == faceImage.width && size?["height"] as? Int == faceImage.height
              && ran["width"] as? Int == Int(fix.output.width) && ran["height"] as? Int == Int(fix.output.height) && ran["model"] as? String == editModel,
            "on the canvas: generate with use_canvas runs the face fix with \(editModel) at \(ran["width"] ?? "?")×\(ran["height"] ?? "?") and merges at the image's size (\(size ?? [:]), \(ran["duration_seconds"] ?? "?") s)")
          check(
            away?.maxDelta == 0 && (within?.meanDelta ?? 0) > 0.5,
            "on the canvas: it changed the face and nothing away from it (max delta away \(away?.maxDelta ?? -1), mean delta on the face \(String(format: "%.1f", within?.meanDelta ?? 0)))")
          // The source's step: the image as it was put on the canvas, which an edit made with
          // paint doesn't record as its input (that's the painted frame).
          var sourceStep: Int64?
          for candidate in model.history.items.sorted(by: { $0.id.logicalTime > $1.id.logicalTime }).prefix(16)
          where candidate.tensorId != ranItem?.tensorId && !candidate.isVideo && candidate.imageTensorId != nil {
            guard let image = await model.history.image(for: candidate), image.width == faceImage.width, image.height == faceImage.height,
                  difference(image, faceImage, where: { _ in true })?.maxDelta == 0
            else { continue }
            sourceStep = candidate.id.logicalTime
            break
          }
          if let ranStep, let sourceStep {
            let matched = try await call(
              "match_colors", ["history_step": ranStep, "original_history_step": sourceStep, "unchanged_only": true])
            let matchedItem = (matched["history_step"] as? NSNumber).flatMap { step in model.history.items.first { $0.id.logicalTime == step.int64Value } }
            let matchedImage: CGImage? = if let matchedItem { await model.history.image(for: matchedItem) } else { nil }
            check(
              (matched["original_history_step"] as? NSNumber)?.int64Value == sourceStep && matched["unchanged_fraction"] is NSNumber
                && matchedImage?.width == faceImage.width && matchedImage?.height == faceImage.height,
              "on the canvas: match_colors with original_history_step \(sourceStep) and unchanged_only matches the fix to the source, at its size (unchanged_fraction \(matched["unchanged_fraction"] ?? "none"), delta_a \(matched["delta_a"] ?? "?"), delta_b \(matched["delta_b"] ?? "?"))")
          } else {
            check(false, "on the canvas: the source image's step is in History, to name as match_colors' original (result step \(ranStep.map { "\($0)" } ?? "none"))")
          }
        } catch {
          check(false, "the face fix on the canvas with \(editModel) (\(error.localizedDescription))")
        }
        await idle()
        model.selectedModel = modelBefore
        await idle()
        if let settingsBefore { model.replaceSettings(with: settingsBefore, actionName: "", undoManager: nil) }
        model.prompt = promptBefore
        check(
          model.selectedModel == modelBefore && model.settings?.width == settingsBefore?.width && model.settings?.steps == settingsBefore?.steps
            && model.prompt == promptBefore,
          "the model, settings and prompt are back as they were before the face fix on the canvas")
      } else {
        print("SKIP the face fix on the canvas: needs --edit-model (one that takes reference images) and --face-input")
      }
      _ = try? await call("set_moodboard", ["clear": true])

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
        // A selection the user made with the Select tool and didn't add: use_canvas adds it first.
        _ = try? await call("set_canvas_mask", ["clear": true])
        model.autoMask.clearPoints(model: model, undoManager: nil)
        model.autoMask.addPoint(subjectPoint, positive: true, model: model, undoManager: nil)
        while model.autoMask.isBusy { try? await Task.sleep(for: .milliseconds(20)) }
        do {
          // In the background, to see the step while the run goes (it leaves the history with the
          // input image once the result lands, as every mask step does).
          let started = try await call("generate", ["use_app_settings": true, "use_canvas": true, "background": true])
          let during = undoManager.undoActionName
          let addedNow = model.autoMask.points.isEmpty && model.isBusy
          var ran = started
          if let job = started["job_id"] as? String {
            for _ in 0..<10 where ran["selection_added"] == nil {
              ran = (try? await call("get_job", ["job_id": job, "wait_seconds": 30])) ?? ran
            }
          }
          check(
            ran["selection_added"] as? Bool == true && during == "Add Selection" && addedNow && paintedAtPoint(),
            "generate use_canvas adds the Select tool's pending selection to the mask first, one “Add Selection” step (selection_added \(ran["selection_added"] ?? "missing"), “\(during)” while it ran, painted \(paintedAtPoint()))")
        } catch {
          check(false, "generate use_canvas with a pending selection (\(error.localizedDescription))")
        }
      } else {
        print("SKIP auto_mask with SAM 2.1 Small: not installed")
        await expectError("auto_mask", ["points": [["x": subjectPoint.x, "y": subjectPoint.y]], "size": "small"], "Select tool", "SAM not downloaded")
      }
      finish()
    }
  }
}
#endif
