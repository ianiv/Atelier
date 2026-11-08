#if os(macOS)
  @preconcurrency import _MediaGenerationKit
  import Foundation
  @preconcurrency import ModelZoo

  extension Automation {
    /// `--model-move-check`: moving a model and a LoRA between models folders, on small stand-in
    /// files. Launch with two scratch folders as argument defaults, so the saved settings and the
    /// real models stay as they are:
    ///
    ///   Atelier --model-move-check -modelsDirectory A -additionalModelsDirectories '(B)' \
    ///     [--show models --snapshot-dir DIR] [--quit]
    ///
    /// Both must be empty or missing. Writes two imported models in A that share a text encoder,
    /// one with its own VAE, and a LoRA; moves the first model and the LoRA to B, checks the files,
    /// the shared encoder being copied, the custom.json and custom_lora.json entries and what the
    /// engine finds, then moves the LoRA back.
    static func modelMoveCheck(_ model: CreateModel, library: ModelLibrary) {
      Task { @MainActor in
        func log(_ message: String) { print(message); fflush(stdout) }
        func check(_ ok: Bool, _ message: String) { log((ok ? "PASS " : "FAIL ") + message) }
        @MainActor func finish() {
          // With --show models (or loras) and --snapshot-dir DIR, a picture of the list.
          let args = CommandLine.arguments
          if let index = args.firstIndex(of: "--snapshot-dir"), index + 1 < args.count {
            snapshot(to: URL(fileURLWithPath: args[index + 1]).appendingPathComponent("model-move.png"))
          }
          log("DONE model move check")
          if CommandLine.arguments.contains("--quit") { exit(0) }
        }
        let fm = FileManager.default
        let a = URL(fileURLWithPath: model.modelsDirectory, isDirectory: true)
        guard let bPath = model.additionalModelsDirectories.first else {
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
        let moving = "move_check_f16.ckpt", other = "move_check_other_f16.ckpt"
        let vae = "move_check_vae_f16.ckpt", encoder = "move_check_te_f16.ckpt"
        let lora = "move_check_lora_f16.ckpt"
        for (file, size) in [(moving, 3 << 20), (moving + "-tensordata", 1 << 20), (other, 1024), (vae, 2048), (encoder, 4096), (lora, 512)] {
          fm.createFile(atPath: a.appendingPathComponent(file).path, contents: Data((0..<size).map { UInt8(truncatingIfNeeded: $0) }))
        }
        for file in [moving, other] {
          var specification = ModelLibrary.specification(for: file, template: template)
          specification.textEncoder = encoder
          specification.autoencoder = file == moving ? vae : encoder
          specification.clipEncoder = encoder
          specification.additionalClipEncoders = nil
          try? ModelLibrary.addToCustomJSON(specification, in: a)
        }
        try? #"[{"name": "Move Check", "file": "\#(lora)", "prefix": "", "version": "sdxl_base_v0.9"}]"#.write(
          to: a.appendingPathComponent("custom_lora.json"), atomically: true, encoding: .utf8)
        await model.reloadModels()
        await library.refresh()

        @MainActor func wait() async {
          while library.moving != nil { try? await Task.sleep(for: .milliseconds(100)) }
          await library.refresh()
        }
        func here(_ file: String, _ folder: URL) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(file).path) }
        func registered(_ registry: String, _ folder: URL) -> [String] {
          struct Entry: Decodable { var file: String }
          let data = fm.contents(atPath: folder.appendingPathComponent(registry).path) ?? Data("[]".utf8)
          return ((try? JSONDecoder().decode([Entry].self, from: data)) ?? []).map(\.file)
        }

        guard let entry = library.catalog.first(where: { $0.file == moving }) else {
          log("FAIL the stand-in model isn't in the catalog")
          return finish()
        }
        check(library.folders[moving]?.standardizedFileURL == a.standardizedFileURL, "the model is listed in A")
        check(library.canMove(entry), "the model can be moved")
        guard let plan = library.planMove(entry, to: b) else {
          log("FAIL no plan: \(library.errorMessage ?? "")")
          return finish()
        }
        check(
          Set(plan.moved) == [moving, moving + "-tensordata", vae] && plan.copied == [encoder] && plan.registry == "custom.json",
          "the plan moves the model and its VAE and copies the shared encoder: \(plan.moved), \(plan.copied)")
        log(library.describe(plan))
        library.runMove(plan)
        check(!library.canMove(entry), "no second move while one runs")
        await wait()
        check(library.errorMessage == nil, "no error: \(library.errorMessage ?? "")")
        check(
          [moving, moving + "-tensordata", vae, encoder].allSatisfy { here($0, b) } && !here(moving, a) && !here(vae, a),
          "the files are in B and gone from A")
        check(here(encoder, a) && here(other, a), "the shared encoder and the other model stay in A")
        check(
          fm.contents(atPath: b.appendingPathComponent(moving).path) == Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0) }),
          "the moved file is intact")
        check(registered("custom.json", b) == [moving] && registered("custom.json", a) == [other], "the custom.json entry moved")
        check(library.folders[moving]?.standardizedFileURL == b.standardizedFileURL, "the library lists the model in B")
        check(ModelZoo.specificationForModel(moving) != nil, "the engine still knows the model")
        check(ModelZoo.isModelDownloaded(moving, memorizedBy: []), "the engine finds the model")
        check(fm.fileExists(atPath: a.appendingPathComponent("custom.json.bak-atelier").path), "A's custom.json was backed up")

        guard let loraEntry = library.loras.first(where: { $0.file == lora }),
              let loraPlan = library.planMove(loraEntry, to: b)
        else {
          log("FAIL no LoRA plan: \(library.errorMessage ?? "")")
          return finish()
        }
        library.runMove(loraPlan)
        await wait()
        check(here(lora, b) && !here(lora, a), "the LoRA moved to B")
        check(registered("custom_lora.json", b) == [lora] && registered("custom_lora.json", a).isEmpty, "its entry moved")
        check(
          library.loras.first { $0.file == lora }?.folder?.standardizedFileURL == b.standardizedFileURL,
          "the library lists the LoRA in B")
        check(LoRAZoo.specificationForModel(lora) != nil, "the engine knows the LoRA")
        if let back = library.loras.first(where: { $0.file == lora }).flatMap({ library.planMove($0, to: a) }) {
          library.runMove(back)
          await wait()
        }
        check(here(lora, a) && !here(lora, b) && registered("custom_lora.json", a) == [lora], "the LoRA moved back")
        check(library.planMove(entry, to: b) == nil, "a folder that has the file can't be chosen again")
        finish()
      }
    }
  }
#endif
