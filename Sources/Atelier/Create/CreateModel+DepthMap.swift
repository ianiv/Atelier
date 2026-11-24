import CoreGraphics
import Foundation

extension CreateModel {
  /// Whether Extract Depth Map can take the canvas: it shows a finished image saved in the
  /// project (an Imported one too), not a video, whose depth map isn't waiting or being made
  /// already (a second would be the same image), and with no colour paint showing on it: the
  /// job reads the step's saved image, so paint not yet run into it wouldn't be in the map.
  /// Whether the model is in doesn't count: the command offers to download it.
  var canExtractCanvasDepthMap: Bool {
    guard let item = canvasImageStep, activePaint == nil else { return false }
    return queue.pendingDepthMap(depthMapJob(for: item)) == nil
  }

  /// Extract Depth Map on the canvas image: queued at once when the depth model is in a models
  /// folder, else after the download the sheet asks for (`DepthModelSheet`).
  func extractCanvasDepthMap() {
    guard canExtractCanvasDepthMap, let item = canvasImageStep else { return }
    guard DepthMap.isModelInstalled else {
      depthModelSheetItem = item
      return
    }
    do {
      try queueDepthMap(item)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// `project` is `item`'s, by default the current one.
  func depthMapJob(for item: HistoryItem, in project: String? = nil) -> DepthMap.Job {
    DepthMap.Job(project: project ?? history.project.name, sourceTensorId: item.tensorId)
  }

  /// Queues the depth map of `item`, a step with an image (an Imported entry's too) of `project`,
  /// by default the current one. It runs on this device whatever Run on says (the source step is
  /// only in this device's project), in turn with the other jobs, and saves into that project
  /// even if another is open by then, as every job does (`JobQueue.Job.project`). Returns the
  /// job's id: the one already waiting or running for the same image when there is one.
  @discardableResult
  func queueDepthMap(_ item: HistoryItem, in project: String? = nil, fromAgent: Bool = false) throws -> UUID {
    guard !item.isVideo, item.hasImage else { throw DepthMap.Failure.video }
    guard DepthMap.isModelInstalled else { throw DepthMap.Failure.modelMissing }
    let job = depthMapJob(for: item, in: project)
    if let pending = queue.pendingDepthMap(job) { return pending.id }
    guard var configuration = settings else { throw DepthMap.Failure.noSettings }
    // The step's settings, as Match Colors carries them; the size is the image's own.
    SettingsRegistry.apply(dump: item.sidecar.configuration, to: &configuration)
    var request = GenerationEngine.Request(
      model: item.sidecar.model, prompt: item.sidecar.prompt, negativePrompt: item.sidecar.negativePrompt,
      seed: item.sidecar.seed, configuration: configuration)
    request.parentTensorId = HistoryStore.tip(of: item)
    request.depthMap = job
    statusNote = nil
    guard let id = queue.append(
      [request], currentTensorId: history.currentTensorId, target: .local, fromAgent: fromAgent, project: job.project).first
    else { throw JobProjectError.beingDeleted(job.project) }
    runNext()
    return id
  }

  /// Queues a depth map for an agent (`extract_depth_map`), or joins the one already waiting or
  /// running for the image, and returns the step it saved, as `matchColors(forAgent:)` does.
  /// Cancelling the caller cancels the job, unless it joined one someone else queued.
  func depthMap(forAgent item: HistoryItem, progress: @escaping (Int, String) -> Void) async throws -> (item: HistoryItem, project: String) {
    let pending = queue.pendingDepthMap(depthMapJob(for: item))?.id
    let id = try queueDepthMap(item, fromAgent: true)
    let joined = id == pending
    let project = history.project.name
    return try await withTaskCancellationHandler {
      try await depthMapResult(of: id, project: project, progress: progress)
    } onCancel: {
      if !joined { Task { @MainActor in self.cancel(id) } }
    }
  }

  /// Waits for Extract Depth Map job `id` to end, and returns the step it saved, read from its
  /// project, with that project's name now.
  private func depthMapResult(of id: UUID, project name: String, progress: (Int, String) -> Void) async throws -> (item: HistoryItem, project: String) {
    var reported: (Int, String)?
    while true {
      if let job = queue.recent.first(where: { $0.id == id }) {
        switch job.status {
        case .finished(let tensorId):
          let name = job.project ?? name
          guard let project = history.project(named: name) else { throw DepthMap.Failure.projectMissing(name) }
          guard let item = await history.item(tensorId: tensorId, in: project) else { throw DepthMap.Failure.stepMissing(name) }
          return (item, name)
        case .failed(let message): throw DepthMap.Failure.failed(message)
        default: throw CancellationError()
        }
      }
      if let job = queue.running, job.id == id, let run = runProgress(of: job) {
        let message = if case .running(let message) = phase { message } else { "Making the depth map" }
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

  /// Runs an Extract Depth Map job on this device: reads the source image from the job's own
  /// project, estimates its depth with the engine (`GenerationEngine.depthMap(image:)`), and saves
  /// the map as a new step after the source with the source as its input and `DepthMap.Record`
  /// in its profile, as `run(_:request:job:)` does for Match Colors to Original. The estimate
  /// reports no steps of its own, so progress moves by phase (of 1,000). In a task, so finishing
  /// never runs the next job from inside `runNext`; tracked, so Stop and Delete Project reach it.
  func runDepthMap(_ depth: DepthMap.Job, request queued: GenerationEngine.Request, job: JobQueue.Job) {
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
        if project === history.project, let listed = history.item(tensorId: depth.sourceTensorId) {
          item = listed
        } else {
          let tree = await project.read { $0.tree() }
          guard let found = tree.step(tensorId: depth.sourceTensorId).flatMap({ tree.items[$0] }) else {
            throw DepthMap.Failure.stepMissing(project.name)
          }
          item = found
        }
        guard !item.isVideo, let imageTensorId = item.imageTensorId else { throw DepthMap.Failure.video }
        guard let source = await project.read({ $0.image(tensorId: imageTensorId) }) else { throw DepthMap.Failure.unreadable }
        try Task.checkCancellation()
        setRunMessage("Estimating depth…", job)
        setRunStep(100, job)
        let output = try await engine.depthMap(image: source)
        guard let made = output.frames.first.flatMap(ImageTensor.cgImage(from:)) else { throw DepthMap.Failure.unreadable }
        try Task.checkCancellation()
        setRunMessage("Saving…", job)
        setRunStep(900, job)
        var request = queued
        SettingsRegistry.apply(dump: item.sidecar.configuration, to: &request.configuration)
        request.configuration.width = made.width
        request.configuration.height = made.height
        // The source is the step's input, so it's the result's parent and Use Settings puts it
        // back on the canvas.
        request.canvas = source
        request.canvasTensorId = item.tensorId
        request.canvasIsImported = false
        request.parentTensorId = HistoryStore.tip(of: item)
        request.moodboard = []
        let followsRun = { self.canvasFollowsRun && job.id == self.foregroundJobID && self.jobProjectIsOpen(job) }
        let history = history
        let (saved, into) = try await oneSaveAtATime {
          // Found again now: a rename since it started closed the project it read from
          // (`renameCurrent`), and the job follows it to the new name.
          let into = try self.project(for: job)
          let saved = try await history.save(
            output, request: request, startedAt: startedAt, finishedAt: Date(),
            into: into, makeCurrent: followsRun)
          return (saved, into)
        }
        setRunStep(1_000, job)
        if into === history.project { landSavedImage(made, tensorId: saved.tensorId, onCanvas: followsRun()) }
        if let failure = await history.writeToOutputFolder(saved, image: made, in: into) { errorMessage = failure }
        saveSession()
        FinishedNotice.post(prompt: "Depth map", seconds: Date().timeIntervalSince(startedAt), title: "Depth map made")
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
}
