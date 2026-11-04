#if os(macOS)
import Foundation
import SwiftUI

/// `--playback-check --project NAME [--play-seconds N] [--quit]` plays the project's first timeline
/// in the Video Editor, on screen, and checks its picture, as PASS/FAIL lines: a seek while paused
/// shows a new frame, playing keeps them coming (N seconds, default 5, printing how many), pausing
/// stops them, looping starts over and the end stops. Measure the main thread during the "playing"
/// line with `sample`. The project needs a timeline with clips: use a copy of one.
extension Automation {
  static func playbackCheck(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore
  ) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    Task { @MainActor in
      var failures = 0
      func log(_ message: String) {
        print(message)
        fflush(stdout)
      }
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(message)")
      }
      @MainActor func finish() {
        log(failures == 0 ? "playback check: all passed" : "playback check: \(failures) failed")
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
          if Date() > deadline { return false }
          try? await Task.sleep(for: .milliseconds(20))
        }
        return true
      }
      while !model.history.isLoaded || model.models.isEmpty || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      model.timelines.load()
      navigation.section = .videoEditor
      ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
      // Making the clips' video files can take minutes the first time.
      guard await wait(seconds: 900, until: { (TimelinePlayback.latest?.duration ?? 0) > 2 }),
            let playback = TimelinePlayback.latest
      else {
        log("FAIL no timeline loaded in \(model.history.project.name)")
        return finish()
      }
      log(String(format: "timeline is %.1f s", playback.duration))

      playback.seek(to: 0.5)
      check(await wait(seconds: 3) { playback.frame != nil }, "a seek while paused shows a frame")
      try? await Task.sleep(for: .milliseconds(300))
      let shown = playback.framesShown
      playback.seek(to: 1.5)
      check(await wait(seconds: 3) { playback.framesShown > shown }, "another seek shows another frame")
      check(abs(playback.time - 1.5) < 0.01, "the playhead is where the seek put it")

      let seconds = value("--play-seconds").flatMap(Double.init) ?? 5
      playback.seek(to: 0)
      try? await Task.sleep(for: .milliseconds(300))
      let before = playback.framesShown
      playback.play()
      log("playing for \(seconds) s")
      try? await Task.sleep(for: .seconds(seconds))
      let frames = playback.framesShown - before
      log(String(format: "%d frames in %.0f s, %.1f a second, at %.2f s", frames, seconds, Double(frames) / seconds, playback.time))
      // Clips run from 16 fps up.
      check(Double(frames) / seconds > 10, "playing keeps frames coming")
      check(abs(playback.time - seconds) < 0.5, "the playhead follows the video")

      playback.pause()
      try? await Task.sleep(for: .milliseconds(300))
      let paused = playback.framesShown
      try? await Task.sleep(for: .milliseconds(500))
      check(playback.framesShown == paused, "pausing stops the frames")

      playback.isLooping = true
      playback.seek(to: playback.duration - 0.5)
      playback.play()
      let looped = await wait(seconds: 5) { playback.time < 0.4 && playback.isPlaying }
      check(looped, "looping starts over at the end")
      let afterLoop = playback.framesShown
      try? await Task.sleep(for: .seconds(1))
      check(playback.framesShown > afterLoop, "frames keep coming after looping")
      playback.isLooping = false
      playback.seek(to: playback.duration - 0.5)
      check(await wait(seconds: 5) { !playback.isPlaying }, "without looping it stops at the end")
      check(abs(playback.time - playback.duration) < 0.01, "and the playhead stays at the end")
      finish()
    }
  }
}
#endif
