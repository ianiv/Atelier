#if os(macOS)
import AVFoundation
import SwiftUI
import VideoToolbox

extension Automation {
  /// Upscales a clip already in the project (the one with the fewest frames, then the smallest,
  /// or `--clip STEP_TENSOR_ID`) and prints how long it took and what came out. With
  /// `--export DIR`, writes the result as an MP4 there.
  ///
  ///   Atelier --upscale-check --project NAME [--method flashVSR|system] [--scale 2]
  ///           [--variant turbo|base] [--clip ID] [--frames N] [--export DIR]
  ///           [--export-clip ID|latest] [--quit]
  static func upscaleCheck(_ model: CreateModel) {
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
      @MainActor func finish() {
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      while !model.history.isLoaded || model.models.isEmpty || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      let clips = model.history.items.filter(\.isVideo)
      // `--export-clip ID`: only export that clip (to `--export DIR`), to retry a failed export.
      // `latest` is the newest clip.
      if let wanted = value("--export-clip"), let directory = value("--export"),
        let item = wanted == "latest"
          ? clips.first : Int64(wanted).flatMap({ id in clips.first { $0.tensorId == id } })
      {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(
          "clip-\(item.tensorId).mp4")
        do {
          try await model.history.exportVideo(item, to: url)
          log("exported \(url.path)")
        } catch {
          log("FAIL export: \(error as NSError)")
        }
        return finish()
      }
      let source =
        value("--clip").flatMap(Int64.init).flatMap { id in clips.first { $0.tensorId == id } }
        ?? clips.min {
          ($0.clip!.frames.count, $0.sidecar.width * $0.sidecar.height)
            < ($1.clip!.frames.count, $1.sidecar.width * $1.sidecar.height)
        }
      guard let source, let clip = source.clip else {
        log("FAIL no clip in \(model.history.project.name)")
        return finish()
      }
      let method = value("--method").flatMap(ClipUpscale.Method.init(rawValue:)) ?? .flashVSR
      let scale = value("--scale").flatMap(Int.init) ?? 2
      let variant = value("--variant").flatMap(FlashVSRFiles.Variant.init(rawValue:)) ?? .turbo
      log(
        "source \(source.tensorId): \(clip.frames.count) frames, \(source.sidecar.width)x\(source.sidecar.height), \(source.sidecar.model)"
      )
      if let problem = ClipUpscale.problem(
        width: source.sidecar.width, height: source.sidecar.height, scale: scale, method: method,
        variant: variant)
      {
        log("FAIL \(problem)")
        return finish()
      }
      log("upscaling \(scale)x with \(method == .flashVSR ? "FlashVSR+ \(variant.title)" : "Apple Super Resolution")")
      let before = model.queue.recent.count
      let upscaleStarted = Date()
      let frameLimit = value("--frames").flatMap(Int.init)
      await model.upscale(
        source, method: method, scale: scale, variant: variant, frameLimit: frameLimit)
      var lastPhase = ""
      while model.queue.recent.count == before || !model.queue.isEmpty {
        if case .running(let text) = model.phase, text != lastPhase {
          lastPhase = text
          log(text)
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      let seconds = Date().timeIntervalSince(upscaleStarted)
      guard let job = model.queue.recent.first, case .finished(let tensorId) = job.status,
        let result = model.history.item(tensorId: tensorId), let out = result.clip
      else {
        log("FAIL \(model.queue.recent.first.map { "\($0.status)" } ?? "no job") \(model.errorMessage ?? "")")
        return finish()
      }
      log(
        String(
          format: "PASS clip %lld: %d frames at %dx%d in %.1fs (%.2fs a frame), audio %@, model %@",
          result.tensorId, out.frames.count, result.sidecar.width, result.sidecar.height, seconds,
          seconds / Double(max(out.frames.count, 1)), out.audioId == nil ? "none" : "kept",
          result.sidecar.model))
      if let directory = value("--export") {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(
          "upscale-\(method.rawValue)-\(scale)x-\(source.tensorId).mp4")
        do {
          try await model.history.exportVideo(result, to: url)
          log("exported \(url.path)")
          // The source too, once, to compare against.
          let sourceURL = URL(fileURLWithPath: directory).appendingPathComponent(
            "source-\(source.tensorId).mp4")
          if !FileManager.default.fileExists(atPath: sourceURL.path) {
            try await model.history.exportVideo(source, to: sourceURL)
            log("exported \(sourceURL.path)")
          }
        } catch {
          log("FAIL export: \(error as NSError)")
        }
      }
      finish()
    }
  }

  /// Exports the project's first timeline upscaled and prints how long it took. `--crossfade N`
  /// fades the first clip into the second over N frames and `--trim N` keeps N frames of each (the end
  /// of the first, the start of the rest), both only for the export: the saved timeline is left
  /// as it is.
  ///
  /// `--clip ID` exports that History video instead (the first `--trim` frames when given), and
  /// `--method none` exports as it is, as Export Video… does without upscaling.
  ///
  ///   Atelier --timeline-export-check --project NAME [--method none|system|flashVSR] [--scale 4]
  ///           [--variant turbo|base] [--clip ID] [--crossfade N] [--trim N] --export DIR [--quit]
  static func timelineExportCheck(_ model: CreateModel) {
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
      @MainActor func finish() {
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      while !model.history.isLoaded || model.models.isEmpty || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      model.timelines.load()
      let clip = value("--clip").flatMap(Int64.init).flatMap(model.history.item(tensorId:))
      guard var timeline = model.timelines.timelines.first, let directory = value("--export") else {
        log("FAIL no timeline in \(model.history.project.name), or no --export")
        return finish()
      }
      if let clip, let frames = clip.clip?.frames.count {
        // The video alone, as History's Export Video… makes it.
        timeline = Timeline(name: model.history.fileName(for: clip))
        let end = min(frames, value("--trim").flatMap(Int.init) ?? frames)
        timeline.entries = [Timeline.Entry(clip: clip.tensorId, start: 0, end: end)]
      } else if let trim = value("--trim").flatMap(Int.init) {
        for index in timeline.entries.indices {
          var entry = timeline.entries[index]
          if index == 0 {
            entry.start = max(entry.start, entry.end - trim)
          } else {
            entry.end = min(entry.end, entry.start + trim)
          }
          timeline.entries[index] = entry
        }
      }
      if let crossfade = value("--crossfade").flatMap(Int.init), timeline.entries.count > 1 {
        timeline.entries[0].crossfadeFrames = crossfade
      }
      let layout = TimelineLayout(timeline, item: model.history.item(tensorId:))
      let none = value("--method") == "none"
      let method = value("--method").flatMap(ClipUpscale.Method.init(rawValue:)) ?? .system
      let upscale = TimelineUpscale(
        method: method, scale: value("--scale").flatMap(Int.init) ?? (method == .system ? 4 : 2),
        variant: value("--variant").flatMap(FlashVSRFiles.Variant.init(rawValue:)) ?? .turbo)
      do {
        var files: [URL] = []
        for segment in layout.segments {
          files.append(try await model.history.videoFile(for: segment.item))
        }
        let composition: TimelineComposition
        if let clip, value("--trim") == nil {
          composition = try await TimelineComposition.make(clip: clip, history: model.history)
        } else if let made = try await TimelineComposition.make(layout, files: files) {
          composition = made
        } else {
          log("FAIL empty timeline")
          return finish()
        }
        if none {
          let url = URL(fileURLWithPath: directory).appending(
            path: "\(clip == nil ? "timeline" : "clip")-export.mp4")
          let exportStarted = Date()
          try await composition.export(to: url, codec: .current, title: timeline.name) { _ in }
          log(String(format: "PASS exported %@ (%d frames, no upscale) in %.1fs", url.path, composition.frameCount, Date().timeIntervalSince(exportStarted)))
          return finish()
        }
        let size = upscale.outputSize(width: composition.width, height: composition.height)
        log(
          "timeline \(timeline.name): \(composition.frameCount) frames at \(composition.width)x\(composition.height), runs \(composition.runs), \(method.rawValue) \(upscale.scale)x to \(size.width)x\(size.height), estimate \(Int(upscale.estimatedSeconds(frames: composition.frameCount, width: composition.width, height: composition.height)))s"
        )
        let url = URL(fileURLWithPath: directory).appending(
          path: "\(clip == nil ? "timeline" : "clip")-\(method.rawValue)-\(upscale.scale)x.mp4")
        let exportStarted = Date()
        // Through the Queue, as Export Upscaled Video… runs it.
        model.queue(
          TimelineExportJob(
            composition: composition, upscale: upscale, title: timeline.name, destination: url))
        log("queued: \(model.queue.running.map { _ in "running" } ?? "waiting"), \(model.queue.waiting.count) waiting")
        var lastTenth = -1
        while !model.queue.isEmpty {
          if model.queue.running?.export != nil, model.totalSteps > 0 {
            let tenth = model.step * 10 / model.totalSteps
            if tenth > lastTenth {
              lastTenth = tenth
              log("\(tenth * 10)% (status bar: \(model.phase))")
            }
          }
          try? await Task.sleep(for: .milliseconds(200))
        }
        guard let job = model.queue.recent.first, case .exported(let written) = job.status,
          written == url
        else {
          log("FAIL \(model.queue.recent.first.map { "\($0.status)" } ?? "no job") \(model.errorMessage ?? "")")
          return finish()
        }
        log(
          String(
            format: "PASS exported %@ in %.1fs, recent row: %@, took %@", url.path,
            Date().timeIntervalSince(exportStarted), "\(job.status)",
            job.elapsed.map { GenerationTime.text($0) } ?? "none"))
      } catch {
        log("FAIL \(error as NSError)")
      }
      finish()
    }
  }
}

extension Automation {
  /// Upscales the first frames of an MP4 with FlashVSR+ and writes the result as an MP4, with
  /// how long each part took. Reads the weights from the models folder's "FlashVSR+".
  ///
  ///   Atelier --flashvsr-check --input FILE.mp4 [--frames 33] [--variant turbo|base]
  ///           [--width 1920 --height 1152] --export DIR [--quit]
  static func flashVSRCheck() {
    let args = CommandLine.arguments
    let value: @Sendable (String) -> String? = { name in
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    let started = Date()
    let log: @Sendable (String) -> Void = { message in
      print(String(format: "[%7.2fs] ", Date().timeIntervalSince(started)) + message)
      fflush(stdout)
    }
    let finish: @Sendable () -> Void = {
      if args.contains("--quit") { Task { @MainActor in AppLifecycle.quit() } }
    }
    guard let input = value("--input"), let directory = value("--export") else {
      log("FAIL --input and --export are needed")
      return finish()
    }
    let variant = value("--variant").flatMap(FlashVSRFiles.Variant.init(rawValue:)) ?? .turbo
    guard let files = FlashVSRFiles.installed(variant) else {
      log("FAIL FlashVSR+ \(variant.rawValue) isn't in \(AppSettings.modelsDirectory)/FlashVSR+")
      return finish()
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: input))
        let reader = try AVAssetReader(asset: asset)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        nonisolated(unsafe) var fps: Double = 24
        Task {
          track = try? await asset.loadTracks(withMediaType: .video).first
          if let track, let rate = try? await track.load(.nominalFrameRate) { fps = Double(rate) }
          semaphore.signal()
        }
        semaphore.wait()
        guard let track else { throw ClipVideoError.noFrames }
        let output = AVAssetReaderTrackOutput(
          track: track,
          outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
        reader.add(output)
        reader.startReading()
        let limit = value("--frames").flatMap(Int.init) ?? 33
        var sources: [CGImage] = []
        while sources.count < limit, let sample = output.copyNextSampleBuffer(),
          let buffer = sample.imageBuffer
        {
          var image: CGImage?
          VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
          if let image, let copy = image.copy() { sources.append(copy) }
        }
        guard let first = sources.first else { throw ClipVideoError.noFrames }
        let size = FlashVSRUpscaler.outputSize(width: first.width, height: first.height)
        let width = value("--width").flatMap(Int.init) ?? size.width
        let height = value("--height").flatMap(Int.init) ?? size.height
        log("\(sources.count) frames at \(first.width)x\(first.height) -> \(width)x\(height), \(variant.rawValue)")
        let upscaler = FlashVSRUpscaler(files: files, width: width, height: height)
        var frames: [CGImage] = []
        let runStarted = Date()
        try upscaler.run(
          count: sources.count, frame: { sources[$0] },
          progress: { phase, done, total in log("\(phase) \(done)/\(total)") },
          shouldContinue: { true }
        ) { tensor in
          if let image = ImageTensor.cgImage(from: tensor) { frames.append(image) }
        }
        let seconds = Date().timeIntervalSince(runStarted)
        log(String(format: "PASS %d frames in %.1fs (%.2fs a frame)", frames.count, seconds, seconds / Double(max(frames.count, 1))))
        let url = URL(fileURLWithPath: directory).appending(
          path: "flashvsr-\(variant.rawValue)-\(width)x\(height)-\(frames.count)f.mp4")
        let written = frames
        Task {
          do {
            try await ClipVideo.write(
              to: url, count: written.count, frame: { written[$0] }, framesPerSecond: fps,
              audio: nil, audioSampleRate: 0, codec: .h264, metadata: nil)
            log("exported \(url.path)")
          } catch {
            log("FAIL export \(error)")
          }
          finish()
        }
      } catch {
        log("FAIL \(error)")
        finish()
      }
    }
  }
}

#endif
