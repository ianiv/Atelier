#if os(macOS)
import Foundation

/// `--cleanup-check [--quit]` checks that temporary data goes away, as PASS/FAIL lines, on files
/// it makes itself in a scratch folder (and one audio copy of its own, among the jobs' copies). The
/// launch and quit cleanup itself isn't run: it acts on the real temporary folder, which `TMPDIR`
/// doesn't redirect.
extension Automation {
  static func cleanupCheck(_ model: CreateModel) {
    let args = CommandLine.arguments
    Task { @MainActor in
      while model.settings == nil || model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      let fileManager = FileManager.default
      let scratch = fileManager.temporaryDirectory.appending(path: "atelier-cleanup-check-\(UUID())")
      defer { try? fileManager.removeItem(at: scratch) }
      func folder(_ name: String) -> URL {
        let url = scratch.appending(path: name, directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
      }
      func touch(_ url: URL, age: TimeInterval = 0) {
        try? fileManager.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: url.path, contents: Data("x".utf8))
        if age > 0 {
          try? fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
      }
      func names(_ url: URL) -> Set<String> {
        Set((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [])
      }

      // Scratch areas.
      let root = folder("Temporary/Atelier")
      for area in TemporaryFiles.Area.allCases {
        touch(root.appending(path: "\(area.rawValue)/file"))
      }
      touch(root.appending(path: "CharacterPreviews/preview.png"))
      TemporaryFiles.sweep(TemporaryFiles.Area.allCases, in: root)
      check(
        TemporaryFiles.Area.allCases.allSatisfy { names(root.appending(path: $0.rawValue)).isEmpty },
        "a sweep empties every area")
      check(
        names(root.appending(path: "CharacterPreviews")) == ["preview.png"],
        "a sweep leaves other folders under Atelier alone")
      touch(root.appending(path: "Drags/old"), age: 7200)
      touch(root.appending(path: "Drags/new"))
      TemporaryFiles.sweep([.drags], in: root, olderThan: 3600)
      check(names(root.appending(path: "Drags")) == ["new"], "an aged sweep removes only old files")

      // The engine's settings folders.
      let temporary = folder("EngineTemporary")
      let engineOld = UUID().uuidString
      let engineNew = UUID().uuidString
      let otherApp = UUID().uuidString
      touch(temporary.appending(path: "\(engineOld)/config.sqlite3"))
      touch(temporary.appending(path: "\(engineOld)/config.sqlite3-wal"))
      touch(temporary.appending(path: "\(engineNew)/config.sqlite3"))
      touch(temporary.appending(path: "\(otherApp)/data.bin"))
      touch(temporary.appending(path: "NotAUUID/config.sqlite3"))
      let past = Date().addingTimeInterval(-7200)
      for name in [engineOld, otherApp, "NotAUUID"] {
        try? fileManager.setAttributes(
          [.modificationDate: past], ofItemAtPath: temporary.appending(path: name).path)
      }
      TemporaryFiles.removeEngineFolders(in: temporary, olderThan: 3600)
      check(
        names(temporary) == [engineNew, otherApp, "NotAUUID"],
        "only old engine folders go, not recent ones or anyone else's")

      // The clip cache.
      let clips = folder("Clips")
      for name in [
        "Kept-Name-1-2-h264.mp4", "Kept-Name-1-2-hevc.mp4", "Gone-1-2-h264.mp4",
        "Kept-Name-3-4-h264.partial.mp4", "notes.txt",
      ] {
        touch(clips.appending(path: name))
      }
      HistoryStore.pruneClipCache(in: clips, projects: ["Kept-Name"], codec: .h264)
      check(
        names(clips) == ["Kept-Name-1-2-h264.mp4", "notes.txt"],
        "the clip cache keeps the current codec of existing projects (\(names(clips).sorted()))")
      touch(clips.appending(path: "Kept-Name-1-2-hevc.mp4"))
      HistoryStore.removeClipFiles(in: clips, project: "Kept-Name", clipId: 1, tensorId: 2)
      check(names(clips) == ["notes.txt"], "deleting a clip removes its files in every codec")

      // A failed import's files.
      let models = folder("Models")
      touch(models.appending(path: "other_f16.ckpt"))
      touch(models.appending(path: "foo_bar_f16.ckpt"))
      let before = names(models)
      touch(models.appending(path: "foo_f16.ckpt"))
      touch(models.appending(path: "foo_clip_vit_l14_f16.ckpt"))
      touch(models.appending(path: "foo_f16.ckpt-wal"))
      ModelLibrary.removeNewFiles(in: models, before: before, prefix: "foo_")
      check(names(models) == before, "a failed import removes only the files it made")

      // Moodboard and style thumbnail files nothing refers to.
      let kept = UUID()
      let orphan = UUID()
      let moodboard = folder("Moodboard")
      for name in ["\(kept).png", "\(orphan).png", "index.json"] {
        touch(moodboard.appending(path: name))
      }
      Moodboard.removeOrphans(in: moodboard, keeping: [kept])
      check(names(moodboard) == ["\(kept).png", "index.json"], "moodboard orphans are removed")
      let thumbnails = folder("StyleThumbnails")
      for id in [kept, orphan] {
        for suffix in [".jpg", "-full.png", ".json"] {
          touch(thumbnails.appending(path: id.uuidString + suffix))
        }
      }
      touch(thumbnails.appending(path: "other.jpg"))
      StyleStore.removeOrphanedThumbnails(in: thumbnails, keeping: [kept])
      check(
        names(thumbnails) == ["\(kept.uuidString).jpg", "\(kept.uuidString)-full.png", "\(kept.uuidString).json", "other.jpg"],
        "orphaned style thumbnails are removed, and files it doesn't recognize kept")

      // A job's audio copy stays while Run Again can use it, and goes with the last job using it.
      if let settings = model.settings {
        let audio = AudioClip.newSnapshotFile(extension: "wav")
        touch(audio)
        var request = GenerationEngine.Request(
          model: "", prompt: "", negativePrompt: "", seed: 0, configuration: settings)
        request.audio = audio
        let queue = JobQueue()
        queue.append([request], currentTensorId: nil)
        let job = queue.startNext()
        if let job { queue.finishRunning(.cancelled, id: job.id) }
        check(fileManager.fileExists(atPath: audio.path), "a finished job's audio stays for Run Again")
        if let job { queue.retry(job.id) }
        let retried = queue.startNext()
        if let job { queue.removeRecent(job.id) }
        check(fileManager.fileExists(atPath: audio.path), "removing a job keeps audio another still uses")
        if let retried { queue.finishRunning(.cancelled, id: retried.id) }
        if let retried { queue.removeRecent(retried.id) }
        check(!fileManager.fileExists(atPath: audio.path), "the audio goes with the last job using it")
        try? fileManager.removeItem(at: audio)
      } else {
        check(false, "no settings loaded, so the audio copy wasn't checked")
      }

      // What saves the session and the queue. The app is gone right after, so this line is the
      // proof: it has to be printed after "cleanup check", as the app quits.
      AppLifecycle.onWillTerminate {
        print("PASS quitting runs the work registered for it")
        fflush(stdout)
      }
      var resigned = false
      var activated = false
      AppLifecycle.onResignActive { resigned = true }
      AppLifecycle.onBecomeActive { activated = true }
      if await AppLifecycle.hideAndShowForCheck() {
        check(resigned, "hiding the app runs the work registered for going to the back")
        check(activated, "showing the app runs the work registered for coming to the front")
      } else {
        print("skipped the front and back checks: the app couldn't come to the front")
      }

      print(failures == 0 ? "cleanup check: all passed" : "cleanup check: \(failures) failed")
      fflush(stdout)
      if args.contains("--quit") { AppLifecycle.quit() }
    }
  }
}
#endif
