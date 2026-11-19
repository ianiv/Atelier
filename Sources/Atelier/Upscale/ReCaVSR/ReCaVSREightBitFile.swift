import Foundation
@preconcurrency import NNC

/// An 8-bit copy of ReCaVSR's DiT that's already somewhere else (made by Atelier on another
/// Mac, say), brought into the ReCaVSR folder without the 10.6 GB published transformer: checks
/// that a file is one, whatever it's named, and copies it in with the prompt and the decoder an
/// 8-bit run also reads. Only the layout `ReCaVSRQuantizer` writes is taken; nothing is
/// converted.
nonisolated enum ReCaVSREightBitFile {
  /// Why a file isn't an 8-bit copy.
  enum Problem: LocalizedError, Equatable {
    case unreadable, notStore, truncated, notClosed, fullPrecision
    case missing(String), notEightBit(String), wrongShape(String)

    var errorDescription: String? {
      switch self {
      case .unreadable: "Couldn't read that file."
      case .notStore: "That isn't a ReCaVSR 8-bit file (\(ReCaVSRFiles.eightBitName))."
      case .truncated: "That file is incomplete; copy it again."
      case .notClosed: "That file was still being written when it was copied; copy it again."
      case .fullPrecision:
        "That's the full-precision file. Put it in the ReCaVSR folder, or use Download and Make 8-bit Copy."
      case .missing(let name): "That isn't Atelier's ReCaVSR 8-bit copy: it has no \(name)."
      case .notEightBit(let name): "That isn't Atelier's ReCaVSR 8-bit copy: \(name) isn't 8-bit."
      case .wrongShape(let name): "That isn't Atelier's ReCaVSR 8-bit copy: \(name) isn't ReCaVSR's size."
      }
    }
  }

  /// Why an import that got past the checks didn't happen.
  enum ImportFailure: LocalizedError {
    case alreadyThere, notEnoughSpace(String)

    var errorDescription: String? {
      switch self {
      case .alreadyThere: "ReCaVSR already has an 8-bit copy."
      case .notEnoughSpace(let needed):
        "The models folder's drive doesn't have enough free space: the import needs \(needed), plus 1 GB to spare."
      }
    }
  }

  /// A layer's modules with a weight and a bias: the matrices the copy stores 8-bit
  /// (`ReCaVSRQuantizer.isEightBit`).
  private static let layerModules = ReCaVSRDenoiser.matrices + ["attn2.to_k", "attn2.to_v"]
  /// A layer's other tensors, float32 in the copy: its norms and its modulation table.
  private static let layerTensors = [
    "attn1.norm_q.weight", "attn1.norm_k.weight", "attn2.norm_q.weight", "attn2.norm_k.weight", "norm2.weight",
    "norm2.bias", "scale_shift_table",
  ]
  /// The modules outside the layers with a weight and a bias: the patch embedding, the recycle
  /// projection, the head, the timestep's and the prompt's embedders and the source projection's
  /// convolutions (`ReCaVSRDenoiser`, `ReCaVSRSourceProjection`).
  private static let outerModules = [
    "patch_embedding", "sr_proj", "proj_out", "condition_embedder.time_embedder.linear_1",
    "condition_embedder.time_embedder.linear_2", "condition_embedder.time_proj",
    "condition_embedder.text_embedder.linear_1", "condition_embedder.text_embedder.linear_2", "lq_proj.conv1",
    "lq_proj.conv2", "lq_proj.out_proj",
  ]
  private static let outerTensors = ["lq_proj.norm1.weight", "lq_proj.norm2.weight", "scale_shift_table"]

  /// Every tensor a copy has, under the published checkpoint's names: what `ReCaVSRQuantizer`
  /// writes from it and the 8-bit loader (`ReCaVSRQuantizedSource`) reads.
  static func expectedNames() -> [String] {
    var names: [String] = []
    for layer in 0..<ReCaVSRConfig.layers {
      let prefix = "blocks.\(layer)."
      for module in layerModules { names += ["\(prefix)\(module).weight", "\(prefix)\(module).bias"] }
      names += layerTensors.map { prefix + $0 }
    }
    for module in outerModules { names += ["\(module).weight", "\(module).bias"] }
    return names + outerTensors
  }

  /// The shape of the 8-bit matrix `name` (rows, columns) in a DiT `hidden` wide with a
  /// feed-forward `wide` wide; nil for the other tensors.
  static func eightBitShape(
    _ name: String, hidden: Int = ReCaVSRConfig.hidden, wide: Int = ReCaVSRConfig.feedForward
  ) -> [Int]? {
    guard ReCaVSRQuantizer.isEightBit(name) else { return nil }
    if name.hasSuffix(".ffn.net.0.proj.weight") { return [wide, hidden] }
    if name.hasSuffix(".ffn.net.2.weight") { return [hidden, wide] }
    return [hidden, hidden]
  }

  /// How much of the start of a file `headerProblem` reads.
  static let headerBytes = 100

  /// What the first bytes of a `fileBytes`-long file say is wrong with it, before it's opened:
  /// an s4nnc store is an SQLite file, whose header gives its page size (bytes 16–17) and its
  /// length in pages (28–31), so one cut short in copying shows here (sqlite.org/fileformat.html
  /// §1.3). A store still in write-ahead mode (bytes 18–19) was copied while it was being
  /// written, and opening it would write beside the original.
  static func headerProblem(_ header: Data, fileBytes: Int64) -> Problem? {
    let bytes = [UInt8](header.prefix(headerBytes))
    // A safetensors file starts with its JSON header's length, then the JSON.
    if bytes.count > 8, bytes[8] == UInt8(ascii: "{"), bytes[4..<8].allSatisfy({ $0 == 0 }) { return .fullPrecision }
    guard bytes.count == headerBytes, bytes.starts(with: Array("SQLite format 3\0".utf8)) else { return .notStore }
    var pageSize = Int64(bytes[16]) << 8 | Int64(bytes[17])
    if pageSize == 1 { pageSize = 65536 }
    let pages = bytes[28..<32].reduce(Int64(0)) { $0 << 8 | Int64($1) }
    guard pageSize * pages <= fileBytes else { return .truncated }
    guard bytes[18] != 2, bytes[19] != 2 else { return .notClosed }
    return nil
  }

  /// Throws the `Problem` when `url` isn't an 8-bit copy as Atelier writes it: every tensor
  /// there, the layers' matrices row-wise 8-bit and ReCaVSR's sizes. Reads the file's header and
  /// the store's names, codecs and shapes, never the weights, so it takes a moment even for a
  /// file on a slow drive; the file is only opened for reading, and nothing is written beside it.
  /// The sizes are ReCaVSR's; tests pass small ones to check small files.
  static func validate(
    _ url: URL, hidden: Int = ReCaVSRConfig.hidden, wide: Int = ReCaVSRConfig.feedForward
  ) throws {
    let path = url.path
    guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil,
          let handle = try? FileHandle(forReadingFrom: url)
    else { throw Problem.unreadable }
    let header = (try? handle.read(upToCount: headerBytes)) ?? Data()
    try? handle.close()
    if let problem = headerProblem(header, fileBytes: size) { throw problem }
    // A journal beside it means its last write never finished.
    for suffix in ["-wal", "-journal"] {
      let sidecar = (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? Int64) ?? nil
      if let sidecar, sidecar > 0 { throw Problem.notClosed }
    }
    var problem: Problem?
    let graph = DynamicGraph()
    let opened = graph.openStore(path, flags: .readOnly) { store in
      let names = Set(store.keys)
      // No tensors table at all: some other SQLite file.
      guard !names.isEmpty else {
        problem = .notStore
        return
      }
      for name in expectedNames() {
        guard names.contains(name) else {
          problem = .missing(name)
          return
        }
        guard let shape = eightBitShape(name, hidden: hidden, wide: wide) else { continue }
        guard store.codec(for: name)?.contains(.i8x) == true else {
          problem = .notEightBit(name)
          return
        }
        guard let like = store.read(like: name), like.shape == TensorShape(shape) else {
          problem = .wrongShape(name)
          return
        }
      }
    }
    if case .failure = opened { throw Problem.notStore }
    if let problem { throw problem }
  }

  /// What a copy on its way in is called until it's checked: not `.part`, which is the
  /// quantizer's own, resumable file.
  static let stagingSuffix = ".import"

  /// Removes what an import that never finished (the app quit, or crashed) left in `folder`:
  /// the staged copies under their `.import` names. Not the quantizer's `.part`, which resumes.
  static func removeStaging(in folder: URL) {
    for name in ReCaVSRFiles.companions.map(\.path) + [ReCaVSRFiles.eightBitName] {
      try? FileManager.default.removeItem(at: folder.appending(path: name + stagingSuffix))
    }
  }

  /// Downloads a published file to where it goes, reporting bytes written.
  typealias Fetch = @Sendable (_ from: URL, _ to: URL, _ progress: @escaping @MainActor (Int64) -> Void) async throws
    -> Void

  /// Copies the 8-bit copy at `source` into `folder` (the ReCaVSR folder), leaving the original
  /// as it is, and with it the prompt and the decoder when `folder` lacks them: the ones beside
  /// `source` if they're there at full size, else downloaded. Those come first, so a download
  /// that fails does so before the long copy, and never leaves a copy that can't run. On a volume
  /// that clones files (APFS) the copy takes no time or space; otherwise it's written in chunks
  /// and read back (`ModelLibrary.copyVerified`). It arrives under another name, is checked again
  /// and only then renamed, so a copy that was stopped is never taken for a finished one.
  /// `progress` gets the fraction done. Cancelling the task stops it and removes what it wrote
  /// of the copy. The check, the downloader and whether it may clone are the real ones unless a
  /// test passes its own.
  @concurrent static func importCopy(
    of source: URL, into folder: URL, allowsCloning: Bool = true,
    validate: @Sendable (URL) throws -> Void = { try ReCaVSREightBitFile.validate($0) },
    fetch: Fetch = { try await FlashVSRDownload.download($0, to: $1, progress: $2) },
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let access = ScopedAccess(source)
    defer { withExtendedLifetime(access) {} }
    try validate(source)
    let fileManager = FileManager.default
    let destination = folder.appending(path: ReCaVSRFiles.eightBitName)
    let resolved = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path }
    // Picked where it already is: nothing to do.
    if resolved(source) == resolved(destination) { return }
    guard !fileManager.fileExists(atPath: destination.path) else { throw ImportFailure.alreadyThere }
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    removeStaging(in: folder)

    let bytes = { (url: URL) in (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil }
    let sourceBytes = bytes(source) ?? 0
    let clones =
      allowsCloning && ModelLibrary.sameVolume(source, folder)
        && (try? folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning) == true
    let companions = ReCaVSRFiles.companions.filter { !ReCaVSRFiles.present($0, in: folder) }
    let companionBytes = companions.reduce(0) { $0 + $1.bytes }
    let needed = (clones ? 0 : sourceBytes) + companionBytes
    if needed > 0, let free = ModelLibrary.freeSpace(at: folder), free < needed + (1 << 30) {
      throw ImportFailure.notEnoughSpace(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))
    }

    // A verified copy reports its bytes twice, written and then checked; halved here.
    let total = Double(max(needed, 1))
    var done = 0.0
    let staged = { (url: URL) in URL(fileURLWithPath: url.path + stagingSuffix) }
    /// `from` into the folder as `to`'s staged file.
    func copy(_ from: URL, to: URL) throws {
      try? fileManager.removeItem(at: staged(to))
      if clones {
        try fileManager.copyItem(at: from, to: staged(to))
      } else {
        let before = done
        var copied = 0.0
        try ModelLibrary.copyVerified(from, to: staged(to)) { count in
          copied += Double(count) / 2
          progress((before + copied) / total)
        }
      }
    }
    /// The staged file into place, over whatever partial file had its name.
    func place(_ to: URL) throws {
      try? fileManager.removeItem(at: to)
      try fileManager.moveItem(at: staged(to), to: to)
    }

    let all = ReCaVSRFiles.companions.map { folder.appending(path: $0.path) } + [destination]
    do {
      for file in companions {
        try Task.checkCancellation()
        let target = folder.appending(path: file.path)
        let sibling = source.deletingLastPathComponent().appending(path: file.path)
        var copied = false
        if bytes(sibling) == file.bytes {
          // A sibling that can't be read (no access to the picked file's folder) is downloaded.
          do {
            try copy(sibling, to: target)
            try place(target)
            copied = true
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            try? fileManager.removeItem(at: staged(target))
          }
        }
        if !copied {
          let before = done
          try await fetch(ReCaVSRFiles.source(file.path), target) { written in
            progress((before + Double(written)) / total)
          }
        }
        done += Double(file.bytes)
        progress(done / total)
      }
      try Task.checkCancellation()
      try copy(source, to: destination)
      try validate(staged(destination))
      // Cancel while it was being checked still stops it.
      try Task.checkCancellation()
      // Made here meanwhile: that one stays.
      guard !fileManager.fileExists(atPath: destination.path) else { throw ImportFailure.alreadyThere }
      try fileManager.moveItem(at: staged(destination), to: destination)
      progress(1)
    } catch {
      for file in all { try? fileManager.removeItem(at: staged(file)) }
      throw error
    }
  }
}
