import Diffusion
import Foundation
import ModelOp
import ModelZoo
import Observation
import _MediaGenerationKit

/// Models and LoRAs in the models directory: the download catalog, downloads, model and LoRA
/// imports, and deletes.
///
/// `ModelZoo`, `ModelOp` and `Diffusion` aren't products of the engine package, but they're built
/// as dependencies of `_MediaGenerationKit` and import fine from the pinned revision. They're
/// needed for what MGK doesn't cover: registering an imported model or LoRA with the running engine
/// (`ModelZoo`/`LoRAZoo.appendCustomSpecification`), checkpoint import, and the LoRA importer's
/// LoHa flag.
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
    /// Holds a picked file open until it's imported or removed (iPad).
    private let access: ScopedAccess

    init(source: URL) {
      self.source = source
      access = ScopedAccess(source)
    }
  }

  /// A model checkpoint waiting to be imported or being imported.
  struct ModelImport: Identifiable {
    let id = UUID()
    var source: URL
    /// Holds a picked file open until it's imported or removed (iPad).
    private let access: ScopedAccess
    var name = ""
    /// `ModelVersion` raw value the importer detected, once the file has been inspected.
    var version: String?
    var isInspecting = true
    /// Why the file can't be imported, if it can't.
    var problem: String?
    var progress: Double?

    var canImport: Bool { !isInspecting && problem == nil }
    var family: String? { version.map(ModelLibrary.familyName) }

    init(source: URL) {
      self.source = source
      access = ScopedAccess(source)
    }
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
  private(set) var importingModels: [ModelImport] = []
  /// 8-bit copies being written, by output file, with their progress.
  private(set) var quantizing: [String: Double] = [:]
  private(set) var freeSpace: Int64?
  var errorMessage: String?

  private var downloadTasks: [String: Task<Void, Never>] = [:]
  private var importTask: Task<Void, Never>?
  private var modelImportTask: Task<Void, Never>?

  init(create: CreateModel) {
    self.create = create
  }

  private var directory: URL {
    URL(fileURLWithPath: create.modelsDirectory, isDirectory: true)
  }

  // MARK: - Models

  /// Reloads the catalog, LoRAs and disk usage. The community list is fetched once per process
  /// and cached by MGK; an offline listing would leave out every community model.
  func refresh() async {
    isLoadingCatalog = true
    defer { isLoadingCatalog = false }
    // The engine points MGK at the models directory; wait until it has.
    await create.engine.useModelsDirectory(create.modelsDirectory)
    let models = await MediaGenerationEnvironment.default.downloadableModels(
      includeDownloaded: true, offline: false)
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

  /// Whether `model` can be deleted now: downloaded (or imported, whose entry can go even when
  /// its file is missing), and not a model a queued or running job uses.
  func canDelete(_ model: MediaGenerationResolvedModel) -> Bool {
    (model.isDownloaded || isCustom(model)) && downloads[model.file] == nil
      && !create.queue.uses(model.file)
      && !(create.isLoadingModel && create.selectedModel == model.file)
  }

  /// Moves the model's own files to the Trash. Shared files (text encoders, VAEs) stay. An
  /// imported model also loses its custom.json entry and the companion files its import wrote.
  func delete(_ model: MediaGenerationResolvedModel) async {
    guard canDelete(model) else { return }
    let isCustom = isCustom(model)
    let companions = isCustom ? Self.importedCompanions(of: model.file) : []
    do {
      for file in [model.file] + companions {
        for url in Self.files(of: file, in: directory) {
          try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
      }
      if isCustom { try unregisterModel(model.file) }
    } catch {
      errorMessage = "Couldn't delete \(model.name): \(error.localizedDescription)"
    }
    await afterChange()
  }

  func reveal(_ file: String) {
    let urls = Self.files(of: file, in: directory)
    Finder.reveal(urls.isEmpty ? [directory] : urls)
  }

  private func afterChange() async {
    await refresh()
    await create.refreshModelList()
  }

  // MARK: - Model import

  static let checkpointExtensions: Set<String> = ["safetensors", "ckpt", "pt", "pth"]

  /// Families ModelImporter detects but can't convert: it traps on them (`fatalError`) instead
  /// of throwing, so they're turned away after inspection. MOSS goes through MOSSImporter.
  private nonisolated static let unconvertibleVersions: Set<ModelVersion> = [
    .mossImage, .minimaxH3, .hiDreamO1, .qwenImage2_1, .ltx2, .ltx2_3, .seedvr2_3b, .seedvr2_7b,
    .kandinsky21, .wurstchenStageB, .longcatVideoAvatar1_5,
  ]

  var isImportingModels: Bool { modelImportTask != nil }

  /// Queues checkpoints for import (shown in the import sheet until confirmed) and inspects each
  /// to detect its family.
  func prepareModelImport(_ urls: [URL]) {
    let accepted = urls.filter {
      Self.checkpointExtensions.contains($0.pathExtension.lowercased())
    }
    if accepted.count < urls.count {
      errorMessage = "Only .safetensors, .ckpt and .pt model checkpoints can be imported."
    }
    for url in accepted {
      let item = ModelImport(source: url)
      importingModels.append(item)
      Task { await inspect(item.id, source: url) }
    }
  }

  private func inspect(_ id: UUID, source: URL) async {
    let result: Result<ModelVersion, Error> = await Task.detached {
      Result {
        // ModelImporter doesn't know MOSS; MOSSImporter converts it.
        if MOSSImporter.isMOSS(source) { return .mossImage }
        return try ModelImporter(
          filePath: source.path, modelName: "", isTextEncoderCustomized: false,
          autoencoderFilePath: nil, textEncoderFilePath: nil, textEncoder2FilePath: nil
        ).inspect().version
      }
    }.value
    guard let index = importingModels.firstIndex(where: { $0.id == id }) else { return }
    importingModels[index].isInspecting = false
    switch result {
    case .success(let version):
      importingModels[index].version = version.rawValue
      if version != .mossImage, Self.unconvertibleVersions.contains(version) {
        importingModels[index].problem =
          "\(ModelZoo.humanReadableNameForVersion(version)) checkpoints can't be converted yet."
      }
    case .failure:
      importingModels[index].problem = "Not a model checkpoint the importer recognizes."
    }
  }

  func updateModelImport(_ id: UUID, name: String) {
    guard let index = importingModels.firstIndex(where: { $0.id == id }) else { return }
    importingModels[index].name = name
  }

  func removeModelImport(_ id: UUID) {
    guard modelImportTask == nil else { return }
    importingModels.removeAll { $0.id == id }
  }

  func cancelModelImports() {
    guard modelImportTask == nil else { return }
    importingModels.removeAll()
  }

  /// Converts the queued checkpoints one by one into the models directory, registers each in
  /// custom.json and with the running engine, then downloads the text encoders and VAE it needs.
  func runModelImports() {
    guard modelImportTask == nil, importingModels.contains(where: \.canImport) else { return }
    errorMessage = nil
    modelImportTask = Task {
      var failures: [String] = []
      var imported: [String] = []
      while let item = importingModels.first {
        if item.canImport {
          do {
            imported.append(try await importModel(item))
          } catch {
            failures.append("\(item.source.lastPathComponent): \(error.localizedDescription)")
          }
        }
        importingModels.removeFirst()
      }
      await afterChange()
      for file in imported {
        if let model = catalog.first(where: { $0.file == file }) { download(model) }
      }
      modelImportTask = nil
      if !failures.isEmpty {
        errorMessage = "Couldn't import " + failures.joined(separator: "\n")
      }
    }
  }

  /// Imports one checkpoint and returns the model file it registered.
  private func importModel(_ item: ModelImport) async throws -> String {
    let stem = item.source.deletingPathExtension().lastPathComponent
    let modelName = Self.availableModelName(for: stem, in: directory)
    let trimmedName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = trimmedName.isEmpty ? stem : trimmedName
    let source = item.source
    let id = item.id
    let progress: @Sendable (Float) -> Void = { [weak self] value in
      Task { @MainActor [weak self] in
        guard let self, let index = importingModels.firstIndex(where: { $0.id == id }) else {
          return
        }
        importingModels[index].progress = Double(value)
      }
    }
    if let index = importingModels.firstIndex(where: { $0.id == id }) {
      importingModels[index].progress = 0
    }
    // ModelImporter writes `<modelName>_f16.ckpt` to ModelZoo.filePathForModelDownloaded, which
    // resolves against the models directory the engine set (as LoRA import does).
    let output = directory.appendingPathComponent(modelName + "_f16.ckpt").path
    let specification = try await Task.detached {
      if MOSSImporter.isMOSS(source) {
        try MOSSImporter.convert(source, to: output, progress: progress)
        guard
          let specification = MOSSImporter.specification(
            file: modelName + "_f16.ckpt", name: displayName)
        else { throw ImportError.unconvertible("MOSS Image") }
        return specification
      }
      let importer = ModelImporter(
        filePath: source.path, modelName: modelName, isTextEncoderCustomized: false,
        autoencoderFilePath: nil, textEncoderFilePath: nil, textEncoder2FilePath: nil)
      // Inspect first: the importer traps on families it can't convert.
      let detected = try importer.inspect().version
      guard !Self.unconvertibleVersions.contains(detected) else {
        throw ImportError.unconvertible(ModelZoo.humanReadableNameForVersion(detected))
      }
      let (files, version, modifier, inspection) = try importer.import(
        versionCheck: { _ in }, progress: progress)
      return ModelImporter.inferModelSpecification(
        modelName: displayName, fileName: modelName,
        fileNames: files.map { URL(fileURLWithPath: $0).lastPathComponent },
        modelVersion: version, modifier: modifier, inspectionResult: inspection, prefix: "",
        objective: nil, conditioning: nil, noiseDiscretization: nil, upcastAttention: false,
        finetuneScale: Self.defaultImportScale(for: version, fileName: source.lastPathComponent)
      ).specification
    }.value
    guard
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(specification.file).path)
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    backUpModelRegistryOnce()
    // custom.json resolves to ~/Documents/Models unless external URLs are preferred, which MGK
    // leaves off. Prefer them just for this call (on the main thread, as the engine requires).
    let preferred = ModelZoo.isExternalUrlsPreferred
    ModelZoo.isExternalUrlsPreferred = true
    ModelZoo.appendCustomSpecification(specification)
    ModelZoo.isExternalUrlsPreferred = preferred
    return specification.file
  }

  /// Whether `model` can get an 8-bit copy in `format`: an imported full-precision MOSS model
  /// without that copy yet. A copy whose file exists but isn't registered was interrupted, and
  /// making it again resumes it.
  func canMake8BitCopy(_ model: MediaGenerationResolvedModel, _ format: MOSSImporter.EightBit)
    -> Bool
  {
    let output = Self.eightBitFile(for: model.file, format)
    return isCustom(model) && model.isDownloaded && model.file.hasSuffix("_f16.ckpt")
      && ModelZoo.specificationForModel(model.file)?.version == .mossImage
      && quantizing[output] == nil && ModelZoo.specificationForModel(output) == nil
  }

  static func eightBitFile(for file: String, _ format: MOSSImporter.EightBit) -> String {
    String(file.dropLast("f16.ckpt".count)) + format.fileSuffix
  }

  /// Writes `<name>_q8p.ckpt` or `<name>_i8x.ckpt` next to the model, about half its size, and
  /// registers it as "<name> (8-bit)" or "(8-bit S)" with the same specification.
  func make8BitCopy(_ model: MediaGenerationResolvedModel, _ format: MOSSImporter.EightBit) {
    guard canMake8BitCopy(model, format),
      var specification = ModelZoo.specificationForModel(model.file)
    else { return }
    errorMessage = nil
    let output = Self.eightBitFile(for: model.file, format)
    let source = directory.appendingPathComponent(model.file).path
    let destination = directory.appendingPathComponent(output).path
    quantizing[output] = 0
    let progress: @Sendable (Float) -> Void = { [weak self] value in
      Task { @MainActor [weak self] in
        guard self?.quantizing[output] != nil else { return }
        self?.quantizing[output] = Double(value)
      }
    }
    Task {
      await Task.detached {
        MOSSImporter.quantize(source, to: destination, format: format, progress: progress)
      }.value
      if FileManager.default.fileExists(atPath: destination) {
        specification.file = output
        specification.name = "\(model.name) (\(format.title))"
        backUpModelRegistryOnce()
        let preferred = ModelZoo.isExternalUrlsPreferred
        ModelZoo.isExternalUrlsPreferred = true
        ModelZoo.appendCustomSpecification(specification)
        ModelZoo.isExternalUrlsPreferred = preferred
      } else {
        errorMessage = "Couldn't write an \(format.title) copy of \(model.name)."
      }
      await afterChange()
      quantizing[output] = nil
    }
  }

  enum ImportError: LocalizedError {
    case unconvertible(String)
    var errorDescription: String? {
      switch self {
      case .unconvertible(let family): "\(family) checkpoints can't be converted yet."
      }
    }
  }

  /// The checkpoint scale (in 64-px units) a new import gets, as draw-things-cli picks it.
  private nonisolated static func defaultImportScale(for version: ModelVersion, fileName: String)
    -> UInt16
  {
    switch version {
    case .hunyuanVideo, .wan21_14b, .wan22_5b, .longcatVideoAvatar1_5, .minimaxH3:
      return 12
    case .wan21_1_3b:
      return 8
    case .pixart:
      return fileName.contains("512") ? 8 : 16
    case .v1, .v2, .kandinsky21, .svdI2v, .seedvr2_3b, .seedvr2_7b:
      return 8
    default:
      return 16
    }
  }

  /// `<cleaned stem>`, numbered if `<stem>_f16.ckpt` is taken. ModelImporter adds `_f16.ckpt`
  /// (and `_vae_f16.ckpt` and the like for companion files).
  private static func availableModelName(for stem: String, in directory: URL) -> String {
    let base = Importer.cleanup(filename: stem)
    var candidate = base
    var counter = 2
    while FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(candidate + "_f16.ckpt").path)
    {
      candidate = "\(base)_\(counter)"
      counter += 1
    }
    return candidate
  }

  /// Files an import of `file` wrote next to it (`<name>_vae_f16.ckpt` and the like, the
  /// suffixes ModelImporter uses), when its specification names them. Shared encoders and VAEs
  /// stay.
  private static func importedCompanions(of file: String) -> [String] {
    guard file.hasSuffix("_f16.ckpt"), let specification = ModelZoo.specificationForModel(file)
    else { return [] }
    let stem = String(file.dropLast("f16.ckpt".count))
    let suffixes = [
      "vae_f16.ckpt", "clip_vit_l14_f16.ckpt", "open_clip_vit_h14_f16.ckpt",
      "open_clip_vit_bigg14_f16.ckpt", "ministral_3_3b_q8p.ckpt",
    ]
    let named = Set(
      [specification.autoencoder, specification.textEncoder, specification.clipEncoder]
        .compactMap { $0 } + (specification.additionalClipEncoders ?? []))
    return suffixes.map { stem + $0 }.filter(named.contains)
  }

  /// Removes `file`'s custom.json entry, keeping every other entry as written, and drops it from
  /// the running engine's model list.
  private func unregisterModel(_ file: String) throws {
    backUpModelRegistryOnce()
    let url = directory.appendingPathComponent("custom.json")
    if let data = try? Data(contentsOf: url),
      let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    {
      let remaining = entries.filter { $0["file"] as? String != file }
      try JSONSerialization.data(
        withJSONObject: remaining, options: [.prettyPrinted, .withoutEscapingSlashes]
      ).write(to: url, options: .atomic)
    }
    ModelZoo.availableSpecifications.removeAll { $0.file == file }
  }

  /// Copies custom.json aside before the app first changes it in a session.
  private var backedUpModels = false
  private func backUpModelRegistryOnce() {
    guard !backedUpModels else { return }
    backedUpModels = true
    Self.backUp("custom.json", in: directory)
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
    Self.backUp("custom_lora.json", in: directory)
  }

  /// Copies a registry file to `<name>.bak-atelier`, replacing an older copy.
  private static func backUp(_ name: String, in directory: URL) {
    let registry = directory.appendingPathComponent(name)
    let backup = directory.appendingPathComponent(name + ".bak-atelier")
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

  /// Rebuilds the engine's model list from the built-in models and `directory`'s custom.json, as
  /// ModelZoo does at first use. ModelZoo reads custom.json only once, from wherever it pointed
  /// then, so models imported in Draw Things stayed missing after the models folder changed.
  static func loadCustomModels(in directory: URL) {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let custom =
      (try? Data(contentsOf: directory.appendingPathComponent("custom.json")))
      .flatMap { try? decoder.decode([Lenient<ModelZoo.Specification>].self, from: $0) }?
      .compactMap(\.value) ?? []
    let files = Set(custom.map(\.file))
    ModelZoo.availableSpecifications =
      ModelZoo.builtinSpecifications.filter { !files.contains($0.file) } + custom
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
