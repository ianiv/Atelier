import CoreGraphics
import Foundation

extension CreateModel {
  /// Queues an Edit screen Save to History: `job` renders `item` (a step of the current project)
  /// with its look and saves the result after it. It runs on this device whatever Run on says
  /// (it needs no model or GPU), in turn with the other jobs, and saves into its own project even
  /// if another is open by then. Returns the job's id: the one already waiting or running for the
  /// same edit when there is one (`JobQueue.pendingEdit`), since a second would make the same image.
  @discardableResult
  func queueEdit(_ job: Edit.Job, item: HistoryItem, fromAgent: Bool = false) throws -> UUID {
    guard !item.isVideo, item.hasImage else { throw EditJobError.video }
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
    let id = queue.append([request], currentTensorId: history.currentTensorId, target: .local, fromAgent: fromAgent)[0]
    runNext()
    return id
  }

  /// Queues an edit for an agent (`edit_image_look`), or joins the one already waiting or
  /// running for the same edit, and returns the step it saved, as `matchColors(forAgent:)` does.
  /// `progress` hears the step (of 1,000) and what it's doing. Cancelling the caller cancels the
  /// job, unless it joined one someone else queued (the Edit screen's Save to History).
  func edit(
    forAgent edit: Edit.Job, item: HistoryItem, progress: @escaping (Int, String) -> Void
  ) async throws -> HistoryItem {
    let pending = queue.pendingEdit(edit)?.id
    let id = try queueEdit(edit, item: item, fromAgent: true)
    let joined = id == pending
    return try await withTaskCancellationHandler {
      try await editResult(of: id, project: edit.project, progress: progress)
    } onCancel: {
      if !joined { Task { @MainActor in self.cancel(id) } }
    }
  }

  /// Waits for Edit job `id` to end, and returns the step it saved, read from `project`.
  private func editResult(of id: UUID, project name: String, progress: (Int, String) -> Void) async throws -> HistoryItem {
    var reported: (Int, String)?
    while true {
      if let job = queue.recent.first(where: { $0.id == id }) {
        switch job.status {
        case .finished(let tensorId):
          guard let project = history.project(named: job.request?.edit?.project ?? name) else { throw EditJobError.projectMissing(name) }
          if project === history.project, let item = history.item(tensorId: tensorId) { return item }
          let tree = await project.read { $0.tree() }
          guard let item = tree.step(tensorId: tensorId).flatMap({ tree.items[$0] }) else { throw EditJobError.stepMissing(name) }
          return item
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
        guard let project = history.project(named: edit.project), project.isOpen else {
          throw EditJobError.projectMissing(edit.project)
        }
        let item: HistoryItem
        if project === history.project, let listed = history.item(tensorId: edit.sourceTensorId) {
          item = listed
        } else {
          let tree = await project.read { $0.tree() }
          guard let found = tree.step(tensorId: edit.sourceTensorId).flatMap({ tree.items[$0] }) else {
            throw EditJobError.stepMissing(edit.project)
          }
          item = found
        }
        guard !item.isVideo, let imageTensorId = item.imageTensorId else { throw EditJobError.video }
        guard let source = await project.read({ $0.image(tensorId: imageTensorId) }) else { throw EditJobError.unreadable }
        try Task.checkCancellation()
        setRunMessage("Rendering the edit…", job)
        setRunStep(100, job)
        // Its own renderer: the screen's caches are for the screen's image, and a full render
        // isn't kept anyway (it's over the cache's size limit).
        let rendered = try await EditRenderer().full(source: source, options: edit.options, context: edit.context)
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
        let followsRun = { self.canvasFollowsRun && job.id == self.foregroundJobID && project === self.history.project }
        let history = history
        let saved = try await oneSaveAtATime {
          // A rename since it started closed the project it read from (`renameCurrent`): saving
          // there would write to a closed file.
          guard history.project(named: edit.project) === project, project.isOpen else {
            throw EditJobError.projectMissing(edit.project)
          }
          return try await history.save(
            GenerationEngine.Output(frames: [tensor]), request: request, startedAt: startedAt, finishedAt: Date(),
            into: project, makeCurrent: followsRun)
        }
        // The saved step's record names where its data went in the project.
        if let record = saved.sidecar.edit { queue.setEditRecord(record, id: job.id) }
        setRunStep(1_000, job)
        if project === history.project { landSavedImage(rendered, tensorId: saved.tensorId, onCanvas: followsRun()) }
        if let failure = await history.writeToOutputFolder(saved, image: rendered, in: project) { errorMessage = failure }
        saveSession()
        FinishedNotice.post(
          prompt: edit.profileName.map { "Edit with “\($0)”" } ?? "Edit", seconds: Date().timeIntervalSince(startedAt),
          title: "Edit saved")
        status = .finished(tensorId: saved.tensorId)
        inputTensorId = saved.inputTensorId
        inOpenProject = project === history.project
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
    case video, unreadable, noSettings, projectMissing(String), stepMissing(String), failed(String)

    var errorDescription: String? {
      switch self {
      case .video: "Edit works on images, not videos."
      case .unreadable: "The image couldn't be read."
      case .noSettings: "There are no settings to save the result with yet: wait for the model list to load."
      case .projectMissing(let name): "The project “\(name)” the image was in is no longer there."
      case .stepMissing(let name): "The image is no longer in the project “\(name)”."
      case .failed(let message): message
      }
    }
  }
}
