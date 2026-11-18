@testable import Atelier
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC
import ProjectFormat
import Testing

/// Input entries (`Project.appendEntry`): how `ProjectTree` lists and keys them beside the steps
/// whose images they share, when one repeats another (`HistoryStore.isDuplicate`), and that
/// deleting keeps a shared tensor until nothing uses it.
@Suite(.tags(.smoke))
struct InputEntryTests {
  private static func tensor(_ seed: Int = 0) throws -> Tensor<FloatType> {
    try #require(ImageTensor.tensor(from: CanvasRefineTests.pattern(width: 8 + seed, height: 8)))
  }

  private static func project() throws -> Project {
    let folder = FileManager.default.temporaryDirectory.appending(path: "InputEntryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return Project(url: folder.appending(path: "Entries.sqlite3"))
  }

  private static func entry(
    _ project: Project, _ reason: HistoryItem.EntryReason, canvas: Project.EntryCanvas, mask: CanvasMask? = nil,
    moodboard: [Project.EntryMood] = [], after parent: Int64?
  ) async throws -> Project.AppendedEntry {
    try await project.appendEntry(
      reason: reason.reason, keyed: reason != .imported, canvas: canvas, mask: mask, moodboard: moodboard,
      thumbnail: CanvasRefineTests.pattern(width: 8, height: 8), model: "m", prompt: "", negativePrompt: "", seed: 0,
      settings: [:], createdAt: Date(), after: parent)
  }

  private static func generated(_ project: Project, after parent: Int64?) async throws -> HistoryItem {
    try await project.append(
      tensor: tensor(), model: "m", prompt: "run", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(),
      duration: 1, after: parent)
  }

  /// A run, an image brought in, a moodboard change showing that image and a run after it: the
  /// entries are listed, the Imported one by its image and the Moodboard one by its own key, and a
  /// lookup by the image finds its own step, never the entry sharing it.
  @Test func listsAndKeysEntries() async throws {
    let project = try Self.project()
    let first = try await Self.generated(project, after: nil)
    let imported = try await Self.entry(project, .imported, canvas: .image(Self.tensor(1)), after: first.tensorId)
    let image = try #require(imported.imageTensorId)
    #expect(imported.key == image)
    let mask = CanvasMask(strokes: [.rect(CGRect(x: 0, y: 0, width: 4, height: 4))])
    let moods = try [
      Project.EntryMood(shuffleId: nil, tensor: Self.tensor(2), weight: 1),
      Project.EntryMood(shuffleId: nil, tensor: Self.tensor(3), weight: 0),
    ]
    let moodboard = try await Self.entry(
      project, .moodboard, canvas: .step(tensorId: image), mask: mask, moodboard: moods, after: imported.key)
    #expect(ProjectMapping.Profile.entryKeys.contains(moodboard.key))
    #expect(moodboard.imageTensorId == image)
    let run = try await Self.generated(project, after: moodboard.key)

    let tree = await project.read { $0.tree() }
    let items = tree.itemsNewestFirst
    #expect(items.map(\.tensorId) == [run.tensorId, moodboard.key, image, first.tensorId])
    let listedImport = try #require(items.first { $0.tensorId == image })
    #expect(listedImport.entryReason == .imported && listedImport.canvasTensorId == image)
    let listedMoodboard = try #require(items.first { $0.tensorId == moodboard.key })
    #expect(listedMoodboard.entryReason == .moodboard && listedMoodboard.canvasTensorId == image)
    #expect(listedMoodboard.entryMask == mask)
    #expect(listedMoodboard.entryMoodboard.map(\.weight) == [1, 0])
    #expect(listedMoodboard.entryMoodboard.map(\.shuffleId) == moodboard.shuffleIds)
    #expect(listedMoodboard.imageTensorId == image && listedMoodboard.hasImage)
    // By image, the image's own step; by key, the entry.
    #expect(tree.step(tensorId: image) == imported.id)
    #expect(tree.step(tensorId: moodboard.key) == moodboard.id)
    #expect(tree.steps(tensorId: image) == [imported.id])
    // The run follows the entry, recorded by its key.
    #expect(tree.steps[run.id]?.parent == moodboard.id)
    #expect(tree.steps[moodboard.id]?.parent == imported.id)
    #expect(tree.steps[run.id]?.recordedParent == moodboard.key)
    // The entry's image is the canvas's, composited from the shared layer.
    let entryImage = await project.read { $0.image(at: moodboard.id) }
    let ownImage = await project.read { $0.image(tensorId: image) }
    #expect(entryImage != nil && entryImage?.width == ownImage?.width)

    // A Clear entry has no image and is keyed too; a run after it follows it.
    let cleared = try await Self.entry(project, .cleared, canvas: .empty, after: run.tensorId)
    let next = try await Self.generated(project, after: cleared.key)
    let after = await project.read { $0.tree() }
    let listedClear = try #require(after.items[cleared.id])
    #expect(listedClear.entryReason == .cleared && !listedClear.hasImage && listedClear.tensorId == cleared.key)
    #expect(after.steps[next.id]?.parent == cleared.id)

    // Deleting by the image deletes the image's own step, not the entry showing it.
    try await project.delete(tensorId: image)
    let deleted = await project.read { $0.tree() }
    #expect(deleted.items.values.contains { $0.tensorId == moodboard.key })
    #expect(!deleted.items.values.contains { $0.tensorId == image })
    // With its own step gone, a lookup by the image finds the entry still showing it.
    #expect(deleted.step(tensorId: image).flatMap { deleted.steps[$0]?.entryKey } == moodboard.key)
  }

  /// Steps that stay hidden: Atelier's frame-render inputs (Other) and Draw Things' own Moodboard
  /// steps, which have no key.
  @Test func hidesOtherInputs() async throws {
    let project = try Self.project()
    let first = try await Self.generated(project, after: nil)
    let other = try await project.append(
      tensor: Self.tensor(1), model: "m", prompt: "", negativePrompt: "", seed: 0, settings: [:], createdAt: Date(),
      duration: 0, reason: .other, generated: false, after: first.tensorId)
    let moodboard = try await project.append(
      tensor: Self.tensor(2), model: "m", prompt: "", negativePrompt: "", seed: 0, settings: [:], createdAt: Date(),
      duration: 0, reason: .moodboard, generated: false, after: other.tensorId)
    let tree = await project.read { $0.tree() }
    #expect(tree.itemsNewestFirst.map(\.tensorId) == [first.tensorId])
    #expect(tree.step(tensorId: moodboard.tensorId) != nil)
  }

  /// An entry repeats another when its canvas, mask and moodboard (weights included) are the same;
  /// a mask that paints nothing is none; there's nothing to repeat without an entry.
  @Test func dedupe() {
    let mask = CanvasMask(strokes: [.rect(CGRect(x: 0, y: 0, width: 4, height: 4))])
    var entry = HistoryItem(
      id: StepID(lineage: 0, logicalTime: 1), tensorId: 2_500_000_000, previewId: 0,
      sidecar: HistoryStore.Sidecar(
        createdAt: Date(), durationSeconds: 0, prompt: "", negativePrompt: "", model: "", seed: 0, width: 8, height: 8,
        steps: 1, guidanceScale: 1, shift: 1, sampler: "", resolutionDependentShift: false, hiresFix: false,
        configuration: [:]))
    entry.entryReason = .moodboard
    entry.canvasTensorId = 123
    entry.entryMask = mask
    entry.entryMoodboard = [.init(shuffleId: 1, weight: 1), .init(shuffleId: 2, weight: 0)]
    let same = HistoryStore.EntrySignature(canvasTensorId: 123, mask: mask, moodboard: entry.entryMoodboard)
    #expect(HistoryStore.isDuplicate(same, of: entry))
    var weight = same
    weight.moodboard[1].weight = 0.5
    #expect(!HistoryStore.isDuplicate(weight, of: entry))
    #expect(!HistoryStore.isDuplicate(
      HistoryStore.EntrySignature(canvasTensorId: 124, mask: mask, moodboard: entry.entryMoodboard), of: entry))
    #expect(!HistoryStore.isDuplicate(
      HistoryStore.EntrySignature(canvasTensorId: 123, mask: nil, moodboard: entry.entryMoodboard), of: entry))
    #expect(!HistoryStore.isDuplicate(same, of: nil))
    #expect(!HistoryStore.isDuplicate(nil, of: entry))
    // No mask and one that paints nothing are the same.
    entry.entryMask = nil
    #expect(HistoryStore.isDuplicate(
      HistoryStore.EntrySignature(canvasTensorId: 123, mask: CanvasMask(), moodboard: entry.entryMoodboard), of: entry))
    // A run isn't an entry to repeat.
    entry.entryReason = nil
    #expect(!HistoryStore.isDuplicate(
      HistoryStore.EntrySignature(canvasTensorId: 123, mask: nil, moodboard: entry.entryMoodboard), of: entry))
  }

  /// Entries share the canvas's tensor and their moodboard's: deleting one keeps every tensor
  /// another step still uses, and the last one to go takes it.
  @Test func sharedTensorDelete() async throws {
    let project = try Self.project()
    let run = try await Self.generated(project, after: nil)
    let moods = try [Project.EntryMood(shuffleId: nil, tensor: Self.tensor(2), weight: 1)]
    let a = try await Self.entry(project, .moodboard, canvas: .step(tensorId: run.tensorId), moodboard: moods, after: run.tensorId)
    // The second shares the first's moodboard tensor.
    let shared = [Project.EntryMood(shuffleId: a.shuffleIds[0], tensor: moods[0].tensor, weight: 0.5)]
    let b = try await Self.entry(project, .moodboard, canvas: .step(tensorId: run.tensorId), moodboard: shared, after: a.key)
    #expect(b.shuffleIds == a.shuffleIds)
    let image = "tensor_history_\(run.tensorId)", shuffle = "shuffle_\(a.shuffleIds[0])"
    var names = await project.read { $0.contents().tensorNames }
    #expect(names.filter { $0.hasPrefix("shuffle_") } == [shuffle])

    // The run goes: the entries still show its image.
    try await project.delete(tensorId: run.tensorId)
    names = await project.read { $0.contents().tensorNames }
    #expect(names.contains(image) && names.contains(shuffle))
    let shown = await project.read { project -> Bool in
      let tree = project.tree()
      return tree.items.values.filter(\.isEntry).allSatisfy { project.image(for: $0) != nil }
    }
    #expect(shown)
    #expect(await project.read { $0.moodboardImages(at: $0.tree(items: false).step(tensorId: b.key)!).count } == 1)

    // One entry goes: the other keeps both tensors.
    try await project.delete(tensorId: a.key)
    names = await project.read { $0.contents().tensorNames }
    #expect(names.contains(image) && names.contains(shuffle))

    // The last one takes them, and its thumbnails.
    try await project.delete(tensorId: b.key)
    let contents = await project.read { $0.contents() }
    #expect(!contents.tensorNames.contains(image) && !contents.tensorNames.contains(shuffle))
    #expect(contents.nodes.isEmpty && contents.layers.isEmpty && contents.moods.isEmpty && contents.thumbnails.isEmpty)
  }

  /// Imported steps written before entries (Atelier's hidden inputs, Draw Things' own) aren't
  /// entries: not listed, and no run takes one, or anything past a Draw Things Moodboard step, as
  /// its input entry.
  @Test func unmarkedInputsAreNoEntries() async throws {
    let project = try Self.project()
    let old = try await project.append(
      tensor: Self.tensor(1), model: "m", prompt: "", negativePrompt: "", seed: 0, settings: [:], createdAt: Date(),
      duration: 0, reason: .imported, generated: false)
    let run = try await project.append(
      tensor: Self.tensor(), model: "m", prompt: "run", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(),
      duration: 1, inputTensorId: old.tensorId, after: old.tensorId)
    var tree = await project.read { $0.tree() }
    #expect(tree.itemsNewestFirst.map(\.tensorId) == [run.tensorId])
    let listedRun = try #require(tree.items[run.id])
    #expect(HistoryStore.inputEntry(of: listedRun, in: tree) == nil)

    // A marked entry, then a Draw Things Moodboard step, then a run: the run has no input entry.
    let entry = try await Self.entry(project, .moodboard, canvas: .step(tensorId: run.tensorId), after: run.tensorId)
    let dt = try await project.append(
      tensor: Self.tensor(2), model: "m", prompt: "", negativePrompt: "", seed: 0, settings: [:], createdAt: Date(),
      duration: 0, reason: .moodboard, generated: false, after: entry.key)
    let after = try await Self.generated(project, after: dt.tensorId)
    // A run straight after the entry, past only a frame step (Other), has it.
    let frame = try await project.append(
      tensor: Self.tensor(3), model: "m", prompt: "", negativePrompt: "", seed: 0, settings: [:], createdAt: Date(),
      duration: 0, reason: .other, generated: false, after: entry.key)
    let framed = try await Self.generated(project, after: frame.tensorId)
    tree = await project.read { $0.tree() }
    #expect(HistoryStore.inputEntry(of: try #require(tree.items[after.id]), in: tree) == nil)
    #expect(HistoryStore.inputEntry(of: try #require(tree.items[framed.id]), in: tree)?.tensorId == entry.key)
  }

  /// A project opens on the step it recorded by what finds it: an entry by its key, not by the
  /// image it shows (which finds the image's own step).
  @Test func opensOnTheEntry() async throws {
    let project = try Self.project()
    let run = try await Self.generated(project, after: nil)
    let entry = try await Self.entry(project, .moodboard, canvas: .step(tensorId: run.tensorId), after: run.tensorId)
    let tree = await project.read { $0.tree(items: false) }
    #expect(HistoryStore.openingCurrent(in: tree, stored: nil) == entry.key)
    #expect(HistoryStore.openingCurrent(in: tree, stored: tree.step(tensorId: run.tensorId)) == run.tensorId)
  }

  /// Deleting the entry a run was made from records what's left of its input: the step before
  /// when it shows the same image, else the image.
  @Test func deletingAnEntryKeepsItsRunsInput() async throws {
    let project = try Self.project()
    let imported = try await Self.entry(project, .imported, canvas: .image(Self.tensor(1)), after: nil)
    let image = try #require(imported.imageTensorId)
    let moodboard = try await Self.entry(project, .moodboard, canvas: .step(tensorId: image), after: imported.key)
    let run = try await project.append(
      tensor: Self.tensor(), model: "m", prompt: "run", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(),
      duration: 1, inputTensorId: moodboard.key, after: moodboard.key)
    try await project.delete(tensorId: moodboard.key)
    var tree = await project.read { $0.tree() }
    let moved = try #require(tree.itemsNewestFirst.first { $0.tensorId == run.tensorId })
    #expect(moved.inputTensorId == image)
    #expect(await project.read { $0.input(of: moved.id, tensorId: image) }?.imageTensorId == image)

    // A Mask entry on the run, after which the next run; the step before it (the run) shows
    // another image, so the next run keeps the entry's image as its input.
    let mask = try await Self.entry(project, .mask, canvas: .step(tensorId: run.tensorId), after: run.tensorId)
    let next = try await project.append(
      tensor: Self.tensor(), model: "m", prompt: "next", negativePrompt: "", seed: 2, settings: [:], createdAt: Date(),
      duration: 1, inputTensorId: mask.key, after: mask.key)
    try await project.delete(tensorId: mask.key)
    tree = await project.read { $0.tree() }
    #expect(tree.itemsNewestFirst.first { $0.tensorId == next.tensorId }?.inputTensorId == run.tensorId)
  }

  /// A moodboard tensor no row uses any more isn't shared: it's written again.
  @Test func aLostMoodboardTensorIsWrittenAgain() async throws {
    let project = try Self.project()
    let run = try await Self.generated(project, after: nil)
    let moods = try [Project.EntryMood(shuffleId: 1_700_000_001, tensor: Self.tensor(2), weight: 1)]
    let entry = try await Self.entry(project, .moodboard, canvas: .step(tensorId: run.tensorId), moodboard: moods, after: run.tensorId)
    #expect(entry.shuffleIds != [1_700_000_001])
    let names = await project.read { $0.contents().tensorNames }
    #expect(names.contains("shuffle_\(entry.shuffleIds[0])"))
  }
}
