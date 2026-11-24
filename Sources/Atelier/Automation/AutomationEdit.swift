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
  /// - with Grain and Halation turned off (their checkboxes), Save to History records them off
  ///   with their settings kept, and the saved pixels are the look rendered with those stages at
  ///   no change (not with them on); Export PNG is that render exactly; opening the step again
  ///   brings back the stages off and their settings; turned back on, Save queues a new job;
  ///   edit_image_look on that step keeps them off unless `options.off` says otherwise (`[]`
  ///   turns them on, the grain saved with it), and refuses a stage name that isn't one;
  /// - Export LUT… of a grade, loaded back as a LUT over no change, renders within a few levels
  ///   of the grade itself;
  /// - Export PNG's metadata records the look at the start, though the look changes while it
  ///   renders;
  /// - Save Profile… to a scratch folder and Open Profile… of that file give back the look's
  ///   settings, and the run's profile library is its own folder, never the user's;
  /// - Add to History pressed twice while the first is saving adds one entry; Open in Edit of a
  ///   step while a session restore runs, and an older open finishing after a newer one, leave
  ///   the newer step on the screen;
  /// - the agent tools (`AgentTools` called directly, as the agent canvas check does):
  ///   list_grain_profiles lists a profile saved to that library; measure_reference on an image
  ///   of known grain (grain at size 2 rendered over flat grey) fits it; edit_image_look with
  ///   match_reference saves a step after the source with the fitted look and a match report;
  ///   editing that step again goes back to the source and keeps its look under the new keys;
  ///   the same background call made twice joins one job, which get_job collects; and bad
  ///   options are refused with an error naming the key.
  ///
  /// With `--snapshot-dir DIR` it also saves the window: the empty screen (`edit-empty.png`),
  /// the look in each comparison mode (`edit-<mode>.png`) and zoomed to 200% (`edit-zoom200.png`),
  /// the inspector with Grain and Halation off (`edit-stage-off.png`),
  /// then, with a long-named reference matched, checks that the inspector still goes to its
  /// narrowest and the window narrow (`edit-long-name*.png`).
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
      let storedKeys = ["editOptions", "editCompareMode", "editSession", AppSettings.embedsSettingsKey].map { ($0, defaults.object(forKey: $0)) }
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
        await longNameSnapshots(edit, look: look, to: snapshotDir, check: check)
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
      await builtInLUTCheck(model, edit: edit, look: look, source: source, check: check)
      await stageOffChecks(model, edit: edit, presets: presets, look: look, image: image, source: source, snapshotDir: snapshotDir, check: check)

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

      // Export's metadata is the look at the start, though the look changes while it renders.
      defaults.set(true, forKey: AppSettings.embedsSettingsKey)
      do {
        let atStart = edit.options
        let export = Task { try await edit.exportPNG() }
        var spins = 0
        while !edit.isExporting, spins < 1_000 {
          await Task.yield()
          spins += 1
        }
        var changed = atStart
        changed.vignette.amount = 0.9
        changed.grain.seed = 1234
        edit.options = changed
        let png = try await export.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let embedded = PNGText.text(keyword: "Atelier", in: png).flatMap { try? decoder.decode(HistoryStore.Sidecar.self, from: Data($0.utf8)) }
        check(
          embedded?.edit?.options == atStart && edit.options == changed.snapped,
          "Export's metadata records the look at the start, not one changed while it rendered")
        edit.options = look
      } catch {
        check(false, "Export PNG with a change during it failed: \(error.localizedDescription)")
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

      await addAndOpenRaceChecks(model, edit: edit, source: source, check: check)
      await agentLookChecks(model, edit: edit, presets: presets, source: source, scratch: scratch, check: check)
      finish()
    }
  }

  /// Add to History pressed twice makes one entry; an open that finishes after a newer one
  /// (a relaunch's restore, a slow read) doesn't replace the newer image.
  /// A built-in LUT chosen from the LUT menu saves with the step, which records the look's name,
  /// digest and table, and opening the step shows that built-in chosen again. Puts `look` back.
  private static func builtInLUTCheck(_ model: CreateModel, edit: EditModel, look: EditOptions, source: HistoryItem, check: (Bool, String) -> Void) async {
    let name = "Teal and Orange"
    let strength = edit.options.lut.strength
    guard edit.chooseBuiltInLUT(name), let table = edit.lut else { return check(false, "the built-in LUT \(name) couldn't be chosen") }
    check(
      edit.options.lut.name == name && edit.options.lut.digest == table.digest && edit.options.lut.strength == strength && edit.builtInLUTName == name,
      "choosing the built-in \(name) sets the look's LUT, keeping the strength")
    guard let jobID = try? edit.save() else { return check(false, "Save to History with a built-in LUT failed") }
    var waited = 0
    while model.queue.recent.first(where: { $0.id == jobID }) == nil, waited < 600 {
      try? await Task.sleep(for: .milliseconds(100))
      waited += 1
    }
    guard case .finished(let tensorId)? = model.queue.recent.first(where: { $0.id == jobID })?.status,
          let saved = model.history.item(tensorId: tensorId)
    else { return check(false, "the Edit job with a built-in LUT didn't save a step") }
    let record = saved.sidecar.edit
    check(
      record?.options.lut.name == name && record?.options.lut.digest == table.digest && record?.lut?.digest == table.digest && record?.lut?.size == 33,
      "the step saved with \(name) records its name, digest and table (\(record?.lut.map { "\($0.name), \($0.size)³" } ?? "no table"))")
    edit.chooseLUT(nil)
    await edit.open(saved)
    check(edit.builtInLUTName == name && edit.item?.tensorId == source.tensorId, "opening that step shows \(name) chosen in the LUT menu")
    edit.reset()
    await edit.open(source)
    edit.options = look
  }

  /// Grain and Halation turned off on `source` with `look`: what's saved, exported, reopened and
  /// what edit_image_look does with it (see the check's list). Puts `look`, all on, back.
  private static func stageOffChecks(
    _ model: CreateModel, edit: EditModel, presets: PresetStore, look: EditOptions, image: CGImage, source: HistoryItem, snapshotDir: URL?,
    check: (Bool, String) -> Void
  ) async {
    defer { edit.options = look }
    func waitFor(_ jobID: UUID) async -> HistoryItem? {
      var waited = 0
      while model.queue.recent.first(where: { $0.id == jobID }) == nil, waited < 600 {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
      }
      guard case .finished(let tensorId)? = model.queue.recent.first(where: { $0.id == jobID })?.status else { return nil }
      return model.history.item(tensorId: tensorId)
    }
    /// The mean and largest difference of two images' colour bytes; nil when they can't be compared.
    func difference(_ a: CGImage?, _ b: CGImage?) -> (mean: Double, largest: Int)? {
      guard let a = a.flatMap(ColorMatch.rgba), let b = b.flatMap(ColorMatch.rgba), a.count == b.count, !a.isEmpty else { return nil }
      var total = 0, largest = 0
      for i in a.indices where i % 4 != 3 {
        let d = abs(Int(a[i]) - Int(b[i]))
        total += d
        largest = max(largest, d)
      }
      return (Double(total) / Double(a.count / 4 * 3), largest)
    }

    edit.options = look
    edit.setStage(.grain, on: false)
    edit.setStage(.halation, on: false)
    let off = edit.options
    check(
      off.off == [.grain, .halation] && off.grain == look.grain && off.halation == look.halation && edit.renderedOptions.grain.isIdentity
        && edit.renderedOptions.halation.isIdentity,
      "turning Grain and Halation off keeps their settings and renders them as no change")
    if let snapshotDir {
      try? await Task.sleep(for: .seconds(2))
      snapshot(to: snapshotDir.appendingPathComponent("edit-stage-off.png"))
    }
    // What it should render: the look with those two stages set to nothing by hand.
    var manual = look
    manual.grain = EditOptions.Grain(lum: 0, size: look.grain.size, chroma: 0, csize: look.grain.csize, real: 0, seed: look.grain.seed)
    manual.halation = EditOptions.Halation()
    let context = edit.context
    guard let expected = try? await EditRenderer().full(source: image, options: manual, context: context),
          let withStages = try? await EditRenderer().full(source: image, options: look, context: context)
    else { return check(false, "the stage-off look couldn't be rendered to compare") }

    guard let jobID = try? edit.save(), let saved = await waitFor(jobID) else { return check(false, "Save to History with stages off didn't save a step") }
    let record = saved.sidecar.edit
    check(
      record?.options.off == [.grain, .halation] && record?.options.grain == look.grain && record?.options.halation == look.halation
        && record?.version == Edit.Record.currentVersion,
      "the step saved with stages off records them off with their settings (version \(record?.version ?? 0))")
    let savedImage = await model.history.project.read { $0.image(tensorId: saved.imageTensorId ?? saved.tensorId) }
    if let same = difference(savedImage, expected), let other = difference(savedImage, withStages) {
      check(
        same.mean < 0.5 && same.largest <= 2 && other.mean > same.mean + 0.5,
        String(format: "the saved pixels are the look without those stages (%.3f levels on average, %d at most; %.2f from the look with them)", same.mean, same.largest, other.mean))
    } else {
      check(false, "the saved step's pixels couldn't be compared (\(savedImage?.width ?? 0)×\(savedImage?.height ?? 0))")
    }
    do {
      let exported = ImageLoader.image(from: try await edit.exportPNG())
      let diff = difference(exported, expected)
      check(diff?.largest == 0, "Export PNG with stages off is that render exactly (\(diff.map { "\($0.largest) at most" } ?? "not comparable"))")
    } catch {
      check(false, "Export PNG with stages off failed: \(error.localizedDescription)")
    }

    // Reopen: the stages off, their settings back.
    edit.reset()
    check(edit.options.off.isEmpty, "Reset turns every stage back on")
    await edit.open(saved)
    check(edit.item?.tensorId == source.tensorId && edit.options == off, "opening the step brings back the stages off and their settings")
    edit.setStage(.grain, on: true)
    edit.setStage(.halation, on: true)
    let problem = edit.saveProblem
    let onID = try? edit.save()
    check(problem == nil && onID != nil && onID != jobID, "turned back on, Save to History queues a new job")
    if let onID { _ = await waitFor(onID) }

    // The agent: the base keeps the stages off; `options.off` replaces them; bad names refused.
    let tools = AgentTools(create: model, presets: presets, grainProfiles: edit.profiles)
    // The saved step on the canvas, which a call without history_step edits: a step number is
    // shared by every edit of the source (a branch each), so it could name another of them.
    func call(_ arguments: [String: Any]) async -> (record: Edit.Record?, error: String?) {
      model.show(saved)
      let before = Set(model.history.items.map(\.tensorId))
      do {
        let answer = try await tools.call("edit_image_look", arguments: arguments) { _ in }
        var result = answer["structuredContent"] as? [String: Any]
        if result == nil, let content = answer["content"] as? [[String: Any]], let text = content.first?["text"] as? String {
          result = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        guard result?["history_step"] != nil else { return (nil, nil) }
        // The step it added: a step number is shared by every edit of the source.
        return (model.history.items.first { !before.contains($0.tensorId) }?.sidecar.edit, nil)
      } catch {
        return (nil, error.localizedDescription)
      }
    }
    let kept = await call(["options": ["vignette": ["amount": 0.2]]])
    check(
      kept.error == nil && kept.record?.options.off == [.grain, .halation] && kept.record?.options.vignette.amount == 0.2,
      "edit_image_look on that step keeps its stages off (\(kept.record.map { "off \($0.options.off.sorted().map(\.rawValue)), vignette \($0.options.vignette.amount)" } ?? "no record"))\(kept.error.map { ": \($0)" } ?? "")")
    let on = await call(["options": ["off": [String]()]])
    check(
      on.error == nil && on.record?.options.off.isEmpty == true && on.record?.options.grain == look.grain,
      "edit_image_look with options.off [] turns them on with the grain saved\(on.error.map { ": \($0)" } ?? "")")
    let bad = await call(["options": ["off": ["sharpen"]]])
    check(bad.error?.contains("off") == true && bad.error?.contains("sharpen") == true, "an unknown stage in options.off is refused (\(bad.error ?? "no error"))")
  }

  /// A reference file with a long name (and the profile Match Reference names after it) must
  /// leave the inspector free to go to its narrowest and the window to go narrow, the names cut
  /// short in their menus and the notes wrapped. Saves `edit-long-name.png`,
  /// `edit-long-name-narrow-inspector.png` and `edit-long-name-narrow-window.png`, then puts the
  /// look, the inspector and the window back.
  private static func longNameSnapshots(_ edit: EditModel, look: EditOptions, to snapshotDir: URL, check: (Bool, String) -> Void) async {
    let name = "575633967_18540294724027661_3024696966612595715_n"
    let file = snapshotDir.appendingPathComponent(name + ".png")
    var grainy = EditOptions.identity
    grainy.grain = EditOptions.Grain(lum: 9, size: 2, chroma: 3, csize: 2, seed: 3)
    guard let grey = flatImage(width: 1440, height: 1080, level: 128),
          let rendered = try? await EditPipeline.render(source: grey, options: grainy), let png = ImageTensor.png(rendered),
          (try? png.write(to: file)) != nil, let reference = ImageLoader.image(at: file)
    else { return check(false, "the long-named reference couldn't be made") }
    // As Choose File… names it.
    await edit.setReference(image: reference, name: file.deletingPathExtension().lastPathComponent)
    await edit.matchReference()
    check(edit.reference?.name == name && edit.profile?.name.contains(name) == true, "a long-named reference is the reference, and Match Reference's profile is named after it")
    try? await Task.sleep(for: .seconds(1))
    snapshot(to: snapshotDir.appendingPathComponent("edit-long-name.png"))
    if let widths = AutomationWindows.setInspectorWidth(0) {
      try? await Task.sleep(for: .seconds(1))
      // The column's minimum is 280; a name setting it would hold it wider.
      check(widths.after <= 290, "with a long-named reference the inspector goes to its narrowest, \(Int(widths.after)) points (was \(Int(widths.before)))")
      snapshot(to: snapshotDir.appendingPathComponent("edit-long-name-narrow-inspector.png"))
      AutomationWindows.setInspectorWidth(nil)
    } else {
      check(false, "the inspector's split wasn't found")
    }
    // The window as narrow as it goes, with the names and then without: they mustn't change it.
    let window = AutomationWindows.setWindowWidth(400)
    try? await Task.sleep(for: .seconds(1))
    snapshot(to: snapshotDir.appendingPathComponent("edit-long-name-narrow-window.png"))
    let withNames = AutomationWindows.setWindowWidth(400)?.after ?? 0
    edit.clearReference()
    edit.applyProfile(nil)
    try? await Task.sleep(for: .seconds(1))
    let without = AutomationWindows.setWindowWidth(400)?.after ?? 0
    check(withNames > 0 && abs(withNames - without) < 1, "a long-named reference leaves the window's narrowest width alone (\(Int(withNames)) points, \(Int(without)) without)")
    if let window { AutomationWindows.setWindowWidth(window.before) }
    edit.clearReference()
    edit.applyProfile(nil)
    edit.options = look
  }

  private static func addAndOpenRaceChecks(_ model: CreateModel, edit: EditModel, source: HistoryItem, check: (Bool, String) -> Void) async {
    let history = model.history
    guard let file = testImage(width: 640, height: 512) else { return check(false, "the Add to History image couldn't be made") }
    edit.open(image: file, name: "Edit Check File")
    edit.options = EditOptions.grainDefaults
    let entriesBefore = history.items.count(where: \.isEntry)
    let firstAdd = Task { try await edit.addToHistory() }
    var spins = 0
    while !edit.isAdding, spins < 1_000 {
      await Task.yield()
      spins += 1
    }
    var secondError: Error?
    do { _ = try await edit.addToHistory() } catch { secondError = error }
    let jobID = try? await firstAdd.value
    let entriesAfter = history.items.count(where: \.isEntry)
    let busy = if case .busy? = secondError as? EditModel.EditError { true } else { false }
    check(
      jobID != nil && busy && entriesAfter == entriesBefore + 1 && !edit.isFromFile,
      "Add to History pressed twice adds one entry (\(entriesAfter - entriesBefore) added; the second says “\(secondError?.localizedDescription ?? "nothing")”)")
    if let jobID {
      var waited = 0
      while model.queue.recent.first(where: { $0.id == jobID }) == nil, waited < 600 {
        try? await Task.sleep(for: .milliseconds(100))
        waited += 1
      }
    }
    guard let entry = edit.item, entry.tensorId != source.tensorId else { return check(false, "the added entry isn't the screen's step") }

    // The session's restore while Open in Edit of another step is reading: the step asked for wins.
    EditSession(project: history.project.name, tensorId: source.tensorId).save()
    edit.open(image: file, name: "Edit Check File")
    let openEntry = Task { await edit.open(entry) }
    spins = 0
    while !edit.isLoading, spins < 1_000 {
      await Task.yield()
      spins += 1
    }
    await edit.restoreSession()
    await openEntry.value
    check(edit.item?.tensorId == entry.tensorId, "a session restore during Open in Edit leaves the step asked for")

    // An open started first (a restore reading its step) finishing after a newer one.
    let openSource = Task { await edit.open(source) }
    spins = 0
    while !edit.isLoading, spins < 1_000 {
      await Task.yield()
      spins += 1
    }
    await edit.open(entry)
    let shown = edit.image
    await openSource.value
    check(
      edit.item?.tensorId == entry.tensorId && edit.image === shown && !edit.isLoading,
      "an older open finishing after a newer one doesn't replace its image")
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

  /// --edit-render-bench: times the Edit screen's renders on a made-up image (`testImage`) or
  /// `--input FILE`, with no model and nothing written, and prints one line per control:
  ///
  ///   Atelier --edit-render-bench [--size WxH | --input FILE] [--pane WxH] [--steps N] [--zoom] [--gestures] [--drag-only] [--quit]
  ///
  /// It renders through an `EditRenderer` as `EditPane` does, the fitted preview for a pane of
  /// `--pane` points at 2× (default 2560 × 1410, a full-screen 5K window's preview;
  /// `EditViewport.fitPixels`), starting from grain.py's defaults with
  /// some halation, and sweeps Halation (amount), Vignette (amount), Grade (exposure) and Grain
  /// (strength) over N values each (default 12), each render finishing before the next, as a
  /// slider dragged slowly enough for every render to land. Each line gives the average and worst
  /// milliseconds and the renderer's cache hits and misses over the sweep. `--zoom` adds a zoom
  /// and pan sequence (50%, 100%, pans at 100%, 200%, back to fit), timing the window render for
  /// each view with the fitted preview it's laid over, the four sweeps again at 100% (each
  /// value's window in view, then the fitted preview under it, timed apart), and pinches and a
  /// pan as gestures make them (`gestureBench`; `--gestures` runs only that). Last, the cancel latency: a render of a look
  /// not yet cached (the fitted preview, then the full size) is cancelled 20 ms in, and the line
  /// gives the milliseconds from the cancel until it returns. `--size` defaults to 6000x4000.
  ///
  /// Then the drag test, as a slider drag on the screen: Halation (amount), Grade (exposure) and
  /// Grain (strength) change every 16 ms for 1.7 s through the lanes the pane runs
  /// (`EditPaneRenders.forScreen()`, asked as `EditPane.schedule` asks them, with the drag's end
  /// as the slider's release), fitted and then zoomed to 100% (the window in view laid over the
  /// fitted preview). Each line gives the previews that went up during the drag, the
  /// milliseconds to the first, and from the release until the final value's preview is up (the
  /// window's, zoomed, then the fitted preview's under it). Last, Halation by arrow key held on
  /// the slider (a change every 30 ms, no release), asked as the pane asks now and as it asked
  /// before (each change final). `--drag-only` skips everything before. `--step-times` instead
  /// times each step on its own (`stepTimes`) and stops.
  static func editRenderBench() {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let size = value("--size").map { $0.lowercased().split(separator: "x").compactMap { Int($0) } }
    let madeWidth = size?.count == 2 ? max(size![0], 16) : 6000
    let madeHeight = size?.count == 2 ? max(size![1], 16) : 4000
    let steps = max(value("--steps").flatMap(Int.init) ?? 12, 1)
    let zoom = args.contains("--zoom")
    let dragOnly = args.contains("--drag-only")
    let input = value("--input")
    let paneSize = value("--pane").map { $0.lowercased().split(separator: "x").compactMap { Double($0) } }
    let pane = paneSize?.count == 2 ? CGSize(width: max(paneSize![0], 16), height: max(paneSize![1], 16)) : CGSize(width: 2560, height: 1410)
    Task { @MainActor in
      func log(_ message: String) {
        print(message)
        fflush(stdout)
      }
      func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
      }
      func summary(_ times: [Double]) -> String {
        guard !times.isEmpty else { return "no renders" }
        return String(format: "avg %7.1f ms, worst %7.1f ms", times.reduce(0, +) / Double(times.count), times.max() ?? 0)
      }
      func cacheLine(_ before: EditRenderer.Counters, _ after: EditRenderer.Counters) -> String {
        "pre-grain \(after.preGrainHits - before.preGrainHits) hit / \(after.preGrainMisses - before.preGrainMisses) miss "
          + "(lens \(after.lensHits - before.lensHits)/\(after.lensMisses - before.lensMisses), "
          + "colour \(after.colourHits - before.colourHits)/\(after.colourMisses - before.colourMisses), "
          + "halation \(after.halationHits - before.halationHits)/\(after.halationMisses - before.halationMisses)), "
          + "fields \(after.fieldHits - before.fieldHits)/\(after.fieldMisses - before.fieldMisses), "
          + "stats \(after.statsHits - before.statsHits)/\(after.statsMisses - before.statsMisses)"
      }
      @MainActor func finish() { if args.contains("--quit") { AppLifecycle.quit() } }
      let made = input.map { ImageLoader.image(at: URL(fileURLWithPath: $0)) } ?? testImage(width: madeWidth, height: madeHeight)
      guard let image = made else {
        log("FAIL edit render bench: " + (input.map { "couldn't read an image at \($0)" } ?? "the \(madeWidth)x\(madeHeight) test image couldn't be made"))
        return finish()
      }
      let width = image.width, height = image.height
      let clock = ContinuousClock()
      let renderer = EditRenderer()
      let fitted = EditViewport(imageWidth: width, imageHeight: height, viewSize: pane, displayScale: 2)
      let fit = fitted.fitPixels
      var base = EditOptions.grainDefaults
      base.halation.amount = 0.4
      base = base.snapped
      log("edit render bench: \(width)x\(height) source\(input.map { " (\(($0 as NSString).lastPathComponent))" } ?? ""), "
        + "pane \(Int(pane.width))x\(Int(pane.height)) pt at 2x, fitted preview \(fit.width)x\(fit.height), \(steps) steps per control")

      // The first render reads the source's pixels and scales it; it's timed on its own.
      do {
        let start = clock.now
        _ = try await renderer.preview(source: image, options: base, context: .empty, fitting: fit.width, height: fit.height)
        log("  first render " + String(format: "%.1f ms", milliseconds(clock.now - start)))
      } catch {
        log("FAIL edit render bench: \(error.localizedDescription)")
        return finish()
      }

      if args.contains("--step-times") {
        await stepTimes(image: image, fit: fit, base: base, log: log)
        return finish()
      }

      if args.contains("--gestures") {
        await gestureBench(image: image, renderer: renderer, pane: pane, look: base, log: log)
        log("edit render bench: done")
        return finish()
      }

      if !dragOnly {
        let controls: [(String, (inout EditOptions, Double) -> Void)] = [
          ("Halation", { $0.halation.amount = 0.05 + 0.9 * $1 }),
          ("Vignette", { $0.vignette.amount = 0.05 + 0.6 * $1 }),
          ("Grade", { $0.grade.exposure = -1 + 2 * $1 }),
          ("Grain", { $0.grain.lum = 2 + 28 * $1 }),
        ]
        for (name, vary) in controls {
          let before = await renderer.counters
          var times: [Double] = []
          for step in 0..<steps {
            var options = base
            vary(&options, steps > 1 ? Double(step) / Double(steps - 1) : 1)
            options = options.snapped
            let start = clock.now
            _ = try? await renderer.preview(source: image, options: options, context: .empty, fitting: fit.width, height: fit.height)
            times.append(milliseconds(clock.now - start))
          }
          let after = await renderer.counters
          log("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) \(summary(times)); \(cacheLine(before, after))")
        }

        if zoom {
          // The same sweeps zoomed to 100%, as the zoomed pane renders each value: the window in
          // view, then the fitted preview under it.
          let zoomed = EditViewport(imageWidth: width, imageHeight: height, viewSize: pane, displayScale: 2, scale: 1)
          if let window = zoomed.zoomed {
            let zoomedFit = zoomed.fitPixels
            log("  at 100%: window \(window.region.width)x\(window.region.height), fitted preview \(zoomedFit.width)x\(zoomedFit.height)")
            _ = try? await renderer.zoomed(source: image, options: base, context: .empty, zoomed: window)
            _ = try? await renderer.preview(source: image, options: base, context: .empty, fitting: zoomedFit.width, height: zoomedFit.height)
            for (name, vary) in controls {
              let before = await renderer.counters
              var windowTimes: [Double] = []
              var fittedTimes: [Double] = []
              for step in 0..<steps {
                var options = base
                vary(&options, steps > 1 ? Double(step) / Double(steps - 1) : 1)
                options = options.snapped
                var start = clock.now
                _ = try? await renderer.zoomed(source: image, options: options, context: .empty, zoomed: window)
                windowTimes.append(milliseconds(clock.now - start))
                start = clock.now
                _ = try? await renderer.preview(source: image, options: options, context: .empty, fitting: zoomedFit.width, height: zoomedFit.height)
                fittedTimes.append(milliseconds(clock.now - start))
              }
              let after = await renderer.counters
              log("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) 100% window \(summary(windowTimes)), then fitted \(summary(fittedTimes)); \(cacheLine(before, after))")
            }
          } else {
            log("  at 100%: the image fits, no window to render")
          }

          // Each view as the pane shows it: the fitted preview (cached after the first) and, zoomed
          // past it, the window in view.
          let views: [(String, Double?, CGSize)] = [
            ("50%", 0.5, .zero), ("100%", 1, .zero), ("100% pan 1", 1, CGSize(width: -300, height: 0)),
            ("100% pan 2", 1, CGSize(width: -600, height: -200)), ("100% pan 3", 1, CGSize(width: -900, height: -400)),
            ("200%", 2, .zero), ("fit", nil, .zero),
          ]
          let before = await renderer.counters
          var times: [Double] = []
          for (label, scale, offset) in views {
            let viewport = EditViewport(imageWidth: width, imageHeight: height, viewSize: pane, displayScale: 2, scale: scale, offset: offset)
            let start = clock.now
            let fitPixels = viewport.fitPixels
            _ = try? await renderer.preview(source: image, options: base, context: .empty, fitting: fitPixels.width, height: fitPixels.height)
            var what = "fitted"
            if let window = viewport.zoomed {
              _ = try? await renderer.zoomed(source: image, options: base, context: .empty, zoomed: window)
              what = "window \(window.region.width)x\(window.region.height)"
            }
            let time = milliseconds(clock.now - start)
            times.append(time)
            log("    zoom \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(format: "%7.1f ms", time)) (\(what))")
          }
          let after = await renderer.counters
          log("  Zoom      \(summary(times)); \(cacheLine(before, after))")
          await gestureBench(image: image, renderer: renderer, pane: pane, look: base, log: log)
        }

        // Cancel latency: a look not cached yet, cancelled 20 ms in.
        for full in [false, true] {
          var latencies: [Double] = []
          var finishedFirst = 0
          for trial in 0..<3 {
            var options = base
            options.halation.amount = 0.5 + 0.03 * Double(trial) + (full ? 0.2 : 0)
            options = options.snapped
            let task = Task {
              if full {
                _ = try await renderer.full(source: image, options: options, context: .empty)
              } else {
                _ = try await renderer.preview(source: image, options: options, context: .empty, fitting: fit.width, height: fit.height)
              }
            }
            try? await Task.sleep(for: .milliseconds(20))
            let cancelled = clock.now
            task.cancel()
            if case .success = await task.result { finishedFirst += 1 }
            latencies.append(milliseconds(clock.now - cancelled))
          }
          let note = finishedFirst > 0 ? " (\(finishedFirst) of 3 finished instead of stopping)" : ""
          log("  Cancel \(full ? "full" : "fitted") \(summary(latencies))\(note)")
        }
      }

      // The drag test.
      /// How the value changes: a drag (16 ms ticks, then the release), or an arrow key held on
      /// the focused slider (30 ms repeats, no onEditingChanged, so no release), each change
      /// asked as not final as the pane asks a slider's, or (`settledKeys`) as final, as the pane
      /// first asked every change made outside a drag.
      enum Gesture { case drag, keys, settledKeys }
      let halation: (inout EditOptions, Double) -> Void = { $0.halation.amount = 0.05 + 0.9 * $1 }
      let dragControls: [(String, Gesture, (inout EditOptions, Double) -> Void)] = [
        ("Halation", .drag, halation),
        ("Grade", .drag, { $0.grade.exposure = -1 + 2 * $1 }),
        ("Grain", .drag, { $0.grain.lum = 2 + 28 * $1 }),
        ("Halation keys", .keys, halation),
        ("Halation keys settled", .settledKeys, halation),
      ]
      for zoomed in [false, true] {
        let viewport = EditViewport(imageWidth: width, imageHeight: height, viewSize: pane, displayScale: 2, scale: zoomed ? 1 : nil)
        let fitPixels = viewport.fitPixels, window = viewport.zoomed
        if zoomed, window == nil {
          log("  Drag zoomed: the image fits at 100%, no window to render")
          continue
        }
        for (name, gesture, vary) in dragControls {
          let tick = Duration.milliseconds(gesture == .drag ? 16 : 30), ticks = gesture == .drag ? 106 : 57
          let renders = EditPaneRenders.forScreen()
          let targets = EditPaneRenders.targets(image, viewport)
          var lastKeys: (fitted: EditPaneRenders.Loop.Key, window: EditPaneRenders.Loop.Key?)?
          /// The pane's `schedule` for a look, and its keys.
          @MainActor func schedule(_ options: EditOptions, settled: Bool) {
            let look = EditRenderLook(options: options, context: 0)
            let fittedKey = EditPaneRenders.Loop.Key(target: targets.fitted!, look: look)
            let windowKey = targets.window.map { EditPaneRenders.Loop.Key(target: $0, look: look) }
            if let last = lastKeys, last.fitted == fittedKey, last.window == windowKey { return }
            lastKeys = (fittedKey, windowKey)
            renders.schedule(targets, image: image, renderer: renderer, context: .empty, look: look, settled: settled)
          }
          func options(at fraction: Double) -> EditOptions {
            var options = base
            vary(&options, fraction)
            return options.snapped
          }
          // Up to date at the drag's start, as the pane is before the slider moves.
          schedule(options(at: 0), settled: true)
          while renders.fitted.isBusy || renders.window.isBusy { try? await Task.sleep(for: .milliseconds(1)) }
          let shownLane = zoomed ? renders.window : renders.fitted
          let before = (fitted: renders.fitted.deliveries, window: renders.window.deliveries)
          var firstUpdate: Double?
          let start = clock.now
          for index in 1...ticks {
            try? await Task.sleep(until: start + tick * index, clock: clock)
            schedule(options(at: Double(index) / Double(ticks)), settled: gesture == .settledKeys)
            if firstUpdate == nil, shownLane.deliveries > (zoomed ? before.window : before.fitted) { firstUpdate = milliseconds(clock.now - start) }
          }
          let during = (fitted: renders.fitted.deliveries - before.fitted, window: renders.window.deliveries - before.window)
          // The release: the slider's onEditingChanged(false). Keys have none: from the last change.
          let released = clock.now
          if gesture == .drag { renders.settle() }
          let final = lastKeys!
          var shownAt: Double?, fittedAt: Double?
          while shownAt == nil || fittedAt == nil, clock.now - released < .seconds(20) {
            if shownAt == nil, shownLane.shown?.key == (zoomed ? final.window : final.fitted) { shownAt = milliseconds(clock.now - released) }
            if fittedAt == nil, renders.fitted.shown?.key == final.fitted { fittedAt = milliseconds(clock.now - released) }
            try? await Task.sleep(for: .milliseconds(1))
          }
          renders.cancel()
          func ms(_ value: Double?) -> String { value.map { String(format: "%6.0f ms", $0) } ?? "  never" }
          let counts = zoomed ? "\(during.window) window, \(during.fitted) fitted" : "\(during.fitted)"
          log("  Drag \(zoomed ? "zoomed" : "fitted") \(name.padding(toLength: 21, withPad: " ", startingAt: 0)) updates during drag \(counts); "
            + "first \(ms(firstUpdate)); release to final \(ms(shownAt))" + (zoomed ? ", fitted \(ms(fittedAt))" : "")
            + (zoomed ? " (window \(window!.region.width)x\(window!.region.height))" : " (\(fitPixels.width)x\(fitPixels.height))"))
        }
      }
      log("edit render bench: done")
      finish()
    }
  }

  /// --edit-render-bench --zoom (or `--gestures`, which runs only this): pinches and a pan as the
  /// pane's gestures move the view, through the lanes the pane runs (`EditPaneRenders.forScreen()`,
  /// asked through `EditPaneRenders.schedule` with the targets `EditPaneRenders.targets` makes),
  /// a tick every 16 ms marked as moving, then the gesture's end. The pinches go from fit (or, a
  /// small image, the first level past it) to 37%, 50%, 71% and 100%, 12 ticks each, centred;
  /// the pan moves 20 pt a tick for 1 s at 100%, then back. Each line gives the renders started
  /// and stopped on their way (`EditRenderCounts`) during the gesture and after its end, and
  /// the milliseconds from the end until the lanes are idle with the final view's window up.
  @MainActor static func gestureBench(image: CGImage, renderer: EditRenderer, pane: CGSize, look options: EditOptions, log: (String) -> Void) async {
    let clock = ContinuousClock()
    func milliseconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    let renders = EditPaneRenders.forScreen()
    let look = EditRenderLook(options: options, context: 0)
    func viewport(_ scale: Double?, _ offset: CGSize = .zero) -> EditViewport {
      EditViewport(imageWidth: image.width, imageHeight: image.height, viewSize: pane, displayScale: 2, scale: scale, offset: offset)
    }
    var last: EditPaneRenders.Targets?
    func schedule(_ viewport: EditViewport, moving: Bool) {
      let targets = EditPaneRenders.targets(image, viewport)
      // As the pane: asked when the targets change, and when the gesture ends.
      if targets == last, moving { return }
      last = targets
      renders.schedule(targets, image: image, renderer: renderer, context: .empty, look: look, settled: true, moving: moving)
    }
    func settled(_ targets: EditPaneRenders.Targets) -> Bool {
      guard !renders.fitted.isBusy, !renders.window.isBusy else { return false }
      guard let window = targets.window else { return true }
      return renders.window.shown?.key.target == window
    }
    /// One gesture: `views` a tick apart, moving, then the end.
    func gesture(_ label: String, _ views: [EditViewport]) async {
      let before = (EditRenderCounts.started, EditRenderCounts.stopped)
      let start = clock.now
      for (index, view) in views.enumerated() {
        try? await Task.sleep(until: start + .milliseconds(16) * (index + 1), clock: clock)
        schedule(view, moving: true)
      }
      let during = (EditRenderCounts.started - before.0, EditRenderCounts.stopped - before.1)
      let ended = clock.now
      schedule(views.last!, moving: false)
      let targets = EditPaneRenders.targets(image, views.last!)
      while !settled(targets), clock.now - ended < .seconds(30) { try? await Task.sleep(for: .milliseconds(1)) }
      let settle = milliseconds(clock.now - ended)
      let after = (EditRenderCounts.started - before.0 - during.0, EditRenderCounts.stopped - before.1 - during.1)
      let window = views.last!.zoomed.map { "\($0.region.width)x\($0.region.height) at \(String(format: "%.3f", $0.scale))" } ?? "none"
      log("    \(label.padding(toLength: 18, withPad: " ", startingAt: 0)) during: \(during.0) started, \(during.1) stopped; "
        + "after the end: \(after.0) started, \(after.1) stopped; settled \(String(format: "%6.0f ms", settle)) (window \(window))")
    }
    // Up to date fitted first, as the pane is before the pinch.
    let fitted = viewport(nil)
    schedule(fitted, moving: false)
    while renders.fitted.isBusy || renders.window.isBusy { try? await Task.sleep(for: .milliseconds(1)) }
    let fit = fitted.fitScale
    log("  Gestures (fit \(String(format: "%.3f", fit))):")
    var from = fit
    for level in [0.37, 0.5, 0.71, 1.0] where level > fit * 1.01 {
      let ticks = 12
      let views = (1...ticks).map { viewport(from * pow(level / from, Double($0) / Double(ticks))) }
      await gesture("pinch \(Int((from * 100).rounded()))→\(Int((level * 100).rounded()))%", views)
      from = level
    }
    let pan = (1...62).map { viewport(1, CGSize(width: -20 * Double($0), height: 0)) }
    await gesture("pan 1 s at 100%", pan)
    await gesture("pan back", pan.reversed().dropFirst().map(\.self) + [viewport(1)])
    await gesture("pinch 100%→fit", (1...12).map { viewport($0 == 12 ? nil : pow(fit, Double($0) / 12)) })
    renders.cancel()
  }

  /// --edit-render-bench --step-times: each step's own time on the source fitted to the pane (as
  /// the fitted preview's planes are), the median of 5 runs, with the bench's look (grain.py's
  /// defaults with some halation) and a grade, vignette and identity LUT added. Then it stops.
  static func stepTimes(image: CGImage, fit: (width: Int, height: Int), base: EditOptions, log: (String) -> Void) async {
    guard let full = EditPipeline.Planes(image) else { return log("FAIL step times: unreadable source") }
    func resized(_ plane: [Float]) -> [Float] {
      Resample.resize(plane, width: full.width, height: full.height, toWidth: fit.width, height: fit.height)
    }
    let planes = EditPipeline.Planes(
      width: fit.width, height: fit.height, r: resized(full.r), g: resized(full.g), b: resized(full.b),
      alpha: [UInt8](repeating: 255, count: fit.width * fit.height))
    let scale = Double(fit.width) / Double(full.width)
    let clock = ContinuousClock()
    func time(_ name: String, _ body: () -> Void) {
      var times: [Double] = []
      for _ in 0..<5 {
        let start = clock.now
        body()
        let d = clock.now - start
        times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
      }
      log("  step \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) " + String(format: "%7.1f ms", times.sorted()[2]))
    }
    log("  step times on \(fit.width)x\(fit.height) planes (median of 5)")
    let sigma = base.halation.radius * scale
    time("Halation") {
      var p = planes
      Halation.apply(base.halation, to: &p, scale: scale)
    }
    time("Blur.gauss 1 plane") { _ = Blur.gauss(planes.r, width: fit.width, height: fit.height, sigma: sigma) }
    let r = Blur.boxSizes(sigma: sigma)[0] / 2
    time("box horizontal") { _ = Blur.boxBlur(planes.r, width: fit.width, height: fit.height, radius: r, horizontal: true) }
    time("box vertical") { _ = Blur.boxBlur(planes.r, width: fit.width, height: fit.height, radius: r, horizontal: false) }
    time("lens blur (σ 2)") { _ = Grain.blur(planes, sigma: 2 * scale) }
    time("luminance") { _ = Grain.luminance(planes) }
    var grade = EditOptions.Grade()
    grade.exposure = 0.3
    grade.contrast = 0.2
    grade.saturation = 0.1
    grade.vibrance = 0.2
    time("Grade") {
      var p = planes
      Grade.apply(grade, to: &p)
    }
    var vignette = base.vignette
    vignette.amount = 0.3
    time("Vignette") {
      var p = planes
      Grade.vignette(vignette, to: &p, fullWidth: fit.width, fullHeight: fit.height)
    }
    let lut = CubeLUT.identity()
    time("LUT") {
      var p = planes
      CubeLUT.apply(lut, to: &p)
    }
    time("sanitize") {
      var p = planes
      EditPipeline.sanitize(&p)
    }
    let grain = base.grain
    let layout = Grain.Layout.whole(width: fit.width, height: fit.height)
    let fields = Grain.grainFields(
      lum: grain.lum, chroma: max(grain.chroma, 1), size: grain.size, csize: grain.csize, seed: grain.seed, refWidth: full.width, layout: layout)
    let luminance = Grain.luminance(planes)
    time("addGrain") {
      var p = planes
      Grain.addGrain(&p, luminance: luminance, lum: grain.lum, chroma: max(grain.chroma, 1), curve: nil, fields: fields)
    }
    time("cropped (whole)") { _ = planes.cropped(x: 0, y: 0, width: fit.width, height: fit.height) }
    time("cropped (inset)") { _ = planes.cropped(x: 40, y: 40, width: fit.width - 80, height: fit.height - 80) }
    time("rgba") { _ = planes.rgba }
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
