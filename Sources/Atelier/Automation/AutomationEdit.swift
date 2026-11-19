#if os(macOS)
import CoreGraphics
import Foundation

extension Automation {
  /// Checks the Edit screen end to end with no model run, and prints PASS/FAIL lines:
  ///
  /// - a made-up test image appended to the project as an Imported step opens in Edit as a step;
  /// - with a fixed look (grain.py's defaults at seed 7, warmer, a vignette and some halation),
  ///   Save to History queues one Edit job, and saving the same edit again while it's pending
  ///   queues nothing (the screen says why, and the second save answers with the first job);
  /// - the saved step comes after its source, is a multiple of 64 in size, and records the look
  ///   and its source;
  /// - opening the saved step goes back to its source with the recorded look;
  /// - Export PNG gives a PNG of the source's size;
  /// - Export LUT… of a grade, loaded back as a LUT over no change, renders within a few levels
  ///   of the grade itself;
  /// - Save Profile… to a scratch folder and Open Profile… of that file give back the look's
  ///   settings, and the run's profile library is its own folder, never the user's;
  /// - the agent tools (`AgentTools` called directly, as the agent canvas check does):
  ///   list_grain_profiles lists a profile saved to that library; measure_reference on an image
  ///   of known grain (grain at size 2 rendered over flat grey) fits it; edit_image_look with
  ///   match_reference saves a step after the source with the fitted look and a match report;
  ///   editing that step again goes back to the source and keeps its look under the new keys;
  ///   the same background call made twice joins one job, which get_job collects; and bad
  ///   options are refused with an error naming the key.
  ///
  /// With `--snapshot-dir DIR` it also saves the window: the empty screen (`edit-empty.png`),
  /// the look in each comparison mode (`edit-<mode>.png`) and zoomed to 200% (`edit-zoom200.png`).
  ///
  ///   Atelier --edit-screen-check --project NAME [--snapshot-dir DIR] [--quit]
  ///
  /// Always pass a scratch `--project`: it adds steps to it. The screen's look, comparison mode,
  /// the sidebar section and the Edit settings in UserDefaults are put back at the end (a
  /// scripted run doesn't save them anyway).
  ///
  ///   Atelier --grain-reference [FILE] --project NAME [--quit]
  ///
  /// Measures FILE as Match Reference does and prints what grain.py `--match FILE` prints (the
  /// fitted grain, size, colour noise, colour size and brightness curve, then the reference's
  /// grain shape and colour blotches beside the fitted grain's), then a line with the reference's
  /// colour blotch strength, noise per brightness band and RGB statistics. Without FILE it
  /// measures a made-up reference of grain at size 2 and prints PASS when the fit finds size 2.
  /// Writes nothing.
  static func editScreenCheck(_ model: CreateModel, navigation: Navigation, presets: PresetStore) {
    let args = CommandLine.arguments
    let snapshotDir = args.firstIndex(of: "--snapshot-dir").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      // What the check changes on the screen, and the settings that keep it, as they are now.
      let defaults = UserDefaults.standard
      let storedKeys = ["editOptions", "editCompareMode", "editSession"].map { ($0, defaults.object(forKey: $0)) }
      let optionsBefore = editModel?.options, compareBefore = editModel?.compareMode, sectionBefore = navigation.section
      let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Atelier edit check \(UUID().uuidString)")
      @MainActor func finish() {
        if let edit = editModel {
          edit.reset()
          if let optionsBefore { edit.options = optionsBefore }
          if let compareBefore { edit.compareMode = compareBefore }
        }
        navigation.section = sectionBefore
        // Exactly as they were: a key that wasn't set stays unset.
        for (key, value) in storedKeys { defaults.set(value, forKey: key) }
        try? FileManager.default.removeItem(at: scratch)
        print(failures == 0 ? "edit screen check: all passed" : "edit screen check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      guard let edit = editModel else {
        check(false, "the app has no Edit screen model")
        return finish()
      }
      navigation.section = .edit
      try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

      var waited = 0
      while model.settings == nil || !model.history.isLoaded || model.isBusy, waited < 600 {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
      }
      guard let settings = model.settings, let image = testImage(width: 1536, height: 1152),
            let tensor = ImageTensor.tensor(from: image)
      else {
        check(false, "the model list or project didn't load, or the test image couldn't be made")
        return finish()
      }
      let history = model.history

      if let snapshotDir {
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        snapshot(to: snapshotDir.appendingPathComponent("edit-empty.png"))
      }

      // The source: the test image as an Imported step.
      var configuration = settings
      configuration.width = image.width
      configuration.height = image.height
      var request = GenerationEngine.Request(
        model: model.selectedModel ?? "", prompt: "edit screen check", negativePrompt: "", seed: 1, configuration: configuration)
      request.canvas = image
      request.canvasIsImported = true
      let source: HistoryItem
      do {
        source = try await history.save(GenerationEngine.Output(frames: [tensor]), request: request, startedAt: Date(), finishedAt: Date())
      } catch {
        check(false, "the test image couldn't be added to the project: \(error.localizedDescription)")
        return finish()
      }
      await edit.open(source)
      check(edit.item?.tensorId == source.tensorId && edit.image != nil && !edit.isFromFile, "the appended step opens in Edit as a step")

      var look = EditOptions.grainDefaults
      look.grain.seed = 7
      look.grade.temperature = 30
      look.vignette.amount = 0.4
      look.halation.amount = 0.3
      look = look.snapped
      edit.options = look
      check(edit.options == look, "the screen takes the fixed look (seed 7)")

      if let snapshotDir {
        for mode in Compare.Mode.allCases {
          edit.compareMode = mode
          try? await Task.sleep(for: .seconds(2))
          snapshot(to: snapshotDir.appendingPathComponent("edit-\(mode.rawValue).png"))
        }
        edit.compareMode = .hold
        edit.canvas.zoom(to: 2)
        try? await Task.sleep(for: .seconds(2))
        snapshot(to: snapshotDir.appendingPathComponent("edit-zoom200.png"))
        edit.canvas.zoomToFit()
        print("snapshots in \(snapshotDir.path)")
      }

      // Save to History, then the same edit again while it's pending.
      let jobID: UUID
      do {
        jobID = try edit.save()
      } catch {
        check(false, "Save to History failed: \(error.localizedDescription)")
        return finish()
      }
      let refusal = edit.saveProblem
      let again = try? edit.save()
      let pendingCount = ((model.queue.running.map { [$0] } ?? []) + model.queue.waiting)
        .filter { $0.request?.edit?.sourceTensorId == source.tensorId }.count
      check(
        refusal != nil && again == jobID && pendingCount == 1,
        "the same edit isn't queued twice (\(pendingCount) pending, the screen says “\(refusal ?? "nothing")”)")
      waited = 0
      while model.queue.recent.first(where: { $0.id == jobID }) == nil, waited < 600 {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
      }
      let job = model.queue.recent.first { $0.id == jobID }
      guard case .finished(let savedTensorId)? = job?.status, let saved = history.item(tensorId: savedTensorId) else {
        check(false, "the Edit job didn't save a step (\(String(describing: job?.status)))")
        return finish()
      }
      let record = saved.sidecar.edit
      check(
        saved.id.logicalTime > source.id.logicalTime && history.parent(of: saved)?.tensorId == source.tensorId,
        "the saved step \(saved.id.logicalTime) comes after its source \(source.id.logicalTime)")
      check(record?.sourceTensorId == source.tensorId && record?.options == look, "the saved step records its source and the look")
      check(
        saved.sidecar.width % 64 == 0 && saved.sidecar.height % 64 == 0 && saved.sidecar.width == image.width,
        "the saved step is \(saved.sidecar.width)×\(saved.sidecar.height)")

      // Reopen: back to the source with the look.
      edit.reset()
      edit.options = EditOptions.identity
      await edit.open(saved)
      check(edit.item?.tensorId == source.tensorId, "opening the saved step goes back to its source")
      check(edit.options == look, "opening the saved step loads its look")
      check(edit.saveProblem == nil, "Save to History is available again once the job is done")

      // Export PNG.
      do {
        let png = try await edit.exportPNG()
        let exported = ImageLoader.image(from: png)
        check(
          png.starts(with: [0x89, 0x50, 0x4E, 0x47]) && exported?.width == image.width && exported?.height == image.height,
          "Export PNG writes a \(exported?.width ?? 0)×\(exported?.height ?? 0) PNG (\(png.count) bytes)")
      } catch {
        check(false, "Export PNG failed: \(error.localizedDescription)")
      }

      // LUT round trip: a grade baked into a .cube, loaded back over no change.
      var grade = EditOptions.identity
      grade.grade.temperature = 25
      grade.grade.contrast = 0.2
      grade.grade.saturation = 0.15
      grade.grade.exposure = 0.2
      edit.removeLUT()
      edit.options = grade
      do {
        let cube = try await edit.exportLUT(name: "Edit Check")
        let url = scratch.appendingPathComponent("Edit Check.cube")
        try cube.write(to: url)
        let graded = try await EditPipeline.render(source: image, options: grade.snapped)
        edit.options = EditOptions.identity
        try edit.loadLUT(from: url)
        check(edit.lut?.size == 33 && edit.options.lut.name != nil, "Export LUT… writes a 33³ .cube that loads back")
        let viaLUT = try await EditPipeline.render(source: image, options: edit.options, context: edit.context)
        if let a = ColorMatch.rgba(graded), let b = ColorMatch.rgba(viaLUT), a.count == b.count {
          var total = 0, largest = 0
          for i in a.indices where i % 4 != 3 {
            let d = abs(Int(a[i]) - Int(b[i]))
            total += d
            largest = max(largest, d)
          }
          let mean = Double(total) / Double(a.count / 4 * 3)
          check(mean < 1 && largest <= 6, String(format: "the LUT renders the grade within %.2f levels on average, %d at most", mean, largest))
        } else {
          check(false, "the LUT renders couldn't be compared")
        }
      } catch {
        check(false, "the LUT round trip failed: \(error.localizedDescription)")
      }
      edit.removeLUT()

      // Profile Save/Open in a scratch folder; the run's library is its own.
      check(edit.profiles.directory != GrainProfileStore.defaultDirectory, "the scripted run's profile library isn't the user's")
      var profileLook = look
      profileLook.grain.size = 1.5
      profileLook.lens.blur = 1.2
      edit.options = profileLook
      let toSave = edit.profileToSave
      let profileURL = scratch.appendingPathComponent("Edit Check.grain.json")
      do {
        try toSave.write(to: profileURL)
        edit.options = look
        try edit.openProfile(at: profileURL)
        check(
          edit.profile?.settings == toSave.settings && edit.options.grain.size == 1.5 && edit.options.lens.blur == 1.2,
          "Save Profile… and Open Profile… give back the look's settings")
      } catch {
        check(false, "the profile round trip failed: \(error.localizedDescription)")
      }

      await agentLookChecks(model, edit: edit, presets: presets, source: source, scratch: scratch, check: check)
      finish()
    }
  }

  /// edit_image_look, list_grain_profiles and measure_reference, called as an agent's calls are.
  private static func agentLookChecks(
    _ model: CreateModel, edit: EditModel, presets: PresetStore, source: HistoryItem, scratch: URL,
    check: (Bool, String) -> Void
  ) async {
    let tools = AgentTools(create: model, presets: presets, grainProfiles: edit.profiles)
    func json(_ answer: [String: Any]?) -> [String: Any] {
      if let structured = answer?["structuredContent"] as? [String: Any] { return structured }
      guard let content = answer?["content"] as? [[String: Any]], let text = content.first?["text"] as? String,
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
      else { return [:] }
      return object as? [String: Any] ?? ["list": object]
    }
    func call(_ name: String, _ arguments: [String: Any]) async -> (result: [String: Any], error: String?) {
      do {
        return (json(try await tools.call(name, arguments: arguments) { _ in }), nil)
      } catch {
        return ([:], error.localizedDescription)
      }
    }
    func step(_ result: [String: Any]) -> HistoryItem? {
      (result["history_step"] as? NSNumber).flatMap { number in model.history.items.first { $0.id.logicalTime == number.intValue } }
    }

    // A profile in the run's library, listed.
    var profile = GrainProfile(name: "Edit Check Library")
    profile.settings.size = 2
    _ = try? edit.profiles.save(profile)
    let listed = await call("list_grain_profiles", [:])
    let names = (listed.result["profiles"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    check(names.contains("Edit Check Library"), "list_grain_profiles lists the library's profiles (\(names.count))")
    try? edit.profiles.delete(profile)

    // A reference of known grain: grain.py's grain at size 2 over flat mid grey.
    guard let grey = flatImage(width: 1440, height: 1080, level: 128) else { return check(false, "the reference couldn't be made") }
    var grainy = EditOptions.identity
    grainy.grain = EditOptions.Grain(lum: 9, size: 2, chroma: 3, csize: 2, seed: 3)
    let referenceURL = scratch.appendingPathComponent("grain reference.png")
    guard let reference = try? await EditPipeline.render(source: grey, options: grainy), let png = ImageTensor.png(reference),
          (try? png.write(to: referenceURL)) != nil
    else { return check(false, "the reference couldn't be written") }
    let measured = await call("measure_reference", ["path": referenceURL.path])
    let fitted = measured.result["settings"] as? [String: Any]
    let size = (fitted?["size"] as? NSNumber)?.doubleValue ?? 0
    let lum = (fitted?["lum"] as? NSNumber)?.doubleValue ?? 0
    check(
      measured.error == nil && (1.5...2.8).contains(size) && lum > 3,
      "measure_reference fits grain of size 2 as size \(size), strength \(lum)\(measured.error.map { ": \($0)" } ?? "")")
    if let report = measured.result["report"] as? String { print(report) }

    // edit_image_look with Match Reference.
    let first = await call(
      "edit_image_look",
      [
        "history_step": source.id.logicalTime, "reference_path": referenceURL.path, "match_reference": true,
        "options": ["grade": ["temperature": 20], "grain": ["seed": 7]],
      ])
    let firstItem = step(first.result)
    let firstRecord = firstItem?.sidecar.edit
    check(
      first.error == nil && firstRecord?.sourceTensorId == source.tensorId && firstRecord?.options.grade.temperature == 20
        && firstRecord?.options.grain.seed == 7 && firstRecord?.options.match.colour == 0.6 && first.result["match_report"] != nil,
      "edit_image_look saves step \(firstItem?.id.logicalTime ?? 0) after the source with the matched look\(first.error.map { ": \($0)" } ?? "")")

    // That step again: back to the source, its look kept under the new keys.
    if let firstItem {
      let second = await call("edit_image_look", ["history_step": firstItem.id.logicalTime, "options": ["vignette": ["amount": 0.25]]])
      let record = step(second.result)?.sidecar.edit
      check(
        second.error == nil && (second.result["source_step"] as? NSNumber)?.int64Value == source.id.logicalTime
          && record?.sourceTensorId == source.tensorId && record?.options.grade.temperature == 20 && record?.options.vignette.amount == 0.25
          && record?.realNoise != nil,
        "editing an edited step starts from its look on its source\(second.error.map { ": \($0)" } ?? "")")
    }

    // The same background call twice: one job.
    let sourceStep = source.id.logicalTime
    func background() -> Task<String?, Never> {
      Task { @MainActor in
        let answer = await call("edit_image_look", ["history_step": sourceStep, "options": ["grade": ["exposure": 0.3]], "background": true])
        return answer.result["job_id"] as? String
      }
    }
    let one = background(), two = background()
    let ids = [await one.value, await two.value]
    check(ids[0] != nil && ids[0] == ids[1], "the same edit_image_look call made twice joins one job (\(ids.map { $0 ?? "none" }))")
    if let id = ids[0] {
      let done = await call("get_job", ["job_id": id, "wait_seconds": 30])
      check(done.result["history_step"] != nil, "get_job returns the background job's step\(done.error.map { ": \($0)" } ?? "")")
    }

    // Bad input.
    let unknown = await call("edit_image_look", ["history_step": source.id.logicalTime, "options": ["grain": ["bogus": 1]]])
    check(unknown.error?.contains("bogus") == true, "an unknown option is refused (\(unknown.error ?? "no error"))")
    let range = await call("edit_image_look", ["history_step": source.id.logicalTime, "options": ["match": ["tint": 2]]])
    check(range.error?.contains("tint") == true, "an option out of range is refused (\(range.error ?? "no error"))")
    let real = await call("edit_image_look", ["history_step": source.id.logicalTime, "options": ["grain": ["real": 1]]])
    check(real.error?.contains("real") == true, "real noise without a profile is refused (\(real.error ?? "no error"))")
  }

  /// --grain-reference [FILE]: what grain.py `--match FILE` prints for it. Without FILE, for a
  /// made-up reference of known grain (grain.py's grain at size 2, strength 9, over flat grey),
  /// with a PASS/FAIL line for whether the fit finds that size.
  static func grainReference(_ path: String?) {
    Task { @MainActor in
      var image = path.flatMap { ImageLoader.image(at: URL(fileURLWithPath: $0)) }
      if path == nil, let grey = flatImage(width: 1440, height: 1080, level: 128) {
        var grainy = EditOptions.identity
        grainy.grain = EditOptions.Grain(lum: 9, size: 2, chroma: 3, csize: 2, seed: 3)
        image = try? await EditPipeline.render(source: grey, options: grainy)
      }
      let path = path ?? "the made-up reference"
      if let image {
        if let measured = await AgentTools.grainMatch(of: image) {
          let match = measured.match
          print(AgentTools.grainPyReport(match))
          func list(_ values: [Double]) -> String { "[" + values.map { String(format: "%.2f", $0) }.joined(separator: ", ") + "]" }
          print(
            "  reference: colour blotch strength \(String(format: "%.2f", match.reference.cSD)), band noise \(list(match.reference.curve)), "
              + "rgb mean \(list(measured.stats.m)), rgb std \(list(measured.stats.s)), width \(image.width)")
          if path == "the made-up reference" {
            print("\(match.size == 2 ? "PASS" : "FAIL") grain of size 2 fits as size \(match.size)")
          }
        } else {
          print("FAIL \(path) has no flat, mid-bright area to measure its grain on")
        }
      } else {
        print("FAIL couldn't read an image at \(path)")
      }
      fflush(stdout)
      if CommandLine.arguments.contains("--quit") { AppLifecycle.quit() }
    }
  }

  /// A flat grey image.
  static func flatImage(width: Int, height: Int, level: UInt8) -> CGImage? {
    var pixels = [UInt8](repeating: level, count: width * height * 4)
    for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
    return ColorMatch.cgImage(rgba: pixels, width: width, height: height)
  }

  /// A test image with gradients and edges, so grain, colour and zoom all show.
  static func testImage(width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let colors = [CGColor(red: 0.15, green: 0.3, blue: 0.6, alpha: 1), CGColor(red: 0.95, green: 0.75, blue: 0.5, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
      context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 0.95, alpha: 1))
    context.fillEllipse(in: CGRect(x: width / 2, y: height / 2, width: width / 5, height: width / 5))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: width / 8, y: height / 6, width: width / 4, height: height / 3))
    return context.makeImage()
  }
}
#endif
