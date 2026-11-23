@preconcurrency import _MediaGenerationKit
@preconcurrency import Diffusion
@preconcurrency import Downloader
import Foundation
@preconcurrency import ModelZoo
import Synchronization

/// What a link download fetches, kept as `download.json` in its staging folder so a download that
/// stopped (cancelled, failed, quit) can be resumed or discarded later, and a finished one that
/// wasn't imported yet can still be.
nonisolated struct LinkDownloadRecord: Codable, Equatable, Sendable {
  struct Item: Codable, Equatable, Sendable {
    var title: String
    var files: [HuggingFaceRepoFile]
    var index: String?
    var merges: Bool
    /// The file handed to the import sheet, in the staging folder; for support files, the folder
    /// they're in.
    var output: String
    /// Files another item's import reads where they downloaded to, not imported themselves: Fibo
    /// 2.0's `text_encoder/`, which `Fibo2TextEncoderImporter` converts with the model. Not joined,
    /// moved or handed to the import sheet. Optional so records written before it still read.
    var supportFiles: Bool?

    var weights: [HuggingFaceRepoFile] { files.filter { $0.path != index } }
    var isSupport: Bool { supportFiles == true }
  }

  /// The link as pasted.
  var link: String
  var repo: String
  /// The commit every file is fetched at.
  var sha: String
  var kind: HuggingFaceListing.Kind
  var items: [Item]
  var created: Date
  /// Outputs already imported, across import runs: a later Import queues only the others, so a
  /// file isn't converted twice, and the staging folder goes once every output is in here.
  /// Optional so records written before it still read.
  var imported: [String]?

  var size: Int64 { items.flatMap(\.files).reduce(0) { $0 + $1.size } }
  /// The items still to import (support files aren't imported on their own).
  var remainingItems: [Item] { items.filter { !$0.isSupport && !(imported ?? []).contains($0.output) } }
  var isFullyImported: Bool { remainingItems.isEmpty }

  /// Notes `output` as imported.
  mutating func markImported(_ output: String) {
    guard items.contains(where: { $0.output == output }), !(imported ?? []).contains(output) else { return }
    imported = (imported ?? []) + [output]
  }
  var title: String { repo + ": " + items.map(\.title).joined(separator: ", ") }
}

/// A running link download, for the sheet and the Models and LoRAs screens.
struct LinkDownloadProgress: Equatable {
  var title: String
  var kind: HuggingFaceListing.Kind
  /// The file being fetched, as catalog downloads show it.
  var download: ModelLibrary.Download?
  /// Joining split safetensors (`SafetensorsMerge`), 0…1.
  var merging: Double?

  var fraction: Double? { merging ?? download?.fraction }
  var description: String {
    if let merging { return "Joining parts… \(Int(merging * 100))%" }
    if let download { return ModelStatus.describe(download) }
    return "Starting…"
  }
}

/// A link download in a staging folder that isn't running or waiting in an import sheet.
struct UnfinishedLinkDownload: Identifiable, Equatable {
  var folder: URL
  var record: LinkDownloadRecord
  /// What its files take on disk now.
  var bytesOnDisk: Int64
  /// Every file is downloaded (and joined); only the import is left.
  var isComplete: Bool
  var id: String { folder.path }
}

/// What a repo looked up offers, for the link sheet.
struct HuggingFaceLookup: Equatable {
  var link: HuggingFaceLink
  var info: HuggingFaceRepoInfo
  var listing: HuggingFaceListing
}

/// The family a checkpoint is, read from its header before it's downloaded.
enum LinkInspection: Equatable {
  case checking
  /// The family's name and `ModelVersion` raw value, and the text encoders and VAE it still needs
  /// from the download server with their total size.
  case detected(family: String, version: String?, companions: [String], companionBytes: Int64)
  /// Can't be downloaded or imported, whatever its weights: Hugging Face refused, or the header
  /// isn't a safetensors one. Blocks Download.
  case problem(String)
  /// What the inspection made of the stand-in; doesn't block Download, since detection can depend
  /// on tensor values the stand-in doesn't have.
  case warning(String)
  /// Only known once downloaded: not a safetensors, or the header couldn't be read.
  case afterDownload
}

/// Importing from Hugging Face links: looks a repo up, downloads what's picked into a staging
/// folder in the folder new models go to (`addFolder`), joins split safetensors, then hands the
/// file to the usual import sheet, which converts it. Not a queue job: like a catalog download it
/// runs beside generations, one file at a time.
///
/// Staging is `<addFolder>/.huggingface/<owner>__<repo>/<sha12>/`, on the same volume as the
/// converted output so nothing is copied across disks. The dot keeps it out of the folder scans
/// (they list top-level checkpoint files only) and out of Draw Things' import list. A download
/// that stops keeps its files there; nothing is deleted until the import succeeds or the person
/// discards it.
extension ModelLibrary {
  nonisolated static let stagingFolderName = ".huggingface"
  nonisolated static let recordName = "download.json"
  /// Files not in LFS (JSON, small configs) are fetched in one request, up to this size.
  nonisolated static let smallFileLimit: Int64 = 16 << 20

  // MARK: - Look up

  func lookUp(_ link: HuggingFaceLink) async throws -> HuggingFaceLookup {
    try await Self.lookUp(link, token: huggingFace.token, user: huggingFace.userName)
  }

  /// The repo's info at the link's revision, then its whole file tree at that commit, and for a
  /// Diffusers repo its `model_index.json`.
  @concurrent nonisolated static func lookUp(_ link: HuggingFaceLink, token: String?, user: String?) async throws -> HuggingFaceLookup {
    let repo = link.repo
    let (infoData, _) = try await HuggingFaceAuth.data(
      HuggingFaceLink.infoURL(repo: repo, revision: link.revision), token: token, limit: 32 << 20, repo: repo, user: user)
    let info = try HuggingFaceRepoInfo.decode(infoData)
    var files: [HuggingFaceRepoFile] = []
    var next: URL? = HuggingFaceLink.treeURL(repo: repo, sha: info.sha)
    var pages = 0
    while let url = next, pages < 200 {
      try Task.checkCancellation()
      let (data, response) = try await HuggingFaceAuth.data(url, token: token, limit: 32 << 20, repo: repo, user: user)
      files += try HuggingFaceRepoInfo.decodeTree(data)
      next = HuggingFaceRepoInfo.nextPage(link: response.value(forHTTPHeaderField: "Link"))
      pages += 1
    }
    var modelIndex: [String: Any]?
    if files.contains(where: { $0.path == "model_index.json" }) {
      let (data, _) = try await HuggingFaceAuth.data(
        HuggingFaceLink.resolveURL(repo: repo, revision: info.sha, path: "model_index.json"), token: token,
        limit: 1 << 20, repo: repo, user: user)
      modelIndex = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    let listing = HuggingFaceListing.make(repo: repo, files: files, modelIndex: modelIndex)
    return HuggingFaceLookup(link: link, info: info, listing: listing)
  }

  /// The catalog model the repo is, if Draw Things has it already converted.
  func catalogMatch(for repo: String) -> MediaGenerationResolvedModelMatch? {
    guard let specification = ModelZoo.specificationForHuggingFaceRepo(repo),
          let model = catalog.first(where: { $0.file == specification.file })
    else { return nil }
    return MediaGenerationResolvedModelMatch(model: model)
  }

  // MARK: - Inspecting before downloading

  /// Reads the header of `entry`'s files from Hugging Face (two small range requests each),
  /// writes it into a sparse stand-in of the full file, and runs the import's own inspection on
  /// it, so the family shows before gigabytes are downloaded. The stand-in has no tensor data, so
  /// what the inspection can't make of it is only a warning: the import sheet checks the real file.
  /// It goes in the system's temporary folder, and only on a volume with sparse files (APFS), where
  /// it takes no space; exFAT and HFS+ would write out its full length.
  func inspectBeforeDownload(_ entry: HuggingFaceListing.Entry, lookup: HuggingFaceLookup) async -> LinkInspection {
    guard entry.isSafetensors else { return .afterDownload }
    let temporary = FileManager.default.temporaryDirectory
    guard (try? temporary.resourceValues(forKeys: [.volumeSupportsSparseFilesKey]))?.volumeSupportsSparseFiles == true else {
      return .afterDownload
    }
    let scratch = temporary.appendingPathComponent("AtelierLinkInspect-\(UUID().uuidString)", isDirectory: true)
    let result = await Self.inspectRemote(
      entry, repo: lookup.link.repo, sha: lookup.info.sha, token: huggingFace.token, user: huggingFace.userName,
      scratch: scratch)
    guard case .detected(let family, let version?, _, _) = result,
          let version = ModelVersion(rawValue: version)
    else { return result }
    let companions = Self.missingCompanions(for: version)
    let support = supportItems(for: [version], listing: lookup.listing).flatMap(\.files).reduce(Int64(0)) { $0 + $1.size }
    // Support files come from the repo, not the download server, and are converted beside it.
    let bytes = await Self.downloadSize(of: support > 0 ? companions.filter { $0 != Fibo2TextEncoderImporter.file } : companions)
    return .detected(family: family, version: version.rawValue, companions: companions, companionBytes: bytes + support * 2)
  }

  @concurrent nonisolated static func inspectRemote(
    _ entry: HuggingFaceListing.Entry, repo: String, sha: String, token: String?, user: String?, scratch: URL
  ) async -> LinkInspection {
    do {
      var parts: [SafetensorsMerge.Part] = []
      var single: Data?
      for file in entry.weights {
        let url = HuggingFaceLink.resolveURL(repo: repo, revision: sha, path: file.path)
        let (lengthData, _) = try await HuggingFaceAuth.data(url, token: token, range: 0..<8, repo: repo, user: user)
        let length = lengthData.withUnsafeBytes { Int64(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        guard length > 0, length < 100_000_000, 8 + length <= file.size else { return .problem("\(file.name) isn't a safetensors file.") }
        let (headerData, _) = try await HuggingFaceAuth.data(
          url, token: token, range: 8..<(8 + length), limit: Int(length), repo: repo, user: user)
        guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else {
          return .problem("\(file.name) isn't a safetensors file.")
        }
        parts.append(SafetensorsMerge.Part(name: file.name, header: header, dataLength: file.size - 8 - length))
        single = headerData
      }
      let header: Data
      if entry.merges {
        var weightMap: [String: String]?
        if let index = entry.index {
          let (data, _) = try await HuggingFaceAuth.data(
            HuggingFaceLink.resolveURL(repo: repo, revision: sha, path: index), token: token, limit: Int(smallFileLimit),
            repo: repo, user: user)
          weightMap = try SafetensorsMerge.weightMap(data)
        }
        header = try SafetensorsMerge.mergedHeader(parts, weightMap: weightMap)
      } else if let single {
        header = single
      } else {
        return .afterDownload
      }
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: scratch) }
      let standIn = scratch.appendingPathComponent(entry.modelOutput)
      try SafetensorsMerge.writeSparse(header: header, dataLength: parts.reduce(0) { $0 + $1.dataLength }, to: standIn)
      if await ModelLibrary.isH3ImageVAE(standIn) { return .detected(family: ModelLibrary.h3ImageVAEFamily, version: nil, companions: [], companionBytes: 0) }
      switch await ModelLibrary.inspectedVersion(of: standIn) {
      case .success(let version):
        if version != .mossImage, unconvertibleVersions.contains(version) {
          return .warning("Looks like \(ModelZoo.humanReadableNameForVersion(version)), which can't be converted yet.")
        }
        return .detected(family: ModelZoo.humanReadableNameForVersion(version), version: version.rawValue, companions: [], companionBytes: 0)
      case .failure:
        return .warning(unrecognizedWarning)
      }
    } catch let error as HuggingFaceError {
      return .problem(error.localizedDescription)
    } catch {
      return .afterDownload
    }
  }

  nonisolated static let h3ImageVAEFamily = "MiniMax H3 Image VAE"
  nonisolated static let unrecognizedWarning = "The importer doesn't recognize it from its header; the import checks the downloaded file again."

  /// The text encoders and VAE a model of `version` downloads after its import that no models
  /// folder has, from a catalog model of that family (what the imported model's specification will
  /// name, `ModelImporter.inferModelSpecification`).
  static func missingCompanions(for version: ModelVersion) -> [String] {
    let files: [String]
    if let specification = ModelZoo.availableSpecifications.first(where: { $0.version == version }) {
      files = ModelZoo.filesToDownload(specification).map(\.file).filter { $0 != specification.file }
    } else if version == .fibo2 {
      // No catalog model is Fibo 2.0; these are what `inferModelSpecification` names for it.
      files = [Fibo2TextEncoderImporter.file, "flux_2_vae_f16.ckpt"]
    } else {
      return []
    }
    return files.filter { $0 != H3ImageVAEImporter.file && !ModelZoo.isModelDownloaded($0) }
  }

  /// Support files a download of a model of `version` from `listing` adds: Fibo 2.0's text
  /// encoder, which the download server doesn't have, when no models folder has it converted.
  func supportItems(for versions: [ModelVersion], listing: HuggingFaceListing) -> [LinkDownloadRecord.Item] {
    guard versions.contains(.fibo2), Fibo2TextEncoderImporter.isMissing(in: directories) else { return [] }
    let files = listing.safetensorsEntries(inFolder: Fibo2TextEncoderImporter.folderName).flatMap(\.files)
    guard !files.isEmpty else { return [] }
    return [LinkDownloadRecord.Item(
      title: Fibo2TextEncoderImporter.folderName, files: files, index: nil, merges: false,
      output: Fibo2TextEncoderImporter.folderName, supportFiles: true)]
  }

  /// The size of each file on the download server (a HEAD each), summed; unknown ones count 0.
  @concurrent nonisolated static func downloadSize(of files: [String]) async -> Int64 {
    var total: Int64 = 0
    for file in files {
      guard let url = ModelDefaults.downloadSources[file]?.url ?? URL(string: "https://static.libnnc.org/\(file)") else { continue }
      total += await withCheckedContinuation { (continuation: CheckedContinuation<Int64, Never>) in
        ResumableDownloader.probe(remoteUrl: url) { result in
          continuation.resume(returning: (try? result.get().expectedLength) ?? 0)
        }
      }
    }
    return total
  }

  /// Disk space a download needs: a model's files, the joined or converted copy and the import's
  /// working room (about 2.1× the download), plus the encoders it fetches after; a LoRA's file and
  /// its smaller converted copy (1.2×).
  nonisolated static func requiredSpace(downloadSize: Int64, kind: HuggingFaceListing.Kind, companionBytes: Int64) -> Int64 {
    kind == .model ? Int64(Double(downloadSize) * 2.1) + companionBytes : Int64(Double(downloadSize) * 1.2)
  }

  // MARK: - Downloading

  /// Starts downloading `entries` of `lookup` as `kind` into a new staging folder in `addFolder`.
  /// `detected` is the families the header check found, which decide the support files it adds.
  func startLinkDownload(
    _ entries: [HuggingFaceListing.Entry], kind: HuggingFaceListing.Kind, lookup: HuggingFaceLookup, linkText: String,
    detected: [ModelVersion] = []
  ) {
    errorMessage = nil
    let support = kind == .model ? supportItems(for: detected, listing: lookup.listing) : []
    let record = LinkDownloadRecord(
      link: linkText, repo: lookup.link.repo, sha: lookup.info.sha, kind: kind,
      items: Self.uniqueOutputs(entries.map {
        LinkDownloadRecord.Item(title: $0.title, files: $0.files, index: $0.index, merges: $0.merges, output: $0.output(for: kind))
      }) + support,
      created: Date())
    do {
      let folder = try Self.makeStagingFolder(for: record, in: addFolder)
      runLinkDownload(record, in: folder)
    } catch {
      errorMessage = "Couldn't start the download: \(error.localizedDescription)"
    }
  }

  /// Gives each item an output name no other item uses, as an output or as a file it downloads:
  /// generic names in different folders (`unet/model.safetensors`, `sub/model.safetensors`) all
  /// take the repo's name. A later item that collides gets its folder's name added, then a number.
  /// Decided once, when the download starts, and kept in download.json, so a resume finds the files.
  nonisolated static func uniqueOutputs(_ items: [LinkDownloadRecord.Item]) -> [LinkDownloadRecord.Item] {
    var taken = Set<String>()
    var result: [LinkDownloadRecord.Item] = []
    for (number, item) in items.enumerated() {
      // Files the other items download, except a single file that is its own output.
      let others = items.enumerated().filter { $0.offset != number }.flatMap { $0.element.files.map(\.path) }
      func isFree(_ name: String) -> Bool { !taken.contains(name) && !others.contains(name) }
      var item = item
      if !isFree(item.output) {
        let ext = (item.output as NSString).pathExtension
        let stem = (item.output as NSString).deletingPathExtension
        let folder = (item.weights.first.map { ($0.path as NSString).deletingLastPathComponent } ?? "")
          .split(separator: "/").last.map(String.init) ?? ""
        var candidates = folder.isEmpty ? [] : ["\(stem)-\(folder)"]
        candidates += (2...999).map { "\(stem)-\($0)" }
        item.output = candidates.map { $0 + "." + ext }.first(where: isFree) ?? item.output
      }
      taken.insert(item.output)
      result.append(item)
    }
    return result
  }

  /// A new folder for `record` under `<folder>/.huggingface/<owner>__<repo>/`, named after the
  /// commit, with its `download.json`. A second download from the same commit gets `-2`, `-3`…
  nonisolated static func makeStagingFolder(for record: LinkDownloadRecord, in folder: URL) throws -> URL {
    let repoFolder = folder.appendingPathComponent(stagingFolderName, isDirectory: true)
      .appendingPathComponent(record.repo.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
    let base = String(record.sha.prefix(12))
    var name = base
    var number = 1
    while FileManager.default.fileExists(atPath: repoFolder.appendingPathComponent(name).path) {
      number += 1
      name = "\(base)-\(number)"
    }
    let staging = repoFolder.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try writeRecord(record, in: staging)
    return staging
  }

  nonisolated static func writeRecord(_ record: LinkDownloadRecord, in folder: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: folder.appendingPathComponent(recordName), options: .atomic)
  }

  nonisolated static func readRecord(in folder: URL) -> LinkDownloadRecord? {
    guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(recordName).path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(LinkDownloadRecord.self, from: data)
  }

  /// Resumes an unfinished download (or, when its files are all there, opens its import).
  func resumeLinkDownload(_ unfinished: UnfinishedLinkDownload) {
    errorMessage = nil
    runLinkDownload(unfinished.record, in: unfinished.folder)
  }

  func runLinkDownload(_ record: LinkDownloadRecord, in folder: URL) {
    let key = folder.path
    guard linkDownloadTasks[key] == nil else { return }
    unfinishedLinkDownloads.removeAll { $0.id == key }
    linkDownloads[key] = LinkDownloadProgress(title: record.title, kind: record.kind)
    let token = huggingFace.token, user = huggingFace.userName
    linkDownloadTasks[key] = Task {
      let show: @Sendable (ModelLibrary.Download?, Double?) -> Void = { download, merging in
        Task { @MainActor in
          guard self.linkDownloadTasks[key] != nil else { return }
          self.linkDownloads[key]?.download = download
          self.linkDownloads[key]?.merging = merging
        }
      }
      var finished = false
      do {
        try await Self.performLinkDownload(record, in: folder, token: token, user: user, progress: show)
        // Cancelled just as it finished: still not handed over.
        finished = !Task.isCancelled
      } catch where Self.isCancellation(error) || Task.isCancelled {
        // Cancelled: the partial files stay for Resume.
      } catch {
        errorMessage = "Couldn't download from \(record.repo): \(Self.describe(error, repo: record.repo, user: user, hasToken: token != nil))"
      }
      linkDownloads[key] = nil
      linkDownloadTasks[key] = nil
      if finished { handOff(record, in: folder) }
      await reloadUnfinishedLinkDownloads()
    }
  }

  func cancelLinkDownload(_ folder: String) {
    linkDownloadTasks[folder]?.cancel()
  }

  /// A cancelled task, or a request cancelled under it (URLSession's, or wrapped by the
  /// downloader), which isn't worth an error message.
  nonisolated static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if case ResumableDownloader.DownloadError.local(let inner)? = error as? ResumableDownloader.DownloadError {
      return isCancellation(inner)
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  /// The downloader's errors in terms of what to do: a 401 or 403 from a gated or private repo.
  /// A 401 with a token means Hugging Face turned the token down.
  nonisolated static func describe(_ error: Error, repo: String, user: String?, hasToken: Bool) -> String {
    if case ResumableDownloader.DownloadError.server(let status)? = error as? ResumableDownloader.DownloadError {
      switch status {
      case 401: return (hasToken ? HuggingFaceError.tokenRejected : HuggingFaceError.needsToken).localizedDescription
      case 403: return HuggingFaceError.gated(repo: repo, user: user).localizedDescription
      case 404: return HuggingFaceError.notFound.localizedDescription
      default: break
      }
    }
    if case ResumableDownloader.DownloadError.fileMismatch? = error as? ResumableDownloader.DownloadError {
      return "A downloaded file didn't match its checksum. Try again."
    }
    return (error as? ResumableDownloader.DownloadError)?.description ?? error.localizedDescription
  }

  /// Fetches every file of `record` not yet in `folder` (one at a time, each checked against its
  /// LFS SHA-256), joins split sets, and moves each item's file to its output name. A file already
  /// at its full size, or an item whose output exists, is done.
  @concurrent nonisolated static func performLinkDownload(
    _ record: LinkDownloadRecord, in folder: URL, token: String?, user: String?,
    progress: @escaping @Sendable (ModelLibrary.Download?, Double?) -> Void
  ) async throws {
    let fileManager = FileManager.default
    let total = record.items.flatMap(\.files).count
    var index = 0
    for item in record.items {
      let output = folder.appendingPathComponent(item.output)
      if !item.isSupport, fileManager.fileExists(atPath: output.path), !fileManager.fileExists(atPath: output.path + ".partial") {
        index += item.files.count
        continue
      }
      for file in item.files {
        try Task.checkCancellation()
        guard HuggingFaceRepoFile.isSafePath(file.path), HuggingFaceRepoFile.isSafePath(item.output) else {
          throw HuggingFaceError.unexpectedResponse
        }
        index += 1
        let destination = folder.appendingPathComponent(file.path)
        let number = index
        progress(ModelLibrary.Download(file: file.name, fileIndex: number, totalFiles: total, bytesWritten: 0, totalBytes: file.size), nil)
        if size(of: destination) == file.size { continue }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let url = HuggingFaceLink.resolveURL(repo: record.repo, revision: record.sha, path: file.path)
        if file.sha256 == nil, file.size <= smallFileLimit {
          let (data, _) = try await HuggingFaceAuth.data(url, token: token, limit: Int(smallFileLimit), repo: record.repo, user: user)
          guard Int64(data.count) == file.size else { throw HuggingFaceError.unexpectedResponse }
          try data.write(to: destination, options: .atomic)
        } else {
          let current = Mutex(ModelLibrary.Download(file: file.name, fileIndex: number, totalFiles: total, bytesWritten: 0, totalBytes: file.size))
          try await fetch(
            url: url, to: destination, sha256: file.sha256, headers: HuggingFaceAuth.headers(for: url, token: token),
            progress: { written, expected in
              progress(current.withLock { $0.bytesWritten = written; $0.totalBytes = expected; return $0 }, nil)
            },
            finishing: { cancelPending in
              progress(current.withLock { $0.finishing = true; $0.cancelPending = cancelPending; return $0 }, nil)
            })
        }
      }
      try Task.checkCancellation()
      if item.isSupport {
        // Stays where it downloaded to, for the model's import.
      } else if item.merges {
        let shards = item.weights.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
          .map { folder.appendingPathComponent($0.path) }
        progress(nil, 0)
        // Cancelling stops between chunks (`CancellationError`); the parts not yet copied stay and
        // the deleted ones download again on Resume, which joins them from the start.
        try SafetensorsMerge.merge(
          shards: shards, index: item.index.map { folder.appendingPathComponent($0) }, into: output,
          deletingShards: true, isCancelled: { Task.isCancelled }
        ) { fraction in progress(nil, fraction) }
      } else if let file = item.files.first, file.path != item.output {
        try? fileManager.removeItem(at: output)
        try fileManager.moveItem(at: folder.appendingPathComponent(file.path), to: output)
      }
    }
    try Task.checkCancellation()
  }

  nonisolated static func size(of url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
  }

  /// Hands the downloaded files to the import sheet for the record's kind; the sheet converts and
  /// registers them, and the staging folder goes once they've imported.
  func handOff(_ record: LinkDownloadRecord, in folder: URL) {
    // What an earlier run imported isn't queued again.
    let remaining = (Self.readRecord(in: folder) ?? record).remainingItems
    guard !remaining.isEmpty else {
      removeLinkStaging([folder])
      return
    }
    let urls = remaining.map { folder.appendingPathComponent($0.output) }
    switch record.kind {
    case .model: prepareModelImport(urls, ownedFolder: folder)
    case .lora: prepareImport(urls, ownedFolder: folder)
    }
    linkHandOffCount += 1
    onLinkDownloadReady?(record.kind)
  }

  // MARK: - Unfinished downloads

  /// Rereads the staging folders of every models folder, leaving out downloads running now and
  /// those waiting in an import sheet.
  func reloadUnfinishedLinkDownloads() async {
    let busy = Set(linkDownloadTasks.keys).union(
      (importing.compactMap(\.ownedFolder) + importingModels.compactMap(\.ownedFolder)).map(\.path))
    let found = await Self.scanStaging(in: directories)
    unfinishedLinkDownloads = found.filter { !busy.contains($0.id) }
  }

  @concurrent nonisolated static func scanStaging(in directories: [URL]) async -> [UnfinishedLinkDownload] {
    let fileManager = FileManager.default
    var found: [UnfinishedLinkDownload] = []
    for directory in directories {
      let root = directory.appendingPathComponent(stagingFolderName, isDirectory: true)
      for repo in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
        for folder in (try? fileManager.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil)) ?? [] {
          guard let record = readRecord(in: folder) else { continue }
          let complete = record.items.allSatisfy { item in
            if item.isSupport {
              return item.files.allSatisfy { size(of: folder.appendingPathComponent($0.path)) == $0.size }
            }
            let output = folder.appendingPathComponent(item.output).path
            return fileManager.fileExists(atPath: output) && !fileManager.fileExists(atPath: output + ".partial")
          }
          found.append(UnfinishedLinkDownload(folder: folder, record: record, bytesOnDisk: allocatedSize(of: folder), isComplete: complete))
        }
      }
    }
    return found.sorted { $0.record.created > $1.record.created }
  }

  nonisolated static func allocatedSize(of folder: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: Set(keys))
      total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
    return total
  }

  /// Deletes an unfinished download's staging folder and what it downloaded.
  func discardLinkDownload(_ unfinished: UnfinishedLinkDownload) async {
    guard linkDownloadTasks[unfinished.id] == nil else { return }
    removeLinkStaging([unfinished.folder])
    await reloadUnfinishedLinkDownloads()
  }

  /// Removes the staging folders whose every item (by output name, from download.json) is among
  /// download.json's imported outputs, from this run and earlier ones. One whose import failed, or
  /// whose file was removed from the import sheet, stays under Unfinished Downloads.
  func removeLinkStaging(ifFullyImported folders: Set<URL>) {
    removeLinkStaging(folders.filter { Self.readRecord(in: $0)?.isFullyImported == true })
  }

  /// Notes in the staging folder's download.json that `output` imported, at once, so it holds even
  /// if the rest of the run is cancelled or the app quits.
  nonisolated static func recordImport(of output: String, in folder: URL) {
    guard var record = readRecord(in: folder) else { return }
    record.markImported(output)
    try? writeRecord(record, in: folder)
  }

  /// Removes staging folders, then their repo folder and `.huggingface` when that leaves them empty.
  func removeLinkStaging(_ folders: Set<URL>) {
    let fileManager = FileManager.default
    for folder in folders {
      try? fileManager.removeItem(at: folder)
      for parent in [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()] {
        guard parent.lastPathComponent != ".", ((try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? ["?"]).isEmpty else { break }
        try? fileManager.removeItem(at: parent)
      }
    }
  }
}

/// A catalog model matching a repo, wrapped so the sheet's state stays `Equatable`.
struct MediaGenerationResolvedModelMatch: Equatable {
  var model: MediaGenerationResolvedModel
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.model.file == rhs.model.file }
}
