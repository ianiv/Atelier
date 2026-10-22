import AppKit
import Diffusion
import Foundation
import ModelOp
import ModelZoo
import Observation
import _MediaGenerationKit

/// Models and LoRAs in the models directory: the download catalog, downloads, LoRA imports and
/// deletes.
///
/// `ModelZoo`, `ModelOp` and `Diffusion` aren't products of the engine package, but they're built
/// as dependencies of `_MediaGenerationKit` and import fine from the pinned revision. They're
/// needed for what MGK doesn't cover: registering an imported LoRA with the running engine
/// (`LoRAZoo.appendCustomSpecification`) and the importer's LoHa flag.
@MainActor
@Observable
final class ModelLibrary {
  struct LoRA: Identifiable, Hashable {
    var name: String
    var file: String
    var prefix: String
    /// `ModelVersion` raw value, e.g. "moss_image".
    var version: String
    var size: Int64?

    var id: String { file }
    var isDownloaded: Bool { size != nil }
    var family: String { ModelLibrary.familyName(version) }
  }

  struct Download: Equatable {
    var file: String
    var fileIndex: Int
    var totalFiles: Int
    var bytesWritten: Int64
    var totalBytes: Int64

    var fraction: Double? {
      totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : nil
    }
  }

  /// A LoRA file waiting to be imported or being imported.
  struct LoRAImport: Identifiable {
    let id = UUID()
    var source: URL
    var name = ""
    var prefix = ""
    var progress: Double?
  }

  let create: CreateModel

  /// Every catalog model (built-in, community and custom.json), downloaded or not.
  private(set) var catalog: [MediaGenerationResolvedModel] = []
  private(set) var isLoadingCatalog = false
  /// Files listed in custom.json: imported models, which can't be downloaded again.
  private(set) var customModels: Set<String> = []
  /// On-disk size of each downloaded model (the file plus its `-tensordata`).
  private(set) var sizes: [String: Int64] = [:]
  private(set) var loras: [LoRA] = []
  private(set) var downloads: [String: Download] = [:]
  private(set) var importing: [LoRAImport] = []
  private(set) var freeSpace: Int64?
  var errorMessage: String?

  private var downloadTasks: [String: Task<Void, Never>] = [:]
  private var importTask: Task<Void, Never>?

  init(create: CreateModel) {
    self.create = create
  }

  private var directory: URL {
    URL(fileURLWithPath: create.modelsDirectory, isDirectory: true)
  }

  // MARK: - Models

  /// Reloads the catalog (fetching the community list unless `offline`), LoRAs and disk usage.
  func refresh(offline: Bool = false) async {
    isLoadingCatalog = true
    defer { isLoadingCatalog = false }
    // The engine points MGK at the models directory; wait until it has.
    await create.engine.useModelsDirectory(create.modelsDirectory)
    let models = await MediaGenerationEnvironment.default.downloadableModels(
      includeDownloaded: true, offline: offline)
    catalog = models.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    customModels = Set(Self.readCustomModels(in: directory))
    reloadLoRAs()
    await measure()
  }

  /// Disk sizes of downloaded models and LoRAs, and free space on the volume.
  private func measure() async {
    let directory = directory
    let files = catalog.filter(\.isDownloaded).map(\.file)
    let (sizes, free) = await Task.detached {
      var sizes: [String: Int64] = [:]
      for file in files {
        sizes[file] = Self.size(of: file, in: directory)
      }
      let free = try? directory.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]
      ).volumeAvailableCapacityForImportantUsage
      return (sizes, free)
    }.value
    self.sizes = sizes
    freeSpace = free
  }

  var downloadedCount: Int { catalog.filter(\.isDownloaded).count }
  var downloadedSize: Int64 { sizes.values.reduce(0, +) }

  func isCustom(_ model: MediaGenerationResolvedModel) -> Bool {
    customModels.contains(model.file)
  }

  func download(_ model: MediaGenerationResolvedModel) {
    let file = model.file
    guard downloadTasks[file] == nil else { return }
    errorMessage = nil
    downloads[file] = Download(
      file: file, fileIndex: 0, totalFiles: 0, bytesWritten: 0, totalBytes: 0)
    downloadTasks[file] = Task {
      do {
        _ = try await MediaGenerationEnvironment.default.ensure(file, offline: false) { state in
          guard case .downloading(let name, let index, let total, let written, let expected) = state
          else { return }
          let progress = Download(
            file: name, fileIndex: index, totalFiles: total, bytesWritten: written,
            totalBytes: expected)
          Task { @MainActor in
            guard self.downloadTasks[file] != nil else { return }
            self.downloads[file] = progress
          }
        }
      } catch is CancellationError {
        // Cancelled; the partial file stays so a later download resumes.
      } catch {
        errorMessage = "Couldn't download \(model.name): \(error.localizedDescription)"
      }
      // Keep showing progress until the model picker has the new model.
      await afterChange()
      downloads[file] = nil
      downloadTasks[file] = nil
    }
  }

  func cancelDownload(_ file: String) {
    downloadTasks[file]?.cancel()
  }

  /// Whether `model` can be deleted now: downloaded, and not the model Create is running.
  func canDelete(_ model: MediaGenerationResolvedModel) -> Bool {
    model.isDownloaded && downloads[model.file] == nil
      && !(create.isBusy && create.selectedModel == model.file)
  }

  /// Moves the model's own files to the Trash. Shared files (text encoders, VAEs) stay.
  func delete(_ model: MediaGenerationResolvedModel) async {
    guard canDelete(model) else { return }
    do {
      for url in Self.files(of: model.file, in: directory) {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      }
    } catch {
      errorMessage = "Couldn't delete \(model.name): \(error.localizedDescription)"
    }
    await afterChange()
  }

  func reveal(_ file: String) {
    let urls = Self.files(of: file, in: directory)
    if urls.isEmpty {
      NSWorkspace.shared.activateFileViewerSelecting([directory])
    } else {
      NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
  }

  private func afterChange() async {
    await refresh(offline: true)
    await create.refreshModelList()
  }

  // MARK: - LoRAs

  /// Rereads custom_lora.json (it can also change outside the app).
  func reloadLoRAs() {
    let directory = directory
    loras = Self.readLoRASpecifications(in: directory).map { specification in
      LoRA(
        name: specification.name, file: specification.file, prefix: specification.prefix,
        version: specification.version.rawValue,
        size: Self.size(of: specification.file, in: directory))
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Model families (readable names, as MGK reports a model's `version`) whose LoRAs the engine
  /// applies to a model of `family`, plus its refiner's: the rule LocalImageGenerator uses, which
  /// silently skips any other LoRA. Compared by name because ModelZoo only knows a community
  /// catalog model's version once its pipeline has loaded.
  nonisolated static func loraFamilies(forModel family: String?, refiner: String? = nil)
    -> Set<String>
  {
    var families = Set([family, refiner].compactMap { $0 })
    if families.contains(ModelZoo.humanReadableNameForVersion(.kandinsky21)) {
      families.insert(ModelZoo.humanReadableNameForVersion(.v1))
    }
    return families
  }

  /// Readable family name for a `ModelVersion` raw value, as Draw Things shows it.
  nonisolated static func familyName(_ version: String?) -> String {
    guard let version, let modelVersion = ModelVersion(rawValue: version) else {
      return version ?? "Unknown"
    }
    return ModelZoo.humanReadableNameForVersion(modelVersion)
  }

  /// Every model family, for overriding the importer's detection.
  static let families: [(version: String, name: String)] = {
    let versions: [ModelVersion] = [
      .v1, .v2, .sdxlBase, .ssd1b, .sd3, .sd3Large, .pixart, .auraflow, .flux1, .flux2,
      .flux2_9b, .flux2_4b, .flux3_5b, .hunyuanVideo, .wan21_1_3b, .wan21_14b, .wan22_5b,
      .hiDreamI1, .hiDreamO1, .qwenImage, .qwenImage2_1, .zImage, .ernieImage, .cosmos2_5_2b,
      .ideogram4, .krea2, .ltx2, .ltx2_3, .minimaxH3, .mossImage,
    ]
    return versions.map { ($0.rawValue, ModelZoo.humanReadableNameForVersion($0)) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }()

  /// Queues LoRA files for import (shown in the import sheet until confirmed).
  func prepareImport(_ urls: [URL]) {
    let accepted = urls.filter { Self.loraExtensions.contains($0.pathExtension.lowercased()) }
    importing += accepted.map { LoRAImport(source: $0) }
    if accepted.count < urls.count {
      errorMessage = "Only .safetensors, .ckpt, .pt and .bin LoRA files can be imported."
    }
  }

  static let loraExtensions: Set<String> = ["safetensors", "ckpt", "pt", "pth", "bin"]

  func updateImport(_ id: UUID, name: String? = nil, prefix: String? = nil) {
    guard let index = importing.firstIndex(where: { $0.id == id }) else { return }
    if let name { importing[index].name = name }
    if let prefix { importing[index].prefix = prefix }
  }

  func removeImport(_ id: UUID) {
    guard importTask == nil else { return }
    importing.removeAll { $0.id == id }
  }

  var isImporting: Bool { importTask != nil }

  /// Converts the queued files one by one into the models directory and registers each with the
  /// engine, so it can be used right away. `version` nil means detect it from the weights.
  func runImports(version: String?) {
    guard importTask == nil, !importing.isEmpty else { return }
    errorMessage = nil
    let forced = version.flatMap(ModelVersion.init(rawValue:))
    importTask = Task {
      var failures: [String] = []
      while let item = importing.first {
        do {
          try await importLoRA(item, version: forced)
        } catch {
          failures.append("\(item.source.lastPathComponent): \(error.localizedDescription)")
        }
        importing.removeFirst()
      }
      importTask = nil
      reloadLoRAs()
      if !failures.isEmpty {
        errorMessage = "Couldn't import " + failures.joined(separator: "\n")
      }
    }
  }

  func cancelImports() {
    guard importTask == nil else { return }
    importing.removeAll()
  }

  private func importLoRA(_ item: LoRAImport, version: ModelVersion?) async throws {
    let directory = directory
    let stem = item.source.deletingPathExtension().lastPathComponent
    let file = Self.availableLoRAFileName(for: stem, in: directory)
    let source = item.source
    let id = item.id
    let progress: @Sendable (Float) -> Void = { [weak self] value in
      Task { @MainActor [weak self] in
        guard let self, let index = importing.firstIndex(where: { $0.id == id }) else { return }
        importing[index].progress = Double(value)
      }
    }
    if let index = importing.firstIndex(where: { $0.id == id }) { importing[index].progress = 0 }
    // ModelOp writes to LoRAZoo.filePathForModelDownloaded(file), which resolves against
    // ModelZoo.externalUrls: the models directory the engine set. MGK's LoRAImporter swaps
    // externalUrls to a temp folder instead, which would race a running generation.
    let (detected, isLoHa) = try await Task.detached {
      let result = try ModelOp.LoRAImporter.import(
        downloadedFile: source.path, name: stem, filename: file, scaleFactor: 1,
        forceVersion: version, progress: progress)
      return (result.0, result.3)
    }.value
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path)
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    let trimmedName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let name =
      trimmedName.isEmpty
      ? "\(stem) (\(ModelZoo.humanReadableNameForVersion(detected)))" : trimmedName
    register(
      LoRAZoo.Specification(
        name: name, file: file, prefix: item.prefix, version: detected,
        isLoHa: isLoHa))
  }

  /// Renames a LoRA or changes its trigger words; other fields in custom_lora.json are kept.
  func update(_ lora: LoRA, name: String, prefix: String) {
    guard
      var specification = Self.readLoRASpecifications(in: directory).first(where: {
        $0.file == lora.file
      })
    else { return }
    specification.name = name
    specification.prefix = prefix
    register(specification)
    reloadLoRAs()
  }

  /// Writes `specification` to custom_lora.json and the running engine's LoRA table.
  private func register(_ specification: LoRAZoo.Specification) {
    backUpLoRARegistryOnce()
    LoRAZoo.appendCustomSpecification(specification)
    LoRAZoo.sortCustomSpecifications()
  }

  /// Moves the LoRA file to the Trash and removes its custom_lora.json entry.
  func delete(_ lora: LoRA) {
    errorMessage = nil
    let url = directory.appendingPathComponent(lora.file)
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      }
      backUpLoRARegistryOnce()
      let remaining = Self.readLoRASpecifications(in: directory).filter { $0.file != lora.file }
      try Self.writeLoRASpecifications(remaining, in: directory)
      // The engine's in-memory table keeps the entry, but with the file gone it's skipped.
    } catch {
      errorMessage = "Couldn't delete \(lora.name): \(error.localizedDescription)"
    }
    reloadLoRAs()
  }

  /// Copies custom_lora.json aside before the app first changes it in a session.
  private var backedUp = false
  private func backUpLoRARegistryOnce() {
    guard !backedUp else { return }
    backedUp = true
    let registry = directory.appendingPathComponent("custom_lora.json")
    let backup = directory.appendingPathComponent("custom_lora.json.bak-atelier")
    guard FileManager.default.fileExists(atPath: registry.path) else { return }
    try? FileManager.default.removeItem(at: backup)
    try? FileManager.default.copyItem(at: registry, to: backup)
  }

  // MARK: - Files

  private nonisolated static func files(of file: String, in directory: URL) -> [URL] {
    [file, file + "-tensordata"].map { directory.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private nonisolated static func size(of file: String, in directory: URL) -> Int64? {
    let urls = files(of: file, in: directory)
    guard !urls.isEmpty else { return nil }
    return urls.reduce(Int64(0)) { total, url in
      let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
        .totalFileAllocatedSize
      return total + Int64(size ?? 0)
    }
  }

  /// `<stem>_lora_f16.ckpt`, cleaned up the way Draw Things names files, with a numeric suffix if
  /// that file already exists.
  private static func availableLoRAFileName(for stem: String, in directory: URL) -> String {
    let base = Importer.cleanup(filename: stem)
    var candidate = base + "_lora_f16.ckpt"
    var counter = 2
    while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
      candidate = "\(base)_\(counter)_lora_f16.ckpt"
      counter += 1
    }
    return candidate
  }

  private static func readCustomModels(in directory: URL) -> [String] {
    struct Entry: Decodable { var file: String }
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("custom.json")),
      let entries = try? JSONDecoder().decode([Lenient<Entry>].self, from: data)
    else { return [] }
    return entries.compactMap(\.value?.file)
  }

  private static func readLoRASpecifications(in directory: URL) -> [LoRAZoo.Specification] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("custom_lora.json")),
      let entries = try? decoder.decode([Lenient<LoRAZoo.Specification>].self, from: data)
    else { return [] }
    return entries.compactMap(\.value)
  }

  /// Same encoding LoRAZoo uses for custom_lora.json.
  private static func writeLoRASpecifications(
    _ specifications: [LoRAZoo.Specification], in directory: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = .prettyPrinted
    try encoder.encode(specifications).write(
      to: directory.appendingPathComponent("custom_lora.json"), options: .atomic)
  }
}

extension MediaGenerationResolvedModel: @retroactive Identifiable {
  public var id: String { file }
}

/// Decodes an array element as nil instead of failing the whole array.
private struct Lenient<Value: Decodable>: Decodable {
  var value: Value?
  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}
