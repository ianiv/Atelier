import CoreGraphics
import Foundation

extension CreateModel {
  /// Queues an Edit screen Save to History: `job` renders `item` (a step of the current project)
  /// with its look and saves the result after it. It runs on this device whatever Run on says
  /// (it needs no model or GPU), in turn with the other jobs, and saves into its own project even
  /// if another is open by then. Returns the job's id: the one already waiting or running for the
  /// same edit when there is one (`JobQueue.pendingEdit`), since a second would make the same image.
  ///
  /// An edited step given as `item` is followed back to the step its record names, and so on to
  /// one with no record (`EditModel.editSource(of:in:)`), as opening it in Edit does: the saved
  /// record then names the real source, and opening the result doesn't put a look on a look.
  @discardableResult
  func queueEdit(_ job: Edit.Job, item: HistoryItem, fromAgent: Bool = false) throws -> UUID {
    var job = job, item = item
    if item.sidecar.edit != nil, job.project == history.project.name {
      let source = EditModel.editSource(of: item, in: history.tree)
      if source.tensorId != item.tensorId {
        item = source
        job.sourceTensorId = source.tensorId
      }
    }
    guard !item.isVideo, item.hasImage else { throw EditJobError.video }
    // Its strokes are a paint layer over a blank image: an edit saved after it would name the
    // blank image as its source. Add to History in Edit makes the drawing a step of its own.
    // In its own project, open or not; one that can't be read is taken to have strokes. As History
    // reads it (`Project.sketchImage`): stored paint that doesn't hold up for the base's own size
    // (its layer's, else the step's recorded size) isn't drawn.
    if item.isSketch, let tensorId = item.imageTensorId {
      guard let project = history.project(named: job.project) else { throw EditJobError.sketch }
      let size = project.layerSize(tensorId: tensorId) ?? (width: max(item.sidecar.width, 1), height: max(item.sidecar.height, 1))
      if project.storedPaint(forImage: tensorId)?.validated(width: size.width, height: size.height)?.mayHaveColor == true {
        throw EditJobError.sketch
      }
    }
    if let pending = queue.pendingEdit(job) { return pending.id }
    guard var configuration = settings else { throw EditJobError.noSettings }
    // The step's settings, as Match Colors carries them; the size is the step's own.
    SettingsRegistry.apply(dump: item.sidecar.configuration, to: &configuration)
    var request = GenerationEngine.Request(
      model: item.sidecar.model, prompt: item.sidecar.prompt, negativePrompt: item.sidecar.negativePrompt,
      seed: item.sidecar.seed, configuration: configuration)
    request.parentTensorId = HistoryStore.tip(of: item)
    request.edit = job
    statusNote = nil
    guard let id = queue.append(
      [request], currentTensorId: history.currentTensorId, target: .local, fromAgent: fromAgent, project: job.project).first
    else { throw JobProjectError.beingDeleted(job.project) }
    runNext()
    return id
  }

  /// Queues an edit for an agent (`edit_image_look`), or joins the one already waiting or
  /// running for the same edit, and returns the step it saved, as `matchColors(forAgent:)` does.
  /// `progress` hears the step (of 1,000) and what it's doing. Cancelling the caller cancels the
  /// job, unless it joined one someone else queued (the Edit screen's Save to History).
  ///
  /// A sketch with strokes is edited as its drawing: added to History after it first, as the Edit
  /// screen's Add to History does (`sketchDrawing`), and the edit saved after that.
  /// Returns the drawing too, when one was added or reused: the edit's real source.
  func edit(
    forAgent edit: Edit.Job, item: HistoryItem, progress: @escaping (Int, String) -> Void
  ) async throws -> (item: HistoryItem, project: String, drawing: HistoryItem?) {
    var edit = edit, item = item
    let drawing = try await sketchDrawing(of: item, project: edit.project)
    if let drawing {
      item = drawing
      edit.sourceTensorId = drawing.tensorId
    }
    let pending = queue.pendingEdit(edit)?.id
    let id = try queueEdit(edit, item: item, fromAgent: true)
    let joined = id == pending
    let saved = try await withTaskCancellationHandler {
      try await editResult(of: id, project: edit.project, progress: progress)
    } onCancel: {
      if !joined { Task { @MainActor in self.cancel(id) } }
    }
    return (saved.item, saved.project, drawing)
  }

  /// For a sketch with strokes in the open project `project`: its drawing (the strokes baked in)
  /// as an Imported entry after it, which an edit can name as its source, as the Edit screen's Add
  /// to History makes one. Nil for anything else (it's edited as it is). The same drawing asked
  /// for again this session is the entry made before, while it's still there.
  ///
  /// Calls for the same sketch at once share one (`sketchDrawingTasks`), so it's added once. A
  /// sketch whose project isn't open, or closes meanwhile, throws: its edit can't be made safely.
  func sketchDrawing(of item: HistoryItem, project: String) async throws -> HistoryItem? {
    guard item.isSketch, let tensorId = item.imageTensorId else { return nil }
    let open = history.project
    guard project == open.name else { throw EditJobError.sketchProjectClosed(project) }
    if let running = sketchDrawingTasks[tensorId] { return try await running.value }
    let task = Task { try await makeSketchDrawing(tensorId: tensorId, project: project, open: open) }
    sketchDrawingTasks[tensorId] = task
    defer { if sketchDrawingTasks[tensorId] == task { sketchDrawingTasks[tensorId] = nil } }
    return try await task.value
  }

  /// `sketchDrawing`'s work, once per sketch at a time.
  private func makeSketchDrawing(tensorId: Int64, project: String, open: Project) async throws -> HistoryItem? {
    await keepSketchNow()
    guard open === history.project else { throw EditJobError.sketchProjectClosed(project) }
    let drawn = await open.read { project -> (image: CGImage, paint: CanvasPaint?)? in
      guard let base = project.image(tensorId: tensorId) else { return nil }
      let baked = project.sketchImage(base, tensorId: tensorId)
      return baked === base ? nil : (baked, project.storedPaint(forImage: tensorId))
    }
    guard open === history.project else { throw EditJobError.sketchProjectClosed(project) }
    // No strokes: it's edited as it is.
    guard let drawn else { return nil }
    if let made = sketchDrawings[tensorId], made.project == project, made.paint == drawn.paint,
       let entry = history.item(tensorId: made.entry)
    {
      return entry
    }
    guard var input = entryInput(.imported) else { throw EditJobError.noSettings }
    input.canvas = .image(drawn.image)
    input.canvasImage = drawn.image
    input.mask = nil
    input.moodboard = []
    guard let entry = try await history.saveEntry(input, after: tensorId, makeCurrent: false), open === history.project else {
      throw EditJobError.stepMissing(project)
    }
    sketchDrawings[tensorId] = (project, drawn.paint, entry.tensorId)
    return entry
  }

  /// Waits for Edit job `id` to end, and returns the step it saved, read from its project (`name`
  /// when it was queued), with that project's name now.
  private func editResult(of id: UUID, project name: String, progress: (Int, String) -> Void) async throws -> (item: HistoryItem, project: String) {
    var reported: (Int, String)?
    while true {
      if let job = queue.recent.first(where: { $0.id == id }) {
        switch job.status {
        case .finished(let tensorId):
          let name = job.project ?? name
          guard let project = history.project(named: name) else { throw EditJobError.projectMissing(name) }
          guard let item = await history.item(tensorId: tensorId, in: project) else { throw EditJobError.stepMissing(name) }
          return (item, name)
        case .failed(let message): throw EditJobError.failed(message)
        default: throw CancellationError()
        }
      }
      if let job = queue.running, job.id == id, let run = runProgress(of: job) {
        let message = if case .running(let message) = phase { message } else { "Rendering the edit" }
        if reported?.0 != run.step || reported?.1 != message {
          reported = (run.step, message)
          progress(run.step, message)
        }
      } else if !queue.waiting.contains(where: { $0.id == id }) {
        // Taken off the lists without ending here (Clear Finished, say).
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Runs an Edit job on this device: reads the source step from the job's own project, renders
  /// it at full size with the job's look and data (`Edit.Job.context`, which it carries from the
  /// moment it's queued) off the main actor, and saves the result as a new step after the
  /// source, recording `Edit.Record`, as `run(_:request:job:)` does for Match Colors to Original.
  /// In a task, so finishing never runs the next job from inside `runNext`; tracked, so Stop and
  /// Delete Project's cancel reach it.
  func runEdit(_ edit: Edit.Job, request queued: GenerationEngine.Request, job: JobQueue.Job) {
    let startedAt = Date()
    beginRun(job, message: "Reading the image…", totalSteps: 1_000, startedAt: startedAt)
    let task = Task {
      var status = JobQueue.Job.Status.cancelled
      var inputTensorId: Int64?
      var inOpenProject = true
      do {
        // Its own project's (`JobQueue.Job.project`), whichever is open.
        let project = try self.project(for: job)
        let item: HistoryItem
        if project === history.project, let listed = history.item(tensorId: edit.sourceTensorId) {
          item = listed
        } else {
          let tree = await project.read { $0.tree() }
          guard let found = tree.step(tensorId: edit.sourceTensorId).flatMap({ tree.items[$0] }) else {
            throw EditJobError.stepMissing(project.name)
          }
          item = found
        }
        guard !item.isVideo, let imageTensorId = item.imageTensorId else { throw EditJobError.video }
        // The step's own image, which the record names as the source. A sketch with strokes never
        // gets here (`queueEdit`): its image is the blank base.
        guard let source = await project.read({ $0.image(tensorId: imageTensorId) }) else { throw EditJobError.unreadable }
        try Task.checkCancellation()
        setRunMessage("Rendering the edit…", job)
        setRunStep(100, job)
        // Its own renderer: the screen's caches are for the screen's image, and a full render
        // isn't kept anyway (it's over the cache's size limit).
        // The retouch first (the Heal strokes, then the crop), then the look, as the screen shows
        // it; the step's input stays the whole unhealed source, so Step's Input and Open in Edit
        // go back to it.
        let retouched = try await EditRetouch.applied(edit.retouch, to: source)
        let rendered = try await EditRenderer().full(source: retouched, options: edit.options, context: edit.context)
        guard let tensor = ImageTensor.tensor(from: rendered) else { throw EditJobError.unreadable }
        try Task.checkCancellation()
        setRunMessage("Saving…", job)
        setRunStep(900, job)
        var request = queued
        SettingsRegistry.apply(dump: item.sidecar.configuration, to: &request.configuration)
        request.configuration.width = rendered.width
        request.configuration.height = rendered.height
        // The source is the step's input, so it's the result's parent and its original.
        request.canvas = source
        request.canvasTensorId = item.tensorId
        request.canvasIsImported = false
        request.parentTensorId = HistoryStore.tip(of: item)
        request.moodboard = []
        let followsRun = { self.canvasFollowsRun && job.id == self.foregroundJobID && self.jobProjectIsOpen(job) }
        let history = history
        // Stopped (or its project deleted) by now: nothing is saved. The save itself runs as a task of
        // its own (`oneSaveAtATime`), which a cancel doesn't reach.
        try Task.checkCancellation()
        let (saved, into) = try await oneSaveAtATime {
          // Found again now: a rename since it started closed the project it read from
          // (`renameCurrent`), and the job follows it to the new name.
          let into = try self.project(for: job)
          let saved = try await history.save(
            GenerationEngine.Output(frames: [tensor]), request: request, startedAt: startedAt, finishedAt: Date(),
            into: into, makeCurrent: followsRun)
          return (saved, into)
        }
        // The saved step's record names where its data went in the project.
        if let record = saved.sidecar.edit { queue.setEditRecord(record, id: job.id) }
        setRunStep(1_000, job)
        if into === history.project { landSavedImage(rendered, tensorId: saved.tensorId, onCanvas: followsRun()) }
        if let failure = await history.writeToOutputFolder(saved, image: rendered, in: into) { errorMessage = failure }
        saveSession()
        FinishedNotice.post(
          prompt: edit.profileName.map { "Edit with “\($0)”" } ?? "Edit", seconds: Date().timeIntervalSince(startedAt),
          title: "Edit saved")
        status = .finished(tensorId: saved.tensorId)
        inputTensorId = saved.inputTensorId
        inOpenProject = into === history.project
      } catch is CancellationError {
      } catch {
        errorMessage = error.localizedDescription
        status = .failed(error.localizedDescription)
      }
      finish(job, status: status, inputTensorId: inputTensorId, inOpenProject: inOpenProject)
    }
    track(task, for: job)
  }

  nonisolated enum EditJobError: LocalizedError {
    case video, unreadable, noSettings, projectMissing(String), stepMissing(String), failed(String), sketch
    case sketchProjectClosed(String)

    var errorDescription: String? {
      switch self {
      case .video: "Edit works on images, not videos."
      case .unreadable: "The image couldn't be read."
      case .noSettings: "There are no settings to save the result with yet: wait for the model list to load."
      case .projectMissing(let name): "The project “\(name)” the image was in is no longer there."
      case .stepMissing(let name): "The image is no longer in the project “\(name)”."
      case .failed(let message): message
      case .sketchProjectClosed(let name):
        "The sketch's project “\(name)” isn't open, so its drawing can't be added to History to edit. Open it and try again."
      case .sketch:
        "That step is a sketch: its strokes are a paint layer over a blank image, so an edit saved after it would start from the blank image. Add the drawing to History first (the Edit screen's Add to History), and edit that step."
      }
    }
  }
}
