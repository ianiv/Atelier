#if os(macOS)
  import Foundation

  /// `--styles-check --file STYLES.md [--library-out FILE.html] [--export-library FILE.html] [--snapshot-dir DIR] [--quit]` reads a style file
  /// (docs/styles.md), checks that writing it back reads the same styles, that every style's
  /// prompt is found again in what it writes (so Reuse brings the style back), and imports it into
  /// a copy of the user's styles that isn't saved. With `--snapshot-dir`, snapshots the Styles
  /// screen, a thumbnail full size and Create with a style selected.
  ///
  /// `--thumbnails N --model M [--steps S] [--width W --height H]` also makes thumbnails for the
  /// file's first N styles with that model (pass `--project` for a scratch project: the images
  /// save there) and checks each style got one.
  extension Automation {
    static func stylesCheck(
      _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore
    ) {
      let args = CommandLine.arguments
      func value(_ name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
      }
      let snapshotDir = value("--snapshot-dir").map { URL(fileURLWithPath: $0) }
      Task { @MainActor in
        func log(_ message: String) { print(message); fflush(stdout) }
        func check(_ ok: Bool, _ message: String) { log((ok ? "PASS " : "FAIL ") + message) }
        defer { if args.contains("--quit") { AppLifecycle.quit() } }
        guard let path = value("--file"), let text = try? String(contentsOfFile: path, encoding: .utf8) else {
          log("FAIL pass --file with a readable style file")
          return
        }
        let parsed = StyleFile.parse(text)
        log("read \(parsed.count) styles in \(Set(parsed.map(\.category)).count) categories")
        check(!parsed.isEmpty, "the file has styles")
        check(parsed.allSatisfy { !$0.category.isEmpty && !$0.template.isEmpty }, "every style has a category and template")

        let reread = StyleFile.parse(StyleFile.write(parsed))
        func content(_ style: Style) -> [String] {
          [style.name, style.category, style.subcategory, style.template, style.negative, style.notes]
        }
        check(reread.map(content) == parsed.map(content), "writing the styles back reads the same styles")

        let subject = "A red fox sitting on a mossy log, looking over its shoulder."
        // Each tag gets distinct text, so a wrong match shows.
        func values(_ style: Style) -> [String: String] {
          Dictionary(uniqueKeysWithValues: style.tags.map { ($0, $0 == Style.subject ? subject : "a misty pine forest (\($0))") })
        }
        var unmatched: [String] = []
        var leftovers: [String] = []
        for style in parsed {
          let filled = values(style)
          let applied = style.apply(filled, negativePrompt: "blurry")
          if applied.prompt.contains("{{") { leftovers.append(style.name) }
          let matched = style.match(prompt: applied.prompt, negativePrompt: applied.negativePrompt)
          if matched?.values != filled || matched?.negativePrompt != "blurry" { unmatched.append(style.name) }
          // Empty tags drop out, and the subject still comes back.
          let bare = style.apply([Style.subject: subject], negativePrompt: "")
          if style.match(prompt: bare.prompt, negativePrompt: "")?.values[Style.subject] != subject {
            unmatched.append(style.name + " (other tags empty)")
          }
        }
        // Defaults fill empty boxes, and come back as empty boxes.
        let defaulted = Style(name: "Defaults", template: "A photo of {{SUBJECT:a cat}} in {{SETTING:a sunny garden}}, {{MOOD}} light.")
        let filled = defaulted.apply([:], negativePrompt: "")
        check(filled.prompt == "A photo of a cat in a sunny garden, light.", "empty boxes take their defaults: \(filled.prompt)")
        check(defaulted.tags == ["SUBJECT", "SETTING", "MOOD"], "tags with defaults keep their names")
        let typed = defaulted.apply([Style.subject: "a fox", "MOOD": "warm"], negativePrompt: "")
        let back = defaulted.match(prompt: typed.prompt, negativePrompt: "")?.values
        check(back == [Style.subject: "a fox", "SETTING": "", "MOOD": "warm"], "a default comes back as an empty box: \(back ?? [:])")
        log("tags used: \(Set(parsed.flatMap(\.tags)).sorted())")
        check(leftovers.isEmpty, "no placeholders left in written prompts \(leftovers.prefix(5))")
        check(unmatched.isEmpty, "every style finds its tag values again \(unmatched.prefix(5))")
        let wrong = parsed.filter { $0.match(prompt: subject, negativePrompt: "") != nil && $0.tags != [Style.subject] }
        check(wrong.isEmpty, "a plain prompt matches no style \(wrong.prefix(3).map(\.name))")

        // A library page carries the same styles and thumbnails back. `--library-out FILE` keeps it.
        let fakeThumbnail = Data("not really a jpeg".utf8)
        if let html = try? StyleLibrary.html(title: "Check", styles: parsed, thumbnail: { $0 == parsed.first?.id ? fakeThumbnail : nil }),
           let back = StyleLibrary.read(html)
        {
          check(back.map { content($0.style) } == parsed.map(content), "a library page reads back the same \(back.count) styles")
          check(back.first?.thumbnail == fakeThumbnail && back.dropFirst().allSatisfy { $0.thumbnail == nil }, "a library page carries thumbnails")
          if let out = value("--library-out") { try? html.write(toFile: out, atomically: true, encoding: .utf8) }
        } else {
          check(false, "a library page can be written and read")
        }

        guard let store = model.styles else { return log("FAIL no style store") }
        // `--export-library FILE` writes the user's own styles and thumbnails as a library page.
        if let out = value("--export-library") {
          let html = try? StyleLibrary.html(title: "Styles", styles: store.styles) { store.thumbnailJPEG($0) }
          check((try? html?.write(toFile: out, atomically: true, encoding: .utf8)) != nil, "exported \(store.styles.count) styles to \(out)")
        }
        let before = store.styles.count
        let first = store.importStyles(parsed)
        let second = store.importStyles(parsed)
        check(
          second.added == 0 && second.replaced == parsed.count && store.styles.count == before + first.added,
          "importing twice replaces instead of duplicating (\(first.added) added, then \(second.replaced) replaced)")

        guard let withTags = store.styles.first(where: { $0.tags.count > 1 }) else { return }
        let setting = "a misty pine forest at dawn"
        model.prompt = subject
        model.styleID = withTags.id
        for tag in withTags.tags where tag != Style.subject { model.styleValues[tag] = setting }
        check(
          model.styledPrompts.prompt.contains(subject) && model.styledPrompts.prompt.contains(setting),
          "Create writes the boxes \(withTags.tags) into \(withTags.name)")
        let full = model.styledPrompts
        model.expandStyle(undoManager: nil)
        check(model.style == nil && model.prompt == full.prompt && model.styledPrompts == full, "Edit Full Prompt puts the whole prompt in the prompt box")
        model.styleID = withTags.id
        model.prompt = subject

        if let count = value("--thumbnails").flatMap(Int.init), let file = value("--model") {
          while model.models.isEmpty || model.settings == nil || model.isBusy {
            try? await Task.sleep(for: .milliseconds(100))
          }
          model.selectedModel = file
          try? await Task.sleep(for: .milliseconds(200))
          while model.isBusy || model.isLoadingModel { try? await Task.sleep(for: .milliseconds(100)) }
          if var settings = model.settings {
            if let steps = value("--steps").flatMap(Int.init) { settings.steps = steps }
            if let width = value("--width").flatMap(Int.init) { settings.width = width }
            if let height = value("--height").flatMap(Int.init) { settings.height = height }
            model.settings = settings
          }
          // Styles with more tags than SUBJECT, so their thumbnail tag values are used.
          let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AtelierStyleThumbnails-\(UUID().uuidString)")
          StyleStore.scratchThumbnailsDirectory = scratch
          defer { try? FileManager.default.removeItem(at: scratch) }
          let chosen = Array(store.styles.filter { $0.tags.count > 1 }.prefix(count))
          for tag in store.allTags where tag != Style.subject { store.thumbnailValues[tag] = "a misty pine forest at dawn" }
          for style in chosen { store.setThumbnail(nil, for: style.id) }
          check(store.thumbnailBlocker(model) == nil, "thumbnails can be made: \(store.thumbnailBlocker(model) ?? "ok")")
          let started = Date()
          let historyBefore = model.history.items.count
          store.makeThumbnails(for: chosen, create: model)
          var lastDone = -1
          while store.thumbnailRun != nil {
            if let run = store.thumbnailRun, run.done != lastDone {
              lastDone = run.done
              log("thumbnail \(run.done + 1) of \(run.total): \(run.current)")
            }
            try? await Task.sleep(for: .milliseconds(250))
          }
          let made = chosen.filter { store.thumbnail($0.id) != nil }
          check(made.count == chosen.count, "\(made.count) of \(chosen.count) styles got a thumbnail in \(Int(Date().timeIntervalSince(started)))s")
          check(model.history.items.count == historyBefore, "thumbnails aren't saved to the project (\(model.history.items.count - historyBefore) new items)")
          // Open in Create brings back the first one's image, prompt boxes and settings.
          if let first = chosen.first, let (image, source) = store.thumbnailSource(first.id) {
            model.styleID = nil
            model.prompt = ""
            model.openThumbnail(image, source: source, undoManager: nil)
            try? await Task.sleep(for: .milliseconds(300))
            check(
              model.styleID == first.id && model.prompt == store.thumbnailValues[Style.subject]
                && model.image?.width == image.width && model.selectedModel == file,
              "Open in Create restores \(first.name), its subject, model and the \(image.width)px image")
          } else {
            check(false, "the first thumbnail can be opened in Create")
          }
          check(made.allSatisfy { store.thumbnail($0.id)?.width == StyleStore.thumbnailSize }, "thumbnails are \(StyleStore.thumbnailSize) px squares")
        }

        if let snapshotDir {
          // `--model` without `--thumbnails` picks the model the snapshots show (one with
          // Layout fills the column beside the prompt most).
          if value("--thumbnails") == nil, let file = value("--model") {
            model.selectedModel = file
            try? await Task.sleep(for: .milliseconds(200))
            while model.isLoadingModel { try? await Task.sleep(for: .milliseconds(100)) }
          }
          // Give SwiftUI's own window time to come up, so there's only one Styles screen.
          try? await Task.sleep(for: .seconds(2))
          ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
          navigation.section = .styles
          try? await Task.sleep(for: .seconds(1))
          snapshot(to: snapshotDir.appendingPathComponent("styles.png"))
          // A thumbnail full size, as a click on it or Space shows it.
          for style in store.styles.prefix(200) { await store.loadThumbnail(style.id) }
          if let shown = store.styles.first(where: { store.thumbnail($0.id) != nil }) {
            let full = await store.fullThumbnailImage(shown.id)
            log("\(shown.name)'s thumbnail is \(full.map { "\($0.width)×\($0.height)" } ?? "missing") full size")
            store.viewingThumbnail = shown.id
            try? await Task.sleep(for: .seconds(2))
            check(
              AutomationWindows.snapshotSheet(to: snapshotDir.appendingPathComponent("thumbnail-viewer.png")),
              "the thumbnail viewer opens")
            store.viewingThumbnail = nil
            try? await Task.sleep(for: .seconds(1))
          }
          navigation.section = .create
          try? await Task.sleep(for: .seconds(1))
          snapshot(to: snapshotDir.appendingPathComponent("create.png"))
          // Coming back to Styles shows the same scroll position and selection.
          if store.styles.count > 60 {
            let top = store.styles[40]
            store.screenSelection = [top.id, store.styles[41].id]
            store.screenScrolledTo = top.id
            navigation.section = .styles
            try? await Task.sleep(for: .seconds(1))
            navigation.section = .create
            try? await Task.sleep(for: .seconds(1))
            navigation.section = .styles
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: snapshotDir.appendingPathComponent("styles-restored.png"))
            check(
              store.screenScrolledTo == top.id,
              "the list comes back scrolled to \(top.name) (top row now \(store.style(id: store.screenScrolledTo)?.name ?? "none"))")
            // End on Create, for a look at the composer.
            navigation.section = .create
          }
        }
      }
    }
  }
#endif
