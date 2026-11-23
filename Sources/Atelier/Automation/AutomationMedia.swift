#if os(macOS)
import AVFoundation
import CoreGraphics
import Foundation

extension Automation {
  /// `--reference-video-check --imported --model FILE --project NAME [--steps N] [--quit]`
  /// checks videos brought in from outside (`Media`) with real runs, as PASS/FAIL lines. FILE is an
  /// H3 Ref2VA model. It writes a 12 s, 30 fps, 640×360 movie, imports it into the scratch project
  /// and checks: the file is in the media folder at its size (and whether the volume clones);
  /// it's listed as an Imported video of 360 frames, current, playing on the canvas; in Edit it's
  /// the reference video; a 22-frame, 2-step run with it follows the imported step and the engine
  /// gets a 22-frame tensor; with its file gone the run says so; a second import started while
  /// one copies leaves one step; with a model that isn't Ref2VA a video still imports; and
  /// deleting the step removes its file.
  static func referenceVideoImportCheck(_ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore) {
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
        log(failures == 0 ? "imported video check: all passed" : "imported video check: \(failures) failed")
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
      @MainActor func jobs() -> Set<UUID> {
        Set(([model.queue.running].compactMap(\.self) + model.queue.waiting + model.queue.recent).map(\.id))
      }
      /// Generates from the screen and waits: the saved item, or the job's error.
      @MainActor func generate() async -> (item: HistoryItem?, error: String?) {
        let known = jobs()
        model.generate()
        var job: JobQueue.Job?
        _ = await wait(seconds: 30) {
          job = ([model.queue.running].compactMap(\.self) + model.queue.waiting + model.queue.recent).first { !known.contains($0.id) }
          return job != nil
        }
        guard let id = job?.id else { return (nil, "nothing was queued") }
        _ = await wait(seconds: 1800) { model.queue.recent.contains { $0.id == id } }
        switch model.queue.recent.first(where: { $0.id == id })?.status {
        case .finished(let tensorId)?: return (model.history.item(tensorId: tensorId), nil)
        case .failed(let message)?: return (nil, message)
        case let other: return (nil, "\(other.map { "\($0)" } ?? "never ended")")
        }
      }
      @MainActor func imported() -> [HistoryItem] { model.history.items.filter(\.isImported) }

      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      navigation.section = .create
      ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
      guard let file = value("--model") else {
        log("FAIL pass --model with an H3 Ref2VA model")
        return finish()
      }
      let folder = URL.temporaryDirectory.appending(path: "Atelier-MediaCheck-\(UUID().uuidString)", directoryHint: .isDirectory)
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let movie = folder.appending(path: "Beach walk.mov")
      let writeStart = Date()
      guard (try? await writeMovie(to: movie, width: 640, height: 360, frames: 360, framesPerSecond: 30)) != nil else {
        log("FAIL couldn't write the test movie")
        return finish()
      }
      let bytes = (try? FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? NSNumber)?.int64Value ?? 0
      log(String(format: "wrote a 12 s 640×360 movie (%lld bytes) in %.1f s", bytes, Date().timeIntervalSince(writeStart)))

      // A model that isn't Ref2VA first: the video still comes in, and the mode is left alone.
      if let other = model.models.first(where: { VideoModel(model: $0.file)?.takesReferences != true && $0.file != file })?.file {
        model.selectedModel = other
        _ = await wait(seconds: 120) { !model.isLoadingModel && model.settings != nil }
        model.canvasMode = .generate
        let before = imported().count
        model.importVideo(movie, name: "Beach walk")
        check(model.statusNote == CreateModel.importingVideoNote, "the status bar says the video is copying")
        await model.videoImportFinished()
        check(imported().count == before + 1 && model.canvasMode == .generate, "with \(other) the video imports, in Generate mode")
      } else {
        log("no model other than Ref2VA ones: the non-Ref2VA import is skipped")
      }

      model.selectedModel = file
      _ = await wait(seconds: 120) { !model.isLoadingModel && model.settings != nil }
      model.resetToModelDefaults(undoManager: nil)
      guard model.videoModel?.takesReferences == true, var settings = model.settings, let video = model.videoModel else {
        log("FAIL \(file) isn't an H3 Ref2VA model")
        return finish()
      }
      log("model \(file), project \(model.history.project.name)")
      settings.steps = value("--steps").flatMap(Int.init) ?? 2
      settings.width = 256
      settings.height = 256
      settings.strength = 1
      settings.numFrames = video.snapped(ReferenceVideo.minimumFrames)
      model.settings = settings
      model.audio.clear()
      model.seedLocked = true
      model.seed = 7
      model.count = 1
      model.prompt = "A person walks along a beach like the one in <Video 1>, the ball in Picture 1 beside them."
      let context = CGContext(
        data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
      context.fillEllipse(in: CGRect(x: 64, y: 64, width: 128, height: 128))
      model.moodboard.removeAll()
      model.moodboard.add(context.makeImage()!)

      // A second import while one copies: only the second's step.
      let before = imported().count
      model.importVideo(movie, name: "First")
      model.importVideo(movie, name: "Second")
      await model.videoImportFinished()
      try? await Task.sleep(for: .milliseconds(300))
      let after = imported()
      check(after.count == before + 1 && after.first?.clip?.media?.name == "Second", "a second import mid-copy leaves one step, its own (\(after.count - before) added)")
      guard let item = after.first, let media = item.clip?.media, let mediaURL = model.history.mediaURL(of: item) else {
        log("FAIL the video wasn't imported")
        return finish()
      }

      // Stored beside the project.
      let stored = (try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size] as? NSNumber)?.int64Value
      check(stored == bytes && media.bytes == bytes, "the file is in the media folder at its size (\(stored ?? -1) of \(bytes))")
      check(mediaURL.deletingLastPathComponent() == model.history.project.mediaFolder, "in \(model.history.project.mediaFolder.lastPathComponent)")
      let clones = (try? model.history.project.mediaFolder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning
      log("the volume \(clones == true ? "clones files: the copy shares the original's blocks" : "doesn't clone: it's a real copy")")
      let partials = ((try? FileManager.default.contentsOfDirectory(atPath: model.history.project.mediaFolder.path)) ?? []).filter { $0.hasSuffix(".partial") }
      check(partials.isEmpty, "no half-copied file is left (\(partials.count))")

      // Listed, current, on the canvas.
      check(item.isImported && item.clip?.frameCount == 360 && abs((item.clip?.framesPerSecond ?? 0) - 30) < 0.5, "listed as an Imported video of 360 frames at 30 fps (\(item.clip?.frameCount ?? 0))")
      check(media.width == 640 && media.height == 360 && !media.hasAudio, "at 640×360, silent")
      check(model.history.currentTensorId == item.tensorId, "it's the current step")
      check(!model.canUse(item), "it has no settings to use")
      check(TimelineStore.entry(for: item) == nil, "the Video Editor doesn't take it")
      _ = await wait(seconds: 10) { model.canvasClip?.tensorId == item.tensorId }
      check(model.canvasClip?.tensorId == item.tensorId, "it plays on the canvas")
      let playback = model.canvasPlayback
      let shown = await wait(seconds: 15) { playback.isReady(for: item.tensorId) && playback.frame != nil }
      check(shown, "the canvas shows a frame from the file")
      playback.play()
      let played = await wait(seconds: 10) { playback.time > 0.5 }
      check(played && playback.isPlaying, "and plays (\(String(format: "%.2f", playback.time)) s)")
      playback.pause()
      let frame = await model.history.frame(200, of: item)
      check(frame?.width == 640 && frame?.height == 360, "a frame decodes from the file at its size")

      // The reference video.
      check(model.canvasMode == .edit && model.referenceClip?.tensorId == item.tensorId, "with Ref2VA it's the reference video, in Edit")
      check(model.screenRequest()?.referenceVideo?.sourceTensorId == item.tensorId, "Generate sends it as the reference")
      let run = await generate()
      check(run.item?.clip?.frames.count == ReferenceVideo.minimumFrames, "a run with it makes 22 frames (\(run.error ?? "ok"))")
      if let made = run.item {
        check(model.history.parent(of: made)?.tensorId == item.tensorId, "it follows the imported step")
      }
      let shape = await model.engine.lastVideoImageShape
      // 640×360 keeps its shape: 1344×768 on MiniMax's canvas, whatever the 256×256 output.
      check(shape == [ReferenceVideo.minimumFrames, 768, 1344, 3], "the engine got the video as 22 frames at 1344×768, its own shape (\(shape.map { "\($0)" } ?? "none"))")

      // With its file gone the run says so.
      model.show(item)
      _ = await wait(seconds: 10) { model.canvasClip?.tensorId == item.tensorId }
      model.canvasMode = .edit
      let aside = folder.appending(path: "aside.mov")
      try? FileManager.default.moveItem(at: mediaURL, to: aside)
      let missing = await generate()
      check(missing.item == nil && missing.error?.contains("missing") == true, "with the file gone the run says so (\(missing.error ?? "ran"))")
      try? FileManager.default.moveItem(at: aside, to: mediaURL)

      // Deleting the step removes its file.
      let others = imported().filter { $0.tensorId != item.tensorId }
      try? await model.deleteHistoryItems([item] + others)
      try? await Task.sleep(for: .milliseconds(300))
      check(!FileManager.default.fileExists(atPath: mediaURL.path), "deleting the step removes its file")
      let left = (try? FileManager.default.contentsOfDirectory(atPath: model.history.project.mediaFolder.path)) ?? []
      check(left.isEmpty, "and the media folder is empty (\(left.count) left)")
      model.moodboard.removeAll()
      finish()
    }
  }

  /// `--reference-video-run --model FILE --video FILE --project NAME [--image FILE] [--prompt-file FILE]
  /// [--width W --height H] [--frames N] [--steps N] [--frames-dir DIR] [--quit]` makes one H3
  /// Ref2VA video from a video file of the user's: imports it into the scratch project, puts
  /// `--image` on the moodboard (Picture 1), and runs with the model's own settings but for the
  /// size, length and (only when given) steps. It prints the reference's frame count and canvas
  /// size as the engine got them, the step and how long it took, and writes frames 0, the middle
  /// and the last of the result as PNGs to `--frames-dir`.
  static func referenceVideoRun(_ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    Task { @MainActor in
      let started = Date()
      func log(_ message: String) {
        print(String(format: "[%7.2fs] ", Date().timeIntervalSince(started)) + message)
        fflush(stdout)
      }
      @MainActor func finish(_ ok: Bool) {
        log(ok ? "reference video run: done" : "reference video run: FAIL")
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
          if Date() > deadline { return false }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return true
      }
      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      navigation.section = .create
      ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
      guard let file = value("--model"), let videoPath = value("--video") else {
        log("FAIL pass --model and --video")
        return finish(false)
      }
      model.selectedModel = file
      _ = await wait(seconds: 120) { !model.isLoadingModel && model.settings != nil }
      model.resetToModelDefaults(undoManager: nil)
      guard model.videoModel?.takesReferences == true, var settings = model.settings, let video = model.videoModel else {
        log("FAIL \(file) isn't an H3 Ref2VA model")
        return finish(false)
      }
      if let width = value("--width").flatMap(Int.init) { settings.width = width }
      if let height = value("--height").flatMap(Int.init) { settings.height = height }
      if let frames = value("--frames").flatMap(Int.init) { settings.numFrames = video.snapped(frames) }
      if let steps = value("--steps").flatMap(Int.init) { settings.steps = steps }
      settings.strength = 1
      model.settings = settings
      model.audio.clear()
      model.count = 1
      if let path = value("--prompt-file"), let prompt = try? String(contentsOfFile: path, encoding: .utf8) {
        model.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      model.moodboard.removeAll()
      if let path = value("--image") {
        guard let image = ImageLoader.image(at: URL(fileURLWithPath: path)) else {
          log("FAIL couldn't read \(path)")
          return finish(false)
        }
        model.moodboard.add(ImageLoader.fitted(image, maxSide: Moodboard.maxSide))
      }
      let url = URL(fileURLWithPath: videoPath)
      model.importVideo(url, name: url.deletingPathExtension().lastPathComponent)
      await model.videoImportFinished()
      guard let item = model.history.items.first(where: \.isImported), let media = item.clip?.media else {
        log("FAIL the video wasn't imported (\(model.errorMessage ?? ""))")
        return finish(false)
      }
      log("imported “\(media.name)”: \(media.width)×\(media.height), \(media.frameCount) frames at \(String(format: "%.3f", media.framesPerSecond)) fps, step \(item.id.logicalTime)")
      model.canvasMode = .edit
      _ = await wait(seconds: 10) { model.referenceClip?.tensorId == item.tensorId }
      if let problem = model.referenceVideoProblem {
        log("FAIL \(problem)")
        return finish(false)
      }
      log("model \(file): \(settings.width)×\(settings.height), \(video.snapped(settings.numFrames)) frames, \(settings.steps) steps, sampler \(settings.sampler), seed \(model.seed)")
      let known = Set((model.queue.waiting + model.queue.recent).map(\.id))
      let runStarted = Date()
      model.generate()
      var job: JobQueue.Job?
      _ = await wait(seconds: 30) {
        job = ([model.queue.running].compactMap(\.self) + model.queue.waiting + model.queue.recent).first { !known.contains($0.id) }
        return job != nil
      }
      guard let id = job?.id else {
        log("FAIL nothing was queued")
        return finish(false)
      }
      _ = await wait(seconds: 3 * 3600) { model.queue.recent.contains { $0.id == id } }
      let seconds = Date().timeIntervalSince(runStarted)
      let shape = await model.engine.lastVideoImageShape
      log("the engine got the reference as \(shape.map { "\($0)" } ?? "none") (frames, height, width, channels)")
      guard case .finished(let tensorId)? = model.queue.recent.first(where: { $0.id == id })?.status,
            let made = model.history.item(tensorId: tensorId), let clip = made.clip
      else {
        log("FAIL the run didn't finish: \(model.errorMessage ?? "")")
        return finish(false)
      }
      log(String(format: "made step %lld (tensor %lld): %d frames in %.1f s", made.id.logicalTime, made.tensorId, clip.frames.count, seconds))
      if let directory = value("--frames-dir") {
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in Set([0, clip.frames.count / 2, clip.frames.count - 1]).sorted() {
          if let image = await model.history.frame(index, of: made), let png = ImageTensor.png(image) {
            try? png.write(to: folder.appending(path: "frame-\(index).png"))
          }
        }
        for index in [0, media.frameCount / 2] {
          if let image = await model.history.frame(index, of: item), let png = ImageTensor.png(image) {
            try? png.write(to: folder.appending(path: "source-\(index).png"))
          }
        }
        log("frames written to \(folder.path)")
      }
      finish(true)
    }
  }

  /// A movie of a colored square moving across a changing background, `frames` long.
  private static func writeMovie(to url: URL, width: Int, height: Int, frames: Int, framesPerSecond: Int32) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<frames {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
      var made: CVPixelBuffer?
      guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
      guard let buffer = made else { throw CocoaError(.fileWriteUnknown) }
      CVPixelBufferLockBaseAddress(buffer, [])
      if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let square = (index * 4) % max(width - 64, 1)
        let tone = UInt8(truncatingIfNeeded: 60 + index / 3)
        for y in 0..<height {
          let line = base + y * row
          for x in 0..<width {
            let inSquare = x >= square && x < square + 64 && y >= height / 2 - 32 && y < height / 2 + 32
            line[x * 4] = inSquare ? 30 : 200
            line[x * 4 + 1] = inSquare ? 40 : tone
            line[x * 4 + 2] = inSquare ? 220 : 120
            line[x * 4 + 3] = 255
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: framesPerSecond)) else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
      }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
  }
}
#endif
