#if os(macOS)
import SwiftUI

extension Automation {
  /// Checks that every job reads from and saves into the project it was queued in
  /// (`JobQueue.Job.project`), whichever project is open by then, as PASS/FAIL lines, with real
  /// 2-step runs at 512×512:
  ///
  /// 0. The queue on its own (a `JobQueue` of its own, nothing run): every job names its
  ///    project, a line never continues into another project, inputs saved from a canvas are
  ///    reused only in their own project, a rename relabels waiting, running and recent jobs and
  ///    what their requests name, `jobs(in:)` counts a project's jobs, a result saved while
  ///    another project is open still moves its line on, and Run Again keeps the project.
  /// 1. A Generate queued in `<name>` that runs and finishes once `<name>-b` is open saves into
  ///    `<name>` after the step current when it was queued; `<name>-b` gains nothing and its
  ///    canvas isn't covered by the run.
  /// 2. Two jobs on one line in `<name>`, run with `<name>-b` open: the second follows the first.
  /// 3. An image upscale queued in `<name>` and run with `<name>-b` open reads and saves there.
  /// 4. Renaming `<name>` while one of its jobs runs and one waits: both save into the renamed
  ///    project, and nothing comes back under the old name.
  /// 5. Deleting `<name>-c` (current, with `<name>-cz` after it) while one of its jobs runs and
  ///    one waits: both are counted and cancelled, nothing is written after its files go, and a
  ///    job of `<name>-b` queued with them still finishes into `<name>-b`.
  /// 6. A saved queue with jobs of two projects, loaded with a third open, brings both back for
  ///    their own projects.
  ///
  ///   Atelier --project-pin-check --project project-pin-<random> [--model M] [--quit]
  ///
  /// It refuses any other project name, makes the `-b`, `-c` and `-cz` projects beside it, and
  /// deletes all but `<name>-cz`, which is left current for the caller to remove (with what the
  /// deletes put in the Trash emptied).
  static func projectPinCheck(_ model: CreateModel) {
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
        print(failures == 0 ? "project pin check: all passed" : "project pin check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func wait(until condition: () -> Bool, seconds: Double = 600) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
          if Date() > deadline { return false }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return true
      }
      let history = model.history
      let queue = model.queue
      let fileManager = FileManager.default
      func exists(_ url: URL, _ suffix: String = "") -> Bool { fileManager.fileExists(atPath: url.path + suffix) }
      while !history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      var name = history.project.name
      guard name.hasPrefix("project-pin-") else {
        check(false, "run with --project project-pin-<random> (got “\(name)”)")
        return finish()
      }
      let other = name + "-b"
      let doomed = name + "-c"
      let last = name + "-cz"
      guard history.items.isEmpty, !HistoryStore.scanProjectNames().contains(where: { [other, doomed, last].contains($0) }) else {
        check(false, "“\(name)” and its siblings must be new")
        return finish()
      }
      if let file = value("--model") {
        model.selectedModel = file
        _ = await wait(until: { !model.isLoadingModel })
        model.resetToModelDefaults(undoManager: nil)
      }
      guard var settings = model.settings else { return finish() }
      settings.steps = 2
      settings.width = 512
      settings.height = 512
      model.settings = settings
      model.canvasMode = .generate
      model.seedLocked = true
      model.seed = 7
      model.count = 1
      model.prompt = "a small wooden boat on a calm lake"

      /// Adds a starting image to `project`, so its runs have a step to follow.
      @MainActor func seed(_ project: Project, _ seed: Int) async -> HistoryItem? {
        guard let image = gradient(width: 64, height: 64, seed: seed), let tensor = ImageTensor.tensor(from: image) else { return nil }
        return try? await project.append(
          tensor: tensor, model: model.selectedModel ?? "check.ckpt", prompt: "pin check \(seed)", negativePrompt: "",
          seed: UInt32(seed), settings: [:], createdAt: Date(), duration: 1)
      }
      /// `project`'s steps as its file has them now, by tensor: the item and its parent's image.
      @MainActor func steps(of projectName: String) async -> [Int64: (item: HistoryItem, parent: Int64?)] {
        guard let project = history.project(named: projectName) else { return [:] }
        let tree = await project.read { $0.tree() }
        var result: [Int64: (item: HistoryItem, parent: Int64?)] = [:]
        for (id, item) in tree.items {
          result[item.tensorId] = (item, tree.steps[id]?.parent.flatMap { tree.steps[$0]?.tensorId })
        }
        return result
      }
      @MainActor func finishedTensor(_ id: UUID?) -> Int64? {
        guard let id, let job = queue.recent.first(where: { $0.id == id }), case .finished(let tensorId) = job.status else { return nil }
        return tensorId
      }
      /// Removes what a delete put in the Trash: it's this check's scratch file.
      func emptyTrashed(_ trashed: URL?) {
        guard let trashed else { return }
        for suffix in ["", "-wal", "-shm", Media.suffix] {
          try? fileManager.removeItem(atPath: trashed.path + suffix)
        }
      }

      guard let start = await seed(history.project, 1) else {
        check(false, "couldn't add an image to “\(name)”")
        return finish()
      }
      for (project, number) in [(other, 2), (doomed, 3), (last, 4)] {
        let opened = Project(url: HistoryStore.url(for: project))
        check(await seed(opened, number) != nil, "made scratch project “\(project)”")
        await opened.close()
      }
      await history.reload()
      history.setCurrent(tensorId: start.tensorId)

      /// Generate with `count`, once it's queued: the new jobs' ids, in order.
      @MainActor func generate(_ count: Int = 1) async -> [UUID] {
        let known = Set(queue.unfinished.map(\.id))
        model.count = count
        model.generate()
        _ = await wait(until: { queue.unfinished.count { !known.contains($0.id) } >= count }, seconds: 30)
        model.count = 1
        return queue.unfinished.map(\.id).filter { !known.contains($0) }
      }

      // 0. The queue alone.
      if var request = model.screenRequest() {
        request.parentTensorId = nil
        request.canvas = nil
        let lines = JobQueue()
        let a = lines.append([request, request], currentTensorId: 5, project: "A")
        let b = lines.append([request], currentTensorId: 5, project: "B")
        check(lines.waiting.map(\.project) == ["A", "A", "B"], "every job names the project it was queued in")
        let lineIDs = lines.waiting.map(\.line)
        check(lineIDs[0] != nil && lineIDs[0] == lineIDs[1] && lineIDs[2] != lineIDs[0], "a line doesn't continue into another project")
        check(lines.jobs(in: "A").map(\.id) == a && lines.jobs(in: "B").map(\.id) == b, "jobs(in:) is each project's jobs")
        // The first of A's runs, saving into A while another project is open: the next follows it.
        let first = lines.startNext()
        lines.finishRunning(.finished(tensorId: 77), id: first?.id ?? UUID(), inOpenProject: false)
        let second = lines.startNext()
        check(second?.request?.parentTensorId == 77, "a result saved while another project is open still moves its line on")
        lines.finishRunning(.cancelled, id: second?.id ?? UUID())
        let third = lines.startNext()
        check(third?.request?.parentTensorId == 5 && third?.project == "B", "B's line follows B's step")
        lines.finishRunning(.cancelled, id: third?.id ?? UUID())
        // Inputs saved from one canvas are only reused in their own project.
        var fromCanvas = request
        fromCanvas.canvas = gradient(width: 16, height: 16)
        fromCanvas.canvasKey = "canvas"
        fromCanvas.placement = TimelinePlacement(project: "A", timeline: UUID(), entry: UUID(), frame: 0, frameTensorId: 1)
        lines.append([fromCanvas], currentTensorId: 1, project: "A")
        lines.append([fromCanvas], currentTensorId: 1, project: "B")
        lines.append([fromCanvas], currentTensorId: 1, project: "A")
        let inA = lines.startNext()
        lines.finishRunning(.finished(tensorId: 90), id: inA?.id ?? UUID(), inputTensorId: 88)
        let inB = lines.startNext()
        check(inB?.request?.canvasTensorId == nil, "an input saved in one project isn't reused in another")
        // A rename relabels the running, waiting and recent jobs, and what their requests name.
        lines.renameProject(from: "A", to: "A2")
        check(
          lines.running?.project == "B" && lines.waiting.first?.project == "A2"
            && lines.waiting.first?.request?.placement?.project == "A2"
            && lines.recent.contains { $0.id == inA?.id && $0.project == "A2" && $0.request?.placement?.project == "A2" },
          "a rename relabels waiting and recent jobs and their placement")
        lines.renameProject(from: "B", to: "B2")
        check(lines.running?.project == "B2" && lines.projectName(of: inB?.id ?? UUID()) == "B2", "and the running job")
        lines.finishRunning(.cancelled, id: inB?.id ?? UUID())
        let againInA = lines.startNext()
        check(againInA?.request?.canvasTensorId == 88, "the input saved in a project is reused there, renamed")
        lines.finishRunning(.cancelled, id: againInA?.id ?? UUID())
        // Run Again keeps the project, detached or not.
        if let inA {
          lines.retry(inA.id)
          check(lines.waiting.last?.project == "A2" && lines.waiting.last?.detached == false, "Run Again keeps its project")
        }
        let device = lines.append(request, remoteDevice: "Device")
        check(!lines.jobs(in: "A2").contains { $0.id == device } && lines.waiting.last?.project == nil, "a paired device's job has no project")
        // A project being deleted takes no jobs.
        lines.acceptsProject = { $0 != "Doomed" }
        check(lines.append([request], currentTensorId: nil, project: "Doomed").isEmpty, "a project being deleted takes no jobs")
      } else {
        check(false, "no request to queue")
      }

      // 1. A Generate queued here, run with the other project open.
      model.show(start)
      _ = await wait(until: { model.imageItem?.tensorId == start.tensorId }, seconds: 10)
      model.setQueuePaused(true)
      let generateID = await generate().first
      check(generateID.flatMap(queue.projectName(of:)) == name, "the Generate names “\(name)”")
      await history.open(other)
      let otherCount = history.items.count
      model.setQueuePaused(false)
      var covered = false
      let shownBefore = (model.canvasShowsImage, model.canvasDisplayImage.map(ObjectIdentifier.init))
      while !queue.isEmpty {
        if model.canvasShowsImage != shownBefore.0 || model.canvasDisplayImage.map(ObjectIdentifier.init) != shownBefore.1 { covered = true }
        try? await Task.sleep(for: .milliseconds(20))
      }
      let generated = finishedTensor(generateID)
      var inName = await steps(of: name)
      check(generated.map { inName[$0] != nil } == true, "its result is a new step of “\(name)” (\(queue.recent.first?.status.description ?? "no job"))")
      check(generated.flatMap { inName[$0]?.parent } == start.tensorId, "after the step current when it was queued")
      check(history.items.count == otherCount, "“\(other)” gained nothing")
      check(!covered, "“\(other)”'s canvas wasn't covered by the run (showed an image before: \(shownBefore.0))")

      // 2. Two on one line, run with the other project open.
      await history.open(name)
      history.setCurrent(tensorId: start.tensorId)
      model.setQueuePaused(true)
      let pairIDs = await generate(2)
      await history.open(other)
      model.setQueuePaused(false)
      _ = await wait(until: { queue.isEmpty })
      inName = await steps(of: name)
      let pair = pairIDs.map(finishedTensor)
      check(pair.allSatisfy { $0.map { inName[$0] != nil } == true }, "both are steps of “\(name)”")
      check(
        pair.count == 2 && pair[1].flatMap { inName[$0]?.parent } == pair[0] && pair[0].flatMap { inName[$0]?.parent } == start.tensorId,
        "the second follows the first, after the step current when they were queued")

      // 3. An image upscale queued here, run with the other project open.
      await history.open(name)
      if let source = history.item(tensorId: generated ?? -1), let image = await history.image(tensorId: source.tensorId, in: name) {
        model.setQueuePaused(true)
        let factor = SystemSuperResolution.scaleFactors(width: image.width, height: image.height, input: .image).first ?? 2
        model.upscale(image: image, item: source, as: ImageUpscale(upscaler: .video(.system, nil), scale: factor))
        let upscaleID = queue.waiting.last?.id
        await history.open(other)
        model.setQueuePaused(false)
        _ = await wait(until: { queue.isEmpty })
        inName = await steps(of: name)
        let upscaled = finishedTensor(upscaleID)
        check(
          upscaled.map { inName[$0]?.item.sidecar.width == image.width * factor } == true,
          "the upscale saved into “\(name)” at \(factor)× the size (\(queue.recent.first?.status.description ?? "no job"))")
        check(history.items.count == otherCount, "and “\(other)” still has nothing new")
      } else {
        check(false, "no result of (1) to upscale")
      }

      // 4. A rename while one job runs and one waits.
      await history.open(name)
      history.setCurrent(tensorId: start.tensorId)
      let renamingIDs = await generate(2)
      _ = await wait(until: { model.step >= 1 || queue.isEmpty }, seconds: 300)
      let renamed = name + "-renamed"
      let oldURL = HistoryStore.url(for: name)
      let runningAtRename = queue.running != nil && !queue.waiting.isEmpty
      do {
        try await history.renameCurrent(to: renamed)
        check(true, "renamed “\(name)” while its jobs ran (one running and one waiting: \(runningAtRename))")
        check(
          renamingIDs.count == 2 && renamingIDs.allSatisfy { queue.projectName(of: $0) == renamed }, "its jobs follow the rename")
        name = renamed
      } catch {
        check(false, "rename: \(error.localizedDescription)")
      }
      _ = await wait(until: { queue.isEmpty })
      let renamedResults = renamingIDs.map(finishedTensor)
      check(
        renamedResults.allSatisfy { $0.map { history.item(tensorId: $0) != nil } == true },
        "both saved into the renamed project (\(renamingIDs.map { id in queue.recent.first { $0.id == id }?.status.description ?? "?" }))")
      check(!exists(oldURL) && !exists(oldURL, "-wal") && !exists(oldURL, "-shm"), "nothing came back under the old name")

      // 5. Delete with one running and one waiting, beside another project's job.
      await history.open(other)
      model.setQueuePaused(true)
      let otherJob = await generate().first
      await history.open(doomed)
      let doomedIDs = await generate(2)
      // Its jobs first, so one is running when the delete comes.
      for id in doomedIDs.reversed() { queue.runNext(id) }
      model.setQueuePaused(false)
      _ = await wait(until: { queue.running.map { doomedIDs.contains($0.id) } == true && model.step >= 1 }, seconds: 300)
      let counts = (model.jobs(in: doomed).count, model.jobs(in: doomed).count { $0.status == .waiting })
      check(counts == (2, 1), "one of “\(doomed)”'s jobs runs and one waits (\(counts))")
      let doomedURL = HistoryStore.url(for: doomed)
      do {
        let trashed = try await model.deleteProject(doomed)
        check(model.jobs(in: doomed).isEmpty, "the delete cancelled its jobs (left: \(model.jobs(in: doomed).map(\.status.description)))")
        check(
          doomedIDs.allSatisfy { id in queue.recent.first { $0.id == id }?.status == .cancelled },
          "both are cancelled in Recent (\(doomedIDs.map { id in queue.recent.first { $0.id == id }?.status.description ?? "not in Recent" }))")
        check(
          doomedIDs.allSatisfy { id in queue.recent.first { $0.id == id }.map { $0.project == nil && $0.projectDeleted } == true },
          "and name the deleted project no more")
        var reappeared: Set<String> = []
        let watchUntil = Date().addingTimeInterval(1.5)
        repeat {
          for suffix in ["", "-wal", "-shm"] where exists(doomedURL, suffix) { reappeared.insert(suffix.isEmpty ? "file" : suffix) }
          try? await Task.sleep(for: .milliseconds(50))
        } while Date() < watchUntil
        check(reappeared.isEmpty, "nothing was written after its files went (got \(reappeared.sorted()))")
        emptyTrashed(trashed)
      } catch {
        check(false, "delete “\(doomed)”: \(error.localizedDescription)")
      }
      _ = await wait(until: { queue.isEmpty })
      let otherSteps = await steps(of: other)
      check(finishedTensor(otherJob).map { otherSteps[$0] != nil } == true, "“\(other)”'s job still finished, into “\(other)”")
      check(history.project.name == last, "“\(last)” opened in its place (got “\(history.project.name)”)")

      // 6. A saved queue of two projects' jobs, loaded with a third open.
      model.setQueuePaused(true)
      await history.open(name)
      let savedIDs = await generate()
      await history.open(other)
      let savedIDs2 = await generate()
      let saved = queue.waiting.filter { (savedIDs + savedIDs2).contains($0.id) }
      let folder = fileManager.temporaryDirectory.appending(path: "atelier-pin-check-\(UUID().uuidString)")
      SavedQueue.save(Array(saved), lineTip: queue.lineTip(of:), in: folder)
      for job in saved { model.cancel(job.id) }
      await history.open(last)
      let loaded = SavedQueue.load(from: folder)
      check(loaded.map(\.project) == [name, other], "a saved queue brings each job back for its own project (\(loaded.map(\.project)))")
      check(loaded.allSatisfy { $0.line != nil }, "each on its line, with the step it follows")
      let restored = await model.savedRequests(loaded)
      model.appendRestored(restored)
      let back = queue.waiting.suffix(restored.count)
      check(back.map(\.project) == [name, other], "and queued again for them")
      for job in back { model.cancel(job.id) }
      try? fileManager.removeItem(at: folder)
      model.setQueuePaused(false)

      // Cleaning up: all but the one now open.
      for project in [name, other] {
        do {
          emptyTrashed(try await model.deleteProject(project))
        } catch {
          check(false, "delete “\(project)”: \(error.localizedDescription)")
        }
      }
      finish()
    }
  }
}

fileprivate extension JobQueue.Job.Status {
  /// For check messages.
  var description: String {
    switch self {
    case .waiting: "waiting"
    case .running: "running"
    case .finished(let tensorId): "finished \(tensorId)"
    case .madeThumbnail: "thumbnail"
    case .exported: "exported"
    case .ranForDevice: "ran for a device"
    case .failed(let message): "failed: \(message)"
    case .cancelled: "cancelled"
    }
  }
}
#endif
