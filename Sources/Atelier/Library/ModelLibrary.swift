@preconcurrency import _MediaGenerationKit
@preconcurrency import Diffusion
@preconcurrency import Downloader
import Foundation
@preconcurrency import ModelOp
@preconcurrency import ModelZoo
import Observation

/// Models and LoRAs in the models folders: the download catalog, downloads, model and LoRA
/// imports, and deletes. Files are looked up in each available models folder in order (the first
/// one with a file wins); downloads, imports and 8-bit copies go to the folder chosen to add to
/// (`addFolder`, the first unless another is chosen).
///
/// `ModelZoo`, `ModelOp` and `Diffusion` aren't products of the engine package, but they're built
/// as dependencies of `_MediaGenerationKit` and import fine from the pinned revision. They're
/// needed for what MGK doesn't cover: registering an imported model or LoRA with the running engine
/// (`ModelZoo`/`LoRAZoo.appendCustomSpecification`), checkpoint import, and the LoRA importer's
/// LoHa flag.
@MainActor
@Observable
final class ModelLibrary {
  nonisolated struct LoRA: Identifiable, Hashable {
    var name: String
    var file: String
    var prefix: String
    /// `ModelVersion` raw value, e.g. "moss_image".
    var version: String
    var size: Int64?
    /// The models folder whose custom_lora.json lists it.
    var registry: URL
    /// The models folder its file is in (the first that has it), if any has.
    var folder: URL?

    var id: String { file }
    var isDownloaded: Bool { size != nil }
    var family: String { ModelLibrary.familyName(version) }
  }

  nonisolated struct Download: Equatable {
    var file: String
    var fileIndex: Int
    var totalFiles: Int
    var bytesWritten: Int64
    var totalBytes: Int64

    var fraction: Double? {
      totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : nil
    }
  }

  /// A preset whose model isn't here, and the catalog entry that can fetch it.
  struct PresetDownload {
    var preset: Preset
    var model: MediaGenerationResolvedModel
  }

  /// A LoRA file waiting to be imported or being imported.
  struct LoRAImport: Identifiable {
    let id = UUID()
    var source: URL
    var name = ""
    var prefix = ""
    /// Multiplies the LoRA's effect, baked into the converted file, as Draw Things' import dialog
    /// does. The importer applies a stored alpha ÷ rank itself; this is on top of that.
    var scaleFactor = 1.0
    var progress: Double?
    /// Holds a picked file open until it's imported or removed (iPad).
    private let access: ScopedAccess

    var hasValidScaleFactor: Bool { scaleFactor.isFinite && scaleFactor > 0 }

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
    /// The file is the MiniMax H3 Image VAE, converted on its own (`H3ImageVAEImporter`).
    var isH3ImageVAE = false
    /// Why the file can't be imported, if it can't.
    var problem: String?
    var progress: Double?

    var canImport: Bool { !isInspecting && problem == nil }
    var family: String? { isH3ImageVAE ? "MiniMax H3 Image VAE" : version.map(ModelLibrary.familyName) }

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
  /// The models folder each downloaded model's file is in (the first that has it).
  private(set) var folders: [String: URL] = [:]
  private(set) var loras: [LoRA] = []
  private(set) var downloads: [String: Download] = [:]
  /// Downloads started by picking a preset, by model file: the preset applies when they finish.
  private(set) var presetDownloads: [String: PresetDownload] = [:]
  private(set) var importing: [LoRAImport] = []
  private(set) var importingModels: [ModelImport] = []
  /// 8-bit copies being written, by output file, with their progress.
  private(set) var quantizing: [String: Double] = [:]
  /// The guided MiniMax H3 Image install (`installH3Image`), for its sheet.
  private(set) var h3ImageInstall = H3ImageInstall()
  /// A MiniMax H3 Image model and its VAE are both in the models folders. The Models list offers
  /// the guided install until they are.
  private(set) var h3ImageInstalled = false
  private(set) var freeSpace: Int64?
  /// The move to another models folder running now (see `ModelMove.swift`); one at a time.
  var moving: MoveProgress?
  var errorMessage: String?

  private var downloadTasks: [String: Task<Void, Never>] = [:]
  var importTask: Task<Void, Never>?
  var modelImportTask: Task<Void, Never>?
  var moveTask: Task<Void, Never>?
  /// The saved choice of folder to add to (`AddFolder.swift`), a path.
  var addFolderPath = UserDefaults.standard.string(forKey: ModelLibrary.addFolderKey)

  init(create: CreateModel) {
    self.create = create
    create.onModelsReloaded = { [weak self] in self?.reloadLoRAs() }
  }

  /// The first models folder that can be reached, else the models directory setting: where the
  /// engine writes a file no folder has yet (`ModelZoo.filePathForModelDownloaded`).
  var directory: URL {
    directories.first ?? URL(fileURLWithPath: create.modelsDirectory, isDirectory: true)
  }

  /// The models folders that can be reached, in lookup order.
  var directories: [URL] {
    create.availableModelsDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  // MARK: - Models

  /// Reloads the catalog, LoRAs and disk usage. The community list is fetched once per process
  /// and cached by MGK, or if that failed, tried again here (`CommunityCatalog`); an offline
  /// listing would leave out every community model.
  func refresh() async {
    isLoadingCatalog = true
    defer { isLoadingCatalog = false }
    // The engine points MGK at the models folders; wait until it has.
    await create.engine.useModelsDirectories(create.availableModelsDirectories)
    let generation = CommunityCatalog.generation
    let models = await CommunityCatalog.models()
    catalog = models.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    // The retry just brought community models in: Create's picker hasn't seen them yet.
    if CommunityCatalog.generation != generation { await create.refreshModelList() }
    customModels = Set(directories.flatMap { Self.readCustomModels(in: $0) })
    reloadLoRAs()
    await measure()
  }

  /// Disk sizes of downloaded models and LoRAs, and free space on the volume.
  private func measure() async {
    let directory = addFolder
    let directories = directories
    let files = catalog.filter(\.isDownloaded).map(\.file)
    let (sizes, folders, free) = await Self.measure(files: files, in: directories, volume: directory)
    self.sizes = sizes
    self.folders = folders
    freeSpace = free
    h3ImageInstalled =
      Self.folder(of: H3ImageVAEImporter.file, in: directories) != nil
        && catalog.contains {
          $0.isDownloaded && ModelZoo.specificationForModel($0.file)?.version == .minimaxH3Image
        }
  }

  @concurrent private nonisolated static func measure(
    files: [String], in directories: [URL], volume: URL
  ) async -> (sizes: [String: Int64], folders: [String: URL], free: Int64?) {
    var sizes: [String: Int64] = [:]
    var folders: [String: URL] = [:]
    for file in files {
      sizes[file] = size(of: file, in: directories)
      folders[file] = folder(of: file, in: directories)
    }
    let free = try? volume.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    ).volumeAvailableCapacityForImportantUsage
    return (sizes, folders, free)
  }

  var downloadedCount: Int { catalog.filter(\.isDownloaded).count }
  var downloadedSize: Int64 { sizes.values.reduce(0, +) }

  func isCustom(_ model: MediaGenerationResolvedModel) -> Bool {
    customModels.contains(model.file)
  }

  /// What can fetch `preset`'s model, if it's in the catalog. An imported model's file can't be
  /// downloaded again, so that's nil too.
  func presetDownload(for preset: Preset) -> PresetDownload? {
    guard let model = catalog.first(where: { $0.file == preset.model }), !isCustom(model) else { return nil }
    return PresetDownload(preset: preset, model: model)
  }

  /// Downloads a preset's model, then applies the preset, which switches to that model.
  func download(_ download: PresetDownload) {
    presetDownloads[download.model.file] = download
    self.download(download.model)
  }

  func download(_ model: MediaGenerationResolvedModel) {
    let file = model.file
    guard downloadTasks[file] == nil else { return }
    errorMessage = nil
    downloads[file] = Download(
      file: file, fileIndex: 0, totalFiles: 0, bytesWritten: 0, totalBytes: 0)
    let folder = addFolder
    // MGK's `ensure` would try to fetch the H3 Image VAE, which the server doesn't have.
    let viaEngine = isEngineFolder(folder) && !awaitsH3ImageVAE(file)
    downloadTasks[file] = Task {
      var finished = false
      let show: @Sendable (Download) -> Void = { progress in
        Task { @MainActor in
          guard self.downloadTasks[file] != nil else { return }
          self.downloads[file] = progress
        }
      }
      do {
        if viaEngine {
          _ = try await MediaGenerationEnvironment.default.ensure(file, offline: false) { state in
            guard case .downloading(let name, let index, let total, let written, let expected) = state
            else { return }
            show(Download(
              file: name, fileIndex: index, totalFiles: total, bytesWritten: written,
              totalBytes: expected))
          }
        } else {
          try await Self.downloadModel(file, into: folder) { name, index, total, written, expected in
            show(Download(
              file: name, fileIndex: index, totalFiles: total, bytesWritten: written,
              totalBytes: expected))
          }
        }
        try await Self.downloadAudioEncoder(for: file, into: folder) { name, written, expected in
          let progress = Download(
            file: name, fileIndex: 1, totalFiles: 1, bytesWritten: written, totalBytes: expected)
          Task { @MainActor in
            guard self.downloadTasks[file] != nil else { return }
            self.downloads[file] = progress
          }
        }
        finished = true
      } catch is CancellationError {
        // Cancelled; the partial file stays so a later download resumes.
      } catch {
        errorMessage = "Couldn't download \(model.name): \(error.localizedDescription)"
      }
      // Keep showing progress until the model picker has the new model.
      await afterChange()
      downloads[file] = nil
      downloadTasks[file] = nil
      if let waiting = presetDownloads.removeValue(forKey: file) {
        if finished {
          create.apply(waiting.preset, undoManager: nil)
        } else if let errorMessage {
          // Started from Create, where this library's own message isn't shown.
          create.errorMessage = errorMessage
        }
      }
    }
  }

  /// Downloads the audio encoder `model` needs if no models folder has it. LongCat's Whisper isn't
  /// in `ModelZoo.filesToDownload`, so MGK's `ensure` skips it (draw-things-cli adds it to its own
  /// file list), and none of the specification's file fields can carry it: the engine loads those
  /// or rewrites them for external data. MGK's own downloader is internal; the URL is the one it
  /// uses (`Storage.downloadFile`). Also runs before a generation, for a model downloaded earlier.
  nonisolated static func downloadAudioEncoder(
    for model: String, into folder: URL? = nil,
    progress: @escaping @Sendable (_ file: String, _ written: Int64, _ expected: Int64) -> Void
  ) async throws {
    let directories = MediaGenerationEnvironment.default.externalUrls
    guard let file = ModelZoo.audioEncoderForModel(model), let directory = folder ?? directories.first,
          !directories.contains(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(file).path)
          }),
          let url = URL(string: "https://static.libnnc.org/\(file)")
    else { return }
    let destination = directory.appendingPathComponent(file)
    // Beside the destination: the system's temporary folder may be on another disk, and a move
    // across disks is a copy that a quit could leave half done under the real name.
    let partial = directory.appendingPathComponent(file + ".part")
    let holder = ObservationHolder()
    let box = DownloadTaskBox()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
          do {
            if let error { throw error }
            guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
              throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
            // URLSession's temporary files are private to the user; the other models aren't.
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: partial.path)
            try FileManager.default.moveItem(at: partial, to: destination)
            continuation.resume()
          } catch {
            continuation.resume(throwing: error)
          }
        }
        holder.observation = task.progress.observe(\.completedUnitCount) { value, _ in
          progress(file, value.completedUnitCount, value.totalUnitCount)
        }
        box.task = task
        task.resume()
      }
    } onCancel: {
      box.task?.cancel()
    }
    _ = holder
  }

  private final nonisolated class ObservationHolder: @unchecked Sendable {
    var observation: NSKeyValueObservation?
  }

  private final nonisolated class DownloadTaskBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
  }

  func cancelDownload(_ file: String) {
    downloadTasks[file]?.cancel()
  }

  /// Whether `model` can be deleted now: downloaded (or imported, whose entry can go even when
  /// its file is missing), and not a model a queued or running job uses.
  func canDelete(_ model: MediaGenerationResolvedModel) -> Bool {
    (model.isDownloaded || isCustom(model)) && downloads[model.file] == nil && moving == nil
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
        for url in Self.files(of: file, in: directories) {
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
    let urls = Self.files(of: file, in: directories)
    Finder.reveal(urls.isEmpty ? [directory] : urls)
  }

  func afterChange() async {
    await refresh()
    await create.refreshModelList()
  }

  // MARK: - Model import

  nonisolated static let checkpointExtensions: Set<String> = ["safetensors", "ckpt", "pt", "pth"]

  /// Families ModelImporter detects but can't convert: it traps on them (`fatalError`) instead
  /// of throwing, so they're turned away after inspection. MOSS goes through MOSSImporter.
  private nonisolated static let unconvertibleVersions: Set<ModelVersion> = [
    .mossImage, .hiDreamO1, .qwenImage2_1, .ltx2, .ltx2_3, .seedvr2_3b, .seedvr2_7b,
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

  @concurrent private nonisolated static func isH3ImageVAE(_ source: URL) async -> Bool {
    H3ImageVAEImporter.isVAE(source)
  }

  @concurrent private nonisolated static func inspectedVersion(of source: URL) async -> Result<ModelVersion, Error> {
    Result {
      // ModelImporter doesn't know MOSS; MOSSImporter converts it.
      if MOSSImporter.isMOSS(source) { return .mossImage }
      return try ModelImporter(
        filePath: source.path, modelName: "", isTextEncoderCustomized: false,
        autoencoderFilePath: nil, textEncoderFilePath: nil, textEncoder2FilePath: nil
      ).inspect().version
    }
  }

  private func inspect(_ id: UUID, source: URL) async {
    if await Self.isH3ImageVAE(source) {
      guard let index = importingModels.firstIndex(where: { $0.id == id }) else { return }
      importingModels[index].isInspecting = false
      importingModels[index].isH3ImageVAE = true
      return
    }
    let result = await Self.inspectedVersion(of: source)
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

  /// Converts the queued checkpoints one by one into `addFolder`, registers each in
  /// custom.json and with the running engine, then downloads the text encoders and VAE it needs.
  func runModelImports() {
    guard modelImportTask == nil, importingModels.contains(where: \.canImport) else { return }
    errorMessage = nil
    modelImportTask = Task {
      var failures: [String] = []
      var imported: [String] = []
      var notices: [String] = []
      while let item = importingModels.first {
        if item.canImport {
          do {
            if item.isH3ImageVAE {
              try await importH3ImageVAE(from: item.source, itemID: item.id)
            } else {
              let file = try await importModel(item)
              imported.append(file)
              if let notice = try await importH3ImageVAEIfNeeded(for: file, model: item) {
                notices.append(notice)
              }
            }
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
      if !notices.isEmpty {
        errorMessage = ([errorMessage].compactMap(\.self) + notices).joined(separator: "\n")
      }
    }
  }

  /// Converts a checkpoint to the engine's format in `folder`.
  @concurrent private nonisolated static func convert(
    _ source: URL, modelName: String, displayName: String, into folder: URL,
    progress: @escaping @Sendable (Float) -> Void
  ) async throws -> ModelZoo.Specification {
    if MOSSImporter.isMOSS(source) {
      try MOSSImporter.convert(source, to: folder.appendingPathComponent(modelName + "_f16.ckpt").path, progress: progress)
      guard
        let specification = MOSSImporter.specification(
          file: modelName + "_f16.ckpt", name: displayName)
      else { throw ImportError.unconvertible("MOSS Image") }
      return specification
    }
    let importer = ModelImporter(
      filePath: source.path, modelName: modelName, isTextEncoderCustomized: false,
      autoencoderFilePath: nil, textEncoderFilePath: nil, textEncoder2FilePath: nil,
      outputDirectory: folder.path)
    // Inspect first: the importer traps on families it can't convert.
    let detected = try importer.inspect().version
    guard !unconvertibleVersions.contains(detected) else {
      throw ImportError.unconvertible(ModelZoo.humanReadableNameForVersion(detected))
    }
    let (files, version, modifier, inspection) = try importer.import(
      versionCheck: { _ in }, progress: progress)
    return ModelImporter.inferModelSpecification(
      modelName: displayName, fileName: modelName,
      fileNames: files.map { URL(fileURLWithPath: $0).lastPathComponent },
      modelVersion: version, modifier: modifier, inspectionResult: inspection, prefix: "",
      objective: nil, conditioning: nil, noiseDiscretization: nil, upcastAttention: false,
      finetuneScale: defaultImportScale(for: version, fileName: source.lastPathComponent)
    ).specification
  }

  /// Removes what an import that failed left in `directory`: files it made, which aren't in
  /// `before`. The prefix alone isn't enough: another model's name can start the same way.
  nonisolated static func removeNewFiles(in directory: URL, before: Set<String>, prefix: String) {
    let fileManager = FileManager.default
    for file in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
      where file.hasPrefix(prefix) && !before.contains(file)
    {
      try? fileManager.removeItem(at: directory.appendingPathComponent(file))
    }
  }

  private nonisolated static func fileNames(in directory: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
  }

  /// Imports one checkpoint into `addFolder` and returns the model file it registered.
  private func importModel(
    _ item: ModelImport, onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
  ) async throws -> String {
    let stem = item.source.deletingPathExtension().lastPathComponent
    let modelName = Self.availableModelName(for: stem, in: directories)
    let folder = addFolder
    // The main file and the text encoders and autoencoder that come out of it share this prefix.
    let before = Self.fileNames(in: folder)
    var succeeded = false
    defer {
      if !succeeded { Self.removeNewFiles(in: folder, before: before, prefix: modelName + "_") }
    }
    let trimmedName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = trimmedName.isEmpty ? stem : trimmedName
    let source = item.source
    let id = item.id
    let progress: @Sendable (Float) -> Void = { [weak self] value in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let index = importingModels.firstIndex(where: { $0.id == id }) {
          importingModels[index].progress = Double(value)
        }
        onProgress?(Double(value))
      }
    }
    if let index = importingModels.firstIndex(where: { $0.id == id }) {
      importingModels[index].progress = 0
    }
    // ModelImporter writes `<modelName>_f16.ckpt` and its encoders to the folder it's given (an
    // `outputDirectory` the fork adds), not just the first models folder.
    let specification = try await Self.convert(
      source, modelName: modelName, displayName: displayName, into: folder, progress: progress)
    guard
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent(specification.file).path)
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    try registerImported(specification, in: folder)
    succeeded = true
    return specification.file
  }

  /// The progress callback for the import with `id`.
  private func importProgress(_ id: UUID) -> @Sendable (Float) -> Void {
    { [weak self] value in
      Task { @MainActor [weak self] in
        guard let self, let index = importingModels.firstIndex(where: { $0.id == id }) else {
          return
        }
        importingModels[index].progress = Double(value)
      }
    }
  }

  /// Converts the MiniMax H3 Image VAE `source` into `addFolder` as `H3ImageVAEImporter.file`.
  @concurrent private nonisolated static func convertH3ImageVAE(
    _ source: URL, into folder: URL, progress: @escaping @Sendable (Float) -> Void
  ) async throws {
    try H3ImageVAEImporter.convert(
      source, to: folder.appendingPathComponent(H3ImageVAEImporter.file).path, progress: progress)
  }

  /// Imports the VAE file on its own, for a MiniMax H3 Image model that is waiting on it.
  private func importH3ImageVAE(from source: URL, itemID: UUID) async throws {
    if let index = importingModels.firstIndex(where: { $0.id == itemID }) {
      importingModels[index].progress = 0
    }
    try await Self.convertH3ImageVAE(source, into: addFolder, progress: importProgress(itemID))
  }

  /// After importing `file`: when it's MiniMax H3 Image and no models folder has its VAE, converts
  /// the VAE found beside the checkpoint into the folder the model went to. Returns what to tell
  /// the person when there's none. The VAE isn't on Draw Things' download server.
  private func importH3ImageVAEIfNeeded(for file: String, model item: ModelImport) async throws -> String? {
    guard let specification = ModelZoo.specificationForModel(file),
          specification.version == .minimaxH3Image,
          specification.autoencoder == H3ImageVAEImporter.file,
          Self.folder(of: H3ImageVAEImporter.file, in: directories) == nil,
          // The VAE file was picked too and is converted when its turn comes.
          !importingModels.contains(where: { $0.isH3ImageVAE && $0.canImport })
    else { return nil }
    let source = item.source
    guard let vae = await Self.siblingH3ImageVAE(of: source) else {
      return "MiniMax H3 Image also needs its VAE. Import minimax_h3_image_vae_fp16.safetensors from the same download."
    }
    if let index = importingModels.firstIndex(where: { $0.id == item.id }) {
      importingModels[index].progress = 0
    }
    try await Self.convertH3ImageVAE(vae, into: addFolder, progress: importProgress(item.id))
    return nil
  }

  @concurrent private nonisolated static func siblingH3ImageVAE(of model: URL) async -> URL? {
    H3ImageVAEImporter.sibling(of: model)
  }

  /// Whether `file` is a model that needs a VAE the app converts itself and no folder has it yet.
  private func awaitsH3ImageVAE(_ file: String) -> Bool {
    guard let specification = ModelZoo.specificationForModel(file) else { return false }
    return specification.autoencoder == H3ImageVAEImporter.file
      && Self.folder(of: H3ImageVAEImporter.file, in: directories) == nil
  }

  /// Whether `model` can get an 8-bit copy in `format`: an imported full-precision MOSS or
  /// MiniMax H3 (video or Image) model without that copy yet. MiniMax H3 only gets 8-bit S, the
  /// format Draw Things' own H3 files use, and MiniMax H3 Image 4-bit S too, for its install. A copy whose file exists but isn't registered was interrupted, and making it
  /// again resumes it.
  func canMake8BitCopy(_ model: MediaGenerationResolvedModel, _ format: MOSSImporter.EightBit)
    -> Bool
  {
    let output = Self.eightBitFile(for: model.file, format)
    let version = ModelZoo.specificationForModel(model.file)?.version
    let supported =
      version == .mossImage
        || ((version == .minimaxH3 || version == .minimaxH3Image) && format == .rowwise)
        || (version == .minimaxH3Image && format == .rowwise4Bit)
    return isCustom(model) && model.isDownloaded && model.file.hasSuffix("_f16.ckpt") && supported
      && quantizing[output] == nil && moving == nil && ModelZoo.specificationForModel(output) == nil
  }

  static func eightBitFile(for file: String, _ format: MOSSImporter.EightBit) -> String {
    String(file.dropLast("f16.ckpt".count)) + format.fileSuffix
  }

  @concurrent private nonisolated static func quantize(
    _ source: String, to destination: String, format: MOSSImporter.EightBit, miniMaxH3: Bool,
    progress: @escaping @Sendable (Float) -> Void
  ) async {
    MOSSImporter.quantize(
      source, to: destination, format: format, miniMaxH3: miniMaxH3, progress: progress)
  }

  /// Writes `<name>_q8p.ckpt` or `<name>_i8x.ckpt` to `addFolder`, about half the model's size,
  /// and registers it there as "<name> (8-bit)" or "(8-bit S)" with the same specification
  /// (`<name>_i4x.ckpt` and "(4-bit S)" for 4-bit S).
  func make8BitCopy(_ model: MediaGenerationResolvedModel, _ format: MOSSImporter.EightBit) {
    guard canMake8BitCopy(model, format),
          var specification = ModelZoo.specificationForModel(model.file)
    else { return }
    errorMessage = nil
    let output = Self.eightBitFile(for: model.file, format)
    let source = (Self.files(of: model.file, in: directories).first
      ?? directory.appendingPathComponent(model.file)).path
    let folder = addFolder
    let destination = folder.appendingPathComponent(output).path
    quantizing[output] = 0
    let progress: @Sendable (Float) -> Void = { [weak self] value in
      Task { @MainActor [weak self] in
        guard self?.quantizing[output] != nil else { return }
        self?.quantizing[output] = Double(value)
      }
    }
    Task {
      await Self.quantize(
        source, to: destination, format: format,
        miniMaxH3: specification.version == .minimaxH3 || specification.version == .minimaxH3Image,
        progress: progress)
      if FileManager.default.fileExists(atPath: destination) {
        specification.file = output
        specification.name = "\(model.name) (\(format.title))"
        do {
          try registerImported(specification, in: folder)
        } catch {
          errorMessage = "Couldn't list the \(format.title) copy of \(model.name): \(error.localizedDescription)"
        }
      } else {
        errorMessage = "Couldn't write an \(format.title) copy of \(model.name)."
      }
      await afterChange()
      quantizing[output] = nil
    }
  }

  // MARK: - Guided MiniMax H3 Image install

  /// The family name MiniMax H3 Image models show, for its row before it's installed.
  nonisolated static var h3ImageFamily: String { ModelZoo.humanReadableNameForVersion(.minimaxH3Image) }

  /// Where the guided install of MiniMax H3 Image is. The model isn't in the download catalog and
  /// its license keeps Atelier from hosting converted files, so the person downloads two files and
  /// the app does the rest.
  struct H3ImageInstall: Equatable {
    enum Stage: Int, CaseIterable {
      case importingModel, convertingVAE, makingEightBit

      /// `format` is the copy the install makes.
      func title(_ format: MOSSImporter.EightBit) -> String {
        switch self {
        case .importingModel: "Importing model"
        case .convertingVAE: "Converting VAE"
        case .makingEightBit: "Making \(format.title) copy"
        }
      }
    }

    /// The smaller copy the install makes: 8-bit S, or 4-bit S for Macs with less memory.
    var format = MOSSImporter.EightBit.rowwise

    /// The stage running now.
    var stage: Stage?
    /// Progress of `stage` from 0 to 1, when it reports any.
    var progress: Double?
    /// Stages that are done, including ones a previous install finished.
    var completed: Set<Stage> = []
    var error: String?
    var isRunning = false
    var isFinished = false
  }

  nonisolated enum H3ImageInstallError: LocalizedError {
    case notH3Image(String)
    case missingModel
    case missingVAE
    case busy
    case cantMakeCopy(String)
    case copyFailed(String, reason: String?)
    case fullInUse(String)

    var errorDescription: String? {
      switch self {
      case .notH3Image(let name):
        "\(name) isn't the MiniMax H3 Image model. Choose minimax_h3_image_pruned_bf16.safetensors."
      case .missingModel:
        "Choose minimax_h3_image_pruned_bf16.safetensors, the model file."
      case .missingVAE:
        "The VAE is missing. Choose minimax_h3_image_vae_fp16.safetensors too."
      case .busy:
        "Another import or move is running. Try again when it has finished."
      case .cantMakeCopy(let title):
        "The \(title) copy can't be made right now. Try again when other work on the models has finished."
      case .copyFailed(let title, let reason):
        reason ?? "Couldn't write the \(title) copy."
      case .fullInUse(let title):
        "The \(title) copy is installed, but the full-precision copy is in use, so it wasn't moved to the Trash. Delete it in Models when it's free."
      }
    }
  }

  /// Splits the picked files into the model and the VAE by reading their headers, and turns away
  /// a model file that isn't MiniMax H3 Image.
  @concurrent private nonisolated static func classifyH3ImageFiles(_ urls: [URL]) async throws -> (
    model: URL?, vae: URL?
  ) {
    var model: URL?
    var vae: URL?
    for url in urls {
      if H3ImageVAEImporter.isVAE(url) {
        vae = vae ?? url
        continue
      }
      let version = try await inspectedVersion(of: url).get()
      guard version == .minimaxH3Image else {
        throw H3ImageInstallError.notH3Image(url.lastPathComponent)
      }
      model = model ?? url
    }
    return (model, vae)
  }

  /// Forgets the last install's result when its sheet opens again.
  func resetH3ImageInstall() {
    guard !h3ImageInstall.isRunning else { return }
    h3ImageInstall = H3ImageInstall()
  }

  private func setH3ImageStage(_ stage: H3ImageInstall.Stage) {
    h3ImageInstall.stage = stage
    h3ImageInstall.progress = 0
  }

  private func finishH3ImageStage(_ stage: H3ImageInstall.Stage) {
    h3ImageInstall.completed.insert(stage)
    h3ImageInstall.progress = nil
  }

  private func h3ImageProgress(_ stage: H3ImageInstall.Stage) -> @MainActor @Sendable (Double) -> Void {
    { [weak self] value in
      guard let self, h3ImageInstall.stage == stage else { return }
      h3ImageInstall.progress = value
    }
  }

  /// Installs MiniMax H3 Image from the two downloads: imports the model, converts the VAE, makes
  /// the smaller copy people should run in `format` (8-bit S, or 4-bit S), and optionally trashes the full-precision file the import
  /// wrote (never the picked `.safetensors`). `files` holds the model, the VAE or both; a VAE not
  /// picked is looked for beside the model. A stage a previous install finished is skipped. The
  /// text encoder then downloads like any model's dependencies. Progress and errors are in
  /// `h3ImageInstall`; returns whether the install finished.
  @discardableResult
  func installH3Image(
    files: [URL], format: MOSSImporter.EightBit = .rowwise, trashFullPrecision: Bool
  ) async -> Bool {
    guard !h3ImageInstall.isRunning else { return false }
    guard modelImportTask == nil, moving == nil else {
      h3ImageInstall = H3ImageInstall(format: format, error: H3ImageInstallError.busy.localizedDescription)
      return false
    }
    h3ImageInstall = H3ImageInstall(format: format, isRunning: true)
    // Holds picked files open (iPad) until the install ends.
    let held = files.map(ModelImport.init(source:))
    defer { withExtendedLifetime(held) {} }
    do {
      try await runH3ImageInstall(files: files, format: format, trashFullPrecision: trashFullPrecision)
      h3ImageInstall.isFinished = true
    } catch {
      h3ImageInstall.error = error.localizedDescription
    }
    h3ImageInstall.isRunning = false
    h3ImageInstall.stage = nil
    h3ImageInstall.progress = nil
    return h3ImageInstall.isFinished
  }

  private func runH3ImageInstall(
    files: [URL], format: MOSSImporter.EightBit, trashFullPrecision: Bool
  ) async throws {
    let picked = try await Self.classifyH3ImageFiles(files)
    await refresh()
    let installed = catalog.filter {
      $0.isDownloaded && isCustom($0)
        && ModelZoo.specificationForModel($0.file)?.version == .minimaxH3Image
    }
    var full = installed.first { $0.file.hasSuffix("_f16.ckpt") }
    var small = installed.first { $0.file.hasSuffix("_" + format.fileSuffix) }
    let needsModel = full == nil && small == nil
    if needsModel, picked.model == nil { throw H3ImageInstallError.missingModel }
    // Find the VAE before the long import so a missing one fails at once.
    var vae: URL?
    if Self.folder(of: H3ImageVAEImporter.file, in: directories) == nil {
      if let url = picked.vae {
        vae = url
      } else if let model = picked.model, let url = await Self.siblingH3ImageVAE(of: model) {
        vae = url
      } else {
        throw H3ImageInstallError.missingVAE
      }
    }

    if needsModel, let source = picked.model {
      setH3ImageStage(.importingModel)
      var item = ModelImport(source: source)
      item.name = "MiniMax H3 Image"
      let file = try await importModel(item, onProgress: h3ImageProgress(.importingModel))
      await afterChange()
      full = catalog.first { $0.file == file }
    }
    finishH3ImageStage(.importingModel)

    if let vae {
      setH3ImageStage(.convertingVAE)
      let progress = h3ImageProgress(.convertingVAE)
      try await Self.convertH3ImageVAE(vae, into: addFolder) { value in
        Task { @MainActor in progress(Double(value)) }
      }
      await afterChange()
    }
    finishH3ImageStage(.convertingVAE)

    if small == nil, let full {
      setH3ImageStage(.makingEightBit)
      let output = Self.eightBitFile(for: full.file, format)
      guard canMake8BitCopy(full, format) else { throw H3ImageInstallError.cantMakeCopy(format.title) }
      make8BitCopy(full, format)
      while let value = quantizing[output] {
        h3ImageInstall.progress = value
        try? await Task.sleep(for: .milliseconds(250))
      }
      small = catalog.first { $0.file == output && $0.isDownloaded }
      guard small != nil else {
        let reason = errorMessage
        errorMessage = nil
        throw H3ImageInstallError.copyFailed(format.title, reason: reason)
      }
    }
    finishH3ImageStage(.makingEightBit)

    var fullInUse = false
    if trashFullPrecision, let small, let full {
      // As `delete` does, but the copy shares the VAE and text encoder, so only the model's own
      // files go. Create moves to the copy first: the model just imported is often the one it
      // picked, still loading its defaults (which `canDelete` turns away), and otherwise it would
      // fall back to whatever model `refreshModelList` picks.
      if create.selectedModel == full.file { create.selectedModel = small.file }
      // Whatever else was using it (a job, a download) gets a minute to let go.
      let entry = catalog.first { $0.file == full.file } ?? full
      let deadline = Date().addingTimeInterval(60)
      while !canDelete(entry), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(250))
      }
      if canDelete(entry) {
        for url in Self.files(of: full.file, in: directories) {
          try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        try unregisterModel(full.file)
        await afterChange()
      } else {
        fullInUse = true
      }
    }
    // The text encoder and anything else the model lists, as after any import.
    if let model = catalog.first(where: { $0.file == small?.file ?? full?.file }) { download(model) }
    if fullInUse { throw H3ImageInstallError.fullInUse(format.title) }
  }

  nonisolated enum ImportError: LocalizedError {
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
    case .minimaxH3Image:
      // Tuned for about 2,048 x 2,048 pixels of area.
      return 32
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

  /// `<cleaned stem>`, numbered if `<stem>_f16.ckpt` is taken in any models folder (the
  /// importer would write over a file the engine finds in another folder). ModelImporter adds
  /// `_f16.ckpt` (and `_vae_f16.ckpt` and the like for companion files).
  private static func availableModelName(for stem: String, in directories: [URL]) -> String {
    let base = Importer.cleanup(filename: stem)
    var candidate = base
    var counter = 2
    while !files(of: candidate + "_f16.ckpt", in: directories).isEmpty {
      candidate = "\(base)_\(counter)"
      counter += 1
    }
    return candidate
  }

  /// Files an import of `file` wrote next to it (`<name>_vae_f16.ckpt` and the like, the
  /// suffixes ModelImporter uses), when its specification names them. Shared encoders and VAEs
  /// stay.
  static func importedCompanions(of file: String) -> [String] {
    guard file.hasSuffix("_f16.ckpt"), let specification = ModelZoo.specificationForModel(file)
    else { return [] }
    let stem = String(file.dropLast("f16.ckpt".count))
    let suffixes = [
      "vae_f16.ckpt", "clip_vit_l14_f16.ckpt", "open_clip_vit_h14_f16.ckpt",
      "open_clip_vit_bigg14_f16.ckpt", "ministral_3_3b_q8p.ckpt",
    ]
    let named = Set(
      [specification.autoencoder, specification.textEncoder, specification.clipEncoder]
        .compactMap(\.self) + (specification.additionalClipEncoders ?? []))
    // An 8-bit copy names the same files, and the H3 Image VAE is shared by every copy even when
    // the model's name would make it look like the import wrote it.
    let shared = Set(
      ModelZoo.availableSpecifications.filter { $0.file != file }.flatMap {
        [$0.autoencoder, $0.textEncoder, $0.clipEncoder].compactMap(\.self) + ($0.additionalClipEncoders ?? [])
      } + [H3ImageVAEImporter.file])
    return suffixes.map { stem + $0 }.filter { named.contains($0) && !shared.contains($0) }
  }

  /// Removes `file`'s custom.json entries in every models folder, keeping every other entry as
  /// written, and drops it from the running engine's model list.
  private func unregisterModel(_ file: String) throws {
    for directory in directories where Self.readCustomModels(in: directory).contains(file) {
      backUpModelRegistryOnce(in: directory)
      let url = directory.appendingPathComponent("custom.json")
      if let data = try? Data(contentsOf: url),
         let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
      {
        let remaining = entries.filter { $0["file"] as? String != file }
        try JSONSerialization.data(
          withJSONObject: remaining, options: [.prettyPrinted, .withoutEscapingSlashes]
        ).write(to: url, options: .atomic)
      }
    }
    ModelZoo.availableSpecifications.removeAll { $0.file == file }
    ModelZoo.fallbackMapping[file] = nil
  }

  /// Lists a model file already in `directory` that nothing explains, from what its owner says it
  /// is. The file can't say: `template`, a catalog model of the same family, supplies the text
  /// encoders, VAE and defaults. Goes in the file's own folder, like everything else about it.
  func registerConverted(file: String, in directory: URL, template: ModelZoo.Specification) throws {
    backUpModelRegistryOnce(in: directory)
    try Self.addToCustomJSON(Self.specification(for: file, template: template), in: directory)
  }

  /// Lists a LoRA file already in `directory` under the family its owner says it's for.
  func registerConverted(loRA file: String, in directory: URL, version: ModelVersion) throws {
    let name = (file as NSString).deletingPathExtension
    try register(LoRAZoo.Specification(name: name, file: file, prefix: "", version: version, isLoHa: false), in: directory)
  }

  /// `template` as the entry for `file`, without what describes only the template's own model.
  nonisolated static func specification(for file: String, template: ModelZoo.Specification) -> ModelZoo.Specification {
    var specification = template
    specification.name = (file as NSString).deletingPathExtension
    specification.file = file
    specification.note = nil
    specification.huggingFaceLink = nil
    specification.deprecated = nil
    // Some checkpoints carry their own encoder (LTX's Gemma features, for one).
    if template.clipEncoder == template.file { specification.clipEncoder = file }
    return specification
  }

  /// Adds an entry to a folder's custom.json as raw JSON, so the entries already there keep fields
  /// this engine doesn't know, and an entry for the same file is replaced.
  nonisolated static func addToCustomJSON(_ specification: ModelZoo.Specification, in directory: URL) throws {
    let url = directory.appendingPathComponent("custom.json")
    let existing = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let entry = try JSONSerialization.jsonObject(with: encoder.encode(specification))
    let entries = existing.filter { $0["file"] as? String != specification.file } + [entry]
    try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .withoutEscapingSlashes])
      .write(to: url, options: .atomic)
  }

  /// Copies a folder's custom.json aside before the app first changes it in a session.
  private var backedUpModelFolders: Set<URL> = []
  func backUpModelRegistryOnce(in directory: URL? = nil) {
    let directory = directory ?? self.directory
    guard backedUpModelFolders.insert(directory).inserted else { return }
    Self.backUp("custom.json", in: directory)
  }

  // MARK: - LoRAs

  /// Rereads every models folder's custom_lora.json (they can also change outside the app). A
  /// LoRA listed in more than one folder comes from the first.
  func reloadLoRAs() {
    let directories = directories
    var seen = Set<String>()
    var loras: [LoRA] = []
    for directory in directories {
      for specification in Self.readLoRASpecifications(in: directory)
        where seen.insert(specification.file).inserted
      {
        loras.append(
          LoRA(
            name: specification.name, file: specification.file, prefix: specification.prefix,
            version: specification.version.rawValue,
            size: Self.size(of: specification.file, in: directories), registry: directory,
            folder: Self.folder(of: specification.file, in: directories)))
      }
    }
    self.loras = Self.linkingLoRACopies(loras).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Draw Things' 8-bit conversion deletes the original LoRA's file but leaves its custom_lora.json
  /// entry, and the copy's new entry has no trigger words. So a file that's gone and a file that's
  /// here, in the same family with the same name apart from the precision, are one LoRA: it's shown
  /// once, as the copy, with the original's trigger words if it has none. Only in memory: this
  /// file is Draw Things' too, and saving an edit in the LoRAs screen is what writes them down.
  nonisolated static func linkingLoRACopies(_ loras: [LoRA]) -> [LoRA] {
    // Names and file names, without what differs between the two. The copy's name is usually just
    // its file name ("Age Slider v1 Krea" becomes age_slider_v1_krea_lora_q8p.ckpt).
    func normalized(_ text: String) -> String {
      text.lowercased()
        .replacingOccurrences(of: "[^a-z0-9.]+", with: "_", options: .regularExpression)
        .replacingOccurrences(of: "\\.ckpt$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(_lora)?(_(f16|q8p|q6p|q5p|i8x|8_?bit))?_*$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "^_+", with: "", options: .regularExpression)
    }
    func keys(_ lora: LoRA) -> Set<String> { [normalized(lora.file), normalized(lora.name)] }
    let present = loras.filter(\.isDownloaded)
    var missing = loras.filter { !$0.isDownloaded }
    var result = present
    for index in result.indices {
      let copy = result[index]
      guard let match = missing.firstIndex(where: { $0.version == copy.version && !keys($0).isDisjoint(with: keys(copy)) }) else { continue }
      if copy.prefix.trimmingCharacters(in: .whitespaces).isEmpty { result[index].prefix = missing[match].prefix }
      // A name that's only the file name says less than the one its owner chose.
      if normalized(copy.name) == normalized(copy.file), normalized(copy.name) != copy.name.lowercased() || copy.name.contains("_") {
        result[index].name = missing[match].name
      }
      missing.remove(at: match)
    }
    return result + missing
  }

  /// Model families (readable names, as MGK reports a model's `version`) whose LoRAs the engine
  /// applies to a model of `family`, plus its refiner's: the rule LocalImageGenerator uses, which
  /// silently skips any other LoRA. Compared by name because ModelZoo only knows a community
  /// catalog model's version once its pipeline has loaded.
  nonisolated static func loraFamilies(forModel family: String?, refiner: String? = nil)
    -> Set<String>
  {
    var families = Set([family, refiner].compactMap(\.self))
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
      .ideogram4, .krea2, .ltx2, .ltx2_3, .minimaxH3, .minimaxH3Image, .mossImage, .fibo2,
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

  func updateImport(_ id: UUID, name: String? = nil, prefix: String? = nil, scaleFactor: Double? = nil) {
    guard let index = importing.firstIndex(where: { $0.id == id }) else { return }
    if let name { importing[index].name = name }
    if let prefix { importing[index].prefix = prefix }
    if let scaleFactor { importing[index].scaleFactor = scaleFactor }
  }

  /// Every queued LoRA has a scale factor the importer can use.
  var canRunImports: Bool { !importing.isEmpty && importing.allSatisfy(\.hasValidScaleFactor) }

  func removeImport(_ id: UUID) {
    guard importTask == nil else { return }
    importing.removeAll { $0.id == id }
  }

  var isImporting: Bool { importTask != nil }

  /// Converts the queued files one by one into `addFolder` and registers each with the
  /// engine, so it can be used right away. `version` nil means detect it from the weights.
  func runImports(version: String?) {
    guard importTask == nil, canRunImports else { return }
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

  @concurrent private nonisolated static func importLoRAFile(
    _ source: URL, name: String, file: String, version: String?, scaleFactor: Double, into folder: URL,
    progress: @escaping @Sendable (Float) -> Void
  ) async throws -> (ModelVersion, Bool, Bool) {
    // MOSS Image Edit trainer LoRAs need renamed tensors first; see MOSSEditLoRA.
    // `scaleFactor` is baked in the way the engine's LoRAImporter.import does it: √scale on each
    // up and down weight (on top of alpha ÷ rank when the file has alpha), the fourth root on
    // each LoHa factor, so the LoRA's effect is multiplied by the scale.
    let converted = try MOSSEditLoRA.convertedCopy(of: source)
    defer {
      if let converted {
        try? FileManager.default.removeItem(at: converted.url.deletingLastPathComponent())
      }
    }
    let result = try ModelOp.LoRAImporter.import(
      downloadedFile: (converted?.url ?? source).path, name: name, filename: file, scaleFactor: scaleFactor,
      forceVersion: version.flatMap(ModelVersion.init(rawValue:)), outputDirectory: folder.path,
      progress: progress)
    return (result.0, result.3, converted?.isEdit ?? false)
  }

  private func importLoRA(_ item: LoRAImport, version: ModelVersion?) async throws {
    let folder = addFolder
    let stem = item.source.deletingPathExtension().lastPathComponent
    let file = Self.availableLoRAFileName(for: stem, in: directories)
    let before = Self.fileNames(in: folder)
    var succeeded = false
    defer {
      if !succeeded { Self.removeNewFiles(in: folder, before: before, prefix: file) }
    }
    let source = item.source
    let id = item.id
    let progress: @Sendable (Float) -> Void = { [weak self] value in
      Task { @MainActor [weak self] in
        guard let self, let index = importing.firstIndex(where: { $0.id == id }) else { return }
        importing[index].progress = Double(value)
      }
    }
    if let index = importing.firstIndex(where: { $0.id == id }) { importing[index].progress = 0 }
    // ModelOp writes to the folder it's given (an `outputDirectory` the fork adds). MGK's
    // LoRAImporter swaps externalUrls to a temp folder instead, which would race a running
    // generation.
    let (detected, isLoHa, isEdit) = try await Self.importLoRAFile(
      source, name: stem, file: file, version: version?.rawValue, scaleFactor: item.scaleFactor,
      into: folder, progress: progress)
    guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    let trimmedName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let name =
      trimmedName.isEmpty
        ? "\(stem) (\(ModelZoo.humanReadableNameForVersion(detected)))" : trimmedName
    try register(
      LoRAZoo.Specification(
        name: name, file: file, prefix: item.prefix, version: detected,
        isLoHa: isLoHa, modifier: isEdit && detected == .mossImage ? .kontext : nil), in: folder)
    succeeded = true
  }

  /// Renames a LoRA or changes its trigger words; other fields in custom_lora.json are kept.
  func update(_ lora: LoRA, name: String, prefix: String) {
    guard
      var specification = Self.readLoRASpecifications(in: lora.registry).first(where: {
        $0.file == lora.file
      })
    else { return }
    specification.name = name
    specification.prefix = prefix
    do {
      try register(specification, in: lora.registry)
    } catch {
      errorMessage = "Couldn't rename \(lora.name): \(error.localizedDescription)"
    }
    reloadLoRAs()
  }

  /// Writes `specification` to `directory`'s custom_lora.json (sorted by name, as LoRAZoo keeps
  /// it) and reloads the running engine's LoRA table. Written here rather than by LoRAZoo, which
  /// writes to the first folder that has a custom_lora.json, not necessarily this one.
  private func register(_ specification: LoRAZoo.Specification, in directory: URL) throws {
    backUpLoRARegistryOnce(in: directory)
    let specifications =
      (Self.readLoRASpecifications(in: directory).filter { $0.file != specification.file }
        + [specification])
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    try Self.writeLoRASpecifications(specifications, in: directory)
    Self.loadCustomLoRAs(in: directories)
  }

  /// Moves the LoRA file to the Trash and removes its custom_lora.json entry.
  func delete(_ lora: LoRA) {
    guard moving?.file != lora.file else { return }
    errorMessage = nil
    do {
      for url in Self.files(of: lora.file, in: directories) {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      }
      backUpLoRARegistryOnce(in: lora.registry)
      let remaining = Self.readLoRASpecifications(in: lora.registry).filter {
        $0.file != lora.file
      }
      try Self.writeLoRASpecifications(remaining, in: lora.registry)
      // The engine's in-memory table keeps the entry, but with the file gone it's skipped.
    } catch {
      errorMessage = "Couldn't delete \(lora.name): \(error.localizedDescription)"
    }
    reloadLoRAs()
  }

  /// Copies a folder's custom_lora.json aside before the app first changes it in a session.
  private var backedUpLoRAFolders: Set<URL> = []
  func backUpLoRARegistryOnce(in directory: URL) {
    guard backedUpLoRAFolders.insert(directory).inserted else { return }
    Self.backUp("custom_lora.json", in: directory)
  }

  /// Copies a registry file to `<name>.bak-atelier`, replacing an older copy.
  private static func backUp(_ name: String, in directory: URL) {
    let registry = directory.appendingPathComponent(name)
    let backup = directory.appendingPathComponent(name + ".bak-atelier")
    guard FileManager.default.fileExists(atPath: registry.path) else { return }
    try? FileManager.default.removeItem(at: backup)
    Log.attempt(Log.library, "Backing up \(name)") {
      try FileManager.default.copyItem(at: registry, to: backup)
    }
  }

  // MARK: - Files

  /// `file` and its `-tensordata`, from the first models folder that has the file (the one the
  /// engine reads).
  nonisolated static func files(of file: String, in directories: [URL]) -> [URL] {
    guard let directory = folder(of: file, in: directories) else { return [] }
    return [file, file + "-tensordata"].map { directory.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// The first models folder that has `file`: the one the engine reads it from.
  nonisolated static func folder(of file: String, in directories: [URL]) -> URL? {
    directories.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(file).path) }
  }

  private nonisolated static func size(of file: String, in directories: [URL]) -> Int64? {
    let urls = files(of: file, in: directories)
    guard !urls.isEmpty else { return nil }
    return urls.reduce(Int64(0)) { total, url in
      let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
        .totalFileAllocatedSize
      return total + Int64(size ?? 0)
    }
  }

  /// `<stem>_lora_f16.ckpt`, cleaned up the way Draw Things names files, with a numeric suffix if
  /// that file already exists in any models folder.
  private static func availableLoRAFileName(for stem: String, in directories: [URL]) -> String {
    let base = Importer.cleanup(filename: stem)
    var candidate = base + "_lora_f16.ckpt"
    var counter = 2
    while !files(of: candidate, in: directories).isEmpty {
      candidate = "\(base)_\(counter)_lora_f16.ckpt"
      counter += 1
    }
    return candidate
  }

  static func readCustomModels(in directory: URL) -> [String] {
    struct Entry: Decodable { var file: String }
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("custom.json")),
          let entries = try? JSONDecoder().decode([Lenient<Entry>].self, from: data)
    else { return [] }
    return entries.compactMap(\.value?.file)
  }

  /// Every file a folder's custom*.json files name, with the files its models depend on. Reads them
  /// for any folder, whether it's in use or not, and for kinds Atelier doesn't import yet (control
  /// nets, textual inversions), since those files aren't strays either.
  nonisolated static func registeredFiles(in directory: URL) -> Set<String> {
    struct Entry: Decodable { var file: String }
    var files = Set(decodeRegistry(ModelZoo.Specification.self, "custom.json", in: directory).flatMap(Self.files(of:)))
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix("custom") && name.hasSuffix(".json") {
      files.formUnion(decodeRegistry(Entry.self, name, in: directory).map(\.file))
    }
    return files
  }

  /// How many models and LoRAs a folder's custom.json and custom_lora.json list.
  nonisolated static func registeredCount(in directory: URL) -> Int {
    struct Entry: Decodable { var file: String }
    return ["custom.json", "custom_lora.json"].reduce(0) { $0 + decodeRegistry(Entry.self, $1, in: directory).count }
  }

  /// A model's file and the files it needs, as `ModelZoo.availableFiles(excluding:)` lists them.
  nonisolated static func files(of specification: ModelZoo.Specification) -> Set<String> {
    var files: Set<String> = [
      specification.file, specification.textEncoder ?? "clip_vit_l14_f16.ckpt",
      specification.autoencoder ?? "vae_ft_mse_840000_f16.ckpt",
    ]
    for file in [specification.imageEncoder, specification.clipEncoder, specification.t5Encoder, specification.diffusionMapping] {
      if let file { files.insert(file) }
    }
    files.formUnion(specification.additionalClipEncoders ?? [])
    files.formUnion(specification.stageModels ?? [])
    files.formUnion((specification.latentsUpscalers ?? []).map(\.file))
    // Not one of the specification's fields: see `downloadAudioEncoder(for:progress:)`.
    if let audioEncoder = ModelZoo.audioEncoderForModel(specification.file) { files.insert(audioEncoder) }
    return files
  }

  /// Rebuilds the engine's model and LoRA lists from the built-in ones and every models folder's
  /// custom.json and custom_lora.json, as ModelZoo and LoRAZoo do at first use. They read those
  /// only once, from the one folder they pointed at then, so models imported in Draw Things
  /// stayed missing after the models folder changed, and other folders were never read.
  static func loadCustomSpecifications(in directories: [URL]) {
    let custom = firstOfEachFile(directories.flatMap { directory in
      decodeRegistry(ModelZoo.Specification.self, "custom.json", in: directory)
    }, file: \.file)
    let files = Set(custom.map(\.file))
    let builtin = ModelZoo.builtinSpecifications.filter { !files.contains($0.file) }
    let builtinFiles = Set(builtin.map(\.file))
    let uncataloged = ModelDefaults.uncatalogedSpecifications.filter {
      !files.contains($0.file) && !builtinFiles.contains($0.file)
    }
    let uncatalogedFiles = Set(uncataloged.map(\.file))
    let community = CommunityCatalog.fallback.filter {
      !files.contains($0.file) && !builtinFiles.contains($0.file) && !uncatalogedFiles.contains($0.file)
    }
    ModelZoo.availableSpecifications = builtin + community + uncataloged + custom
    // ModelZoo looks a model up in a table it fills once; one it doesn't have is looked up here.
    ModelZoo.fallbackMapping = Dictionary((custom + uncataloged + community).map { ($0.file, $0) }) { first, _ in first }
    loadCustomLoRAs(in: directories)
  }

  /// The LoRA half of `loadCustomSpecifications(in:)`.
  static func loadCustomLoRAs(in directories: [URL]) {
    let custom = firstOfEachFile(
      directories.flatMap { readLoRASpecifications(in: $0) }, file: \.file)
    let files = Set(custom.map(\.file))
    LoRAZoo.availableSpecifications =
      LoRAZoo.builtinSpecifications.filter { !files.contains($0.file) } + custom
    LoRAZoo.fallbackMapping = Dictionary(custom.map { ($0.file, $0) }) { first, _ in first }
  }

  /// Keeps the first entry for each file name.
  private static func firstOfEachFile<Value>(_ values: [Value], file: (Value) -> String)
    -> [Value]
  {
    var seen = Set<String>()
    return values.filter { seen.insert(file($0)).inserted }
  }

  private nonisolated static func decodeRegistry<Value: Decodable>(
    _: Value.Type, _ name: String, in directory: URL
  ) -> [Value] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
          let entries = try? decoder.decode([Lenient<Value>].self, from: data)
    else { return [] }
    return entries.compactMap(\.value)
  }

  private static func readLoRASpecifications(in directory: URL) -> [LoRAZoo.Specification] {
    decodeRegistry(LoRAZoo.Specification.self, "custom_lora.json", in: directory)
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

nonisolated extension MediaGenerationResolvedModel: @retroactive Identifiable {
  public var id: String { file }
}

/// Decodes an array element as nil instead of failing the whole array.
private nonisolated struct Lenient<Value: Decodable>: Decodable {
  var value: Value?
  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}
