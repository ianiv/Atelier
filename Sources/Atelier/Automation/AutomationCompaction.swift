#if os(macOS)
  import Foundation

  extension Automation {
    /// Checks giving project files' free pages back (`ProjectCompaction`) through the app, on copies
    /// of real project files, as PASS/FAIL lines. For each `--source`, a copy opens as a project:
    /// the Compact offer shows exactly when `offersCompaction` says, Compact Project… (the same call
    /// the sheet makes) leaves an incremental file with no free pages, no bigger, with the same
    /// steps and readable images. A second copy opens and is switched away from: once it's let go,
    /// the clean-up empties its freelist when it's incremental and leaves it alone when it isn't.
    /// The copies are deleted afterwards; the sources are only read.
    ///
    ///   Atelier --compact-check --project compact-check-<random> --source FILE [--source FILE …] [--quit]
    static func compactCheck(_ model: CreateModel) {
      let args = CommandLine.arguments
      let sources = args.indices.filter { args[$0] == "--source" && $0 + 1 < args.count }.map { URL(fileURLWithPath: args[$0 + 1]) }
      Task { @MainActor in
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
          if !ok { failures += 1 }
          print("\(ok ? "PASS" : "FAIL") \(message)")
          fflush(stdout)
        }
        @MainActor func finish() {
          print(failures == 0 ? "compact check: all passed" : "compact check: \(failures) failed")
          fflush(stdout)
          if args.contains("--quit") { AppLifecycle.quit() }
        }
        let history = model.history
        while !history.isLoaded || model.isBusy {
          try? await Task.sleep(for: .milliseconds(100))
        }
        let home = history.project.name
        guard home.hasPrefix("compact-check-"), !sources.isEmpty else {
          check(false, "run with --project compact-check-<random> and at least one --source FILE (got “\(home)”)")
          return finish()
        }
        let fileManager = FileManager.default
        func copy(_ source: URL, as name: String) -> Bool {
          let target = HistoryStore.url(for: name)
          guard !fileManager.fileExists(atPath: target.path) else { return false }
          for suffix in ["", "-wal"] where fileManager.fileExists(atPath: source.path + suffix) {
            guard (try? fileManager.copyItem(atPath: source.path + suffix, toPath: target.path + suffix)) != nil else { return false }
          }
          return true
        }
        func remove(_ name: String) async {
          if let trashed = try? await history.delete(name) {
            for suffix in ["", "-wal", "-shm"] {
              try? fileManager.removeItem(atPath: trashed.path + suffix)
            }
          }
        }
        func describe(_ stats: ProjectCompaction.Stats?) -> String {
          guard let stats else { return "unreadable" }
          return "mode \(stats.mode.rawValue), \(stats.journalMode), \(ProjectCompaction.format(stats.databaseBytes)), \(ProjectCompaction.format(stats.freeBytes)) free"
        }

        for (index, source) in sources.enumerated() {
          let label = source.deletingPathExtension().lastPathComponent
          let name = "\(home)-\(index)"
          guard copy(source, as: name) else {
            check(false, "\(label): couldn't copy to “\(name)”")
            continue
          }
          let url = HistoryStore.url(for: name)
          let before = ProjectCompaction.stats(at: url)
          print("\(label): copy is \(describe(before))")
          await history.open(name)
          while !history.isLoaded {
            try? await Task.sleep(for: .milliseconds(100))
          }
          let steps = history.items.map(\.tensorId)
          let expectsOffer = before.map(ProjectCompaction.offersCompaction) ?? false
          check((history.compactionOffer != nil) == expectsOffer, "\(label): offer shown \(history.compactionOffer != nil), expected \(expectsOffer)")

          let started = Date()
          do {
            let outcome = try await model.compactProject()
            let seconds = Date().timeIntervalSince(started)
            print("\(label): compacted \(ProjectCompaction.format(outcome.bytesBefore)) → \(ProjectCompaction.format(outcome.bytesAfter)) in \(String(format: "%.1f", seconds)) s")
            let after = ProjectCompaction.stats(at: url)
            print("\(label): after, \(describe(after))")
            check(after?.mode == .incremental, "\(label): incremental after compacting")
            check(after?.freePages == 0, "\(label): no free pages after compacting")
            // A file changing mode gains a pointer-map page per ~1,000 (incremental bookkeeping).
            let slack = before?.mode == .incremental ? 0 : outcome.bytesBefore / 200
            check(outcome.bytesAfter <= outcome.bytesBefore + slack, "\(label): no bigger after compacting (beyond the pointer map a change of mode adds)")
            check(history.project.name == name && history.project.isOpen, "\(label): the project is open again")
            check(history.items.map(\.tensorId) == steps, "\(label): the same \(steps.count) steps")
            if let first = history.items.first(where: { !$0.isEntry }) {
              let image = await history.project.read { $0.image(for: first) }
              check(image != nil, "\(label): its newest image reads")
            }
            check(history.compactionOffer == nil, "\(label): no offer after compacting")
          } catch {
            check(false, "\(label): Compact failed: \(error.localizedDescription)")
          }

          // A clean-up once a project is let go.
          let closing = "\(home)-\(index)-close"
          guard copy(source, as: closing) else {
            check(false, "\(label): couldn't copy to “\(closing)”")
            await history.open(home)
            await remove(name)
            continue
          }
          let closingURL = HistoryStore.url(for: closing)
          await history.open(closing)
          while !history.isLoaded {
            try? await Task.sleep(for: .milliseconds(100))
          }
          await history.open(home)
          // A freelist of many GB takes longer than one clean-up's budget: it frees some each time.
          let wanted = before.map(ProjectCompaction.needsCleanUp) == true && before?.mode == .incremental
          let partial = (before?.freeBytes ?? 0) > 2_000 * ProjectCompaction.megabyte
          var cleaned = ProjectCompaction.stats(at: closingURL)
          let deadline = Date().addingTimeInterval(ProjectCompaction.cleanUpBudgetSeconds + 30)
          while wanted, cleaned?.freePages != 0, Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            cleaned = ProjectCompaction.stats(at: closingURL)
          }
          if !wanted { try? await Task.sleep(for: .seconds(5)) }
          cleaned = ProjectCompaction.stats(at: closingURL)
          print("\(label): after closing, \(describe(cleaned)), \(ProjectCompaction.format(ProjectCompaction.fileBytes(closingURL))) on disk")
          if wanted, partial {
            check((cleaned?.freePages ?? .max) < (before?.freePages ?? 0), "\(label): the clean-up after closing freed some pages, within its budget")
          } else if wanted {
            check(cleaned?.freePages == 0, "\(label): the clean-up after closing freed every page")
          } else {
            check(cleaned?.freePages == before?.freePages, "\(label): no clean-up after closing (mode \(before?.mode.rawValue ?? -1), below the thresholds or not incremental)")
          }
          await remove(name)
          await remove(closing)
        }
        finish()
      }
    }
  }
#endif
