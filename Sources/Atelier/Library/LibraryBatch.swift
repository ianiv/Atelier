@preconcurrency import _MediaGenerationKit
import Foundation
@preconcurrency import ModelZoo

/// Working on several models or LoRAs at once: the Models and LoRAs screens' multi-selections.
/// Move To runs as one `MoveBatch` (ModelMove.swift); Move to Trash as one `TrashBatch` here, so
/// the catalog, sizes and Create's model list are reread once rather than after every file, and
/// each folder's custom.json or custom_lora.json is rewritten once. A file that can't go is
/// reported and the rest carry on. The pure helpers (wording, totals, which commands fit) are
/// static, for the unit tests.
extension ModelLibrary {
  /// Something a multi-selection had that a batch leaves out, and why.
  nonisolated struct BatchSkip: Hashable, Sendable {
    var name: String
    var file: String
    var reason: String
  }

  nonisolated struct BatchFailure: Hashable, Sendable {
    var name: String
    var message: String
  }

  nonisolated enum BatchKind: Sendable { case model, lora }

  /// One model or LoRA going to the Trash.
  nonisolated struct TrashItem: Hashable, Sendable {
    var name: String
    var file: String
    /// Listed in custom.json (a model) or custom_lora.json (a LoRA), whose entry goes too.
    var isRegistered: Bool
    /// Its file is missing: only its entry goes ("Remove from Library").
    var entryOnly: Bool
    /// Files that go with it: an import's own VAE and encoders, a hidden refiner. As planned:
    /// `trash(_:)` works the import's out again from what actually went.
    var companions: [String] = []
    /// A LoRA's models folder whose custom_lora.json lists it.
    var registry: URL?
  }

  /// What a Move to Trash confirmation offers, planned when it opens.
  nonisolated struct TrashBatch: Identifiable, Sendable {
    var kind: BatchKind
    var items: [TrashItem]
    var skipped: [BatchSkip]
    /// The files' size on disk, with their companions.
    var bytes: Int64
    let id = UUID()
  }

  nonisolated struct TrashResult: Sendable {
    /// The items whose files (or entries) went.
    var trashed: [String] = []
    /// Where the files are in the Trash, for the scripted checks to empty their own.
    var trashedURLs: [URL] = []
    var failed: [BatchFailure] = []
  }

  // MARK: - Wording

  /// "1 model", "5 models".
  nonisolated static func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }

  /// Up to three names, then "and N more".
  nonisolated static func nameList(_ names: [String], limit: Int = 3) -> String {
    let shown = names.prefix(limit)
    let rest = names.count - shown.count
    if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) more" }
    if shown.count < 2 { return shown.joined() }
    return shown.dropLast().joined(separator: ", ") + " and " + shown.last!
  }

  /// "A (used by a queued job), B (downloading) and 2 more".
  nonisolated static func skipList(_ skipped: [BatchSkip]) -> String {
    nameList(skipped.map { "\($0.name) (\($0.reason))" })
  }

  nonisolated static func failureList(_ failed: [BatchFailure]) -> String {
    failed.map { "\($0.name) (\($0.message))" }.joined(separator: "; ")
  }

  nonisolated static func trashTitle(_ batch: TrashBatch) -> String {
    if batch.items.count == 1 { return "Move \(batch.items[0].name) to the Trash?" }
    return "Move \(counted(batch.items.count, batch.kind == .model ? "model" : "LoRA")) to the Trash?"
  }

  /// The confirmation's message. One item reads as a single delete always has; several say how
  /// much goes, which lose a registry entry, and what the selection had that stays.
  nonisolated static func trashMessage(_ batch: TrashBatch) -> String {
    var text: String
    let shared = "Shared files such as text encoders and VAEs stay in the models folder."
    if batch.items.count == 1 {
      let item = batch.items[0]
      text =
        switch batch.kind {
        case .model:
          item.isRegistered
            ? "\(item.file) is moved to the Trash and removed from custom.json. \(shared)"
            : "\(item.file) is moved to the Trash. \(shared)"
        case .lora: "\(item.file) is moved to the Trash and removed from custom_lora.json."
        }
    } else {
      let withFiles = batch.items.filter { !$0.entryOnly }
      let entryOnly = batch.items.count - withFiles.count
      let registry = batch.kind == .model ? "custom.json" : "custom_lora.json"
      var sentences: [String] = []
      if !withFiles.isEmpty {
        sentences.append(
          withFiles.count == 1
            ? "Its file, \(ModelsView.bytes(batch.bytes)), is moved to the Trash."
            : "Their files, \(ModelsView.bytes(batch.bytes)), are moved to the Trash.")
      }
      switch batch.kind {
      case .model:
        let imported = withFiles.count(where: \.isRegistered)
        if imported > 0 {
          sentences.append(
            "\(counted(imported, "imported model")) \(imported == 1 ? "is" : "are") also removed from custom.json.")
        }
      case .lora:
        if !withFiles.isEmpty { sentences.append("Their entries are removed from custom_lora.json.") }
      }
      if entryOnly > 0 {
        sentences.append(
          entryOnly == 1
            ? "1 only loses its \(registry) entry (its file is missing)."
            : "\(entryOnly) only lose their \(registry) entries (their files are missing).")
      }
      if batch.kind == .model { sentences.append(shared) }
      text = sentences.joined(separator: " ")
    }
    if !batch.skipped.isEmpty { text += " Not moved: " + skipList(batch.skipped) + "." }
    return text
  }

  /// Why a model can't go to the Trash now, or nil if it can.
  nonisolated static func trashSkipReason(downloading: Bool, moving: Bool, queued: Bool, loading: Bool) -> String? {
    if downloading { return "downloading" }
    if moving { return "a move is running" }
    if queued { return "used by a queued job" }
    if loading { return "loading in Create" }
    return nil
  }

  // MARK: - Selection

  /// The selected rows still shown, in the list's order. A `Set` selection keeps rows a search or
  /// filter has hidden, and nothing should act on a row nobody can see.
  nonisolated static func visibleSelection(_ selection: Set<String>, visible: [String]) -> [String] {
    visible.filter(selection.contains)
  }

  /// A registry's entries without those for `files`, the rest as written and in their order.
  nonisolated static func removingEntries(_ files: Set<String>, from entries: [[String: Any]]) -> [[String: Any]] {
    entries.filter { ($0["file"] as? String).map { !files.contains($0) } ?? true }
  }

  /// The multi-selection inspector's totals.
  nonisolated struct SelectionSummary: Equatable, Sendable {
    nonisolated struct FolderCount: Equatable, Sendable {
      var name: String
      var count: Int
    }

    var count: Int
    /// Downloaded ones only.
    var bytes: Int64
    var downloaded: Int
    /// The folder they're all in, "3 folders", or nil when none is downloaded.
    var folder: String?
    /// How many are in each folder, when they're in two or three.
    var folderCounts: [FolderCount]
    /// The family they all share, or "Mixed".
    var family: String?

    /// `sizes` has the downloaded files; `folders` and `families` give display names.
    static func make(
      files: [String], sizes: [String: Int64], folders: [String: String], families: [String: String]
    ) -> SelectionSummary {
      let downloaded = files.filter { sizes[$0] != nil }
      let bytes = downloaded.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
      var counts: [String: Int] = [:]
      for file in files { if let folder = folders[file] { counts[folder, default: 0] += 1 } }
      let names = counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      let folder: String? =
        switch names.count {
        case 0: nil
        case 1: names[0]
        default: "\(names.count) folders"
        }
      let folderCounts =
        (2...3).contains(names.count) ? names.map { FolderCount(name: $0, count: counts[$0] ?? 0) } : []
      let familySet = Set(files.compactMap { families[$0] })
      let family = familySet.count > 1 ? "Mixed" : familySet.first
      return SelectionSummary(
        count: files.count, bytes: bytes, downloaded: downloaded.count, folder: folder, folderCounts: folderCounts,
        family: family)
    }
  }

  /// What one model in a multi-selection allows, for `ModelSelectionKinds`.
  nonisolated struct ModelBatchState: Sendable {
    var downloaded = false
    var imported = false
    var downloading = false
    var hasHiddenRefiner = false
    var missingRefiner = false
    var canMove = false
    var canDelete = false
  }

  /// Which multi-selection commands fit at least one selected model: each is enabled when one
  /// does. Every command is always in the menu, disabled when it fits none.
  nonisolated struct ModelSelectionKinds: Equatable, Sendable {
    var canDownload = false
    var canCancelDownload = false
    var canDownloadMissing = false
    var canReveal = false
    var canMove = false
    var canTrash = false

    init(_ states: [ModelBatchState]) {
      for state in states {
        if !state.downloaded, !state.imported, !state.downloading { canDownload = true }
        if state.downloading { canCancelDownload = true }
        if state.downloaded, state.missingRefiner, !state.downloading { canDownloadMissing = true }
        if state.downloaded { canReveal = true }
        if state.canMove { canMove = true }
        if state.canDelete { canTrash = true }
      }
    }
  }

  /// The folders a multi-selection's Move To lists: every other one, leaving out only a folder
  /// all of them are in already.
  nonisolated static func batchDestinations(all: [URL], folders: [URL?]) -> [URL] {
    let homes = Set(folders.map { $0?.standardizedFileURL })
    guard homes.count == 1, let home = homes.first ?? nil else { return all }
    return all.filter { $0.standardizedFileURL != home }
  }

  /// A Move To folder is disabled when every file is in it already, where it lives or as a copy.
  nonisolated static func destinationDisabled(
    _ destination: URL, files: [String], folders: [URL?], has: (String, URL) -> Bool
  ) -> Bool {
    zip(files, folders).allSatisfy { file, folder in
      folder?.standardizedFileURL == destination.standardizedFileURL || has(file, destination)
    }
  }

  // MARK: - Library

  func selectionKinds(_ models: [MediaGenerationResolvedModel]) -> ModelSelectionKinds {
    ModelSelectionKinds(
      models.map { model in
        ModelBatchState(
          downloaded: model.isDownloaded, imported: isCustom(model), downloading: downloads[model.file] != nil,
          hasHiddenRefiner: !Self.hiddenCompanions(of: model.file).isEmpty,
          missingRefiner: missingHiddenRefiner(of: model) != nil, canMove: canMove(model), canDelete: canDelete(model))
      })
  }

  /// A Move to Trash of `models`, or nil when none can go. A model with no file and no entry (a
  /// catalog model that isn't downloaded) is left out silently; one in use is skipped and named.
  /// An import's own companions go when nothing outside the batch names them, so a model and its
  /// 8-bit copy, trashed together, take the VAE the import wrote.
  func planTrash(_ models: [MediaGenerationResolvedModel]) -> TrashBatch? {
    var going: [MediaGenerationResolvedModel] = []
    var skipped: [BatchSkip] = []
    for model in models where model.isDownloaded || isCustom(model) {
      if let reason = Self.trashSkipReason(
        downloading: downloads[model.file] != nil, moving: moving != nil, queued: create.queue.uses(model.file),
        loading: create.isLoadingModel && create.selectedModel == model.file)
      {
        skipped.append(BatchSkip(name: model.name, file: model.file, reason: reason))
      } else {
        going.append(model)
      }
    }
    guard !going.isEmpty else { return nil }
    // Only what goes counts: a skipped 8-bit copy still names the VAE, so it stays.
    let goingFiles = Set(going.map(\.file))
    var taken = Set<String>()
    var bytes: Int64 = 0
    let items = going.map { model in
      let registered = isCustom(model)
      let companions = ((registered ? Self.importedCompanions(of: model.file, excluding: goingFiles) : [])
        + Self.hiddenCompanions(of: model.file)).filter { !goingFiles.contains($0) && taken.insert($0).inserted }
      bytes += (sizes[model.file] ?? 0) + companions.reduce(0) { $0 + (Self.size(of: $1, in: directories) ?? 0) }
      return TrashItem(
        name: model.name, file: model.file, isRegistered: registered, entryOnly: !model.isDownloaded, companions: companions)
    }
    return TrashBatch(kind: .model, items: items, skipped: skipped, bytes: bytes)
  }

  /// A Move to Trash of `loras`, or nil when none can go (each one's file is moving).
  func planTrash(_ loras: [LoRA]) -> TrashBatch? {
    var items: [TrashItem] = []
    var skipped: [BatchSkip] = []
    for lora in loras {
      if moving?.files.contains(lora.file) == true {
        skipped.append(BatchSkip(name: lora.name, file: lora.file, reason: "moving"))
        continue
      }
      items.append(
        TrashItem(name: lora.name, file: lora.file, isRegistered: true, entryOnly: !lora.isDownloaded, registry: lora.registry))
    }
    guard !items.isEmpty else { return nil }
    return TrashBatch(kind: .lora, items: items, skipped: skipped, bytes: loras.reduce(0) { $0 + ($1.size ?? 0) })
  }

  /// Runs a planned Move to Trash. A model that's come into use since it was planned stays, and
  /// is reported; a file that can't go to the Trash (a volume without one) keeps its entry.
  func trash(_ batch: TrashBatch) async -> TrashResult {
    if batch.kind == .lora { return trashLoRAs(batch) }
    errorMessage = nil
    var result = TrashResult()
    var unregister = Set<String>()
    var failedNames = Set<String>()
    // Each model's own file, with its hidden refiner, which is its alone.
    for item in batch.items {
      if let model = catalog.first(where: { $0.file == item.file }), !canDelete(model) {
        result.failed.append(BatchFailure(name: item.name, message: "it's in use now"))
        continue
      }
      do {
        for file in [item.file] + Self.hiddenCompanions(of: item.file) {
          for url in Self.files(of: file, in: directories) {
            result.trashedURLs.append(try Self.moveToTrash(url))
          }
        }
        result.trashed.append(item.file)
        if item.isRegistered { unregister.insert(item.file) }
      } catch {
        result.failed.append(BatchFailure(name: item.name, message: error.localizedDescription))
        failedNames.insert(item.name)
        // Its own file went before its refiner failed: the entry goes with it.
        if item.isRegistered, Self.folder(of: item.file, in: directories) == nil { unregister.insert(item.file) }
      }
    }
    // Then the files imports wrote, worked out against what actually went: one an 8-bit copy
    // still names, because it was in use or couldn't go, stays.
    let went = Set(result.trashed)
    var taken = Set<String>()
    for item in batch.items where item.isRegistered && went.contains(item.file) {
      for file in Self.importedCompanions(of: item.file, excluding: went) where !went.contains(file) && taken.insert(file).inserted {
        do {
          for url in Self.files(of: file, in: directories) {
            result.trashedURLs.append(try Self.moveToTrash(url))
          }
        } catch {
          if failedNames.insert(item.name).inserted {
            result.failed.append(BatchFailure(name: item.name, message: error.localizedDescription))
          }
        }
      }
    }
    do {
      try unregisterModels(unregister)
    } catch {
      result.failed.append(BatchFailure(name: "custom.json", message: error.localizedDescription))
    }
    report(result, of: batch)
    await afterChange()
    return result
  }

  /// `trash(_:)` for LoRAs, which runs at once: each present file goes to the Trash, then each
  /// folder's custom_lora.json loses the entries of the ones that went, in one write.
  func trashLoRAs(_ batch: TrashBatch) -> TrashResult {
    errorMessage = nil
    var result = TrashResult()
    var removed: [URL: Set<String>] = [:]
    for item in batch.items {
      guard moving?.files.contains(item.file) != true, let registry = item.registry else { continue }
      do {
        for url in Self.files(of: item.file, in: directories) {
          result.trashedURLs.append(try Self.moveToTrash(url))
        }
        removed[registry, default: []].insert(item.file)
        result.trashed.append(item.file)
      } catch {
        result.failed.append(BatchFailure(name: item.name, message: error.localizedDescription))
      }
    }
    for (registry, files) in removed {
      backUpLoRARegistryOnce(in: registry)
      let url = registry.appendingPathComponent("custom_lora.json")
      do {
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        guard let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else {
          throw MoveFailure.unreadableRegistry(url.path)
        }
        try JSONSerialization.data(
          withJSONObject: Self.removingEntries(files, from: entries), options: [.prettyPrinted, .withoutEscapingSlashes]
        ).write(to: url, options: .atomic)
      } catch {
        result.failed.append(BatchFailure(name: url.path, message: error.localizedDescription))
      }
    }
    // The engine's in-memory table keeps the entries, but with the files gone they're skipped.
    unlistLoRAs(Set(result.trashed))
    report(result, of: batch)
    Task { await reloadLoRAs() }
    return result
  }

  /// One alert for a batch's failures; a batch of one keeps a single delete's wording.
  private func report(_ result: TrashResult, of batch: TrashBatch) {
    guard !result.failed.isEmpty else { return }
    if batch.items.count == 1, let failure = result.failed.first {
      errorMessage = "Couldn't delete \(batch.items[0].name): \(failure.message)"
    } else {
      errorMessage = "Couldn't move \(result.failed.count) of \(batch.items.count) to the Trash: \(Self.failureList(result.failed))."
    }
  }

  private nonisolated static func moveToTrash(_ url: URL) throws -> URL {
    var trashed: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
    return (trashed as URL?) ?? url
  }
}

/// What the Models screen shows, kept on `ModelLibrary` while other screens are open.
struct ModelScreenState {
  var selection: Set<String> = []
}
