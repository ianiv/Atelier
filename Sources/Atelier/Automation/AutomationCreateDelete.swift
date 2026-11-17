#if os(macOS)
import Foundation
import SwiftUI

/// `--create-delete-check --project NAME [--snapshot-dir DIR] [--quit]` checks Delete from the
/// Create screen (the strip's and the canvas's menus), as PASS/FAIL lines. It puts the newest image
/// on the canvas and deletes it the way the confirmation's Delete does
/// (`CreateModel.deleteHistoryItems(_:movesCanvas:)`): the image leaves History and the canvas
/// moves to the step now current. Deleting an image that isn't on the canvas leaves the canvas
/// alone. Then it plays the shortest clip on the canvas and deletes it: the clip leaves History
/// and every timeline, the canvas's shared player lets it go, and the canvas moves on. It DELETES
/// from the project, so run it only on a scratch copy (`--project` with a copy of a project's
/// `.sqlite3`, `-wal` and `-shm`) with at least three images and one video. `--snapshot-dir`
/// saves the confirmation and the canvas after each delete.
extension Automation {
  static func createDeleteCheck(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore
  ) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    let snapshotDir = value("--snapshot-dir").map { URL(fileURLWithPath: $0) }
    if let snapshotDir { try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true) }
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
        log(failures == 0 ? "create delete check: all passed" : "create delete check: \(failures) failed")
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
      @MainActor func shot(_ name: String) {
        if let snapshotDir { snapshot(to: snapshotDir.appendingPathComponent("\(name).png")) }
      }
      while !model.history.isLoaded || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      navigation.section = .create
      ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
      let history = model.history
      let playback = model.canvasPlayback
      func name(_ item: HistoryItem?) -> String { item.map { "\($0.tensorId)\($0.isEntry ? " (entry)" : "")" } ?? "none" }
      /// The canvas shows the step History would select after a delete: the current one, else the
      /// newest (an entry's canvas image for an entry).
      @MainActor func canvasShowsNext() -> Bool {
        guard let next = history.currentItem ?? history.items.first else { return model.image == nil }
        // An entry puts its canvas back (an image, or none) and stays current.
        if next.isEntry { return history.currentItem?.tensorId == next.tensorId && (model.image != nil) == (next.canvasTensorId != nil) }
        return model.imageItem?.tensorId == next.tensorId && model.image != nil
      }
      let images = history.items.filter { !$0.isVideo && !$0.isEntry && $0.hasImage }
      log("project \(history.project.name): \(history.items.count) items, \(images.count) images, \(history.items.count(where: \.isVideo)) videos")
      guard images.count >= 3 else {
        log("FAIL need at least three images")
        failures += 1
        return finish()
      }

      // An image on the canvas, deleted from it.
      let image = images[0]
      model.show(image)
      check(await wait(seconds: 30) { model.imageItem?.tensorId == image.tensorId && model.image != nil }, "image \(name(image)) is on the canvas")
      model.pendingHistoryDelete = [image]
      try? await Task.sleep(for: .seconds(1))
      shot("confirm-image")
      model.pendingHistoryDelete = nil
      try? await Task.sleep(for: .milliseconds(500))
      do {
        try await model.deleteHistoryItems([image], movesCanvas: true)
        check(true, "deleted image \(name(image))")
      } catch {
        check(false, "deleting image \(name(image)): \(error.localizedDescription)")
      }
      check(history.item(tensorId: image.tensorId) == nil, "image \(name(image)) is gone from History")
      check(await wait(seconds: 10) { canvasShowsNext() }, "the canvas moved to \(name(history.currentItem ?? history.items.first)) (shows \(name(model.imageItem)), image \(model.image != nil), current \(history.currentTensorId.map(String.init) ?? "nil"))")
      try? await Task.sleep(for: .milliseconds(500))
      shot("after-image")

      // An image that isn't on the canvas: the canvas stays.
      let onCanvas = model.imageItem?.tensorId
      if let other = history.items.first(where: { !$0.isVideo && !$0.isEntry && $0.tensorId != onCanvas }) {
        do {
          try await model.deleteHistoryItems([other], movesCanvas: true)
        } catch {
          check(false, "deleting image \(name(other)): \(error.localizedDescription)")
        }
        check(history.item(tensorId: other.tensorId) == nil, "image \(name(other)) off the canvas is gone from History")
        check(model.imageItem?.tensorId == onCanvas, "the canvas still shows \(onCanvas.map(String.init) ?? "nil") (shows \(name(model.imageItem)), image \(model.image != nil), current \(history.currentTensorId.map(String.init) ?? "nil"))")
      }

      // A clip playing on the canvas, deleted from it.
      guard let video = history.items.filter(\.isVideo).min(by: { ($0.clip?.frames.count ?? 0) < ($1.clip?.frames.count ?? 0) }) else {
        log("FAIL no video in the project")
        failures += 1
        return finish()
      }
      model.show(video)
      check(await wait(seconds: 30) { model.canvasClip?.tensorId == video.tensorId && playback.isReady(for: video.tensorId) }, "clip \(name(video)) is on the canvas")
      playback.play()
      try? await Task.sleep(for: .milliseconds(500))
      model.pendingHistoryDelete = [video]
      try? await Task.sleep(for: .seconds(1))
      shot("confirm-video")
      model.pendingHistoryDelete = nil
      try? await Task.sleep(for: .milliseconds(500))
      let frames = Set(video.clip?.frames ?? [])
      do {
        try await model.deleteHistoryItems([video], movesCanvas: true)
        check(true, "deleted clip \(name(video))")
      } catch {
        check(false, "deleting clip \(name(video)): \(error.localizedDescription)")
      }
      check(history.item(tensorId: video.tensorId) == nil, "clip \(name(video)) is gone from History")
      check(model.timelines.timelines(using: video.tensorId).isEmpty, "clip \(name(video)) is on no timeline")
      check(playback.loadedTensorId != video.tensorId, "the canvas player let the clip go (loaded \(playback.loadedTensorId.map(String.init) ?? "nil"))")
      check(model.canvasClip?.tensorId != video.tensorId, "the canvas clip isn't the deleted one (\(name(model.canvasClip)))")
      check(await wait(seconds: 10) { canvasShowsNext() }, "the canvas moved to \(name(history.currentItem ?? history.items.first)) (shows \(name(model.imageItem)), image \(model.image != nil), current \(history.currentTensorId.map(String.init) ?? "nil"))")
      if let clip = model.canvasClip {
        check(await wait(seconds: 10) { playback.isReady(for: clip.tensorId) }, "the next clip \(name(clip)) loads in the player")
      }
      try? await Task.sleep(for: .milliseconds(500))
      let staleFrame = playback.shownFrameTensorId.map { frames.contains($0) } ?? false
      check(!staleFrame, "no frame of the deleted clip is on screen")
      shot("after-video")
      finish()
    }
  }
}
#endif
