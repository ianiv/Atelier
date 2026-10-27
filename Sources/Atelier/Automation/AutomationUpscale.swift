#if os(macOS)
import SwiftUI

extension Automation {
  /// Upscales a clip already in the project (the one with the fewest frames, then the smallest,
  /// or `--clip STEP_TENSOR_ID`) and prints how long it took and what came out. With
  /// `--export DIR`, writes the result as an MP4 there.
  ///
  ///   Atelier --upscale-check --project NAME [--method seedVR2|system] [--scale 2]
  ///           [--seedvr2 FILE] [--clip ID] [--frames N] [--export DIR]
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
      let method = value("--method").flatMap(ClipUpscale.Method.init(rawValue:)) ?? .seedVR2
      let scale = value("--scale").flatMap(Int.init) ?? 2
      let seedVR2 =
        value("--seedvr2")
        ?? model.models.map(\.file).filter(ClipUpscale.isSeedVR2).sorted().last ?? ""
      log(
        "source \(source.tensorId): \(clip.frames.count) frames, \(source.sidecar.width)x\(source.sidecar.height), \(source.sidecar.model)"
      )
      if let problem = ClipUpscale.problem(
        width: source.sidecar.width, height: source.sidecar.height, scale: scale, method: method)
      {
        log("FAIL \(problem)")
        return finish()
      }
      log("upscaling \(scale)x with \(method == .seedVR2 ? seedVR2 : "Apple Super Resolution")")
      let before = model.queue.recent.count
      let upscaleStarted = Date()
      let frameLimit = value("--frames").flatMap(Int.init)
      await model.upscale(
        source, method: method, scale: scale, seedVR2: seedVR2, frameLimit: frameLimit)
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
}
#endif
