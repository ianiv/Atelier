@testable import Atelier
import Foundation
@preconcurrency import ModelZoo
import Testing

@Suite(.tags(.smoke))
struct LibraryBatchTests {
  typealias Library = ModelLibrary

  private func item(_ name: String, registered: Bool = false, entryOnly: Bool = false) -> Library.TrashItem {
    Library.TrashItem(name: name, file: name.lowercased() + "_f16.ckpt", isRegistered: registered, entryOnly: entryOnly)
  }

  // MARK: Commands

  @Test func eachCommandFitsTheModelsItSuits() {
    let downloaded = Library.ModelBatchState(downloaded: true, canMove: true, canDelete: true)
    let available = Library.ModelBatchState()
    let downloading = Library.ModelBatchState(downloading: true)
    let missingFile = Library.ModelBatchState(imported: true, canDelete: true)
    let refiner = Library.ModelBatchState(downloaded: true, hasHiddenRefiner: true, missingRefiner: true)

    let onlyDownloaded = Library.ModelSelectionKinds([downloaded, downloaded])
    #expect(!onlyDownloaded.canDownload && !onlyDownloaded.canCancelDownload)
    #expect(onlyDownloaded.canReveal && onlyDownloaded.canMove && onlyDownloaded.canTrash)
    #expect(!onlyDownloaded.offersMissingFile)

    let mixed = Library.ModelSelectionKinds([available, downloading, missingFile])
    #expect(mixed.canDownload && mixed.canCancelDownload && mixed.canTrash)
    #expect(!mixed.canReveal && !mixed.canMove)

    // An imported model with a missing file can't be downloaded again.
    #expect(!Library.ModelSelectionKinds([missingFile]).canDownload)

    let withRefiner = Library.ModelSelectionKinds([refiner, available])
    #expect(withRefiner.offersMissingFile && withRefiner.canDownloadMissing)
    var refinerDownloading = refiner
    refinerDownloading.downloading = true
    let busy = Library.ModelSelectionKinds([refinerDownloading])
    #expect(busy.offersMissingFile && !busy.canDownloadMissing)
  }

  @Test func aModelInUseIsSkippedWithItsReason() {
    #expect(Library.trashSkipReason(downloading: false, moving: false, queued: false, loading: false) == nil)
    #expect(Library.trashSkipReason(downloading: true, moving: false, queued: true, loading: false) == "downloading")
    #expect(Library.trashSkipReason(downloading: false, moving: true, queued: false, loading: false) == "a move is running")
    #expect(Library.trashSkipReason(downloading: false, moving: false, queued: true, loading: false) == "used by a queued job")
    #expect(Library.trashSkipReason(downloading: false, moving: false, queued: false, loading: true) == "loading in Create")
  }

  // MARK: Wording

  @Test func oneItemReadsAsASingleDelete() {
    let model = Library.TrashBatch(kind: .model, items: [item("Alpha", registered: true)], skipped: [], bytes: 10)
    #expect(Library.trashTitle(model) == "Move Alpha to the Trash?")
    #expect(
      Library.trashMessage(model)
        == "alpha_f16.ckpt is moved to the Trash and removed from custom.json. Shared files such as text encoders and VAEs stay in the models folder.")
    let lora = Library.TrashBatch(kind: .lora, items: [item("Style", registered: true)], skipped: [], bytes: 10)
    #expect(Library.trashMessage(lora) == "style_f16.ckpt is moved to the Trash and removed from custom_lora.json.")
  }

  @Test func severalItemsAreCountedWithWhatStays() {
    let batch = Library.TrashBatch(
      kind: .model,
      items: [item("A", registered: true), item("B", registered: true), item("C"), item("D", registered: true, entryOnly: true)],
      skipped: [Library.BatchSkip(name: "SDXL Base", file: "sdxl.ckpt", reason: "used by a queued job")], bytes: 0)
    #expect(Library.trashTitle(batch) == "Move 4 models to the Trash?")
    let message = Library.trashMessage(batch)
    #expect(message.contains("Their files, "))
    #expect(message.contains("2 imported models are also removed from custom.json."))
    #expect(message.contains("1 only loses its custom.json entry (its file is missing)."))
    #expect(message.contains("Shared files such as text encoders and VAEs stay"))
    #expect(message.hasSuffix("Not moved: SDXL Base (used by a queued job)."))

    let loras = Library.TrashBatch(
      kind: .lora, items: [item("A", registered: true), item("B", registered: true, entryOnly: true), item("C", registered: true, entryOnly: true)],
      skipped: [], bytes: 0)
    #expect(Library.trashTitle(loras) == "Move 3 LoRAs to the Trash?")
    #expect(Library.trashMessage(loras).contains("2 only lose their custom_lora.json entries (their files are missing)."))
    #expect(!Library.trashMessage(loras).contains("Shared files"))
  }

  @Test func longListsStopAtThreeNames() {
    #expect(Library.nameList(["A"]) == "A")
    #expect(Library.nameList(["A", "B"]) == "A and B")
    #expect(Library.nameList(["A", "B", "C"]) == "A, B and C")
    #expect(Library.nameList(["A", "B", "C", "D", "E"]) == "A, B, C and 2 more")
    #expect(Library.counted(1, "model") == "1 model")
    #expect(Library.counted(3, "LoRA") == "3 LoRAs")
  }

  // MARK: Selection

  @Test func hiddenRowsAreLeftOutInTheListsOrder() {
    #expect(Library.visibleSelection(["c", "a", "hidden"], visible: ["a", "b", "c"]) == ["a", "c"])
    #expect(Library.visibleSelection([], visible: ["a"]).isEmpty)
  }

  @Test func theSummaryTotalsWhatsDownloaded() {
    let summary = Library.SelectionSummary.make(
      files: ["a", "b", "c"], sizes: ["a": 100, "b": 50], folders: ["a": "Internal", "b": "Internal"],
      families: ["a": "SDXL", "b": "SDXL", "c": "SDXL"])
    #expect(summary.count == 3 && summary.bytes == 150 && summary.downloaded == 2)
    #expect(summary.folder == "Internal" && summary.folderCounts.isEmpty)
    #expect(summary.family == "SDXL")

    let spread = Library.SelectionSummary.make(
      files: ["a", "b", "c"], sizes: ["a": 1, "b": 1, "c": 1], folders: ["a": "Internal", "b": "External", "c": "External"],
      families: ["a": "SDXL", "b": "FLUX.1"])
    #expect(spread.folder == "2 folders")
    #expect(spread.folderCounts == [.init(name: "External", count: 2), .init(name: "Internal", count: 1)])
    #expect(spread.family == "Mixed")

    let none = Library.SelectionSummary.make(files: ["a"], sizes: [:], folders: [:], families: [:])
    #expect(none.folder == nil && none.family == nil && none.bytes == 0)
  }

  @Test func moveToLeavesOutOnlyAFolderAllAreIn() {
    let a = URL(fileURLWithPath: "/A", isDirectory: true), b = URL(fileURLWithPath: "/B", isDirectory: true)
    let c = URL(fileURLWithPath: "/C", isDirectory: true)
    #expect(Library.batchDestinations(all: [a, b, c], folders: [a, a]) == [b, c])
    #expect(Library.batchDestinations(all: [a, b, c], folders: [a, b]) == [a, b, c])
    // Every file there already, where it lives or as a copy, disables the folder.
    let copies: Set = ["y in C"]
    let has = { (file: String, folder: URL) in copies.contains("\(file) in \(folder.lastPathComponent)") }
    #expect(Library.destinationDisabled(a, files: ["x"], folders: [a], has: has))
    #expect(!Library.destinationDisabled(a, files: ["x", "y"], folders: [a, b], has: has))
    #expect(Library.destinationDisabled(c, files: ["y"], folders: [b], has: has))
    #expect(!Library.destinationDisabled(c, files: ["x", "y"], folders: [b, b], has: has))
  }

  // MARK: Files

  @Test func aModelAndItsEightBitCopyTakeTheImportsVAE() throws {
    let template = try #require(ModelZoo.builtinSpecifications.first { $0.version == .sdxlBase })
    var model = ModelLibrary.specification(for: "batch_f16.ckpt", template: template)
    model.autoencoder = "batch_vae_f16.ckpt"
    model.textEncoder = "shared_te_f16.ckpt"
    model.clipEncoder = "shared_te_f16.ckpt"
    model.additionalClipEncoders = nil
    var copy = model
    copy.file = "batch_q8p.ckpt"
    let others = [model, copy]
    // Alone, either keeps the VAE: the other still names it.
    #expect(Library.importedCompanions(of: model.file, specification: model, others: others, excluding: []).isEmpty)
    #expect(
      Library.importedCompanions(of: model.file, specification: model, others: others, excluding: [model.file, copy.file])
        == ["batch_vae_f16.ckpt"])
    // The copy skipped (in a queued job) or failing at run time isn't in what goes: it still
    // names the VAE, so the VAE stays.
    #expect(Library.importedCompanions(of: model.file, specification: model, others: others, excluding: [model.file]).isEmpty)
    // A copy has no `_f16.ckpt` stem, so nothing is its own.
    #expect(Library.importedCompanions(of: copy.file, specification: copy, others: others, excluding: [model.file, copy.file]).isEmpty)
  }

  @Test func removingEntriesKeepsTheRestAsWritten() throws {
    let json = #"[{"file":"b.ckpt","name":"Beta","extra":1},{"file":"a.ckpt","name":"Alpha"},{"name":"No file"},{"file":"c.ckpt","name":"Gamma"}]"#
    let entries = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    let left = Library.removingEntries(["a.ckpt", "c.ckpt"], from: entries)
    #expect(left.map { $0["name"] as? String } == ["Beta", "No file"])
    #expect(left.first?["extra"] as? Int == 1)
  }
}
