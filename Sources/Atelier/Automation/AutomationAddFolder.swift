#if os(macOS)
  @preconcurrency import _MediaGenerationKit
  import Foundation
  @preconcurrency import ModelZoo

  extension Automation {
    /// `--add-folder-check`: choosing which models folder new files go to, on small stand-in files.
    /// Launch with two scratch folders as argument defaults, so the saved settings and the real
    /// models stay as they are:
    ///
    ///   Atelier --add-folder-check -modelsDirectory A -additionalModelsDirectories '(B)' \
    ///     [--download FILE] [--show models --snapshot-dir DIR] [--quit]
    ///
    /// Both must be empty or missing. Chooses B, then does what an import there does after
    /// converting (moves the new files from A, lists the model in B's custom.json) and checks the
    /// files, the registry and what the engine and the library find. Lists one in A the engine's
    /// way too, and checks a missing chosen folder falls back to A. With `--download FILE`, also
    /// downloads that catalog file (a small one: realesrgan_x2plus_f16.ckpt is 34 MB) into B.
    static func addFolderCheck(_ model: CreateModel, library: ModelLibrary) {
      Task { @MainActor in
        func log(_ message: String) { print(message); fflush(stdout) }
        func check(_ ok: Bool, _ message: String) { log((ok ? "PASS " : "FAIL ") + message) }
        let args = CommandLine.arguments
        // The choice is saved like any other setting; put back what was there before exiting.
        let saved = UserDefaults.standard.string(forKey: ModelLibrary.addFolderKey)
        @MainActor func finish() {
          if let saved { UserDefaults.standard.set(saved, forKey: ModelLibrary.addFolderKey) } else { UserDefaults.standard.removeObject(forKey: ModelLibrary.addFolderKey) }
          if let index = args.firstIndex(of: "--snapshot-dir"), index + 1 < args.count {
            snapshot(to: URL(fileURLWithPath: args[index + 1]).appendingPathComponent("add-folder.png"))
          }
          log("DONE add folder check")
          if args.contains("--quit") { exit(0) }
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
        await model.reloadModels()
        await library.refresh()
        func here(_ file: String, _ folder: URL) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(file).path) }
        func registered(_ folder: URL) -> [String] {
          struct Entry: Decodable { var file: String }
          let data = fm.contents(atPath: folder.appendingPathComponent("custom.json").path) ?? Data("[]".utf8)
          return ((try? JSONDecoder().decode([Entry].self, from: data)) ?? []).map(\.file)
        }

        check(library.addFolder.standardizedFileURL == a.standardizedFileURL, "adds to the first folder by default")
        library.setAddFolder(b)
        check(library.addFolder.standardizedFileURL == b.standardizedFileURL, "adds to the chosen folder")
        check(!library.isEngineFolder(b), "the chosen folder isn't the one the engine writes to")

        // What an import into B does once the converter has written to A.
        let file = "add_check_f16.ckpt", encoder = "add_check_clip_vit_l14_f16.ckpt"
        for (name, size) in [(file, 3 << 20), (file + "-tensordata", 1 << 20), (encoder, 4096)] {
          fm.createFile(atPath: a.appendingPathComponent(name).path, contents: Data(count: size))
        }
        var specification = ModelLibrary.specification(for: file, template: template)
        specification.clipEncoder = encoder
        do {
          try await ModelLibrary.moveImported([file, file + "-tensordata", encoder], from: a, to: b)
          try library.registerImported(specification, in: b)
        } catch {
          log("FAIL moving the import: \(error.localizedDescription)")
        }
        check([file, file + "-tensordata", encoder].allSatisfy { here($0, b) && !here($0, a) }, "the import's files are in B, not A")
        check(registered(b) == [file] && registered(a).isEmpty, "listed in B's custom.json only")
        check(ModelZoo.specificationForModel(file) != nil, "the engine knows the imported model")
        await library.afterChange()
        check(library.catalog.contains { $0.file == file && $0.isDownloaded }, "the library lists it as downloaded")
        check(library.folders[file]?.standardizedFileURL == b.standardizedFileURL, "the library finds it in B")

        // The first folder keeps the engine's own way of listing.
        let first = "add_check_first_f16.ckpt"
        fm.createFile(atPath: a.appendingPathComponent(first).path, contents: Data(count: 1024))
        try? library.registerImported(ModelLibrary.specification(for: first, template: template), in: a)
        check(registered(a) == [first], "listed in A's custom.json the engine's way")

        // A chosen folder that's gone falls back to the first.
        library.addFolderPath = b.appendingPathComponent("missing").path
        check(library.addFolder.standardizedFileURL == a.standardizedFileURL, "a missing chosen folder falls back to A")
        library.setAddFolder(b)

        if let index = args.firstIndex(of: "--download"), index + 1 < args.count {
          let download = args[index + 1]
          log("downloading \(download) into B")
          do {
            try await ModelLibrary.downloadModel(download, into: b) { name, index, total, written, expected in
              if written == expected { print("  \(name) \(index) of \(total): \(written) bytes") }
            }
            check(here(download, b) && !here(download, a), "the download is in B, not A")
          } catch {
            log("FAIL download: \(error.localizedDescription)")
          }
        }
        await library.refresh()
        if let index = args.firstIndex(of: "--show"), index + 1 < args.count { try? await Task.sleep(for: .seconds(1)) }
        finish()
      }
    }
  }
#endif
