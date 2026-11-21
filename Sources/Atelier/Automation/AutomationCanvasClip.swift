#if os(macOS)
import AVFoundation
import Foundation
import SwiftUI

/// `--canvas-clip-check --project NAME [--snapshot-dir DIR] [--quit]` checks the Create canvas's
/// shared clip player and opening videos from History, as PASS/FAIL lines: a picked clip shows its
/// first frame straight from the project (no video file is written first), picking another
/// drops the previous clip (the old one never stands in for the new one), playing keeps up with
/// the clip's frame rate, pause, seeking and the frame steps land on the right frame, a quick pick of B then C ends
/// on C, and opening a video made from an input image (History's double-click) shows the clip
/// rather than its input still, while a rerun and an image edit step still bring back their input
/// in Edit mode. It picks the project's shortest clips itself. The project needs at least three
/// video clips (five for the quick-switch part), including one made from an input image. It writes
/// nothing to the project, but run it on a scratch copy anyway (`--project` with a copy of a video
/// project's `.sqlite3`, `-wal` and `-shm`). `--snapshot-dir` saves window shots while playing
/// and after.
extension Automation {
  static func canvasClipCheck(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore
  ) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    let snapshotDir = value("--snapshot-dir").map { URL(fileURLWithPath: $0) }
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
        log(failures == 0 ? "canvas clip check: all passed" : "canvas clip check: \(failures) failed")
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
      navigation.section = .create
      ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
      let playback = model.canvasPlayback
      let originalMode = model.canvasMode
      defer { model.canvasMode = originalMode }
      func name(_ item: HistoryItem) -> String { "\(item.tensorId)" }
      @MainActor func shown() -> String { playback.shownFrameTensorId.map(String.init) ?? "none" }
      /// Waits for `item`'s frame `index` to be on screen; the time it took, nil if it never was.
      @MainActor func waitForFrame(_ index: Int, of item: HistoryItem, seconds: Double = 5) async -> Double? {
        let start = Date()
        let id = item.clip?.frames[index]
        guard await wait(seconds: seconds, until: { playback.shownFrameTensorId == id }) else { return nil }
        return Date().timeIntervalSince(start)
      }

      let videos = model.history.items.filter { $0.isVideo && model.canUse($0) }
      log("project \(model.history.project.name): \(videos.count) usable clips")
      guard videos.count >= 3 else {
        log("FAIL need at least three usable clips")
        return finish()
      }
      let picks = videos.sorted { ($0.clip?.frames.count ?? 0) < ($1.clip?.frames.count ?? 0) }
      let a = picks[0], b = picks[1], c = picks[2]
      log("A \(name(a)) (\(a.clip?.frames.count ?? 0) frames), B \(name(b)) (\(b.clip?.frames.count ?? 0), audio \(b.clip?.audioId != nil)), C \(name(c)) (\(c.clip?.frames.count ?? 0))")

      // Picking clips, as the strip does.
      model.use(a, restoreInput: false)
      let aFirst = await waitForFrame(0, of: a)
      check(aFirst.map { $0 < 1 } ?? false, "A's first frame shows from the project (\(aFirst.map { String(format: "%.0f ms", $0 * 1000) } ?? "never"))")
      check(model.canvasClip?.tensorId == a.tensorId, "the canvas clip is A")
      try? await Task.sleep(for: .milliseconds(500))

      model.use(b, restoreInput: false)
      // Watch the load: A's frames must never stand in for B.
      let aFrames = Set(a.clip?.frames ?? [])
      var staleSamples = 0, samples = 0
      let bFirstId = b.clip?.frames.first
      let loadedB = await wait(seconds: 5) {
        samples += 1
        if let id = playback.shownFrameTensorId, aFrames.contains(id) { staleSamples += 1 }
        return playback.shownFrameTensorId == bFirstId
      }
      check(loadedB, "B's first frame shows after A (\(samples) samples of 20 ms)")
      // The first sample comes before the view has re-rendered with B (its task resets then).
      check(staleSamples <= 1, "A's frame stayed up for \(staleSamples) of \(samples) samples while B loaded")

      // Playing: the clock runs and the picture keeps up with it.
      playback.play()
      var seen = Set<Int64>()
      let playStart = Date()
      while Date().timeIntervalSince(playStart) < 2 {
        if let id = playback.shownFrameTensorId { seen.insert(id) }
        try? await Task.sleep(for: .milliseconds(10))
      }
      // A clip shorter than 2 s has only so many frames to show.
      let expected = min(Int(2 * playback.framesPerSecond), b.clip?.frames.count ?? Int.max)
      log("played 2 s: time \(String(format: "%.2f", playback.time)) s, \(seen.count) distinct frames of \(expected)")
      check(playback.isPlaying && playback.time > 0.5, "B plays (time \(String(format: "%.2f", playback.time)))")
      check(seen.count >= expected * 3 / 4, "the picture keeps up: \(seen.count) of \(expected) frames shown in 2 s")
      if let snapshotDir {
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        snapshot(to: snapshotDir.appendingPathComponent("playing.png"))
      }
      playback.pause()
      let pausedAt = playback.time
      try? await Task.sleep(for: .milliseconds(500))
      check(!playback.isPlaying && playback.time == pausedAt, "pause holds the time (\(String(format: "%.2f", pausedAt)))")
      let count = b.clip?.frames.count ?? 1
      let target = count / 2
      playback.seek(to: Double(target) / playback.framesPerSecond + 0.001)
      let seekTime = await waitForFrame(target, of: b)
      check(seekTime != nil, "seeking while paused shows frame \(target) (\(seekTime.map { String(format: "%.0f ms", $0 * 1000) } ?? "shown \(shown())"))")
      check(playback.pauseOnFrame(count: count) == target, "the frame on screen is the one Use This Frame takes")
      playback.step(1)
      check(await waitForFrame(target + 1, of: b) != nil, "Next Frame shows frame \(target + 1) (\(shown()))")
      playback.step(-1)
      playback.step(-1)
      check(await waitForFrame(target - 1, of: b) != nil, "Previous Frame twice shows frame \(target - 1) (\(shown()))")
      check(playback.pauseOnFrame(count: count) == target - 1, "Use This Frame takes the stepped-to frame")
      playback.seek(to: 0)
      playback.step(-1)
      check(await waitForFrame(0, of: b) != nil, "Previous Frame stops at the first frame (\(shown()))")

      // Quick B then C: the next two clips.
      guard picks.count >= 5 else {
        log("only \(picks.count) clips: quick switch skipped")
        return finish()
      }
      let b2 = picks[3], c2 = picks[4]
      log("quick switch: B \(name(b2)) then C \(name(c2))")
      model.use(b2, restoreInput: false)
      try? await Task.sleep(for: .milliseconds(150))
      model.use(c2, restoreInput: false)
      let cFirst = await waitForFrame(0, of: c2)
      check(cFirst != nil, "C's first frame shows")
      try? await Task.sleep(for: .seconds(1))
      check(playback.loadedTensorId == c2.tensorId, "a second later the canvas still has C (loaded \(playback.loadedTensorId.map(String.init) ?? "nil"))")
      check(playback.shownFrameTensorId == c2.clip?.frames.first, "and shows C's first frame (\(shown()))")
      check(model.canvasClip?.tensorId == c2.tensorId, "the canvas clip is C")
      if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent("c.png")) }

      // Opening from History, as `HistoryView.use` does: restoreInput is `newSeed || !item.isVideo`.
      if let made = videos.first(where: { $0.inputTensorId != nil }) {
        model.canvasMode = .generate
        log("video with input: \(name(made)) from input \(made.inputTensorId!)")
        let newSeed = false
        model.use(made, newSeed: newSeed, restoreInput: newSeed || !made.isVideo)
        navigation.section = .create
        try? await Task.sleep(for: .seconds(2))
        check(model.canvasClip?.tensorId == made.tensorId, "History open: the canvas clip is the video (\(model.canvasClip.map(name) ?? "nil"))")
        check(model.canvasMode != .edit, "History open: not in Edit mode (\(model.canvasMode))")
        log("current \(model.history.currentTensorId.map(String.init) ?? "nil"), clip frames first \(made.clip?.frames.first ?? 0) last \(made.clip?.frames.last ?? 0)")
        check(model.history.currentTensorId != made.inputTensorId, "History open: the input isn't current")
        check(await waitForFrame(0, of: made) != nil, "History open: the clip shows (\(shown()), playing \(playback.isPlaying))")
        if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent("history-open.png")) }

        // A rerun (newSeed true) passes restoreInput true: that path restores the input.
        model.canvasMode = .generate
        model.use(made, newSeed: false, restoreInput: true)
        let restored = await wait(seconds: 20) { model.history.currentTensorId == made.inputTensorId }
        check(restored, "restoreInput brings back the input (current \(model.history.currentTensorId.map(String.init) ?? "nil"))")
        try? await Task.sleep(for: .milliseconds(500))
        check(model.canvasMode == .edit && model.canvasClip == nil, "restoreInput: Edit mode, still on the canvas")
      } else {
        log("FAIL no video with an input image in the project")
        failures += 1
      }
      // Image edit steps: restoreInput stays true (not video).
      if let edit = model.history.items.first(where: { !$0.isVideo && $0.inputTensorId != nil && model.canUse($0) }) {
        model.canvasMode = .generate
        let newSeed = false
        model.use(edit, newSeed: newSeed, restoreInput: newSeed || !edit.isVideo)
        let restored = await wait(seconds: 20) { model.history.currentTensorId == edit.inputTensorId }
        try? await Task.sleep(for: .milliseconds(500))
        check(restored && model.canvasMode == .edit, "image edit step opens its input in Edit mode")
      } else {
        log("no image edit step in the project; skipped")
      }
      finish()
    }
  }
}
#endif
