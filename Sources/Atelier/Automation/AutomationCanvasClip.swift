#if os(macOS)
import AVFoundation
import Foundation
import SwiftUI

/// `--canvas-clip-check --project NAME [--snapshot-dir DIR] [--quit]` checks the Create canvas's
/// shared clip player and opening videos from History, as PASS/FAIL lines: picking another clip
/// drops the previous video while the next one loads (the old clip never stands in for the new
/// one), a quick pick of B then C ends on C even after B's encode finishes, and opening a video
/// made from an input image (History's double-click) shows the clip rather than its input still,
/// while a rerun and an image edit step still bring back their input in Edit mode. It picks the
/// project's shortest clips itself. The project needs at least three video clips (five for the
/// quick-switch part), including one made from an input image. Run it on a scratch copy: copy a
/// video project's `.sqlite3` (and its `-wal`/`-shm`) under a new name, so none of its clips are
/// cached and the slow encode path is exercised; afterwards delete the copy and its
/// `NAME-*` files in the Clips cache. `--snapshot-dir` saves window shots while loading and after.
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
      func currentURL() -> String {
        (playback.player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "none"
      }
      func name(_ item: HistoryItem) -> String { "\(item.tensorId)" }

      let videos = model.history.items.filter { $0.isVideo && model.canUse($0) }
      log("project \(model.history.project.name): \(videos.count) usable clips")
      guard videos.count >= 3 else {
        log("FAIL need at least three usable clips")
        return finish()
      }
      // Prefer shorter clips: their encode is quicker but still not instant.
      let picks = videos.sorted { ($0.clip?.frames.count ?? 0) < ($1.clip?.frames.count ?? 0) }
      let a = picks[0], b = picks[1], c = picks[2]
      log("A \(name(a)) (\(a.clip?.frames.count ?? 0) frames), B \(name(b)) (\(b.clip?.frames.count ?? 0)), C \(name(c)) (\(c.clip?.frames.count ?? 0))")

      // Picking clips, as the strip does.
      model.use(a, restoreInput: false)
      check(await wait(seconds: 600) { playback.isReady(for: a.tensorId) }, "A loads on the canvas (\(currentURL()))")
      check(model.canvasClip?.tensorId == a.tensorId, "the canvas clip is A")
      try? await Task.sleep(for: .milliseconds(500))

      model.use(b, restoreInput: false)
      // Watch the load: A must never stand in for B.
      var staleSamples = 0, samples = 0, sawNoItem = false
      let loadedB = await wait(seconds: 600) {
        samples += 1
        // Ready with another clip loaded: what showing on `isReady` alone would have played.
        if playback.isReady, playback.loadedTensorId != b.tensorId { staleSamples += 1 }
        if playback.player.currentItem == nil { sawNoItem = true }
        return playback.isReady(for: b.tensorId)
      }
      check(loadedB, "B loads after A")
      check(samples > 3, "B's load took a while (\(samples) samples of 20 ms), so it was uncached")
      // The first sample comes before the view has re-rendered with B (its task resets then).
      check(staleSamples <= 1, "A stayed loaded for \(staleSamples) of \(samples) samples while B loaded")
      check(sawNoItem, "the player held no item during B's load")
      check(currentURL().contains("-\(b.tensorId)-"), "the player plays B's file (\(currentURL()))")

      // Quick B then C, both uncached: the next two clips.
      guard picks.count >= 5 else {
        log("only \(picks.count) clips: B-then-C done with C cached? skipping")
        return finish()
      }
      let b2 = picks[3], c2 = picks[4]
      log("quick switch: B \(name(b2)) then C \(name(c2)), both uncached")
      model.use(b2, restoreInput: false)
      try? await Task.sleep(for: .milliseconds(150))
      let b2Ready = playback.isReady(for: b2.tensorId)
      check(!b2Ready, "B isn't ready 150 ms after picking it")
      check(playback.loadedTensorId != b.tensorId, "the earlier clip was dropped (loaded \(playback.loadedTensorId.map(String.init) ?? "nil"))")
      if let snapshotDir {
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        snapshot(to: snapshotDir.appendingPathComponent("loading.png"))
      }
      model.use(c2, restoreInput: false)
      check(await wait(seconds: 600) { playback.isReady(for: c2.tensorId) }, "C loads")
      // Give B's encode time to finish and try to take over.
      try? await model.history.videoFile(for: b2)
      try? await Task.sleep(for: .seconds(2))
      check(playback.loadedTensorId == c2.tensorId, "after B's encode finishes the canvas still has C (loaded \(playback.loadedTensorId.map(String.init) ?? "nil"))")
      check(currentURL().contains("-\(c2.tensorId)-"), "the player plays C's file (\(currentURL()))")
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
        check(await wait(seconds: 600) { playback.isReady(for: made.tensorId) }, "History open: the clip plays (\(currentURL()), playing \(playback.isPlaying))")
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
