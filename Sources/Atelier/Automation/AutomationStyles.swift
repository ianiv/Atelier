#if os(macOS)
  import Foundation

  /// `--styles-check --file STYLES.md [--snapshot-dir DIR] [--quit]` reads a style file
  /// (docs/styles.md), checks that writing it back reads the same styles, that every style's
  /// prompt is found again in what it writes (so Reuse brings the style back), and imports it into
  /// a copy of the user's styles that isn't saved. With `--snapshot-dir`, snapshots the Styles
  /// screen and Create with a style selected.
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
        let setting = "A misty pine forest at dawn."
        var unmatched: [String] = []
        var leftovers: [String] = []
        for style in parsed {
          let applied = style.apply(prompt: subject, negativePrompt: "blurry", setting: setting)
          if applied.prompt.contains("{{") { leftovers.append(style.name) }
          let matched = style.match(prompt: applied.prompt, negativePrompt: applied.negativePrompt)
          if matched?.prompt != subject || matched?.negativePrompt != "blurry"
            || (style.takesSetting && matched?.setting != setting)
          {
            unmatched.append(style.name)
          }
          // Empty slots drop out, and the prompt still comes back.
          let bare = style.apply(prompt: subject, negativePrompt: "", setting: "")
          if style.match(prompt: bare.prompt, negativePrompt: "")?.prompt != subject { unmatched.append(style.name + " (no setting)") }
        }
        check(leftovers.isEmpty, "no placeholders left in written prompts \(leftovers.prefix(5))")
        check(unmatched.isEmpty, "every style finds its prompt again \(unmatched.prefix(5))")
        let wrong = parsed.filter { other in
          other.match(prompt: subject, negativePrompt: "") != nil && other.template.replacingOccurrences(of: Style.subject, with: "") != ""
        }
        check(wrong.isEmpty, "a plain prompt matches no style \(wrong.prefix(3).map(\.name))")

        guard let store = model.styles else { return log("FAIL no style store") }
        let before = store.styles.count
        let first = store.importStyles(parsed)
        let second = store.importStyles(parsed)
        check(
          second.added == 0 && second.replaced == parsed.count && store.styles.count == before + first.added,
          "importing twice replaces instead of duplicating (\(first.added) added, then \(second.replaced) replaced)")

        guard let withSetting = store.styles.first(where: \.takesSetting) else { return }
        model.prompt = subject
        model.styleID = withSetting.id
        model.styleSetting = setting
        check(model.styledPrompts.prompt.contains(subject) && model.styledPrompts.prompt.contains(setting), "Create writes the prompt into \(withSetting.name)")

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
          let chosen = Array(store.styles.prefix(count))
          for style in chosen { store.setThumbnail(nil, for: style.id) }
          check(store.thumbnailBlocker(model) == nil, "thumbnails can be made: \(store.thumbnailBlocker(model) ?? "ok")")
          let started = Date()
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
          check(made.allSatisfy { store.thumbnail($0.id)?.width == StyleStore.thumbnailSize }, "thumbnails are \(StyleStore.thumbnailSize) px squares")
        }

        if let snapshotDir {
          ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
          navigation.section = .styles
          try? await Task.sleep(for: .seconds(1))
          snapshot(to: snapshotDir.appendingPathComponent("styles.png"))
          navigation.section = .create
          try? await Task.sleep(for: .seconds(1))
          snapshot(to: snapshotDir.appendingPathComponent("create.png"))
        }
      }
    }
  }
#endif
