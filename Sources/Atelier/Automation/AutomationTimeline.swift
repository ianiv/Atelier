#if os(macOS)
import AVFoundation
import SwiftUI

extension Automation {
  /// Checks timelines with real runs, as PASS/FAIL lines: two short clips added to a new timeline
  /// saved in the project file, trim, split, undo and redo, Continue from Here placing its run
  /// after the frame it started from, a crossfade, the composition's length, an export's length,
  /// size and sound, and deleting a clip taking it off the timeline. Use the smallest clips the
  /// model takes:
  ///
  ///   Atelier --timeline-check --project NAME --model ltx_2.3_22b_distilled_q8p.ckpt
  ///           [--width 256 --height 256 --steps 2 --num-frames 9] [--snapshot-dir DIR] [--quit]
  ///
  /// `--timeline-check --dump --project NAME [--snapshot-dir DIR]` only prints the project's saved
  /// timelines (and snapshots the Video Editor).
  static func timelineCheck(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore
  ) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    if args.contains("--dump") {
      Task { @MainActor in
        while !model.history.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        print(model.history.project.timelinesJSON ?? "no timelines")
        model.timelines.load()
        print("store: \(model.timelines.timelines.count) timelines, \(model.timelines.selected?.entries.count ?? 0) entries")
        fflush(stdout)
        if let folder = value("--snapshot-dir") {
          navigation.section = .videoEditor
          ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
          try? await Task.sleep(for: .seconds(4))
          AutomationWindows.snapshot(to: URL(fileURLWithPath: folder).appending(path: "timeline.png"))
        }
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      return
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
        log(failures == 0 ? "timeline check: all passed" : "timeline check: \(failures) failed")
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      @MainActor func wait(until condition: () -> Bool, seconds: Double = 900) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
          if Date() > deadline { return false }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return true
      }
      /// Generates one clip with what's on screen; the clip, or nil when the run failed.
      @MainActor func run(_ prompt: String) async -> HistoryItem? {
        let previous = model.lastSavedStep
        model.prompt = prompt
        model.generate()
        try? await Task.sleep(for: .milliseconds(200))
        _ = await wait(until: { !model.isBusy })
        if let error = model.errorMessage { log("error: \(error)") }
        guard let step = model.lastSavedStep, step != previous, let item = model.history.item(step),
          item.isVideo
        else { return nil }
        log("made clip \(item.tensorId): \(item.clip?.frames.count ?? 0) frames")
        return item
      }

      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if let file = value("--model") {
        model.selectedModel = file
        try? await Task.sleep(for: .milliseconds(200))
        _ = await wait(until: { !model.isLoadingModel })
        model.resetToModelDefaults(undoManager: nil)
      }
      guard var settings = model.settings, model.videoModel != nil else {
        log("FAIL pick a video model with --model")
        failures += 1
        return finish()
      }
      settings.width = value("--width").flatMap(Int.init) ?? 256
      settings.height = value("--height").flatMap(Int.init) ?? 256
      settings.steps = value("--steps").flatMap(Int.init) ?? 2
      settings.numFrames = value("--num-frames").flatMap(Int.init) ?? 9
      settings.hiresFix = false
      model.settings = settings
      model.canvasMode = .generate
      model.seedLocked = true
      model.seed = 7
      model.count = 1

      guard let first = await run("a paper boat on a pond"),
        let second = await run("a red kite over a beach")
      else {
        check(false, "two clips generated")
        return finish()
      }
      let store = model.timelines
      let undo = UndoManager()
      undo.groupsByEvent = false
      @MainActor func step(_: String, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
      }
      step("add") { store.append([first, second], undoManager: undo) }
      guard var timeline = store.selected else {
        check(false, "Add to Timeline makes a timeline")
        return finish()
      }
      check(timeline.entries.map(\.clip) == [first.tensorId, second.tensorId], "both clips are on the timeline, in order")

      let count = first.clip!.frames.count
      let fps = first.clip!.framesPerSecond
      var layout = TimelineLayout(timeline, item: model.history.item(tensorId:))
      let expected = Double(count + second.clip!.frames.count) / fps
      check(abs(layout.duration - expected) < 0.01, "layout plays \(layout.duration) s (expected \(expected))")

      // Trim the first clip's last two frames, split the second in the middle.
      let trimmedEnd = count - 2
      step("trim") {
        store.edit(timeline.id, "Trim Clip", undoManager: undo) { $0.entries[0].end = trimmedEnd }
      }
      step("split") {
        store.edit(timeline.id, "Split Clip", undoManager: undo) { timeline in
          var second = timeline.entries[1]
          second.id = UUID()
          second.start = 4
          timeline.entries[1].end = 4
          timeline.entries.append(second)
        }
      }
      timeline = store.selected!
      check(timeline.entries.count == 3 && timeline.entries[0].end == trimmedEnd, "trim and split")
      undo.undo()
      check(store.selected?.entries.count == 2, "Undo takes the split back")
      undo.redo()
      check(store.selected?.entries.count == 3, "Redo splits again")
      undo.undo()
      undo.undo()
      check(store.selected?.entries[0].end == count, "a second Undo takes the trim back")
      undo.redo()
      timeline = store.selected!

      // Continue from frame 3 of the first clip: its run goes right after that frame.
      let entry = timeline.entries[0]
      model.continueTimeline(timeline, entry: entry, frame: 3, of: first)
      _ = await wait(until: { model.image != nil && model.canvasClip == nil }, seconds: 10)
      try? await Task.sleep(for: .milliseconds(500))
      check(model.history.currentTensorId == first.clip!.frames[3], "Continue from Here makes that frame current")
      check(model.effectiveCanvasMode == .edit, "the frame goes on the canvas in Edit mode")
      guard let continued = await run("the paper boat sails on") else {
        check(false, "the continued clip generated")
        return finish()
      }
      timeline = store.selected!
      check(timeline.entries.count == 3, "the continued clip goes on the timeline")
      check(timeline.entries[0].end == 4, "the first clip now ends at the frame it continued from")
      check(
        timeline.entries.count > 1 && timeline.entries[1].clip == continued.tensorId
          && timeline.entries[1].start == 1,
        "the new clip follows it, without its repeated first frame")
      check(model.history.parent(of: continued)?.tensorId == first.tensorId, "History shows it following the first clip")

      // A crossfade, then the composition and an export.
      step("fade") {
        store.edit(timeline.id, "Crossfade", undoManager: undo) { $0.entries[0].crossfadeFrames = 2 }
      }
      timeline = store.selected!
      layout = TimelineLayout(timeline, item: model.history.item(tensorId:))
      check(layout.segments[0].fade > 0, "the crossfade overlaps the first two clips")
      do {
        var files: [URL] = []
        for segment in layout.segments { files.append(try await model.history.videoFile(for: segment.item)) }
        guard let composition = try await TimelineComposition.make(layout, files: files) else {
          check(false, "the composition builds")
          return finish()
        }
        check(abs(composition.duration - layout.duration) < 0.05, "the composition plays \(composition.duration) s (layout \(layout.duration) s)")
        let folder = value("--snapshot-dir").map { URL(fileURLWithPath: $0) } ?? URL.temporaryDirectory
        let url = folder.appending(path: "timeline.mp4")
        try await composition.export(to: url, codec: .h264, title: timeline.name) { _ in }
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let size = try await video?.load(.naturalSize) ?? .zero
        let seconds = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        check(abs(seconds - layout.duration) < 0.1, "the export plays \(seconds) s")
        check(Int(size.width) == layout.width && Int(size.height) == layout.height, "the export is \(Int(size.width))×\(Int(size.height))")
        let hasSound = layout.segments.contains { $0.clip.audioId != nil }
        check(audio.isEmpty != hasSound, "the export's sound matches its clips (\(audio.count) audio tracks)")
        log("exported \(url.path)")
      } catch {
        check(false, "composition and export: \(error.localizedDescription)")
      }

      // Deleting a clip takes it off the timeline.
      do {
        try await model.history.delete([second])
        store.removeClips([second.tensorId])
        check(store.selected?.entries.contains { $0.clip == second.tensorId } == false, "deleting a clip takes it off the timeline")
      } catch {
        check(false, "delete: \(error.localizedDescription)")
      }
      // The project file has the timeline as it ended up (dictionary writes land shortly after).
      try? await Task.sleep(for: .seconds(2))
      let reopened = Project(url: model.history.project.url)
      let saved = reopened.timelinesJSON.flatMap { try? JSONDecoder().decode([Timeline].self, from: Data($0.utf8)) }
      check(saved?.first { $0.id == store.selected?.id } == store.selected, "the timeline is saved in the project file")
      await reopened.close()
      finish()
    }
  }
}
#endif
