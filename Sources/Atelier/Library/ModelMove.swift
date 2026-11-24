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

  /// Several moves to one folder, confirmed and run together (a multi-selection's Move To).
  /// `skipped` names what the selection had that can't go: already there, or in use.
  nonisolated struct MoveBatch: Identifiable, Sendable {
    var kind: Move.Kind
    var items: [Move]
    var skipped: [BatchSkip]
    var destination: URL
    let id = UUID()

    /// The one item's name, or "5 models".
    var title: String {
      items.count == 1 ? items[0].name : ModelLibrary.counted(items.count, kind == .model ? "model" : "LoRA")
    }
  }

  nonisolated struct MoveProgress: Sendable {
    /// The files of every item in the batch running, in order; `file` is the current one's.
    var files: [String]
    var index = 0
    var destination: URL
    /// nil until the engine's turn starts (waiting for a run to finish); then the share of the
    /// batch's bytes that have crossed.
    var fraction: Double?

    var file: String { files.indices.contains(index) ? files[index] : files.first ?? "" }
    var count: Int { files.count }
  }

  /// How a batch of moves ended, for the error alert and the scripted checks.
  nonisolated struct MoveOutcome: Sendable {
    var moved: [String] = []
    var failed: [BatchFailure] = []
    var cancelled = false
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
    planMoves([model], to: destination)?.items.first
  }

  /// What moving `lora` to `destination` does, or nil (with `errorMessage` set) if it can't.
  func planMove(_ lora: LoRA, to destination: URL) -> Move? {
    planMoves([lora], to: destination)?.items.first
  }

  /// What moving `models` to `destination` does, or nil (with `errorMessage` set) if none can go.
  /// A model already in the destination, or in use, is skipped and named; one that lives there
  /// (a selection from several folders) or isn't downloaded is left out silently. What other
  /// downloaded models need is worked out from the models outside the batch, so a text encoder
  /// two of them share moves once, with the first, rather than being copied by one and then found
  /// already there by the other.
  func planMoves(_ models: [MediaGenerationResolvedModel], to destination: URL) -> MoveBatch? {
    errorMessage = nil
    let batchFiles = Set(models.map(\.file))
    var skipped: [BatchSkip] = []
    var candidates: [(model: MediaGenerationResolvedModel, source: URL, own: [String], needs: Set<String>)] = []
    for model in models {
      guard let source = Self.folder(of: model.file, in: directories),
            source.standardizedFileURL != destination.standardizedFileURL
      else { continue }
      if has(model.file, in: destination) {
        skipped.append(BatchSkip(name: model.name, file: model.file, reason: "already in \(folderName(destination))"))
        continue
      }
      guard canMove(model) else {
        skipped.append(BatchSkip(name: model.name, file: model.file, reason: moveBlockReason(model)))
        continue
      }
      // A hidden refiner (LongCat-Video Avatar 1.6's OPSD half) has no row to move it from.
      let own = [model.file] + (isCustom(model) ? Self.importedCompanions(of: model.file, excluding: batchFiles) : [])
        + Self.hiddenCompanions(of: model.file)
      let needs = ModelZoo.specificationForModel(model.file).map(Self.files(of:)) ?? []
      candidates.append((model, source, own, needs))
    }
    // What the downloaded models outside the batch need, unless they're in the destination already.
    var neededElsewhere = Set<String>()
    for other in catalog where other.isDownloaded && !batchFiles.contains(other.file) {
      guard folders[other.file]?.standardizedFileURL != destination.standardizedFileURL,
            let specification = ModelZoo.specificationForModel(other.file)
      else { continue }
      neededElsewhere.formUnion(Self.files(of: specification))
    }
    let sorted = Self.sortBatchFiles(
      items: candidates.map { ($0.own, $0.needs, $0.source) }, neededElsewhere: neededElsewhere, to: destination)
    let items = zip(candidates, sorted).map { candidate, files in
      move(
        .model, name: candidate.model.name, file: candidate.model.file, files: files,
        registry: Self.readCustomModels(in: candidate.source).contains(candidate.model.file) ? "custom.json" : nil,
        from: candidate.source, to: destination)
    }
    return batch(.model, items: items, skipped: skipped, to: destination)
  }

  /// What moving `loras` to `destination` does, or nil (with `errorMessage` set) if none can go.
  func planMoves(_ loras: [LoRA], to destination: URL) -> MoveBatch? {
    errorMessage = nil
    var skipped: [BatchSkip] = []
    var items: [Move] = []
    for lora in loras {
      guard let source = Self.folder(of: lora.file, in: directories),
            source.standardizedFileURL != destination.standardizedFileURL
      else { continue }
      if has(lora.file, in: destination) {
        skipped.append(BatchSkip(name: lora.name, file: lora.file, reason: "already in \(folderName(destination))"))
        continue
      }
      guard canMove(lora) else {
        skipped.append(BatchSkip(name: lora.name, file: lora.file, reason: "another move is running"))
        continue
      }
      let files = Self.sortFiles(own: [lora.file], needs: [], neededElsewhere: [], from: source, to: destination)
      let registry = lora.registry.standardizedFileURL == source.standardizedFileURL ? "custom_lora.json" : nil
      items.append(move(.lora, name: lora.name, file: lora.file, files: files, registry: registry, from: source, to: destination))
    }
    return batch(.lora, items: items, skipped: skipped, to: destination)
  }

  /// Why `model` can't move now, for a batch's "Not moved" list.
  private func moveBlockReason(_ model: MediaGenerationResolvedModel) -> String {
    if create.queue.uses(model.file) { return "used by a queued job" }
    if create.isLoadingModel, create.selectedModel == model.file { return "loading in Create" }
    return "busy"
  }

  private func move(
    _ kind: Move.Kind, name: String, file: String, files: (moved: [String], copied: [String]), registry: String?,
    from source: URL, to destination: URL
  ) -> Move {
    Move(
      kind: kind, name: name, file: file, source: source, destination: destination, moved: files.moved,
      copied: files.copied, registry: registry, movedBytes: Self.bytes(files.moved, in: source),
      copiedBytes: Self.bytes(files.copied, in: source), sameVolume: Self.sameVolume(source, destination))
  }

  /// The batch of `items`, or nil with `errorMessage` saying why when there's nothing to move or
  /// the destination's drive hasn't room for all of it (plus 1 GB to spare).
  private func batch(_ kind: Move.Kind, items: [Move], skipped: [BatchSkip], to destination: URL) -> MoveBatch? {
    guard !items.isEmpty else {
      // One file already there keeps the sentence a single move has always shown.
      if skipped.count == 1, skipped[0].reason.hasPrefix("already in") {
        errorMessage = MoveFailure.alreadyThere(skipped[0].file, folderName(destination)).localizedDescription
      } else if !skipped.isEmpty {
        errorMessage = "Nothing to move: " + Self.skipList(skipped) + "."
      }
      return nil
    }
    let needed = items.reduce(Int64(0)) { $0 + ($1.sameVolume ? 0 : $1.movedBytes) + $1.copiedBytes }
    if needed > 0, let free = Self.freeSpace(at: destination), free < needed + (1 << 30) {
      errorMessage = MoveFailure.notEnoughSpace(ModelsView.bytes(needed), folderName(destination)).localizedDescription
      return nil
    }
    return MoveBatch(kind: kind, items: items, skipped: skipped, destination: destination)
  }

  /// `sortFiles` for each item of a batch moving to `destination`. A file one item owns never
  /// counts as another's need (it goes with its owner), and a need several items share goes with
  /// the first that needs it: moved when nothing outside the batch needs it, else copied once.
  nonisolated static func sortBatchFiles(
    items: [(own: [String], needs: Set<String>, source: URL)], neededElsewhere: Set<String>, to destination: URL
  ) -> [(moved: [String], copied: [String])] {
    let owned = Set(items.flatMap(\.own))
    var claimed = Set<String>()
    return items.map { item in
      let needs = item.needs.subtracting(owned).subtracting(claimed)
      claimed.formUnion(needs)
      return sortFiles(own: item.own, needs: needs, neededElsewhere: neededElsewhere, from: item.source, to: destination)
    }
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

  nonisolated static func bytes(_ files: [String], in folder: URL) -> Int64 {
    files.reduce(0) { $0 + fileSize(folder.appendingPathComponent($1)) }
  }

  private nonisolated static func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
  }

  nonisolated static func freeSpace(at folder: URL) -> Int64? {
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

  /// The confirmation's text for a batch: one item reads as it always has; several are counted,
  /// with the shared files copied named, and what the selection had that won't move.
  func describe(_ batch: MoveBatch) -> String {
    var text: String
    if batch.items.count == 1 {
      text = describe(batch.items[0])
    } else {
      let noun = batch.kind == .model ? "model" : "LoRA"
      let ownFiles = Set(batch.items.map(\.file))
      let others = batch.items.flatMap(\.moved).filter { !ownFiles.contains($0) && !$0.hasSuffix("-tensordata") }
      let sources = Array(Set(batch.items.map(\.source.standardizedFileURL))).map(folderName).sorted()
      text = "Moves \(Self.counted(batch.items.count, noun))"
      if !others.isEmpty { text += " and \(Self.counted(others.count, "file")) they need" }
      text += " (\(ModelsView.bytes(batch.items.reduce(0) { $0 + $1.movedBytes }))) from \(sources.joined(separator: " and "))."
      let copied = batch.items.flatMap(\.copied).filter { !$0.hasSuffix("-tensordata") }
      if !copied.isEmpty {
        text += " Copies \(Self.nameList(copied)) (\(ModelsView.bytes(batch.items.reduce(0) { $0 + $1.copiedBytes }))), which other models use too."
      }
      let registries = batch.items.compactMap(\.registry)
      if let registry = registries.first {
        text += registries.count == 1 ? " One \(registry) entry moves too." : " \(registries.count) \(registry) entries move too."
      }
      if batch.items.contains(where: { !$0.sameVolume }) {
        text += " Each file is checked after it's copied, and the original deleted only then. Keep both drives connected until it finishes."
      }
    }
    if !batch.skipped.isEmpty { text += " Not moved: " + Self.skipList(batch.skipped) + "." }
    return text
  }

  // MARK: - Running

  /// Starts `move`. Runs after the current generation, if any; later ones wait for it.
  func runMove(_ move: Move) {
    runMoves(MoveBatch(kind: move.kind, items: [move], skipped: [], destination: move.destination))
  }

  /// Starts `batch`: one engine turn for all of it, so a generation waits once rather than between
  /// every item, and the folders and catalog are reread once at the end. Items go in order, each
  /// through `transfer`, so each is all-or-nothing; one that fails is reported and the rest carry
  /// on. Cancelling rolls back the item in progress and stops; the ones done stay done.
  func runMoves(_ batch: MoveBatch) {
    guard moving == nil, !batch.items.isEmpty else { return }
    errorMessage = nil
    let items = batch.items
    moving = MoveProgress(files: items.map(\.file), destination: batch.destination)
    for move in items {
      guard let registry = move.registry else { continue }
      for folder in [move.source, move.destination] {
        if registry == "custom.json" { backUpModelRegistryOnce(in: folder) } else { backUpLoRARegistryOnce(in: folder) }
      }
    }
    // Progress is the share of the batch's bytes that cross; renames on one drive count nothing.
    let weights = items.map { Double(($0.sameVolume ? 0 : $0.movedBytes) + $0.copiedBytes) }
    let total = weights.reduce(0, +)
    moveTask = Task {
      var outcome = MoveOutcome()
      do {
        outcome = try await create.engine.movingModelFiles(reloading: create.availableModelsDirectories) {
          var outcome = MoveOutcome()
          var done = 0.0
          for (index, move) in items.enumerated() {
            if Task.isCancelled {
              outcome.cancelled = true
              break
            }
            let start = total > 0 ? done / total : Double(index) / Double(items.count)
            await MainActor.run {
              self.moving?.index = index
              self.moving?.fraction = start
            }
            let before = done, weight = weights[index]
            do {
              try await Self.transfer(move) { fraction in
                let overall = total > 0 ? (before + fraction * weight) / total : start
                Task { @MainActor in if self.moving?.index == index { self.moving?.fraction = overall } }
              }
              outcome.moved.append(move.file)
            } catch is CancellationError {
              outcome.cancelled = true
              break
            } catch {
              outcome.failed.append(BatchFailure(name: move.name, message: error.localizedDescription))
            }
            done += weight
          }
          return outcome
        }
      } catch is CancellationError {
        outcome.cancelled = true
      } catch {
        outcome.failed.append(BatchFailure(name: batch.title, message: error.localizedDescription))
      }
      if items.count == 1, let failure = outcome.failed.first {
        errorMessage = "Couldn't move \(items[0].name): \(failure.message)"
      } else if !outcome.failed.isEmpty {
        errorMessage = "Couldn't move \(outcome.failed.count) of \(items.count): " + Self.failureList(outcome.failed) + "."
      } else if outcome.cancelled, !outcome.moved.isEmpty {
        errorMessage = "Moved \(outcome.moved.count) of \(items.count); cancelled."
      }
      lastMoveOutcome = outcome
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
