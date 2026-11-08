@preconcurrency import _MediaGenerationKit
@preconcurrency import Downloader
import Foundation
@preconcurrency import ModelZoo
import SwiftUI
import Synchronization

/// Which models folder new files go to: downloads, model and LoRA imports, and 8-bit copies. With
/// more than one folder a person picks it (`AddFolderPicker`, on the Models screen and in the
/// import sheets), so a model can land on the internal drive without a move afterwards.
///
/// The engine writes a file no folder has yet to the first folder
/// (`ModelZoo.filePathForModelDownloaded`), and its importers take only a file name, so:
/// - A download to another folder fetches the files itself, as MGK's `ensureModelReady` does
///   (same file list, URL, resumable downloader and checksum), straight into that folder.
/// - An import to another folder converts into the first folder as before, then moves the new
///   files over before they're registered, so nothing reads them mid-move.
/// - An 8-bit copy is written by `MOSSImporter`, which takes a path, straight into the folder.
/// The first folder keeps the engine's own paths, unchanged.
extension ModelLibrary {
  nonisolated static let addFolderKey = "addModelsFolder"

  /// Where new files go: the chosen folder while it can be reached, else the first folder.
  var addFolder: URL {
    let chosen = addFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    return directories.first { $0.standardizedFileURL == chosen } ?? directory
  }

  func setAddFolder(_ folder: URL) {
    addFolderPath = folder.path
    UserDefaults.standard.set(folder.path, forKey: Self.addFolderKey)
    Task { await refresh() }
  }

  /// Whether `folder` is the one the engine writes new files to itself.
  func isEngineFolder(_ folder: URL) -> Bool {
    folder.standardizedFileURL == directory.standardizedFileURL
  }

  // MARK: - Downloads

  /// Downloads `file` and what it needs (`ModelZoo.filesToDownload`) that no models folder has yet
  /// into `folder`, following MGK's `ensureModelReady` and `downloadFile`.
  nonisolated static func downloadModel(
    _ file: String, into folder: URL,
    progress: @escaping @Sendable (_ file: String, _ index: Int, _ total: Int, _ written: Int64, _ expected: Int64) -> Void
  ) async throws {
    // Resolving puts a community model's specification where ModelZoo looks (MGK's
    // `ModelResolver.primeOverrideMapping`), so its text encoders and VAE are listed too.
    _ = await MediaGenerationEnvironment.default.resolveModel(file, offline: false)
    let files = ModelZoo.specificationForModel(file).map { ModelZoo.filesToDownload($0).map(\.file) } ?? [file]
    let missing = files.filter { !ModelZoo.isModelDownloaded($0) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (index, name) in missing.enumerated() {
      try Task.checkCancellation()
      try await downloadFile(name, to: folder.appendingPathComponent(name)) { written, expected in
        progress(name, index + 1, missing.count, written, expected)
      }
    }
  }

  /// One file, resumable, checked against the catalog's SHA-256 when it has one.
  private nonisolated static func downloadFile(
    _ name: String, to destination: URL,
    progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
  ) async throws {
    guard let url = URL(string: "https://static.libnnc.org/\(name)") else { return }
    let downloader = ResumableDownloader(
      remoteUrl: url, localUrl: destination, sha256: ModelZoo.fileSHA256ForModelDownloaded(name))
    let resumed = Mutex(false)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        // The handler can be called again after it's done (MGK's bridge guards the same way).
        let finish: @Sendable (Error?) -> Void = { error in
          guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
        downloader.resume { written, expected, isComplete, error in
          if let error {
            finish(error)
            return
          }
          progress(written, expected)
          if isComplete { finish(nil) }
        }
      }
    } onCancel: {
      DispatchQueue.global(qos: .userInitiated).async { downloader.cancel() }
    }
    try Task.checkCancellation()
  }

  // MARK: - Imports

  /// Moves files an import just wrote in the first folder into `folder`, with their `-tensordata`.
  /// They aren't registered yet, so nothing has them open. Off the main actor: across drives a move
  /// is a copy.
  @concurrent nonisolated static func moveImported(_ files: [String], from source: URL, to folder: URL) async throws {
    let fileManager = FileManager.default
    for file in files {
      let from = source.appendingPathComponent(file)
      guard fileManager.fileExists(atPath: from.path) else { continue }
      let to = folder.appendingPathComponent(file)
      try? fileManager.removeItem(at: to)
      try fileManager.moveItem(at: from, to: to)
    }
  }

  /// Lists an imported model in `folder`'s custom.json and with the running engine. The first
  /// folder goes through ModelZoo as it always has; another folder gets the entry written there
  /// directly, since ModelZoo writes only to the first.
  func registerImported(_ specification: ModelZoo.Specification, in folder: URL) throws {
    if isEngineFolder(folder) {
      backUpModelRegistryOnce()
      // custom.json resolves to ~/Documents/Models unless external URLs are preferred, which MGK
      // leaves off. Prefer them just for this call (on the main thread, as the engine requires).
      let preferred = ModelZoo.isExternalUrlsPreferred
      ModelZoo.isExternalUrlsPreferred = true
      ModelZoo.appendCustomSpecification(specification)
      ModelZoo.isExternalUrlsPreferred = preferred
    } else {
      backUpModelRegistryOnce(in: folder)
      try Self.addToCustomJSON(specification, in: folder)
      Self.loadCustomSpecifications(in: directories)
    }
  }
}

/// "Add To": the models folder new downloads, imports and 8-bit copies go to. Always shown, and
/// disabled with only one folder, so it's clear where they go.
struct AddFolderPicker: View {
  @Environment(ModelLibrary.self) private var library
  var title = "Add To"

  var body: some View {
    Picker(
      title,
      selection: Binding(get: { library.addFolder }, set: { library.setAddFolder($0) })
    ) {
      ForEach(library.directories, id: \.self) { folder in
        Text(library.folderName(folder)).tag(folder)
      }
    }
    .pickerStyle(.menu)
    .fixedSize()
    .disabled(!library.hasOtherFolders)
    .help(
      library.hasOtherFolders
        ? "The models folder new downloads, imports and 8-bit copies go to"
        : "Add another models folder in Settings to choose where new models go")
  }
}
