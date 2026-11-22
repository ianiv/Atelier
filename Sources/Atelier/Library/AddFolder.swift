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
/// (`ModelZoo.filePathForModelDownloaded`), and reordering its folders would shift them under a
/// running generation, so each writer is pointed at the folder instead:
/// - A download to another folder fetches the files itself, as MGK's `ensureModelReady` does
///   (same file list, URL, resumable downloader and checksum), straight into that folder.
/// - Model and LoRA imports pass it to the importers as `outputDirectory`, which the fork adds to
///   `ModelImporter` and `LoRAImporter.import`.
/// - An 8-bit copy is written by `MOSSImporter`, which takes a path.
/// Downloads to the first folder still go through MGK, unchanged, unless a file comes from
/// somewhere MGK doesn't fetch from (`needsOwnDownloader`).
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
    // The MiniMax H3 Image VAE isn't on the server; the app converts it (`H3ImageVAEImporter`).
    let missing = files.filter { $0 != H3ImageVAEImporter.file && !ModelZoo.isModelDownloaded($0) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (index, name) in missing.enumerated() {
      try Task.checkCancellation()
      try await downloadFile(name, to: folder.appendingPathComponent(name)) { written, expected in
        progress(name, index + 1, missing.count, written, expected)
      }
    }
  }

  /// Whether `file` or anything it needs downloads from somewhere other than static.libnnc.org
  /// (`ModelDefaults.downloadSources`), which MGK's `ensure` can't fetch, so `download(_:)` goes
  /// through `downloadModel(_:into:)` even for the first folder.
  nonisolated static func needsOwnDownloader(_ file: String) -> Bool {
    let files = ModelZoo.specificationForModel(file).map { ModelZoo.filesToDownload($0).map(\.file) } ?? [file]
    return files.contains { ModelDefaults.downloadSources[$0] != nil }
  }

  /// One file, resumable, checked against the catalog's SHA-256 when it has one.
  private nonisolated static func downloadFile(
    _ name: String, to destination: URL,
    progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
  ) async throws {
    let source = ModelDefaults.downloadSources[name]
    guard let url = source?.url ?? URL(string: "https://static.libnnc.org/\(name)") else { return }
    try await fetch(
      url: url, to: destination, sha256: source?.sha256 ?? ModelZoo.fileSHA256ForModelDownloaded(name),
      progress: progress)
  }

  /// Downloads `url` to `destination` with the engine's resumable downloader (segmented when the
  /// server takes ranges; `.partial` and `.partial.map` beside the file let a later call resume),
  /// checked against `sha256` when given. `headers` go with every request, and the fork's
  /// downloader drops `Authorization` on a redirect to another host. Cancelling the task cancels
  /// the download and keeps what it has.
  nonisolated static func fetch(
    url: URL, to destination: URL, sha256: String?, headers: [String: String] = [:],
    progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
  ) async throws {
    let downloader = ResumableDownloader(
      remoteUrl: url, localUrl: destination, sha256: sha256, headers: headers)
    // The handler can be called again after it's done (MGK's bridge guards the same way), and a
    // cancelled downloader stops calling it, so cancelling finishes the wait itself.
    let pending = Mutex<CheckedContinuation<Void, Error>?>(nil)
    let finish: @Sendable (Error?) -> Void = { error in
      guard let continuation = pending.withLock({ waiting in defer { waiting = nil }; return waiting }) else { return }
      if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    // A cancel waits while the downloader finalizes: once every byte is in, the backends hash the
    // file (minutes for a large one) and move it into place, and a cancelled downloader still does
    // that, unseen. A Resume meanwhile would start a second downloader on the same `.partial` and
    // fail when the first moves it. So a cancel then lets it finish, and the call ends when it
    // does; the file is complete and the next call finds it. A resumed download whose blocks are
    // all in finalizes without reporting progress first, so one with a segment map counts as
    // finalizing until its first progress report says otherwise.
    let state = Mutex(CancelState(finalizing: FileManager.default.fileExists(atPath: destination.path + ".partial.map")))
    let cancelNow: @Sendable () -> Void = {
      DispatchQueue.global(qos: .userInitiated).async {
        downloader.cancel()
        // A block write already under way, and the download-task backend's resume data (`.part`),
        // land moments after `cancel()` returns, so the call ends a little later.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(500)) {
          finish(CancellationError())
        }
      }
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        pending.withLock { $0 = continuation }
        if Task.isCancelled {
          finish(CancellationError())
          return
        }
        downloader.resume { written, expected, isComplete, error in
          if let error {
            finish(error)
            return
          }
          if isComplete {
            progress(written, expected)
            finish(nil)
            return
          }
          let cancelsNow = state.withLock { state in
            state.finalizing = expected > 0 && written >= expected
            return state.takeDeferredCancel()
          }
          if cancelsNow { cancelNow() }
          progress(written, expected)
        }
      }
    } onCancel: {
      let cancelsNow = state.withLock { state in
        state.cancelRequested = true
        return state.takeDeferredCancel()
      }
      if cancelsNow {
        cancelNow()
      } else {
        // Finalizing: give it a generous while, then cancel anyway rather than wait forever.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(30 * 60)) {
          if state.withLock({ state in defer { state.cancelIssued = true }; return !state.cancelIssued }) { cancelNow() }
        }
      }
    }
    try Task.checkCancellation()
  }

  /// A `fetch` call's cancel, held back while the downloader finalizes.
  private nonisolated struct CancelState {
    var finalizing: Bool
    var cancelRequested = false
    var cancelIssued = false

    /// Whether to cancel the downloader now: asked for, not yet done, and not finalizing.
    mutating func takeDeferredCancel() -> Bool {
      guard cancelRequested, !cancelIssued, !finalizing else { return false }
      cancelIssued = true
      return true
    }
  }

  // MARK: - Imports

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
      // A re-import of the same file would otherwise still find the entry read before it.
      if Self.overriddenFiles.contains(specification.file) {
        ModelZoo.overrideMapping[specification.file] = specification
      }
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
