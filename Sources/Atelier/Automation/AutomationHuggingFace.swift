#if os(macOS)
  import CryptoKit
  @preconcurrency import Diffusion
  import Foundation
  @preconcurrency import ModelZoo

  extension Automation {
    /// `--hf-link-check`: importing from Hugging Face links, against small public test repos.
    /// Launch with an empty scratch folder as the only models folder, as argument defaults, so the
    /// saved settings, ~/Atelier and the real models folder stay as they are:
    ///
    ///   Atelier --hf-link-check -modelsDirectory SCRATCH -additionalModelsDirectories '()' \
    ///     [--import-lora] [--diffusers] [--gated] [--quit]
    ///
    /// Refuses unless SCRATCH is empty and the only folder. The token is kept in memory (from
    /// `HF_TOKEN` if set), never the Keychain.
    /// - (a) hf-internal-testing/tiny-sd-lora-peft's pytorch_lora_weights.safetensors (132 kB):
    ///   link parsing, listing, a download cancelled at once and resumed, its SHA-256, the handoff
    ///   to the LoRA import sheet, and the unfinished list, then discards it.
    /// - (b) hf-internal-testing/tiny-random-bert-sharded-safetensors: five parts and an index,
    ///   joined; every tensor's bytes match the parts on Hugging Face, and the model import sheet
    ///   says it isn't a checkpoint it recognizes (without crashing).
    /// - (c) hf-internal-testing/tiny-stable-diffusion-pipe: a Diffusers repo; unet/ is picked,
    ///   text_encoder/ and vae/ listed as not imported, the .bin downloads and is turned away cleanly.
    /// - `--import-lora`: latent-consistency/lcm-lora-sdv1-5 (135 MB), cancelled partway and
    ///   resumed, imported into SCRATCH's custom_lora.json; the staging folder goes after.
    /// - `--diffusers`: stable-diffusion-v1-5's fp16 unet (1.7 GB): detected as SD 1.5 before the
    ///   download, imported, and its text encoder and VAE downloaded.
    /// - `--gated` (needs `HF_TOKEN`, run by hand): black-forest-labs/FLUX.1-dev's ae.safetensors.
    static func huggingFaceLinkCheck(_ model: CreateModel, library: ModelLibrary) {
      Task { @MainActor in
        func log(_ message: String) { print(message); fflush(stdout) }
        func check(_ ok: Bool, _ message: String) { log((ok ? "PASS " : "FAIL ") + message) }
        let args = CommandLine.arguments
        let savedAddFolder = UserDefaults.standard.string(forKey: ModelLibrary.addFolderKey)
        @MainActor func finish() {
          if let savedAddFolder {
            UserDefaults.standard.set(savedAddFolder, forKey: ModelLibrary.addFolderKey)
          } else {
            UserDefaults.standard.removeObject(forKey: ModelLibrary.addFolderKey)
          }
          log("DONE hf link check")
          if args.contains("--quit") { exit(0) }
        }
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: model.modelsDirectory, isDirectory: true).standardizedFileURL
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        guard ((try? fm.contentsOfDirectory(atPath: scratch.path)) ?? []).isEmpty else {
          log("FAIL \(scratch.path) isn't empty: pass an empty scratch folder as -modelsDirectory")
          return finish()
        }
        guard model.additionalModelsDirectories.isEmpty else {
          log("FAIL other models folders are set: pass -additionalModelsDirectories '()'")
          return finish()
        }
        await model.reloadModels()
        await library.refresh()
        library.setAddFolder(scratch)
        guard library.addFolder.standardizedFileURL == scratch, library.directory.standardizedFileURL == scratch,
              library.directories.map(\.standardizedFileURL) == [scratch]
        else {
          log("FAIL the models folders aren't just \(scratch.path): \(library.directories.map(\.path))")
          return finish()
        }
        check(true, "SCRATCH is the only models folder and the one new files go to")
        let staging = scratch.appendingPathComponent(ModelLibrary.stagingFolderName)

        func sha256(_ url: URL) -> String? {
          guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
          defer { try? handle.close() }
          var hasher = SHA256()
          while let data = try? handle.read(upToCount: 16 << 20), !data.isEmpty { hasher.update(data: data) }
          return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        @MainActor func lookUp(_ text: String) async -> HuggingFaceLookup? {
          guard let link = HuggingFaceLink.parse(text) else {
            log("FAIL \(text) doesn't parse")
            return nil
          }
          do {
            return try await library.lookUp(link)
          } catch {
            log("FAIL looking up \(text): \(error.localizedDescription)")
            return nil
          }
        }
        /// Starts a download and returns its staging folder's path.
        @MainActor func start(_ entries: [HuggingFaceListing.Entry], _ kind: HuggingFaceListing.Kind, _ lookup: HuggingFaceLookup) -> String? {
          let before = Set(library.linkDownloadTasks.keys)
          library.startLinkDownload(entries, kind: kind, lookup: lookup, linkText: lookup.link.repo)
          return Set(library.linkDownloadTasks.keys).subtracting(before).first
        }
        @MainActor func waitForDownload(_ key: String) async {
          await waitUntil { library.linkDownloadTasks[key] == nil }
        }
        @MainActor func discardAll() async {
          await library.reloadUnfinishedLinkDownloads()
          for unfinished in library.unfinishedLinkDownloads { await library.discardLinkDownload(unfinished) }
        }

        // (a) A tiny LoRA.
        log("(a) tiny LoRA")
        let parsed = HuggingFaceLink.parse("https://huggingface.co/hf-internal-testing/tiny-sd-lora-peft/blob/main/pytorch_lora_weights.safetensors?download=true")
        check(
          parsed == HuggingFaceLink(repo: "hf-internal-testing/tiny-sd-lora-peft", revision: "main", path: "pytorch_lora_weights.safetensors"),
          "a blob link parses to repo, revision and file")
        if let lookup = await lookUp("https://huggingface.co/hf-internal-testing/tiny-sd-lora-peft/blob/main/pytorch_lora_weights.safetensors") {
          let entry = lookup.listing.entries.first { $0.id == "pytorch_lora_weights.safetensors" }
          check(entry?.size == 132_216 && entry?.files.first?.sha256 != nil, "the listing has the 132,216-byte file with its SHA-256")
          check(HuggingFaceListing.guessesLoRA(repo: lookup.link.repo, entry: entry), "a LoRA repo starts the sheet on LoRA")
          check(entry?.loraOutput == "tiny-sd-lora-peft.safetensors", "a generic file name takes the repo's name")
          if let entry, let key = start([entry], .lora, lookup) {
            library.cancelLinkDownload(key)
            await waitForDownload(key)
            await library.reloadUnfinishedLinkDownloads()
            let unfinished = library.unfinishedLinkDownloads.first { $0.id == key }
            check(unfinished != nil && fm.fileExists(atPath: key + "/" + ModelLibrary.recordName), "a cancelled download is kept as unfinished with its record")
            if let unfinished {
              library.resumeLinkDownload(unfinished)
              await waitForDownload(key)
            } else {
              library.cancelImports()
            }
            let output = URL(fileURLWithPath: key).appendingPathComponent(entry.loraOutput)
            check(sha256(output) == entry.files.first?.sha256, "resumed, and the file matches its LFS SHA-256")
            check(library.importing.contains { $0.ownedFolder?.path == key && $0.source == output }, "the LoRA import sheet gets the downloaded file")
            library.cancelImports()
            await library.reloadUnfinishedLinkDownloads()
            check(library.unfinishedLinkDownloads.first { $0.id == key }?.isComplete == true, "a download whose import was cancelled is listed as downloaded, not imported")
            await discardAll()
            check(!fm.fileExists(atPath: key) && !fm.fileExists(atPath: staging.path), "Discard deletes the staging folder")
          } else {
            log("FAIL couldn't start the tiny LoRA download: \(library.errorMessage ?? "")")
          }
        }

        // (b) Split safetensors.
        log("(b) split safetensors")
        if let lookup = await lookUp("hf-internal-testing/tiny-random-bert-sharded-safetensors") {
          let entry = lookup.listing.entries.first { $0.merges }
          check(entry?.weights.count == 5 && entry?.index != nil, "five parts and their index are one row")
          check(entry?.loraProblem != nil, "split files can't be imported as a LoRA")
          if let entry {
            let inspection = await library.inspectBeforeDownload(entry, lookup: lookup)
            log("  before download: \(inspection)")
            check(inspection == .problem("Not a model checkpoint the importer recognizes."), "the header check before downloading says it isn't a checkpoint")
          }
          if let entry, let key = start([entry], .model, lookup) {
            await waitForDownload(key)
            if let message = library.errorMessage { log("FAIL download: \(message)") }
            let merged = URL(fileURLWithPath: key).appendingPathComponent(entry.modelOutput)
            check(entry.weights.allSatisfy { !fm.fileExists(atPath: key + "/" + $0.path) }, "the parts are deleted once joined")
            // Compare every tensor with the parts on Hugging Face.
            var matches = true
            var count = 0
            if let header = try? SafetensorsHeader.read(merged), let mergedData = fm.contents(atPath: merged.path) {
              let headerLength = mergedData.prefix(8).withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
              check((8 + headerLength) % 8 == 0, "the joined header is padded to 8 bytes")
              for file in entry.weights {
                let url = HuggingFaceLink.resolveURL(repo: lookup.link.repo, revision: lookup.info.sha, path: file.path)
                guard let data = try? await HuggingFaceAuth.data(url, token: nil, repo: lookup.link.repo, user: nil).0 else {
                  matches = false
                  continue
                }
                let partLength = data.prefix(8).withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
                let part = (try? JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + partLength)))) as? [String: Any] ?? [:]
                for (name, value) in part where name != "__metadata__" {
                  count += 1
                  guard let offsets = (value as? [String: Any])?["data_offsets"] as? [Int],
                        let joined = (header[name] as? [String: Any])?["data_offsets"] as? [Int]
                  else { matches = false; continue }
                  let original = data.subdata(in: (8 + partLength + offsets[0])..<(8 + partLength + offsets[1]))
                  let copy = mergedData.subdata(in: (8 + headerLength + joined[0])..<(8 + headerLength + joined[1]))
                  if original != copy { matches = false }
                }
              }
              check(matches && count == header.keys.filter { $0 != "__metadata__" }.count && count > 0, "all \(count) tensors match the parts byte for byte")
              check(SafeTensors(url: merged) != nil, "the engine's SafeTensors reads the joined file")
            } else {
              log("FAIL the joined file isn't readable")
            }
            check(library.importingModels.contains { $0.ownedFolder?.path == key }, "the model import sheet gets the joined file")
            await waitUntil { !library.importingModels.contains { $0.isInspecting } }
            let problem = library.importingModels.first { $0.ownedFolder?.path == key }?.problem
            log("  import sheet: \(problem ?? "no problem")")
            check(problem == "Not a model checkpoint the importer recognizes.", "the import sheet turns it away without crashing")
            library.cancelModelImports()
            await discardAll()
          }
        }

        // (c) A Diffusers repo.
        log("(c) Diffusers repo")
        if let lookup = await lookUp("https://huggingface.co/hf-internal-testing/tiny-stable-diffusion-pipe/tree/main") {
          let diffusers = lookup.listing.diffusers
          check(diffusers?.folder == "unet", "Diffusers detected, with unet/ as the denoiser (\(diffusers?.className ?? "none"))")
          let variant = diffusers?.variants.first?.entry
          log("  variants: \(diffusers?.variants.map(\.title) ?? []), picked \(variant?.files.map(\.path) ?? [])")
          check(variant?.files.contains { $0.path.hasPrefix("unet/") && $0.pathExtension == "bin" } == true, "the unet/ .bin is picked")
          let encoders = lookup.listing.entries.filter { $0.files.contains { $0.path.hasPrefix("text_encoder/") || $0.path.hasPrefix("vae/") } }
          check(!encoders.isEmpty && encoders.allSatisfy { $0.modelProblem == HuggingFaceListing.usesOwnEncoders }, "text_encoder/ and vae/ are listed as not imported")
          if let variant, let key = start([variant], .model, lookup) {
            await waitForDownload(key)
            if let message = library.errorMessage { log("FAIL download: \(message)") }
            check(fm.fileExists(atPath: key + "/tiny-stable-diffusion-pipe.ckpt"), "the .bin is handed over as <repo>.ckpt")
            await waitUntil { !library.importingModels.contains { $0.isInspecting } }
            let item = library.importingModels.first { $0.ownedFolder?.path == key }
            log("  import sheet: \(item?.problem ?? item?.family ?? "missing")")
            check(item != nil && item?.problem != nil, "the import sheet turns the tiny UNet away cleanly")
            library.cancelModelImports()
            await discardAll()
          }
        }

        if args.contains("--import-lora") {
          log("--import-lora: lcm-lora-sdv1-5")
          if let lookup = await lookUp("https://huggingface.co/latent-consistency/lcm-lora-sdv1-5"),
             let entry = lookup.listing.entries.first(where: { $0.id == "pytorch_lora_weights.safetensors" })
          {
            check(entry.size == 134_621_556, "the listing has the 134,621,556-byte LoRA")
            if let key = start([entry], .lora, lookup) {
              await waitUntil { (library.linkDownloads[key]?.download?.bytesWritten ?? 0) > 30 << 20 || library.linkDownloadTasks[key] == nil }
              library.cancelLinkDownload(key)
              await waitForDownload(key)
              let partial = key + "/pytorch_lora_weights.safetensors.partial"
              let kept = fm.fileExists(atPath: partial) || fm.fileExists(atPath: key + "/pytorch_lora_weights.safetensors.part")
              check(kept, "cancelling partway keeps the partial file")
              await library.reloadUnfinishedLinkDownloads()
              if let unfinished = library.unfinishedLinkDownloads.first(where: { $0.id == key }) {
                library.resumeLinkDownload(unfinished)
                await waitForDownload(key)
              }
              let output = URL(fileURLWithPath: key).appendingPathComponent(entry.loraOutput)
              check(sha256(output) == entry.files.first?.sha256, "resumed, and the file matches its LFS SHA-256")
              check(library.importing.contains { $0.ownedFolder?.path == key }, "the LoRA import sheet gets it")
              library.runImports(version: nil, asksH3: false)
              await waitUntil { !library.isImporting }
              if let message = library.errorMessage { log("FAIL import: \(message)") }
              let registry = fm.contents(atPath: scratch.appendingPathComponent("custom_lora.json").path).flatMap { String(data: $0, encoding: .utf8) } ?? ""
              check(registry.contains("lcm-lora-sdv1-5"), "listed in SCRATCH's custom_lora.json")
              check(library.loras.contains { $0.file.hasPrefix("lcm_lora_sdv1_5") && $0.registry.standardizedFileURL.path == scratch.path }, "the LoRA is in the library")
              check(!fm.fileExists(atPath: key), "the staging folder is deleted after the import")
            }
          }
        }

        if args.contains("--diffusers") {
          log("--diffusers: stable-diffusion-v1-5 fp16 unet")
          if let lookup = await lookUp("https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5") {
            let variant = lookup.listing.diffusers?.variants.first
            check(variant?.name == "fp16" && variant?.entry.size == 1_719_125_304, "the fp16 unet is the default precision")
            if let entry = variant?.entry {
              let inspection = await library.inspectBeforeDownload(entry, lookup: lookup)
              log("  before download: \(inspection)")
              if case .detected(_, let version, _, _) = inspection {
                check(version == ModelVersion.v1.rawValue, "detected as SD 1.5 before downloading")
              } else {
                log("FAIL not detected before downloading")
              }
              if let key = start([entry], .model, lookup) {
                await waitForDownload(key)
                if let message = library.errorMessage { log("FAIL download: \(message)") }
                await waitUntil { !library.importingModels.contains { $0.isInspecting } }
                library.runModelImports()
                await waitUntil { !library.isImportingModels }
                if let message = library.errorMessage { log("  import message: \(message)") }
                let registry = fm.contents(atPath: scratch.appendingPathComponent("custom.json").path).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                check(registry.contains("stable-diffusion-v1-5"), "listed in SCRATCH's custom.json")
                check(!fm.fileExists(atPath: key), "the staging folder is deleted after the import")
                await waitUntil { library.downloads.isEmpty }
                if let file = library.catalog.first(where: { $0.file.hasPrefix("stable-diffusion-v1-5") })?.file,
                   let specification = ModelZoo.specificationForModel(file)
                {
                  let missing = ModelZoo.filesToDownload(specification).map(\.file).filter { !fm.fileExists(atPath: scratch.appendingPathComponent($0).path) }
                  check(missing.isEmpty, "its text encoder and VAE downloaded into SCRATCH (missing: \(missing))")
                }
              }
            }
          }
        }

        if args.contains("--gated") {
          log("--gated: FLUX.1-dev ae.safetensors")
          await library.huggingFace.check()
          log("  token: \(library.huggingFace.statusText)")
          if let lookup = await lookUp("https://huggingface.co/black-forest-labs/FLUX.1-dev/blob/main/ae.safetensors"),
             let entry = lookup.listing.entries.first(where: { $0.id == "ae.safetensors" })
          {
            check(lookup.info.isGated, "the repo is gated")
            let inspection = await library.inspectBeforeDownload(entry, lookup: lookup)
            log("  before download: \(inspection)")
            if let key = start([entry], .model, lookup) {
              await waitForDownload(key)
              if let message = library.errorMessage { log("FAIL download: \(message)") }
              let output = URL(fileURLWithPath: key).appendingPathComponent(entry.modelOutput)
              check(sha256(output) == entry.files.first?.sha256, "the gated file downloaded and matches its SHA-256")
              library.cancelModelImports()
              await discardAll()
            }
          }
        }

        await library.refresh()
        finish()
      }
    }
  }
#endif
