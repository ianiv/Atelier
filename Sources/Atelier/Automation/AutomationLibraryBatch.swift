#if os(macOS)
  @preconcurrency import _MediaGenerationKit
  import Foundation
  @preconcurrency import ModelZoo

  extension Automation {
    /// `--library-batch-check`: Move To and Move to Trash on several models and LoRAs at once
    /// (the Models and LoRAs screens' multi-selections), on small stand-in files. Launch with two
    /// scratch folders as argument defaults, so the saved settings and the real models stay as
    /// they are:
    ///
    ///   Atelier --library-batch-check -modelsDirectory A -additionalModelsDirectories '(B)' \
    ///     [--show models --snapshot-dir DIR] [--quit]
    ///
    /// Both must be empty or missing. Writes three imported models in A sharing a text encoder,
    /// the first with its own VAE and an 8-bit copy that names the same VAE, and three LoRAs, one
    /// with no file. Moves two models and two LoRAs to B in one batch each (the encoder, which a
    /// model outside the batch needs, is copied once), checks a model already in B is skipped,
    /// then selects all four models, checks the summary and the confirmation, and trashes them
    /// with one of them locked, so the rest go and that one is reported. Takes its own items out
    /// of the Trash afterwards. The Add To choice and the Models filter are put back as they were.
    static func libraryBatchCheck(_ model: CreateModel, library: ModelLibrary) {
      Task { @MainActor in
        func log(_ message: String) { print(message); fflush(stdout) }
        func check(_ ok: Bool, _ message: String) { log((ok ? "PASS " : "FAIL ") + message) }
        let args = CommandLine.arguments
        let fm = FileManager.default
        let defaults = UserDefaults.standard
        let savedAddFolder = defaults.string(forKey: ModelLibrary.addFolderKey)
        let savedFilter = defaults.string(forKey: "modelsFilter")
        var trashed: [URL] = []
        var locked: URL?
        @MainActor func finish() {
          if let locked { try? fm.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
          for url in trashed { try? fm.removeItem(at: url) }
          if let savedAddFolder { defaults.set(savedAddFolder, forKey: ModelLibrary.addFolderKey) } else { defaults.removeObject(forKey: ModelLibrary.addFolderKey) }
          if let savedFilter { defaults.set(savedFilter, forKey: "modelsFilter") } else { defaults.removeObject(forKey: "modelsFilter") }
          library.modelScreen.selection = []
          log("DONE library batch check")
          if args.contains("--quit") { exit(0) }
        }
        let a = URL(fileURLWithPath: model.modelsDirectory, isDirectory: true)
        guard let bPath = model.additionalModelsDirectories.first, model.additionalModelsDirectories.count == 1 else {
          log("FAIL pass -additionalModelsDirectories '(B)'")
          return finish()
        }
        let b = URL(fileURLWithPath: bPath, isDirectory: true)
        for folder in [a, b] {
          try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
          guard ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty else {
            log("FAIL \(folder.path) isn't empty: use scratch folders")
            return finish()
          }
        }
        guard let template = ModelZoo.builtinSpecifications.first(where: { $0.version == .sdxlBase }) else {
          log("FAIL no SDXL template")
          return finish()
        }
        library.addFolderPath = a.path
        defaults.set(ModelsView.Filter.downloaded.rawValue, forKey: "modelsFilter")

        let one = "batch_check_1_f16.ckpt", two = "batch_check_2_f16.ckpt", three = "batch_check_3_f16.ckpt"
        let copy = "batch_check_1_q8p.ckpt", vae = "batch_check_1_vae_f16.ckpt", encoder = "batch_check_te_f16.ckpt"
        let loraFiles = ["batch_check_a_lora_f16.ckpt", "batch_check_b_lora_f16.ckpt", "batch_check_c_lora_f16.ckpt"]
        for (file, size) in [(one, 2048), (two, 3 << 20), (two + "-tensordata", 1024), (three, 1024), (copy, 1024), (vae, 512), (encoder, 4096), (loraFiles[0], 256), (loraFiles[1], 256)] {
          fm.createFile(atPath: a.appendingPathComponent(file).path, contents: Data((0..<size).map { UInt8(truncatingIfNeeded: $0) }))
        }
        for file in [one, two, three, copy] {
          var specification = ModelLibrary.specification(for: file, template: template)
          specification.textEncoder = encoder
          specification.autoencoder = file == one || file == copy ? vae : encoder
          specification.clipEncoder = encoder
          specification.additionalClipEncoders = nil
          try? ModelLibrary.addToCustomJSON(specification, in: a)
        }
        let loraJSON = loraFiles.enumerated().map { index, file in
          #"{"name": "Batch Check \#(index + 1)", "file": "\#(file)", "prefix": "", "version": "sdxl_base_v0.9"}"#
        }
        try? "[\(loraJSON.joined(separator: ","))]".write(to: a.appendingPathComponent("custom_lora.json"), atomically: true, encoding: .utf8)
        await model.reloadModels()
        await library.refresh()

        @MainActor func wait() async {
          while library.moving != nil { try? await Task.sleep(for: .milliseconds(50)) }
          await library.refresh()
        }
        func here(_ file: String, _ folder: URL) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(file).path) }
        func registered(_ registry: String, _ folder: URL) -> [String] {
          struct Entry: Decodable { var file: String }
          let data = fm.contents(atPath: folder.appendingPathComponent(registry).path) ?? Data("[]".utf8)
          return ((try? JSONDecoder().decode([Entry].self, from: data)) ?? []).map(\.file).sorted()
        }
        @MainActor func entries(_ files: [String]) -> [MediaGenerationResolvedModel] {
          files.compactMap { file in library.catalog.first { $0.file == file } }
        }

        // Move To: models 2 and 3; model 1 and its copy, outside the batch, need the encoder.
        guard entries([one, two, three, copy]).count == 4 else {
          log("FAIL the stand-in models aren't in the catalog")
          return finish()
        }
        guard let batch = library.planMoves(entries([two, three]), to: b) else {
          log("FAIL no move plan: \(library.errorMessage ?? "")")
          return finish()
        }
        check(batch.items.map(\.file) == [two, three] && batch.skipped.isEmpty, "the batch moves both models")
        check(
          batch.items[0].copied == [encoder] && batch.items[1].copied.isEmpty,
          "the shared encoder is copied once, by the first: \(batch.items.map(\.copied))")
        check(
          batch.items.allSatisfy { !$0.moved.contains(encoder) } && batch.items.allSatisfy { $0.registry == "custom.json" },
          "the encoder isn't moved, and both custom.json entries go")
        log(library.describe(batch))
        library.runMoves(batch)
        check(library.moving?.count == 2 && library.moving?.index == 0, "the move runs as one batch of 2")
        check(!library.canMove(entries([one])[0]), "no other move while it runs")
        await wait()
        check(library.errorMessage == nil, "no error: \(library.errorMessage ?? "")")
        check(library.lastMoveOutcome?.moved == [two, three] && library.lastMoveOutcome?.failed.isEmpty == true, "both moved")
        check(
          [two, two + "-tensordata", three, encoder].allSatisfy { here($0, b) } && !here(two, a) && !here(three, a),
          "the models are in B")
        check(here(encoder, a) && here(one, a) && here(vae, a) && !here(vae, b), "the encoder stays in A too, with model 1 and its VAE")
        check(
          fm.contents(atPath: b.appendingPathComponent(two).path) == Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0) }),
          "the moved file is intact")
        check(registered("custom.json", b) == [two, three] && registered("custom.json", a) == [one, copy], "the entries moved")

        // Models already in B are left out of a later batch; one B has a copy of is skipped.
        if let again = library.planMoves(entries([one, two, three]), to: b) {
          check(
            again.items.map(\.file) == [one] && again.items[0].copied == [vae] && !again.items[0].moved.contains(encoder),
            "a batch leaves out what lives in B and doesn't move what B has: \(again.items.map(\.moved))")
        } else {
          check(false, "no second plan: \(library.errorMessage ?? "")")
        }
        fm.createFile(atPath: b.appendingPathComponent(one).path, contents: Data([1]))
        check(
          library.planMoves(entries([one]), to: b) == nil && library.errorMessage?.contains("already in") == true,
          "a model B already has is refused: \(library.errorMessage ?? "")")
        try? fm.removeItem(at: b.appendingPathComponent(one))

        // LoRAs: two with files to B, in one batch.
        let loras = library.loras.filter { loraFiles.contains($0.file) }
        if let loraBatch = library.planMoves(loras, to: b) {
          check(loraBatch.items.count == 2, "the LoRA batch moves the two with files")
          library.runMoves(loraBatch)
          await wait()
          check(loraFiles.prefix(2).allSatisfy { here($0, b) && !here($0, a) }, "the LoRAs are in B")
          check(
            registered("custom_lora.json", b) == Array(loraFiles.prefix(2)) && registered("custom_lora.json", a) == [loraFiles[2]],
            "their entries moved; the missing one's stayed")
        } else {
          check(false, "no LoRA plan: \(library.errorMessage ?? "")")
        }

        // Move to Trash: all four models, from two folders.
        library.modelScreen.selection = [one, two, three, copy]
        let selected = entries([one, two, three, copy])
        let summary = ModelLibrary.SelectionSummary.make(
          files: selected.map(\.file), sizes: library.sizes, folders: library.folders.mapValues(library.folderName),
          families: Dictionary(selected.compactMap { model in model.version.map { (model.file, $0) } }) { first, _ in first })
        check(
          summary.count == 4 && summary.downloaded == 4 && summary.folder == "2 folders" && summary.folderCounts.count == 2,
          "the summary counts 4 in 2 folders: \(summary)")
        check(library.selectionKinds(selected).canTrash && library.selectionKinds(selected).canMove, "Move to Trash and Move To fit")
        if args.contains("--snapshot-dir") {
          try? await Task.sleep(for: .seconds(1))
          if let index = args.firstIndex(of: "--snapshot-dir"), index + 1 < args.count {
            snapshot(to: URL(fileURLWithPath: args[index + 1]).appendingPathComponent("library-batch.png"))
          }
        }
        guard let trash = library.planTrash(selected) else {
          log("FAIL no trash plan")
          return finish()
        }
        check(trash.items.count == 4 && trash.skipped.isEmpty, "all four can go")
        check(
          trash.items.first { $0.file == one }?.companions == [vae],
          "model 1 takes its VAE, which only its copy, also going, names: \(trash.items.map(\.companions))")
        check(ModelLibrary.trashTitle(trash) == "Move 4 models to the Trash?", "the title counts them")
        log(ModelLibrary.trashMessage(trash))
        check(ModelLibrary.trashMessage(trash).contains("4 imported models are also removed from custom.json."), "the message says custom.json")
        // A locked file can't go to the Trash: the rest still do.
        let lockedURL = b.appendingPathComponent(three)
        try? fm.setAttributes([.immutable: true], ofItemAtPath: lockedURL.path)
        locked = lockedURL
        let result = await library.trash(trash)
        trashed += result.trashedURLs
        check(
          result.failed.map(\.name) == [entries([three]).first?.name ?? three] && result.trashed.sorted() == [one, two, copy].sorted(),
          "the locked one is reported, the rest go: \(result.failed)")
        check(library.errorMessage?.hasPrefix("Couldn't move 1 of 4 to the Trash") == true, "one alert: \(library.errorMessage ?? "")")
        check(![one, copy, vae].contains { here($0, a) } && !here(two, b) && !here(two + "-tensordata", b), "their files went")
        check(here(encoder, a) && here(encoder, b), "the shared encoder stays")
        check(registered("custom.json", a).isEmpty && registered("custom.json", b) == [three], "custom.json keeps only the one that stayed")
        check(fm.fileExists(atPath: a.appendingPathComponent("custom.json.bak-atelier").path), "custom.json was backed up")
        try? fm.setAttributes([.immutable: false], ofItemAtPath: lockedURL.path)
        locked = nil
        library.errorMessage = nil
        if let entry = entries([three]).first, let single = library.planTrash([entry]) {
          check(
            ModelLibrary.trashTitle(single) == "Move \(entry.name) to the Trash?"
              && ModelLibrary.trashMessage(single).hasPrefix("\(three) is moved to the Trash and removed from custom.json."),
            "one model reads as before")
          trashed += await library.trash(single).trashedURLs
        }
        check(!here(three, b) && registered("custom.json", b).isEmpty, "then it goes too")

        // LoRAs: the two in B and the one with no file, in one batch.
        let allLoRAs = library.loras.filter { loraFiles.contains($0.file) }
        if let loraTrash = library.planTrash(allLoRAs) {
          check(
            loraTrash.items.count == 3 && ModelLibrary.trashMessage(loraTrash).contains("1 only loses its custom_lora.json entry"),
            "three LoRAs, one only an entry")
          let loraResult = library.trashLoRAs(loraTrash)
          trashed += loraResult.trashedURLs
          check(loraResult.failed.isEmpty && loraResult.trashed.count == 3, "all three went: \(loraResult.failed)")
          check(!loraFiles.contains { here($0, a) || here($0, b) }, "the LoRA files went")
          check(registered("custom_lora.json", a).isEmpty && registered("custom_lora.json", b).isEmpty, "both custom_lora.json files are empty")
          check(!library.loras.contains { loraFiles.contains($0.file) }, "the list dropped them")
        } else {
          check(false, "no LoRA trash plan")
        }
        finish()
      }
    }
  }
#endif
