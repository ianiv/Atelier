#if os(macOS)
@preconcurrency import _MediaGenerationKit
import SwiftUI

extension Automation {
  /// Checks the Draw Things project format end to end on a scratch project, as PASS/FAIL lines:
  /// append, list, settings round trip, image round trip, thumbnails, delete and renumbering, and
  /// branches (see `branchChecks`).
  ///
  ///   Atelier --project-check [--keep DIR] [--quit]
  ///
  /// With `--keep DIR` the scratch project is left at DIR/Check.sqlite3 for other readers
  /// (DTDB Browser, sqlite3).
  static func projectCheck(_ model: CreateModel) {
    let args = CommandLine.arguments
    let keep = args.firstIndex(of: "--keep").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      while model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let base = model.settings, let modelFile = model.selectedModel else { return }

      let directory = keep.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "atelier-project-check-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("Check.sqlite3")
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
      let project = Project(url: url)

      // Three steps with different settings.
      var variants: [PipelineConfiguration] = [base]
      var second = base
      second.steps = base.steps + 3
      second.shift = base.shift + 0.5
      second.hiresFix = !base.hiresFix
      second.width = 768
      second.height = 512
      variants.append(second)
      var third = base
      third.guidanceScale = base.guidanceScale + 1
      third.loras = [LoRA(file: "example_lora_f16.ckpt", weight: 0.75, mode: .all)]
      third.tiledDecoding = true
      variants.append(third)

      guard let original = gradient(width: 320, height: 192),
        let tensor = ImageTensor.tensor(from: original)
      else {
        check(false, "couldn't build a test image")
        return
      }
      var appended: [HistoryItem] = []
      for (index, settings) in variants.enumerated() {
        var settings = settings
        settings.seed = UInt32(1000 + index)
        do {
          let item = try await project.append(
            tensor: tensor, model: modelFile, prompt: "check prompt \(index) “quoted” ✓",
            negativePrompt: index == 1 ? "blurry" : "", seed: settings.seed,
            settings: JSONValue.fields(of: settings), createdAt: Date(), duration: 1.5 + Double(index))
          appended.append(item)
        } catch {
          check(false, "append \(index): \(error.localizedDescription)")
        }
      }
      check(appended.map(\.id.logicalTime) == [0, 1, 2], "appended steps 0, 1, 2 on lineage 0")

      let items = project.items()
      check(items.map(\.id.logicalTime) == [2, 1, 0], "items lists the steps newest first")
      for (index, settings) in variants.enumerated() {
        guard let item = items.first(where: { $0.id.logicalTime == Int64(index) }) else { continue }
        var expected = JSONValue.fields(of: settings)
        expected["seed"] = .number(Double(1000 + index))
        let read = item.sidecar.configuration
        let differing = Set(expected.keys).union(read.keys).filter { expected[$0] != read[$0] }
          .sorted()
        check(differing.isEmpty, "step \(index): every configuration field round-trips \(differing.map { "\($0): \(expected[$0].map { "\($0)" } ?? "missing") → \(read[$0].map { "\($0)" } ?? "missing")" })")
        var restored = base
        SettingsRegistry.apply(dump: read, to: &restored)
        let registry = SettingsRegistry.all.filter { $0.get(restored) != $0.get(settings) }.map(\.id)
        check(registry.isEmpty, "step \(index): Use settings restores all registry fields \(registry)")
        check(
          item.sidecar.prompt == "check prompt \(index) “quoted” ✓"
            && item.sidecar.negativePrompt == (index == 1 ? "blurry" : "")
            && item.sidecar.seed == UInt32(1000 + index) && item.sidecar.model == modelFile,
          "step \(index): prompt, negative prompt, seed and model")
      }

      if let item = items.first, let image = project.image(for: item),
        let difference = pixelDifference(original, image)
      {
        check(difference.maxDelta == 0, "image round trip is exact (max channel delta \(difference.maxDelta))")
      } else {
        check(false, "image round trip: couldn't read the image back")
      }
      if let item = items.first {
        let full = project.thumbnail(previewId: item.previewId, half: false)
        let half = project.thumbnail(previewId: item.previewId, half: true)
        check(
          full?.width == 320 && half.map { $0.width < 320 } == true,
          "thumbnails: full \(full?.width ?? 0)×\(full?.height ?? 0), half \(half?.width ?? 0)×\(half?.height ?? 0)")
      }

      // Delete the middle step: the last one moves down to step 1.
      let middle = items.first { $0.id.logicalTime == 1 }
      if let middle {
        do {
          try await project.delete(middle.id)
          let after = project.items()
          check(after.map(\.id.logicalTime) == [1, 0], "deleting step 1 renumbers step 2 to 1")
          check(
            after.first?.sidecar.seed == 1002 && after.first.flatMap { project.image(for: $0) } != nil,
            "the moved step keeps its settings and image")
          check(
            project.thumbnail(previewId: middle.previewId, half: false) == nil
              && project.tensor(id: middle.tensorId) == nil,
            "the deleted step's thumbnail and tensor are gone")
        } catch {
          check(false, "delete: \(error.localizedDescription)")
        }
      }

      // Edit steps: a non-generated input step, then a step recording it as its input.
      if let base = project.items().first {
        do {
          let input = try await project.append(
            tensor: tensor, model: modelFile, prompt: "input", negativePrompt: "", seed: 0,
            settings: JSONValue.fields(of: variants[0]), createdAt: Date(), duration: 0,
            reason: .other, generated: false)
          let edit = try await project.append(
            tensor: tensor, model: modelFile, prompt: "edit", negativePrompt: "", seed: 7,
            settings: JSONValue.fields(of: variants[0]), createdAt: Date(), duration: 2,
            inputTensorId: input.tensorId)
          let iterate = try await project.append(
            tensor: tensor, model: modelFile, prompt: "iterate", negativePrompt: "", seed: 8,
            settings: JSONValue.fields(of: variants[0]), createdAt: Date(), duration: 2,
            inputTensorId: edit.tensorId)
          let listed = project.items()
          check(
            listed.map(\.id.logicalTime) == [4, 3, 1, 0],
            "History lists only generated steps (\(listed.map(\.id.logicalTime)))")
          check(
            listed.first?.inputTensorId == edit.tensorId && listed.last?.inputTensorId == nil,
            "the input tensor id round-trips through profile_data")
          check(
            project.input(of: edit.id, tensorId: input.tensorId)?.id == input.id
              && project.input(of: iterate.id, tensorId: edit.tensorId)?.id == edit.id,
            "an Edit step finds its input step")
          try await project.delete(input.id)
          let renumbered = project.items()
          let movedEdit = renumbered.first { $0.tensorId == edit.tensorId }
          let movedIterate = renumbered.first { $0.tensorId == iterate.tensorId }
          check(
            movedEdit.map { project.input(of: $0.id, tensorId: input.tensorId) == nil } == true,
            "deleting the input step: its Edit step falls back (parent is now step \(base.id.logicalTime))")
          check(
            movedIterate.flatMap { project.input(of: $0.id, tensorId: edit.tensorId) }?.id
              == movedEdit?.id,
            "renumbering keeps the link of a later Edit step")
        } catch {
          check(false, "edit steps: \(error.localizedDescription)")
        }
      }

      await project.close()
      let reopened = Project(url: url)
      check(reopened.items().count == 4, "a reopened project lists the same steps")
      await reopened.close()

      await branchChecks(
        url: directory.appendingPathComponent("Branches.sqlite3"), model: modelFile,
        settings: JSONValue.fields(of: base), check: check)
      if keep == nil {
        try? FileManager.default.removeItem(at: directory)
      } else {
        print("kept \(url.path) and Branches.sqlite3")
      }
      print(failures == 0 ? "project check: all passed" : "project check: \(failures) failed")
      fflush(stdout)
      if args.contains("--quit") { AppLifecycle.quit() }
    }
  }

  /// Use Settings on Edit steps, end to end with real runs (use a scratch `--project`):
  /// an Edit run from `--input`, then one iterating on its result; Use Settings on the second
  /// must put the first result back on the canvas in Edit mode and rerunning must reproduce the
  /// second, as a branch from the first; after deleting the first result, Use Settings falls back
  /// to the result with a note. Then text-to-image runs after showing an earlier image branch
  /// from it.
  ///
  ///   Atelier --edit-input-check --project NAME --input FILE [--model M] [--steps N]
  ///           [--width W --height H] [--strength S] [--seed N] [--quit]
  static func editInputCheck(_ model: CreateModel) {
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
        print(failures == 0 ? "edit input check: all passed" : "edit input check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func idle() async {
        try? await Task.sleep(for: .milliseconds(200))
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      }
      /// The canvas comparison once Use Settings has restored the image (up to 5 s).
      @MainActor func settled(
        _ difference: () -> (count: Int, total: Int, maxDelta: Int, meanDelta: Double)?
      ) async -> (count: Int, total: Int, maxDelta: Int, meanDelta: Double)? {
        for _ in 0..<50 {
          if difference()?.maxDelta == 0 { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return difference()
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
      guard let path = value("--input"), let input = ImageLoader.image(at: URL(fileURLWithPath: path))
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
      if let width = value("--width").flatMap(Int.init) { settings.width = width }
      if let height = value("--height").flatMap(Int.init) { settings.height = height }
      if let strength = value("--strength").flatMap(Float.init) { settings.strength = strength }
      model.settings = settings
      model.seed = value("--seed").flatMap(UInt32.init) ?? 42
      model.seedLocked = true
      model.prompt = "make it a watercolor painting"
      model.setCanvasImage(input)

      guard let first = await run() else {
        check(false, "first Edit run saved nothing")
        return finish()
      }
      check(first.inputTensorId != nil, "first Edit run records its input")
      model.prompt = "add a full moon in the sky"
      guard let second = await run() else {
        check(false, "second Edit run saved nothing")
        return finish()
      }
      check(
        second.inputTensorId == first.tensorId && second.id.logicalTime == first.id.logicalTime + 1,
        "iterating in place records the first result as input, with no extra step")
      guard let firstImage = await model.history.image(for: first),
        let secondImage = await model.history.image(for: second)
      else {
        check(false, "couldn't read the results back")
        return finish()
      }

      model.canvasMode = .generate
      model.prompt = ""
      model.use(second)
      await idle()
      let restored = await settled { model.image.flatMap { pixelDifference($0, firstImage) } }
      check(
        restored?.maxDelta == 0 && model.canvasMode == .edit && model.canvas.scale == nil,
        "Use Settings on the second step puts the first result on the canvas, fitted, in Edit mode (image \(restored.map { "max delta \($0.maxDelta)" } ?? "size differs"), zoom \(model.canvas.scale.map { "\($0)" } ?? "fit"), mode \(model.canvasMode.rawValue))")
      check(model.prompt == second.sidecar.prompt, "and loads the second step's prompt")
      if let rerun = await run(), let rerunImage = await model.history.image(for: rerun),
        let difference = pixelDifference(rerunImage, secondImage)
      {
        check(
          rerun.inputTensorId == first.tensorId
            && model.history.parent(of: rerun)?.tensorId == first.tensorId
            && Set(model.history.children(of: first).map(\.tensorId))
              == [second.tensorId, rerun.tensorId],
          "the rerun branches from the first result, beside the second, with no extra step")
        check(
          difference.meanDelta < 2,
          "rerunning reproduces the second step (mean channel delta \(difference.meanDelta.formatted(.number.precision(.fractionLength(2)))), max \(difference.maxDelta))")
      } else {
        check(false, "rerun saved nothing")
      }

      do {
        try await model.history.delete([first])
      } catch {
        check(false, "delete: \(error.localizedDescription)")
      }
      guard let moved = model.history.items.first(where: { $0.tensorId == second.tensorId }) else {
        check(false, "the second step is gone after deleting the first")
        return finish()
      }
      model.canvasMode = .generate
      model.use(moved)
      await idle()
      let fallback = await settled { model.image.flatMap { pixelDifference($0, secondImage) } }
      check(
        fallback?.maxDelta == 0 && model.statusNote != nil && model.canvasMode == .generate,
        "with its input deleted, Use Settings shows the result and a note (\(model.statusNote ?? "no note"))")

      // Text-to-image runs follow the current step too: showing an earlier image and generating
      // branches from it, and generating again continues that branch.
      model.show(moved)
      check(
        model.history.currentItem?.tensorId == second.tensorId, "showing an image makes it the current step")
      model.prompt = "a lighthouse at dusk"
      guard let branch = await run() else {
        check(false, "the text-to-image run saved nothing")
        return finish()
      }
      check(
        model.history.parent(of: branch)?.tensorId == second.tensorId && branch.inputTensorId == nil,
        "a text-to-image run after showing an earlier image branches from it")
      check(
        model.history.currentItem?.tensorId == branch.tensorId
          && model.history.currentLineage.map(\.tensorId).starts(with: [branch.tensorId, second.tensorId]),
        "the new image is current, and its lineage runs through the one shown")
      if let next = await run() {
        check(
          model.history.parent(of: next)?.tensorId == branch.tensorId
            && next.id == StepID(lineage: branch.id.lineage, logicalTime: branch.id.logicalTime + 1),
          "generating again appends to the same branch")
      } else {
        check(false, "the second text-to-image run saved nothing")
      }
      if let shown = model.history.item(tensorId: branch.tensorId) {
        model.show(shown)
        if let sibling = await run() {
          check(
            model.history.parent(of: sibling)?.tensorId == branch.tensorId
              && model.history.children(of: shown).count == 2,
            "generating after an image that already has a follower forks it in two")
        }
      }
      let graph = HistoryGraph(items: model.history.items, parent: model.history.parent(of:))
      check(graph.lanes >= 2, "the graph gives the branches lanes of their own (\(graph.lanes))")
      if let directory = value("--snapshot-dir") {
        // The graph's lanes, drawn off screen (thumbnails load asynchronously and stay blank).
        let current = model.history.currentItem?.tensorId
        let rows = VStack(spacing: 0) {
          ForEach(Array(zip(model.history.items, graph.rows)), id: \.0.tensorId) { item, row in
            HistoryGraphRow(
              item: item, row: row, lanes: graph.lanes, isCurrent: item.tensorId == current,
              isSelected: false)
          }
        }
        .frame(width: 600)
        .background(.white)
        .environment(model)
        .environment(model.history)
        .environment(model.timelines)
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 2
        if let image = renderer.cgImage, let png = ImageTensor.png(image) {
          let url = URL(fileURLWithPath: directory).appendingPathComponent("graph.png")
          try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          try? png.write(to: url)
        }
      }
      finish()
    }
  }

  /// Forks and deletes on a scratch project, checking after each one (and after a reopen) every
  /// step's parent, the main line, Draw Things' sacred line (the greatest lineage at each step
  /// number), and that every step keeps its image and thumbnails.
  ///
  ///   A0 → A1 → A2 → A3 (parents not recorded, as before branching), then B after A1 (fork
  ///   from the middle), C after A2 (A2's lineage isn't
  ///   the greatest at its number any more, so it's renumbered), D after B (a fork of a fork,
  ///   renumbered again) and E after D (a plain append); then delete A3 (a branch's tip), D (on a
  ///   branch, E moves down) and A1 (a fork point, its children follow A0).
  private static func branchChecks(
    url: URL, model: String, settings: [String: JSONValue], check: (Bool, String) -> Void
  ) async {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    var project = Project(url: url)
    var names: [Int64: String] = [:]
    var images: [String: CGImage] = [:]
    var tensors: [String: Int64] = [:]
    func add(_ name: String, after parent: String?) async -> StepID? {
      guard let image = gradient(width: 192, height: 128, seed: names.count + 1),
        let tensor = ImageTensor.tensor(from: image)
      else { return nil }
      do {
        let item = try await project.append(
          tensor: tensor, model: model, prompt: name, negativePrompt: "", seed: 0,
          settings: settings, createdAt: Date(), duration: 1,
          after: parent.flatMap { tensors[$0] })
        names[item.tensorId] = name
        tensors[name] = item.tensorId
        images[name] = image
        return item.id
      } catch {
        check(false, "append \(name): \(error.localizedDescription)")
        return nil
      }
    }
    func key(_ id: StepID?) -> String { id.map { "(\($0.lineage),\($0.logicalTime))" } ?? "-" }
    /// The steps as "name(lineage,time)<parent", sorted by name.
    func shape(_ tree: ProjectTree) -> String {
      tree.steps.values.sorted { (names[$0.tensorId ?? 0] ?? "") < (names[$1.tensorId ?? 0] ?? "") }
        .map { step in
          let parent = step.parent.flatMap { tree.steps[$0]?.tensorId }.flatMap { names[$0] } ?? "-"
          return "\(names[step.tensorId ?? 0] ?? "?")\(key(step.id))<\(parent)"
        }
        .joined(separator: " ")
    }
    func line(_ ids: [StepID], _ tree: ProjectTree) -> String {
      ids.compactMap { tree.steps[$0]?.tensorId }.map { names[$0] ?? "?" }.joined(separator: " ")
    }
    func verify(_ label: String, shape expected: String, main: String, sacred: String) {
      let tree = project.tree()
      check(shape(tree) == expected, "\(label): steps and parents \(shape(tree))")
      check(line(tree.mainLine, tree) == main, "\(label): main line \(line(tree.mainLine, tree))")
      check(line(tree.sacredLine, tree) == sacred, "\(label): sacred line \(line(tree.sacredLine, tree))")
      let items = project.items()
      let intact = items.allSatisfy { item in
        guard let name = names[item.tensorId], let expected = images[name],
          let image = project.image(at: item.id),
          let difference = pixelDifference(expected, image)
        else { return false }
        return difference.maxDelta == 0
          && project.thumbnail(previewId: item.previewId, half: false) != nil
          && project.thumbnail(previewId: item.previewId, half: true) != nil
      }
      check(intact && items.count == tree.steps.count, "\(label): every step keeps its image and thumbnails")
    }

    _ = await add("A0", after: nil)
    _ = await add("A1", after: "A0")
    _ = await add("A2", after: "A1")
    _ = await add("A3", after: "A2")
    // As a project written before branching: the first fork records the parents first.
    await project.forgetParentLinks()
    check(
      project.tree().steps.values.allSatisfy { !$0.recordsParent },
      "steps written before branching have no recorded parent")
    let b = await add("B", after: "A1")
    check(
      project.tree().steps.values.allSatisfy { $0.recordsParent || $0.id.logicalTime == 0 },
      "the first fork records every step's parent")
    check(key(b) == "(1,2)", "fork from the middle starts lineage 1 at step 2 \(key(b))")
    verify(
      "fork from the middle", shape: "A0(0,0)<- A1(0,1)<A0 A2(0,2)<A1 A3(0,3)<A2 B(1,2)<A1",
      main: "B A1 A0", sacred: "A0 A1 B A3")
    let c = await add("C", after: "A2")
    check(key(c) == "(3,3)", "fork from a step that isn't the greatest lineage at its number \(key(c))")
    verify(
      "fork from a non-sacred branch",
      shape: "A0(3,0)<- A1(3,1)<A0 A2(2,2)<A1 A3(2,3)<A2 B(1,2)<A1 C(3,3)<A2",
      main: "C A2 A1 A0", sacred: "A0 A1 A2 C")
    let d = await add("D", after: "B")
    let e = await add("E", after: "D")
    check(key(d) == "(5,3)" && key(e) == "(5,4)", "a fork of a fork \(key(d)), then a plain append \(key(e))")
    verify(
      "fork of a fork",
      shape: "A0(3,0)<- A1(3,1)<A0 A2(2,2)<A1 A3(2,3)<A2 B(4,2)<A1 C(3,3)<A2 D(5,3)<B E(5,4)<D",
      main: "E D B A1 A0", sacred: "A0 A1 B D E")

    do {
      try await project.delete(tensorId: tensors["A3"] ?? 0)
      check(
        project.tensor(id: tensors["A3"] ?? 0) == nil, "deleting a branch's tip removes its tensor")
      verify(
        "delete a branch's tip",
        shape: "A0(3,0)<- A1(3,1)<A0 A2(2,2)<A1 B(4,2)<A1 C(3,3)<A2 D(5,3)<B E(5,4)<D",
        main: "E D B A1 A0", sacred: "A0 A1 B D E")
      let parent = try await project.delete(tensorId: tensors["D"] ?? 0)
      check(parent == tensors["B"], "deleting a step returns its parent")
      verify(
        "delete on a branch",
        shape: "A0(3,0)<- A1(3,1)<A0 A2(2,2)<A1 B(4,2)<A1 C(3,3)<A2 E(5,3)<B",
        main: "E B A1 A0", sacred: "A0 A1 B E")
      try await project.delete(tensorId: tensors["A1"] ?? 0)
      verify(
        "delete a fork point",
        shape: "A0(3,0)<- A2(2,2)<A0 B(4,1)<A0 C(3,2)<A2 E(5,2)<B",
        main: "E B A0", sacred: "A0 B E")
    } catch {
      check(false, "branch deletes: \(error.localizedDescription)")
    }

    if let c = project.tree().step(tensorId: tensors["C"] ?? 0) { project.setCurrentStep(c) }
    await project.close()
    project = Project(url: url)
    verify(
      "after reopening", shape: "A0(3,0)<- A2(2,2)<A0 B(4,1)<A0 C(3,2)<A2 E(5,2)<B",
      main: "E B A0", sacred: "A0 B E")
    let tree = project.tree()
    check(
      project.storedCurrentStep(in: tree).flatMap { tree.steps[$0]?.tensorId } == tensors["C"],
      "the current step survives a reopen")
    await project.close()
  }

  /// Deletes scratch projects the way Delete Project… does (`CreateModel.deleteProject`), as
  /// PASS/FAIL lines: the current project switches to the next one, its files go to the Trash,
  /// its media folder (a video imported into it) with them, and once the project it closed has
  /// had time to shut down no -wal, -shm or media folder is back at the old path, not even from
  /// an import into it still running when the delete came (as an agent's `import_video`), which
  /// either stops because the project closed or finished first and went to the Trash with it, and
  /// put nothing into the project opened in its place; another project's media folder stays. Its
  /// cached clip videos go (another project's stay), its queued jobs (a Match Colors job and a
  /// generation) are counted for the confirmation and cancelled while another project's queued
  /// job stays (a SKIP line when there are no settings to queue them with), the canvas image isn't taken for a
  /// step of a later project of the same name, and thumbnails aren't either. Last, a rename that
  /// another project opens under (`<name>-r`, made and deleted here) throws and renames neither.
  ///
  ///   Atelier --delete-project-check --project delete-check-<random> [--quit]
  ///
  /// It makes `<name>-z` and `<name>-zz` beside the scratch project, so the projects it opens in
  /// place of the deleted ones are its own, never the user's; it refuses any other project name.
  /// It deletes `<name>` (twice: again after making it anew), `<name>-z` and `<name>-r`, and empties
  /// what they put in the Trash. `<name>-zz` is left current at the end, for the caller to remove.
  static func deleteProjectCheck(_ model: CreateModel) {
    let args = CommandLine.arguments
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      @MainActor func finish() {
        print(failures == 0 ? "delete project check: all passed" : "delete project check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      let history = model.history
      while !history.isLoaded || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      let name = history.project.name
      guard name.hasPrefix("delete-check-") else {
        check(false, "run with --project delete-check-<random> (got “\(name)”)")
        return finish()
      }
      let sibling = name + "-z"
      let last = name + "-zz"
      guard history.items.isEmpty, !HistoryStore.scanProjectNames().contains(where: { $0 == sibling || $0 == last }) else {
        check(false, "“\(name)” and its siblings must be new")
        return finish()
      }
      let fileManager = FileManager.default
      func exists(_ url: URL, _ suffix: String = "") -> Bool { fileManager.fileExists(atPath: url.path + suffix) }
      @MainActor func add(to project: Project, seed: Int) async -> HistoryItem? {
        guard let image = gradient(width: 64, height: 64, seed: seed), let tensor = ImageTensor.tensor(from: image) else { return nil }
        return try? await project.append(
          tensor: tensor, model: model.selectedModel ?? "check.ckpt", prompt: "delete check \(seed)", negativePrompt: "",
          seed: UInt32(seed), settings: [:], createdAt: Date(), duration: 1)
      }
      func pixels(_ image: CGImage?) -> Data? { image?.dataProvider?.data as Data? }
      /// Removes what a delete put in the Trash: it's this check's scratch file.
      func emptyTrashed(_ trashed: URL?) {
        guard let trashed else { return }
        for suffix in ["", "-wal", "-shm", Media.suffix] {
          try? fileManager.removeItem(atPath: trashed.path + suffix)
        }
      }

      // Each project with an image.
      guard let first = await add(to: history.project, seed: 1) else {
        check(false, "couldn't add an image to “\(name)”")
        return finish()
      }
      for (other, seed) in [(sibling, 2), (last, 3)] {
        let project = Project(url: HistoryStore.url(for: other))
        check(await add(to: project, seed: seed) != nil, "made scratch project “\(other)”")
        await project.close()
      }
      await history.reload()
      let next = history.projectToOpen(afterDeleting: name)
      check(next == sibling, "the project after “\(name)” is “\(sibling)” (got “\(next)”)")
      guard next == sibling else { return finish() }

      // A cached clip video of each.
      let clips = URL.cachesDirectory.appending(path: "Atelier/Clips", directoryHint: .isDirectory)
      try? fileManager.createDirectory(at: clips, withIntermediateDirectories: true)
      let ownClips = ["\(name)-1-2-h264.mp4", "\(name)-1-2-hevc.mp4"].map { clips.appending(path: $0) }
      let siblingClip = clips.appending(path: "\(sibling)-1-2-h264.mp4")
      for url in ownClips + [siblingClip] {
        fileManager.createFile(atPath: url.path, contents: Data())
      }

      let firstThumbnail = await history.thumbnail(for: first, half: false)
      model.show(first)
      for _ in 0..<50 where model.imageItem?.tensorId != first.tensorId {
        try? await Task.sleep(for: .milliseconds(100))
      }
      check(model.imageItem?.tensorId == first.tensorId, "the image is on the canvas")

      // A Match Colors job for the project, held in the paused queue.
      model.setQueuePaused(true)
      if let settings = model.settings {
        var request = GenerationEngine.Request(
          model: first.sidecar.model, prompt: first.sidecar.prompt, negativePrompt: "", seed: first.sidecar.seed,
          configuration: settings)
        request.colorMatch = ColorMatch.Job(project: name, sourceTensorId: first.tensorId, options: ColorMatch.Options())
        model.queue.append([request], currentTensorId: history.currentTensorId, project: name)
        // A generation for it, and one for the project that opens in its place, which must stay.
        var generation = request
        generation.colorMatch = nil
        model.queue.append([generation], currentTensorId: history.currentTensorId, project: name)
        model.queue.append([generation], currentTensorId: nil, project: sibling)
        check(
          model.jobs(in: name).count == 2 && model.jobs(in: name).contains { $0.request?.colorMatch != nil },
          "a Match Colors job and a generation for “\(name)” wait")
        check(
          ProjectDeletion.jobsMessage(project: name, running: 0, waiting: model.jobs(in: name).count)
            == "2 jobs for “\(name)” are waiting. Deleting the project cancels them."
            && ProjectDeletion.confirmTitle(jobCount: model.jobs(in: name).count) == "Cancel Jobs and Delete",
          "the confirmation counts them and its button says they go")
      } else {
        print("SKIP the queued jobs: no settings to queue them with")
        fflush(stdout)
      }

      // A video in the project's media folder, and one in another project's (`last`, which isn't
      // opened before it's looked at, so its orphan clean-up can't take the file).
      let movie = fileManager.temporaryDirectory.appending(path: "\(name)-movie.mov", directoryHint: .notDirectory)
      do {
        try await writeMovie(to: movie, width: 64, height: 32, frames: 8, framesPerSecond: 24)
        _ = try await history.importVideo(movie, name: "Delete check")
      } catch {
        check(false, "import a video into “\(name)”: \(error.localizedDescription)")
      }
      let lastMedia = Media.folder(forProject: HistoryStore.url(for: last))
      let lastMediaFile = lastMedia.appending(path: "\(UUID().uuidString).mov", directoryHint: .notDirectory)
      try? fileManager.createDirectory(at: lastMedia, withIntermediateDirectories: true)
      try? fileManager.copyItem(at: movie, to: lastMediaFile)

      let deleted = history.project
      let url = deleted.url
      check(exists(url, Media.suffix), "“\(name)” has a media folder")
      do {
        // Another import, into this project, still running as the delete starts, as an agent's is
        // (nothing cancels it). `importVideo` takes the project it imports into before its first
        // suspension, so once it has started it's this one's; then it's given until its file
        // shows up in the media folder (the copy is a clone, so it may be done by then).
        let mediaFolder = Media.folder(forProject: url)
        func mediaCount() -> Int { (try? fileManager.contentsOfDirectory(atPath: mediaFolder.path).count) ?? 0 }
        let before = mediaCount()
        let progress = RaceProgress()
        let racing = Task { @MainActor in
          progress.started = true
          defer { progress.done = true }
          return try await history.importVideo(movie, name: "Delete check during delete")
        }
        let deadline = Date().addingTimeInterval(2)
        while !progress.started || (!progress.done && mediaCount() == before && Date() < deadline) {
          await Task.yield()
          if progress.started { try? await Task.sleep(for: .milliseconds(1)) }
        }
        check(history.project === deleted, "the import during the delete started into “\(name)”")
        let trashed = try await model.deleteProject(name)
        let raced = await racing.result
        // The closed project's background shut-down, had it been let go, or a write it refused
        // would come in this time: nothing of it may come back at the old path meanwhile.
        var reappeared: Set<String> = []
        let watchUntil = Date().addingTimeInterval(1.5)
        repeat {
          for suffix in ["", "-wal", "-shm", Media.suffix] where exists(url, suffix) { reappeared.insert(url.lastPathComponent + suffix) }
          try? await Task.sleep(for: .milliseconds(50))
        } while Date() < watchUntil
        check(reappeared.isEmpty, "nothing came back at the old path after the delete (got \(reappeared.sorted()))")
        check(!HistoryStore.scanProjectNames().contains(name), "and the Projects folder doesn't list it")
        switch raced {
        case .success(let item):
          print("the import during the delete finished first")
          let file = item.clip?.media?.file
          check(
            file != nil && trashed.map { exists($0, Media.suffix + "/" + (file ?? "")) } == true,
            "the import that finished first went to the Trash with the project")
        case .failure(let error):
          print("the import during the delete stopped: \(error.localizedDescription)")
          check(
            error is CancellationError || (error as? HistoryStore.ImportError) == .projectClosed,
            "it stopped because the project closed (got \(error.localizedDescription))")
        }
        check(!exists(HistoryStore.url(for: sibling), Media.suffix), "the import put nothing into “\(sibling)”")
        check(history.project.name == sibling, "“\(sibling)” is open in its place (got “\(history.project.name)”)")
        check(history.items.count == 1, "and lists exactly its own image (got \(history.items.count))")
        check(!exists(url) && !exists(url, "-wal") && !exists(url, "-shm"), "the project's files are gone from Projects")
        check(!exists(url, Media.suffix), "its media folder is gone from Projects")
        check(trashed.map { exists($0) } == true, "the project file is in the Trash")
        check(trashed.map { exists($0, Media.suffix) } == true, "its media folder is in the Trash")
        check(exists(lastMediaFile), "another project's media folder stays")
        emptyTrashed(trashed)
        check(!history.projectNames.contains(name), "the project menu no longer lists it")
        check(!deleted.isOpen, "the project that was open is closed")
        check(!ownClips.contains(where: { exists($0) }), "its cached clip videos are gone")
        check(exists(siblingClip), "another project's cached clip video stays")
        check(model.jobs(in: name).isEmpty, "its jobs are cancelled")
        if model.settings != nil {
          check(model.jobs(in: sibling).count == 1, "another project's job still waits")
        }
      } catch {
        check(false, "delete “\(name)”: \(error.localizedDescription)")
      }
      // It was only there to stay: it isn't run.
      for job in model.jobs(in: sibling) { model.cancel(job.id) }
      model.setQueuePaused(false)
      try? fileManager.removeItem(at: siblingClip)

      // A new project under the same name: its first image has the same tensor id as the old one's.
      await history.open(name)
      if let again = await add(to: history.project, seed: 4) {
        await history.reload()
        check(history.items.count == 1, "“\(name)” made anew is empty but for its new image")
        if again.tensorId == first.tensorId {
          check(model.imageItem == nil, "the canvas image isn't taken for the new project's image of the same id")
        }
        let thumbnail = await history.thumbnail(for: again, half: false)
        check(
          thumbnail != nil && pixels(thumbnail) != pixels(firstThumbnail),
          "the new image's thumbnail isn't the deleted one's")
      } else {
        check(false, "couldn't add an image to “\(name)” made anew")
      }
      do {
        emptyTrashed(try await model.deleteProject(name))
        check(history.project.name == sibling, "deleting it again opens “\(sibling)”")
        emptyTrashed(try await model.deleteProject(sibling))
        check(history.project.name == last, "deleting “\(sibling)” opens “\(last)”")
        check(!exists(HistoryStore.url(for: sibling)), "“\(sibling)” is gone")
      } catch {
        check(false, "delete again: \(error.localizedDescription)")
      }
      // A rename the open project changes under (another project opened while the rename writes
      // what's pending, `willSwitchProject`) renames nothing and throws, so no caller relabels the
      // wrong project's jobs.
      if history.project.name == last {
        let other = name + "-r"
        let renamedName = name + "-renamed"
        let otherProject = Project(url: HistoryStore.url(for: other))
        check(await add(to: otherProject, seed: 5) != nil, "made scratch project “\(other)”")
        await otherProject.close()
        let original = history.willSwitchProject
        history.willSwitchProject = { [weak history] in
          history?.willSwitchProject = original
          await original?()
          await history?.open(other)
        }
        do {
          let renamed = try await history.renameCurrent(to: renamedName)
          check(false, "a rename the open project changed under throws (renamed \(renamed.from) to \(renamed.to))")
        } catch {
          check(
            (error as? HistoryStore.RenameError).map { if case .projectChanged = $0 { true } else { false } } == true,
            "a rename the open project changed under throws (\(error.localizedDescription))")
        }
        history.willSwitchProject = original
        check(history.project.name == other, "the project opened meanwhile stays open, its name unchanged (got “\(history.project.name)”)")
        check(
          exists(HistoryStore.url(for: last)) && exists(HistoryStore.url(for: other)) && !exists(HistoryStore.url(for: renamedName)),
          "neither project was renamed")
        await history.open(last)
        do {
          emptyTrashed(try await model.deleteProject(other))
        } catch {
          check(false, "delete “\(other)”: \(error.localizedDescription)")
        }
        let leftOver = HistoryStore.url(for: renamedName)
        if exists(leftOver) { emptyTrashed(leftOver) }
      } else {
        check(false, "“\(last)” is open for the rename check (got “\(history.project.name)”)")
      }
      // Before `finish`, which may quit.
      try? fileManager.removeItem(at: lastMedia)
      try? fileManager.removeItem(at: movie)
      finish()
    }
  }

  /// How far `deleteProjectCheck`'s import during the delete has got.
  @MainActor private final class RaceProgress {
    var started = false
    var done = false
  }

  /// A test image with distinct values in every channel; `seed` varies the blue channel.
  static func gradient(width: Int, height: Int, seed: Int = 0) -> CGImage? {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        bytes[i] = UInt8(x * 255 / (width - 1))
        bytes[i + 1] = UInt8(y * 255 / (height - 1))
        bytes[i + 2] = UInt8((x * 7 + y * 13 + seed * 37) % 256)
      }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}
#endif
