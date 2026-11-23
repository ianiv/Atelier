#if os(macOS)
import CoreGraphics
import Foundation
@preconcurrency import NNC

extension Automation {
  /// `--reference-video-check --model FILE --project NAME [--steps N] [--quit]` checks H3
  /// Ref2VA's reference video (`ReferenceVideo`) with real runs, as PASS/FAIL lines. FILE is an H3
  /// Ref2VA model. In the scratch project it makes a 22-frame clip at 256×256 (Generate mode, a
  /// synthetic moodboard image as Picture 1, which Ref2VA needs), puts it on the canvas in Edit
  /// and checks: it's the reference clip, labelled Video 1; an audio file, Strength 50% and a
  /// Length of 5 each disable Generate with a reason; the moodboard image is still Picture 1;
  /// `screenRequest()` names the clip and sends no canvas image; generate's `reference_video`
  /// refuses what the screen refuses; the queued job comes back from a saved queue with its clip
  /// in its own project only; and a run with the reference reads its frames when it starts and
  /// makes 22 frames after the clip, the engine given the clip as a 22-frame tensor. Steps default
  /// to 2. `--probe-no-pictures` then runs once more with an empty moodboard and logs what
  /// happens (the distilled Ref2VA models need a picture), as no PASS or FAIL.
  static func referenceVideoCheck(_ model: CreateModel, presets: PresetStore) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    Task { @MainActor in
      let started = Date()
      var failures = 0
      func log(_ message: String) {
        print(String(format: "[%7.2fs] ", Date().timeIntervalSince(started)) + message)
        fflush(stdout)
      }
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(message)")
      }
      @MainActor func finish() {
        log(failures == 0 ? "reference video check: all passed" : "reference video check: \(failures) failed")
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
          if Date() > deadline { return false }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return true
      }
      /// The job Generate just queued: it may first wait for History to record the moodboard.
      @MainActor func queuedJob(after known: Set<UUID>) async -> JobQueue.Job? {
        var job: JobQueue.Job?
        _ = await wait(seconds: 30) {
          job = ([model.queue.running].compactMap(\.self) + model.queue.waiting + model.queue.recent).first { !known.contains($0.id) }
          return job != nil
        }
        return job
      }
      @MainActor func knownJobs() -> Set<UUID> {
        Set(([model.queue.running].compactMap(\.self) + model.queue.waiting + model.queue.recent).map(\.id))
      }
      /// Waits for job `id` to end; its saved item when it finished.
      @MainActor func result(of id: UUID?) async -> HistoryItem? {
        guard let id else { return nil }
        _ = await wait(seconds: 1800) { model.queue.recent.contains { $0.id == id } }
        let status = model.queue.recent.first { $0.id == id }?.status
        guard case .finished(let tensorId)? = status else {
          log("job ended: \(status.map { "\($0)" } ?? "never") \(model.errorMessage ?? "")")
          return nil
        }
        return model.history.item(tensorId: tensorId)
      }

      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let file = value("--model") else {
        log("FAIL pass --model with an H3 Ref2VA model")
        return finish()
      }
      model.selectedModel = file
      _ = await wait(seconds: 120) { !model.isLoadingModel && model.settings != nil }
      model.resetToModelDefaults(undoManager: nil)
      guard model.videoModel?.takesReferences == true, var settings = model.settings, let video = model.videoModel else {
        log("FAIL \(file) isn't an H3 Ref2VA model")
        return finish()
      }
      log("model \(file), project \(model.history.project.name)")
      let steps = value("--steps").flatMap(Int.init) ?? 2
      settings.steps = steps
      settings.width = 256
      settings.height = 256
      settings.strength = 1
      settings.numFrames = video.snapped(ReferenceVideo.minimumFrames)
      model.settings = settings
      model.audio.clear()
      model.seedLocked = true
      model.seed = 7
      model.count = 1

      // Ref2VA needs a reference image: a synthetic one, Picture 1 in both runs.
      let context = CGContext(
        data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
      context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
      context.fillEllipse(in: CGRect(x: 64, y: 64, width: 128, height: 128))
      model.moodboard.removeAll()
      model.moodboard.add(context.makeImage()!)

      // The clip: text and Picture 1 only.
      model.canvasMode = .generate
      model.prompt = "A blue ball rolls slowly across a red table, like the ball in Picture 1."
      check(model.referenceClip == nil && model.screenRequest()?.referenceVideo == nil, "Generate mode sends no reference video")
      let clipStart = Date()
      var known = knownJobs()
      model.generate()
      guard let clip = await result(of: await queuedJob(after: known)?.id), clip.isVideo else {
        log("FAIL the clip wasn't made")
        return finish()
      }
      log(String(format: "clip %lld: %d frames in %.1f s", clip.tensorId, clip.clip?.frames.count ?? 0, Date().timeIntervalSince(clipStart)))
      check(clip.clip?.frames.count == ReferenceVideo.minimumFrames, "the clip has \(ReferenceVideo.minimumFrames) frames (\(clip.clip?.frames.count ?? 0))")
      if model.canvasClip?.tensorId != clip.tensorId { model.use(clip, restoreInput: false) }
      _ = await wait(seconds: 10) { model.canvasClip?.tensorId == clip.tensorId }
      // Use brings back the clip's settings; the next run is the same size and length.
      model.settings = settings
      model.canvasMode = .edit
      check(model.referenceClip?.tensorId == clip.tensorId, "in Edit, the clip on the canvas is the reference video")
      check(model.referenceVideoProblem == nil && model.canGenerate, "Generate can take it (\(model.referenceVideoProblem ?? "no problem"))")

      // What the settings can't take disables Generate, with a reason.
      try? model.audio.set(
        samples: Tensor<Float>(Array(repeating: 0, count: 16_000), .CPU, .NC(1, 16_000)), sampleRate: 16_000, name: "silence.wav")
      check(
        model.audio.url != nil && !model.canGenerate && model.referenceVideoProblem?.contains("audio") == true,
        "an audio file disables Generate (\(model.referenceVideoProblem ?? "no problem"))")
      model.audio.clear()
      var changed = settings
      changed.strength = 0.5
      model.settings = changed
      check(!model.canGenerate && model.referenceVideoProblem?.contains("Strength") == true, "Strength 50% disables Generate (\(model.referenceVideoProblem ?? "no problem"))")
      changed = settings
      changed.numFrames = 5
      model.settings = changed
      check(!model.canGenerate && model.referenceVideoProblem?.contains("22") == true, "a Length of 5 disables Generate (\(model.referenceVideoProblem ?? "no problem"))")
      model.settings = settings
      check(model.canGenerate, "back at Strength 100% and 22 frames, Generate is on")

      // The moodboard image is Picture 1: a clip is no picture.
      let tools = AgentTools(create: model, presets: presets)
      @MainActor func structured(_ name: String, _ arguments: [String: Any] = [:]) async -> (result: [String: Any], error: String?) {
        do {
          let answer = try await tools.call(name, arguments: arguments) { _ in }
          if let structured = answer["structuredContent"] as? [String: Any] { return (structured, nil) }
          let text = ((answer["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "{}"
          let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
          return (json ?? [:], nil)
        } catch {
          return ([:], error.localizedDescription)
        }
      }
      let board = await structured("get_moodboard").result
      let picture = ((board["images"] as? [[String: Any]])?.first?["picture"] as? NSNumber)?.intValue
      check(picture == 1, "the moodboard image is Picture 1 (\(picture.map(String.init) ?? "none"))")
      let screen = await structured("get_create_screen").result
      let reference = screen["reference_video"] as? [String: Any]
      check(
        (reference?["history_step"] as? NSNumber)?.int64Value == clip.id.logicalTime
          && (reference?["frames"] as? NSNumber)?.intValue == ReferenceVideo.minimumFrames,
        "get_create_screen names the reference video (\(reference.map { "\($0)" } ?? "none"))")

      // The request names the clip and sends no canvas image; its frames come when it starts.
      let request = model.screenRequest()
      check(
        request?.referenceVideo?.sourceTensorId == clip.tensorId && request?.referenceVideo?.frames.isEmpty == true
          && request?.canvas == nil && request?.moodboard.count == 1,
        "screenRequest sends the clip as the reference video, no canvas, the moodboard image")

      // generate's reference_video refuses what the screen refuses, before running anything.
      let step = Int(clip.id.logicalTime)
      let base: [String: Any] = [
        "prompt": "x", "model": file, "width": 256, "height": 256, "steps": steps, "num_frames": 22,
        "reference_video": ["history_step": step],
      ]
      @MainActor func refusal(_ extra: [String: Any]) async -> String? {
        await structured("generate", base.merging(extra) { _, new in new }).error
      }
      let jobsBefore = model.queue.recent.count
      let short = await refusal(["num_frames": 5])
      check(short?.contains("num_frames") == true, "reference_video with num_frames 5 is refused (\(short ?? "ran"))")
      let partial = await refusal(["strength": 0.5])
      check(partial?.contains("strength") == true, "reference_video with strength 0.5 is refused (\(partial ?? "ran"))")
      let image = await refusal(["input_image": "data:image/png;base64," + (ImageTensor.png(context.makeImage()!)?.base64EncodedString() ?? "")])
      check(image?.contains("input_image") == true, "reference_video with input_image is refused (\(image ?? "ran"))")
      let still = model.history.items.first { !$0.isVideo && !$0.isEntry }
      if let still {
        let notVideo = await refusal(["reference_video": ["history_step": Int(still.id.logicalTime)]])
        check(notVideo?.contains("not a video") == true, "reference_video naming an image is refused (\(notVideo ?? "ran"))")
      }
      check(model.queue.recent.count == jobsBefore && model.queue.isEmpty, "nothing was queued by the refusals")
      let listed = (try? await tools.call("list_models", arguments: [:]) { _ in })
        .flatMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
        .flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [[String: Any]] }
      let inputs = listed?.first { $0["file"] as? String == file }?["video_inputs"] as? [String]
      check(inputs?.contains("reference_video") == true, "list_models says it takes a reference_video (\(inputs ?? []))")

      // Queued and saved, it comes back with its clip in its own project only.
      model.setQueuePaused(true)
      known = knownJobs()
      model.generate()
      let queued = await queuedJob(after: known)
      check(queued?.request?.referenceVideo?.sourceTensorId == clip.tensorId, "the queued job keeps the clip, not its frames")
      if let queued {
        let folder = URL.temporaryDirectory.appending(path: "Atelier-ReferenceVideoCheck-\(UUID().uuidString)", directoryHint: .isDirectory)
        SavedQueue.save([queued], project: model.history.project.name, in: folder)
        let restored = await model.savedRequests(SavedQueue.load(project: model.history.project.name, from: folder))
        check(
          restored.count == 1 && restored.first?.referenceVideo?.sourceTensorId == clip.tensorId
            && restored.first?.referenceVideo?.project == model.history.project.name,
          "a saved queue brings the job back with its clip")
        SavedQueue.save([queued], project: model.history.project.name, in: folder)
        check(SavedQueue.load(project: "Another Project", from: folder).isEmpty, "but not in another project")
        try? FileManager.default.removeItem(at: folder)
      }

      // The run: frames read as it starts, 22 frames after the clip.
      var sawReading = false
      let runStart = Date()
      model.setQueuePaused(false)
      let id = queued?.id
      let watcher = Task { @MainActor in
        while !Task.isCancelled {
          if case .running(let message) = model.phase, message.hasPrefix("Reading") { sawReading = true }
          try? await Task.sleep(for: .milliseconds(20))
        }
      }
      let made = await result(of: id)
      watcher.cancel()
      log(String(format: "reference run: %.1f s", Date().timeIntervalSince(runStart)))
      check(sawReading, "the job read the clip's frames when it started")
      check(made?.isVideo == true && made?.clip?.frames.count == ReferenceVideo.minimumFrames, "the run made \(ReferenceVideo.minimumFrames) frames (\(made?.clip?.frames.count ?? 0))")
      if let made {
        let parent = model.history.parent(of: made)
        check(parent?.tensorId == clip.tensorId, "it follows the clip (parent \(parent.map { "\($0.tensorId)" } ?? "none"))")
        check(made.inputTensorId == nil, "the result records no input image")
      }
      let shape = await model.engine.lastVideoImageShape
      check(shape == [ReferenceVideo.minimumFrames, 256, 256, 3], "the engine got the clip as a 22-frame tensor (\(shape.map { "\($0)" } ?? "none"))")
      model.moodboard.removeAll()
      if args.contains("--probe-no-pictures") {
        // Only the reference video: what the model makes of it is logged, not judged.
        _ = await wait(seconds: 10) { !model.isRunning }
        if model.canvasClip?.tensorId != clip.tensorId { model.use(clip, restoreInput: false) }
        _ = await wait(seconds: 10) { model.canvasClip?.tensorId == clip.tensorId }
        model.settings = settings
        model.canvasMode = .edit
        known = knownJobs()
        model.generate()
        let probe = await queuedJob(after: known)
        let probed = await result(of: probe?.id)
        let status = model.queue.recent.first { $0.id == probe?.id }?.status
        log("probe, no pictures: \(probed.map { "made \($0.clip?.frames.count ?? 0) frames" } ?? "no result") (status \(status.map { "\($0)" } ?? "none"), error \(model.errorMessage ?? "none"))")
      }
      finish()
    }
  }
}
#endif
