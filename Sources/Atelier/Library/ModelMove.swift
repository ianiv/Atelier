@preconcurrency import _MediaGenerationKit
import Foundation
@preconcurrency import ModelZoo

/// Moving a model or LoRA to another models folder, so a person chooses what lives on the internal
/// drive and what on an external one. The engine finds a file in whichever folder has it, so a move
/// changes only where it's read from.
///
/// A model takes along the files it needs (`files(of:)`, the list the engine downloads with it),
/// except that one another model also needs, outside the destination, is copied: that model keeps
/// working with the destination's drive disconnected. A file the destination already has stays
/// put. The model's or LoRA's custom.json / custom_lora.json entry moves when it's in the source
/// folder's file, so each folder keeps describing its own files.
///
/// It runs in the engine's turn with nothing loaded (`GenerationEngine.movingModelFiles`), so it
/// never moves a file the engine is reading. Across drives, every file is copied beside its
/// destination as `.part`, read back and compared, and only when all are in place renamed and the
/// originals deleted; cancelling or failing before then leaves the source as it was.
extension ModelLibrary {
  nonisolated struct Move: Identifiable, Sendable {
    nonisolated enum Kind: Sendable { case model, lora }
    var kind: Kind
    var name: String
    /// The model's or LoRA's own file, the one the library lists.
    var file: String
    var source: URL
    var destination: URL
    /// Files (with their `-tensordata`) that leave `source`.
    var moved: [String]
    /// Files other models need too, copied to `destination`.
    var copied: [String]
    /// The registry file in `source` whose entry for `file` moves along.
    var registry: String?
    var movedBytes: Int64
    var copiedBytes: Int64
    /// Source and destination are on one volume, where a move is a rename.
    var sameVolume: Bool

    var id: String { file + "\u{0}" + destination.path }
  }

  nonisolated struct MoveProgress: Sendable {
    var file: String
    var destination: URL
    /// nil until files start crossing (waiting for a run to finish, or a rename).
    var fraction: Double?
  }

  nonisolated enum MoveFailure: LocalizedError {
    case alreadyThere(String, String)
    case notEnoughSpace(String, String)
    case mismatch(String)
    case unreadableRegistry(String)

    var errorDescription: String? {
      switch self {
      case .alreadyThere(let file, let folder): "\(file) is already in \(folder)."
      case .notEnoughSpace(let needed, let folder): "\(folder) doesn't have enough free space: the move needs \(needed), plus 1 GB to spare."
      case .mismatch(let file): "The copy of \(file) didn't match the original, so the original was kept."
      case .unreadableRegistry(let path): "\(path) couldn't be read, so it wasn't changed."
      }
    }
  }

  /// More than one models folder can be reached.
  var hasOtherFolders: Bool { directories.count > 1 }

  /// Whether anything that writes to the models folders is running: a move waits for none of them.
  private var isWritingModels: Bool {
    moving != nil || !downloads.isEmpty || importTask != nil || modelImportTask != nil || !quantizing.isEmpty
  }

  func canMove(_ model: MediaGenerationResolvedModel) -> Bool {
    hasOtherFolders && model.isDownloaded && !isWritingModels && !create.queue.uses(model.file)
      && !(create.isLoadingModel && create.selectedModel == model.file)
  }

  func canMove(_ lora: LoRA) -> Bool {
    hasOtherFolders && lora.isDownloaded && !isWritingModels
  }

  /// The folders `file` could move to: every other models folder that can be reached.
  func destinations(from folder: URL?) -> [URL] {
    directories.filter { $0.standardizedFileURL != folder?.standardizedFileURL }
  }

  func has(_ file: String, in folder: URL) -> Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
  }

  /// A folder's name, with its volume (or its path) when another models folder has the same name.
  func folderName(_ folder: URL) -> String {
    let name = FileManager.default.displayName(atPath: folder.path)
    let twins = directories.filter { FileManager.default.displayName(atPath: $0.path) == name }
    guard twins.count > 1 else { return name }
    let volume = { (url: URL) in try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName }
    if let own = volume(folder), twins.filter({ volume($0) == own }).count == 1 {
      return "\(name) on \(own)"
    }
    return (folder.path as NSString).abbreviatingWithTildeInPath
  }

  // MARK: - Planning

  /// What moving `model` to `destination` does, or nil (with `errorMessage` set) if it can't.
  func planMove(_ model: MediaGenerationResolvedModel, to destination: URL) -> Move? {
    errorMessage = nil
    guard let source = Self.folder(of: model.file, in: directories) else { return nil }
    let own = [model.file] + (isCustom(model) ? Self.importedCompanions(of: model.file) : [])
    let needs = ModelZoo.specificationForModel(model.file).map(Self.files(of:)) ?? []
    // What the other downloaded models need, unless they're in the destination already.
    var neededElsewhere = Set<String>()
    for other in catalog where other.isDownloaded && other.file != model.file {
      guard folders[other.file]?.standardizedFileURL != destination.standardizedFileURL,
            let specification = ModelZoo.specificationForModel(other.file)
      else { continue }
      neededElsewhere.formUnion(Self.files(of: specification))
    }
    let registry = Self.readCustomModels(in: source).contains(model.file) ? "custom.json" : nil
    return plan(
      .model, name: model.name, file: model.file, own: own, needs: needs, neededElsewhere: neededElsewhere,
      registry: registry, from: source, to: destination)
  }

  /// What moving `lora` to `destination` does, or nil (with `errorMessage` set) if it can't.
  func planMove(_ lora: LoRA, to destination: URL) -> Move? {
    errorMessage = nil
    guard let source = Self.folder(of: lora.file, in: directories) else { return nil }
    let registry = lora.registry.standardizedFileURL == source.standardizedFileURL ? "custom_lora.json" : nil
    return plan(
      .lora, name: lora.name, file: lora.file, own: [lora.file], needs: [], neededElsewhere: [],
      registry: registry, from: source, to: destination)
  }

  private func plan(
    _ kind: Move.Kind, name: String, file: String, own: [String], needs: Set<String>, neededElsewhere: Set<String>,
    registry: String?, from source: URL, to destination: URL
  ) -> Move? {
    guard !has(file, in: destination) else {
      errorMessage = MoveFailure.alreadyThere(file, folderName(destination)).localizedDescription
      return nil
    }
    let (moved, copied) = Self.sortFiles(
      own: own, needs: needs, neededElsewhere: neededElsewhere, from: source, to: destination)
    let sameVolume = Self.sameVolume(source, destination)
    let move = Move(
      kind: kind, name: name, file: file, source: source, destination: destination, moved: moved, copied: copied,
      registry: registry, movedBytes: Self.bytes(moved, in: source), copiedBytes: Self.bytes(copied, in: source),
      sameVolume: sameVolume)
    let needed = (sameVolume ? 0 : move.movedBytes) + move.copiedBytes
    if needed > 0, let free = Self.freeSpace(at: destination), free < needed + (1 << 30) {
      errorMessage = MoveFailure.notEnoughSpace(ModelsView.bytes(needed), folderName(destination)).localizedDescription
      return nil
    }
    return move
  }

  /// Which files in `source` move and which are copied: the model's own files move; a file it
  /// needs moves unless another model outside the destination needs it too, then it's copied.
  /// Files the destination already has, or `source` doesn't, are left alone. Each comes with its
  /// `-tensordata` when there is one.
  nonisolated static func sortFiles(
    own: [String], needs: Set<String>, neededElsewhere: Set<String>, from source: URL, to destination: URL
  ) -> (moved: [String], copied: [String]) {
    let exists = { (folder: URL, file: String) in
      FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
    }
    let withData = { (files: [String]) in
      files.flatMap { [$0, $0 + "-tensordata"] }.filter { exists(source, $0) && !exists(destination, $0) }
    }
    let ownSet = Set(own)
    let needed = needs.subtracting(ownSet).sorted()
    let moved = own + needed.filter { !neededElsewhere.contains($0) }
    let copied = needed.filter { neededElsewhere.contains($0) }
    return (withData(moved), withData(copied))
  }

  nonisolated static func sameVolume(_ first: URL, _ second: URL) -> Bool {
    let volume = { (url: URL) in try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier }
    guard let a = volume(first), let b = volume(second) else { return false }
    return a.isEqual(b)
  }

  private nonisolated static func bytes(_ files: [String], in folder: URL) -> Int64 {
    files.reduce(0) { $0 + fileSize(folder.appendingPathComponent($1)) }
  }

  private nonisolated static func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
  }

  private nonisolated static func freeSpace(at folder: URL) -> Int64? {
    let values = try? folder.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    // External drives may not report the first.
    return values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
      ?? values?.volumeAvailableCapacity.map(Int64.init)
  }

  /// One sentence or three for the confirmation: what moves, what's copied, what to keep plugged in.
  func describe(_ move: Move) -> String {
    let others = move.moved.filter { $0 != move.file && !$0.hasSuffix("-tensordata") }
    var text = "Moves \(move.file)"
    if !others.isEmpty { text += " and \(others.joined(separator: ", "))" }
    text += " (\(ModelsView.bytes(move.movedBytes))) from \(folderName(move.source))."
    let copied = move.copied.filter { !$0.hasSuffix("-tensordata") }
    if !copied.isEmpty {
      text += " Copies \(copied.joined(separator: ", ")) (\(ModelsView.bytes(move.copiedBytes))), which other models use too."
    }
    if let registry = move.registry { text += " Its \(registry) entry moves too." }
    if !move.sameVolume {
      text += " Each file is checked after it's copied, and the original deleted only then. Keep both drives connected until it finishes."
    }
    return text
  }

  // MARK: - Running

  /// Starts `move`. Runs after the current generation, if any; later ones wait for it.
  func runMove(_ move: Move) {
    guard moving == nil else { return }
    errorMessage = nil
    moving = MoveProgress(file: move.file, destination: move.destination)
    if let registry = move.registry {
      for folder in [move.source, move.destination] {
        if registry == "custom.json" { backUpModelRegistryOnce(in: folder) } else { backUpLoRARegistryOnce(in: folder) }
      }
    }
    moveTask = Task {
      do {
        try await create.engine.movingModelFiles(reloading: create.availableModelsDirectories) {
          try await Self.transfer(move) { fraction in
            Task { @MainActor in self.moving?.fraction = fraction }
          }
        }
      } catch is CancellationError {
        // Nothing changed.
      } catch {
        errorMessage = "Couldn't move \(move.name): \(error.localizedDescription)"
      }
      moving = nil
      moveTask = nil
      await afterChange()
    }
  }

  /// Stops a move that's still copying; once its files are in place it finishes.
  func cancelMove() {
    moveTask?.cancel()
  }

  /// Does `move`'s file work. See the type's comment for the order.
  @concurrent nonisolated static func transfer(
    _ move: Move, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let fileManager = FileManager.default
    let staged = (move.sameVolume ? [] : move.moved) + move.copied
    let part = { (file: String) in move.destination.appendingPathComponent(file + ".part") }
    // Copy, then read back: twice the bytes.
    let total = Double(max(1, staged.reduce(Int64(0)) { $0 + fileSize(move.source.appendingPathComponent($1)) } * 2))
    var done: Int64 = 0
    if !staged.isEmpty { progress(0) }
    do {
      for file in staged {
        let source = move.source.appendingPathComponent(file)
        if move.sameVolume {
          // A clone on APFS: instant, and no extra space.
          try? fileManager.removeItem(at: part(file))
          try fileManager.copyItem(at: source, to: part(file))
        } else {
          try copyVerified(source, to: part(file)) { bytes in
            done += bytes
            progress(Double(done) / total)
          }
        }
      }
      try Task.checkCancellation()
    } catch {
      for file in staged { try? fileManager.removeItem(at: part(file)) }
      throw error
    }
    // Past here a move finishes: cancelling would leave it half done.
    for file in staged {
      try fileManager.moveItem(at: part(file), to: move.destination.appendingPathComponent(file))
    }
    if move.sameVolume {
      for file in move.moved {
        try fileManager.moveItem(
          at: move.source.appendingPathComponent(file), to: move.destination.appendingPathComponent(file))
      }
    }
    if let registry = move.registry {
      try moveRegistryEntry(move.file, in: registry, from: move.source, to: move.destination)
    }
    if !move.sameVolume {
      for file in move.moved { try fileManager.removeItem(at: move.source.appendingPathComponent(file)) }
    }
  }

  /// Copies `source` to `target` in chunks (reporting bytes as they're written, then as they're
  /// checked), then reads the copy back from the disk, past the cache, and compares it.
  nonisolated static func copyVerified(_ source: URL, to target: URL, progress: (Int64) -> Void) throws {
    let chunk = 16 << 20
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
    }
    let output = try FileHandle(forWritingTo: target)
    do {
      while let data = try input.read(upToCount: chunk), !data.isEmpty {
        try Task.checkCancellation()
        try output.write(contentsOf: data)
        progress(Int64(data.count))
      }
      try output.synchronize()
      try output.close()
    } catch {
      try? output.close()
      throw error
    }
    let check = try FileHandle(forReadingFrom: target)
    defer { try? check.close() }
    _ = fcntl(check.fileDescriptor, F_NOCACHE, 1)
    try input.seek(toOffset: 0)
    while true {
      try Task.checkCancellation()
      let original = try input.read(upToCount: chunk) ?? Data()
      let copy = try check.read(upToCount: chunk) ?? Data()
      guard original == copy else { throw MoveFailure.mismatch(source.lastPathComponent) }
      if original.isEmpty { break }
      progress(Int64(original.count))
    }
  }

  /// Moves `file`'s entries from `source`'s registry file to `destination`'s, as raw JSON so fields
  /// this engine doesn't know survive, replacing an entry the destination had for it. The
  /// destination is written first: a failure in between leaves the entry in both, which the
  /// engine reads once (`firstOfEachFile`). custom_lora.json stays sorted by name, as LoRAZoo keeps it.
  nonisolated static func moveRegistryEntry(_ file: String, in registry: String, from source: URL, to destination: URL) throws {
    func read(_ url: URL) throws -> [[String: Any]] {
      guard FileManager.default.fileExists(atPath: url.path) else { return [] }
      guard let entries = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else {
        throw MoveFailure.unreadableRegistry(url.path)
      }
      return entries
    }
    func write(_ entries: [[String: Any]], to url: URL) throws {
      try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .withoutEscapingSlashes])
        .write(to: url, options: .atomic)
    }
    let sourceURL = source.appendingPathComponent(registry)
    let destinationURL = destination.appendingPathComponent(registry)
    let entries = try read(sourceURL)
    let moving = entries.filter { $0["file"] as? String == file }
    guard !moving.isEmpty else { return }
    var arrived = try read(destinationURL).filter { $0["file"] as? String != file } + moving
    if registry == "custom_lora.json" {
      arrived.sort {
        ($0["name"] as? String ?? "").localizedStandardCompare($1["name"] as? String ?? "") == .orderedAscending
      }
    }
    try write(arrived, to: destinationURL)
    try write(entries.filter { $0["file"] as? String != file }, to: sourceURL)
  }
}
