#if os(macOS)
  import CoreGraphics
  import Foundation

  /// `--characters-check [--snapshot-dir DIR] [--quit]` checks the Characters screen on scratch
  /// characters (the user's aren't read or changed): the knob file, that the two descriptions in
  /// docs/characters.md come out word for word, Custom, Randomize and its locks, Edit as Text, and
  /// that characters and saved images come back in a new store. With `--snapshot-dir`, snapshots
  /// the screen.
  ///
  /// `--model M [--project NAME] [--steps S] [--width W --height H] [--styles N]` also renders with
  /// that model (pass `--project` for a scratch project: Send to Create adds to it): in No Style
  /// and in the first N of the user's styles with one seed, checks that previews stay out of
  /// History, then saves one to the character and sends it to Create. `--sheet ID` also renders
  /// that sheet at 1 MP and checks its size.
  extension Automation {
    static func charactersCheck(
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
        guard let store = model.characters else { return log("FAIL no character store") }
        let knobs = store.knobs
        let all = knobs.sections.flatMap(\.knobs)
        check(!all.isEmpty, "the knob file has \(all.count) knobs in \(knobs.sections.count) sections")
        check(all.filter { $0.control != .text }.allSatisfy { !$0.options.isEmpty }, "every slider and picker has options")
        check(Set(all.map(\.id)).count == all.count, "knob ids are unique")

        func set(_ character: inout SavedCharacter, _ values: [String: String]) {
          for (id, value) in values {
            guard let knob = all.first(where: { $0.id == id }) else { return log("FAIL no knob \(id)") }
            if knob.control != .text, knob.option(value) == nil { log("FAIL \(id) has no option \(value)") }
            character.knobs[id, default: KnobSetting()].value = value
          }
        }

        var woman = SavedCharacter(name: "Check woman")
        check(knobs.description(of: woman).isEmpty, "a new character has no description")
        set(&woman, [
          "kind": "woman", "age": "middle-aged", "pronoun": "she", "height": "tall", "build": "slender", "muscle": "athletic",
          "posture": "upright", "faceShape": "oval", "eyeColour": "green", "expression": "warm smile",
          "hairLength": "shoulder-length", "hairStyle": "wavy", "hairColour": "auburn", "skinTone": "fair", "skinTexture": "freckled",
          "outfit": "evening gown", "era": "Victorian", "mainColour": "deep green", "accessories": "a leather satchel and a pocket watch",
        ])
        woman.texts["marks"] = "a scar through the left eyebrow"
        let womanExpected = "A middle-aged woman with an oval face, green eyes and a warm smile. She is tall, slender and athletic, with an upright posture. She has shoulder-length wavy auburn hair and fair, freckled skin. She wears a Victorian evening gown in deep green, with a leather satchel and a pocket watch. She has a scar through the left eyebrow."
        let womanWritten = knobs.description(of: woman)
        check(womanWritten == womanExpected, "the woman's description matches the doc: \(womanWritten)")

        var dog = SavedCharacter(name: "Check dog")
        set(&dog, [
          "kind": "dog", "age": "young", "expression": "warm smile", "height": "small", "build": "sturdy",
          "hairLength": "short", "hairStyle": "wiry", "hairColour": "brown", "skinTexture": "patched",
          "outfit": "a collar", "mainColour": "red",
        ])
        dog.nouns = ["hair": "fur", "skin": "coat"]
        let dogExpected = "A young dog with a warm smile. The dog is small and sturdy. The dog has short wiry brown fur and a patched coat. The dog wears a red collar."
        let dogWritten = knobs.description(of: dog)
        check(dogWritten == dogExpected, "the dog's description matches the doc: \(dogWritten)")

        // Forms that aren't in the doc's examples.
        func written(_ values: [String: String], change: (inout SavedCharacter) -> Void = { _ in }) -> String {
          var character = SavedCharacter(name: "Form")
          set(&character, values)
          change(&character)
          return knobs.description(of: character)
        }
        func expect(_ got: String, _ wanted: String) {
          check(got == wanted, "“\(wanted)”" + (got == wanted ? "" : " but got “\(got)”"))
        }
        expect(written(["kind": "old man", "age": "elderly"]), "An elderly old man.")
        expect(written(["kind": "an old man", "height": "tall"]), "An old man. The old man is tall.")
        expect(written(["kind": "robot", "pronoun": "they", "height": "tall", "outfit": "armour"]), "A robot. They are tall. They wear armour.")
        expect(written(["height": "tall"]), "The person is tall.")
        expect(written(["posture": "proud", "kind": "cat"]), "A cat. The cat has a proud posture.")
        expect(written(["kind": "monk", "hairLength": "hairless", "hairColour": "red"]), "A monk. The monk has no hair.")
        expect(written(["kind": "girl", "hairColour": "auburn", "hairStyle": "bun"]), "A girl. The girl has auburn hair in a bun.")
        expect(written(["kind": "man", "outfit": "nothing", "era": "medieval"]), "A man. The man wears nothing.")
        expect(written(["kind": "man", "era": "medieval"]), "A man. The man wears medieval clothes.")
        expect(written(["kind": "man", "accessories": "a cane"]), "A man. The man wears a cane.")
        expect(written(["kind": "lion"]) { $0.nouns["hair"] = "mane"; $0.knobs["hairLength"] = KnobSetting(value: "long") }, "A lion. The lion has a long mane.")
        expect(written(["kind": "wizard"]) { $0.knobs["age"] = KnobSetting(custom: "ageless") }, "An ageless wizard.")
        expect(written(["kind": "wizard", "age": "young"]) { $0.knobs["age"]?.custom = "thousand-year-old" }, "A thousand-year-old wizard.")
        for (age, wanted) in [("35", "A 35-year-old woman."), ("8", "An 8-year-old woman."), ("18", "An 18-year-old woman."), ("11", "An 11-year-old woman."), ("80", "An 80-year-old woman."), ("110", "A 110-year-old woman."), ("2.5", "A 2.5-year-old woman.")] {
          expect(written(["kind": "woman", "age": "young"]) { $0.knobs["age"]?.custom = age }, wanted)
        }
        expect(written(["kind": "woman"]) { $0.knobs["height"] = KnobSetting(custom: "6") }, "A woman. The woman is 6.")
        expect(written(["kind": "knight", "era": "medieval"]) { $0.knobs["outfit"] = KnobSetting(custom: "a battered trench coat") }, "A knight. The knight wears a medieval battered trench coat.")
        expect(written(["kind": "woman", "pronoun": "she"]) { $0.texts["identity"] = "of Irish descent."; $0.texts["face"] = "a crooked nose" }, "A woman, of Irish descent, with a crooked nose.")
        expect(written(["pronoun": "he"]) { $0.texts["marks"] = "a limp" }, "He has a limp.")
        expect(written(["pronoun": "she"]), "")

        // Randomize: locked, Custom, Kind and Pronoun stay put.
        var dice = woman
        dice.knobs["age"]?.locked = true
        dice.knobs["height"] = KnobSetting(custom: "impossibly tall")
        var changed = false
        for _ in 0..<40 {
          knobs.randomizeAll(in: &dice)
          changed = changed || dice.knobs["eyeColour"]?.value != "green"
        }
        check(changed, "Randomize All changes knobs")
        check(
          dice.knobs["age"]?.value == "middle-aged" && dice.knobs["height"]?.value == nil && dice.knobs["height"]?.custom == "impossibly tall"
            && dice.knobs["kind"]?.value == "woman" && dice.knobs["pronoun"]?.value == "she" && dice.knobs["accessories"]?.value != nil,
          "Randomize leaves locked, Custom, Kind, Pronoun and text knobs alone")
        check(dice.texts == woman.texts && dice.nouns == woman.nouns, "Randomize leaves free text and the noun switches alone")
        var section = woman
        if let body = knobs.sections.first(where: { $0.id == "body" }) {
          for _ in 0..<40 { knobs.randomize(body, in: &section) }
        }
        check(section.knobs["eyeColour"]?.value == "green" && section.knobs["outfit"]?.value == "evening gown", "a section's dice change only that section")

        // A style's subject, and Edit as Text.
        let style = Style(name: "Check", template: "A painting. {{SUBJECT}} {{SETTING:A quiet street.}}", negative: "text")
        var inStyle = woman
        inStyle.tagValues["SETTING"] = "A misty harbour."
        check(
          style.apply(inStyle.tagValues.merging([Style.subject: womanWritten]) { $1 }, negativePrompt: "").prompt == "A painting. \(womanWritten) A misty harbour.",
          "the description fills the style's subject and the character's tags fill the rest")
        let reference = knobs.referenceStyle.apply([Style.subject: "A cat."], negativePrompt: "")
        check(reference.prompt.contains("A cat.") && reference.prompt.lowercased().contains("full body") && reference.negativePrompt.contains("bokeh"), "No Style is the neutral reference: \(reference.prompt)")

        // The saved image and the file come back in a new store.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AtelierCharactersCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = CharacterStore(persists: false, directory: scratch)
        let added = first.newCharacter()
        first.replace({ var copy = woman; copy.id = added.id; return copy }())
        let pixels = ImageTensor.cgImage(from: ImageTensor.tensor(from: testImage())!)!
        let info = CharacterImageInfo(
          source: ThumbnailSource(prompt: "p", negativePrompt: "n", model: "m", seed: 7, settings: [:]),
          styleID: nil, styleName: "No Style", tagValues: [:], subject: womanWritten)
        let image1 = first.addSavedImage(pixels, info: info, to: added.id)
        let image2 = first.addSavedImage(pixels, info: info, to: added.id)
        check(first.character(id: added.id)?.images == [image1, image2].compactMap(\.self) && first.character(id: added.id)?.mainImageID == image1, "saving adds images; the first is the main image")
        if let image2 { first.makeMain(image2, of: added.id) }
        check(first.character(id: added.id)?.mainImageID == image2, "Make Main Image changes the main image")
        first.duplicate(added.id)
        first.flush()
        let second = CharacterStore(persists: false, directory: scratch)
        check(second.characters.count == 2 && second.characters[0].knobs == woman.knobs, "characters come back from the file")
        let copy = second.characters[1]
        check(copy.images.count == 2 && Set(copy.images).isDisjoint(with: second.characters[0].images), "a duplicate gets its own saved images")
        if let main = copy.mainImageID {
          await second.loadSaved(main)
          await second.loadThumbnail(main)
          check(
            main == copy.images[1] && second.savedImages[main]?.width == pixels.width
              && second.thumbnail(main)?.width == StyleStore.thumbnailSize
              && second.savedInfo[main]?.source.seed == 7,
            "saved images, their settings and the main image come back, for the duplicate too")
          second.removeSavedImage(main, from: copy.id)
          check(second.character(id: copy.id)?.mainImageID == copy.images[0] && second.character(id: copy.id)?.images.count == 1, "removing the main image hands over to the first left")
          second.makeMain(copy.images[0], of: copy.id)
          second.addSavedImage(pixels, info: info, to: copy.id)
        }
        // A character from when there was one saved image, its files under the character's id.
        let legacy = scratch.appendingPathComponent("legacy", isDirectory: true)
        let legacyID = UUID()
        try? FileManager.default.createDirectory(at: legacy.appendingPathComponent("CharacterImages"), withIntermediateDirectories: true)
        try? Data("[{\"id\":\"\(legacyID.uuidString)\",\"name\":\"Old\"}]".utf8).write(to: legacy.appendingPathComponent("Characters.json"))
        try? Data(ImageTensor.jpeg(pixels, quality: 0.85) ?? []).write(to: legacy.appendingPathComponent("CharacterImages/\(legacyID.uuidString).jpg"))
        try? ImageTensor.png(pixels)?.write(to: legacy.appendingPathComponent("CharacterImages/\(legacyID.uuidString)-full.png"))
        let migrated = CharacterStore(persists: false, directory: legacy)
        await migrated.loadThumbnail(legacyID)
        check(migrated.characters.first?.images == [legacyID] && migrated.characters.first?.mainImageID == legacyID && migrated.thumbnail(legacyID) != nil, "an earlier single saved image becomes the main image")
        migrated.flush()
        check(CharacterStore(persists: false, directory: legacy).characters.first?.images == [legacyID], "the migration is saved")
        // Sheets.
        check(knobs.sheets.count >= 4 && knobs.sheets.contains { $0.takesText == true }, "\(knobs.sheets.map(\.title)) sheets")
        for sheet in knobs.sheets {
          for megapixels in CharacterKnobSet.sheetMegapixels {
            let size = sheet.size(megapixels: megapixels)
            let area = Double(size.width * size.height) / 1_000_000
            check(
              size.width % 64 == 0 && size.height % 64 == 0 && abs(area - Double(megapixels)) < 0.15 * Double(megapixels)
                && abs(Double(size.width) / Double(size.height) - sheet.aspect) < 0.1,
              "\(sheet.title) at \(megapixels) MP is \(size.width)×\(size.height)")
          }
          let wrapped = sheet.subject(description: "A cat.", custom: "in three hats.")
          check(wrapped.contains("A cat.") && !wrapped.contains("{{") && !wrapped.contains("hats.."), "\(sheet.title) wraps the description")
        }
        let noStyleSheet = knobs.referenceSheetStyle.apply([Style.subject: "S."], negativePrompt: "")
        check(noStyleSheet.prompt.lowercased().contains("deep focus") && !noStyleSheet.prompt.contains("facing the viewer") && noStyleSheet.negativePrompt.contains("bokeh"), "a No Style sheet keeps the plain look without the single framing")
        let exported = second.exported(second.characters.map(\.id))
        let third = CharacterStore(persists: false, directory: scratch.appendingPathComponent("import", isDirectory: true))
        let imported = third.importCharacters(exported)
        check(
          imported?.added == 2 && third.characters[0].images.count == 2 && third.characters[0].mainImageID == third.characters[0].images[1]
            && third.characters[0].mainImageID.flatMap(third.thumbnail) != nil,
          "a characters file imports, with its images and main image")
        check(third.importCharacters(exported)?.replaced == 2 && third.characters.count == 2, "importing twice replaces instead of duplicating")
        check(third.importCharacters(Data("[]".utf8)) == nil, "another file isn't taken for a characters file")
        let deleted = second.characters[0]
        second.delete(deleted.id)
        second.flush()
        check(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("CharacterImages/\(deleted.images[0].uuidString).jpg").path), "deleting a character removes its images")
        check(CharacterStore(persists: false, directory: scratch).characters.count == 1, "deleting a character is saved")

        // The screen's store, with characters to show.
        let shown = store.newCharacter()
        store.replace({ var copy = woman; copy.id = shown.id; copy.name = "Mara"; return copy }())
        let pup = store.newCharacter()
        store.replace({ var copy = dog; copy.id = pup.id; copy.name = "Biscuit"; return copy }())
        store.selection = shown.id
        store.edit(shown.id) { $0.editedDescription = "typed" }
        check(store.description(of: store.character(id: shown.id)!) == "typed", "Edit as Text replaces the description")
        store.edit(shown.id) { $0.editedDescription = nil }
        check(store.description(of: store.character(id: shown.id)!) == womanWritten, "without it the knobs write it again")

        if let file = value("--model") {
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
          model.prompt = "Not used by a render"
          let chosen = Array((model.styles?.styles ?? []).prefix(value("--styles").flatMap(Int.init) ?? 0))
          let character = store.character(id: shown.id)!
          check(store.renderBlocker(model, for: character) == nil, "ready to render: \(store.renderBlocker(model, for: character) ?? "ok")")
          let historyBefore = model.history.items.count
          let canvasBefore = model.image
          let seed = model.seed
          store.render(character, in: [nil] + chosen.map(Optional.some), create: model)
          let started = Date()
          while store.renderRun != nil {
            if let snapshotDir, model.queue.running?.characterPreview != nil, model.livePreview != nil, !FileManager.default.fileExists(atPath: snapshotDir.appendingPathComponent("characters-rendering.png").path) {
              ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
              navigation.section = .characters
              try? await Task.sleep(for: .milliseconds(500))
              snapshot(to: snapshotDir.appendingPathComponent("characters-rendering.png"))
            }
            try? await Task.sleep(for: .milliseconds(200))
          }
          let previews = store.previews[shown.id] ?? []
          check(previews.count == chosen.count + 1, "\(previews.count) previews in \(Int(Date().timeIntervalSince(started)))s\(store.renderError.map { ": \($0)" } ?? "")")
          check(model.history.items.count == historyBefore, "previews aren't saved to the project (\(model.history.items.count - historyBefore) new items)")
          check(model.image === canvasBefore, "a render leaves the canvas alone")
          check(previews.allSatisfy { $0.info.source.seed == seed }, "every preview uses Create's seed \(seed)")
          check(model.prompt == "Not used by a render", "a render leaves Create's prompt alone")
          check(previews.last?.info.styleID == nil && previews.last?.info.source.prompt.contains(womanWritten) == true, "No Style writes the description into the reference")
          for preview in previews.dropLast() {
            check(preview.info.source.prompt.contains(womanWritten), "\(preview.info.styleName) has the description in its prompt")
          }
          if let preview = previews.first {
            store.save(preview, to: shown.id)
            store.save(preview, to: shown.id)
            check(store.character(id: shown.id)?.images.count == 1, "Save to Character adds the preview once")
            if let sheetValue = value("--sheet") {
              store.edit(shown.id) { $0.sheet = sheetValue; $0.sheetMegapixels = 1; $0.customSheet = "in three outfits, side by side." }
              let before = store.previews[shown.id]?.count ?? 0
              let createSize = model.settings.map { ($0.width, $0.height) }
              let sheetCharacter = store.character(id: shown.id)!
              let expected = store.knobs.sheet(of: sheetCharacter)?.size(megapixels: 1)
              check(store.sheetBlocker(model, for: sheetCharacter) == nil, "ready to render a sheet")
              store.renderSheet(sheetCharacter, in: nil, create: model)
              while store.renderRun != nil { try? await Task.sleep(for: .milliseconds(200)) }
              let sheetPreview = store.previews[shown.id]?.first
              check((store.previews[shown.id]?.count ?? 0) == before + 1, "a sheet is one preview\(store.renderError.map { ": \($0)" } ?? "")")
              check(sheetPreview?.image.width == expected?.width && sheetPreview?.image.height == expected?.height, "the sheet is \(sheetPreview?.image.width ?? 0)×\(sheetPreview?.image.height ?? 0), its own size")
              check(model.settings?.width == createSize?.0 && model.settings?.height == createSize?.1, "Create's size isn't changed")
              check(model.history.items.count == historyBefore, "the sheet isn't saved to the project")
              log("sheet prompt: \(sheetPreview?.info.source.prompt ?? "")")
              if let snapshotDir, let sheetPreview, let png = ImageTensor.png(sheetPreview.image) {
                try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                try? png.write(to: snapshotDir.appendingPathComponent("sheet.png"))
              }
            }
            await store.sendToCreate(preview.image, info: preview.info, create: model, navigation: navigation, undoManager: nil)
            check(store.renderError == nil, "Send to Create worked: \(store.renderError ?? "ok")")
            check(navigation.section == .create, "Send to Create goes to Create")
            check(model.history.items.count == historyBefore + 1, "Send to Create adds one step to the project")
            check(model.history.items.first?.sidecar.prompt == preview.info.source.prompt || model.history.items.contains { $0.sidecar.prompt == preview.info.source.prompt }, "the step has the prompt it was made with")
            check(model.image?.width == preview.image.width, "the image is on the canvas")
            check(model.selectedModel == file && model.seed == seed, "the model and seed are loaded")
            if let id = preview.info.styleID {
              check(model.styleID == id && model.prompt == womanWritten, "the style is selected with the description in Subject")
            } else {
              check(model.styleID == nil && model.prompt == preview.info.source.prompt, "with No Style the prompt it was made with is in the prompt box")
            }
          }
        }

        if let snapshotDir {
          try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
          try? await Task.sleep(for: .seconds(2))
          ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
          navigation.section = .characters
          try? await Task.sleep(for: .seconds(1))
          snapshot(to: snapshotDir.appendingPathComponent("characters.png"))
          store.screenGrid = true
          try? await Task.sleep(for: .seconds(1))
          snapshot(to: snapshotDir.appendingPathComponent("characters-grid.png"))
          store.screenGrid = false
          store.selection = pup.id
          try? await Task.sleep(for: .seconds(1))
          snapshot(to: snapshotDir.appendingPathComponent("characters-dog.png"))
          store.edit(pup.id) { $0.editedDescription = "A young dog, typed by hand." }
          try? await Task.sleep(for: .seconds(1))
          snapshot(to: snapshotDir.appendingPathComponent("characters-edit-as-text.png"))
        }
        store.flush()
      }
    }

    /// A small image to save without running the engine.
    private static func testImage() -> CGImage {
      let context = CGContext(
        data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.setFillColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
      return context.makeImage()!
    }
  }
#endif
