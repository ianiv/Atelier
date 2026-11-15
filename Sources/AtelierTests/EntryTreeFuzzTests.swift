@testable import Atelier
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC
import ProjectFormat
import Testing

/// Random sequences of input entries and runs after random steps: the parent links never loop.
/// And if they ever did, the walks over them (the strip's Current Lineage, ancestry, a run's
/// input entry) stop where the loop comes back round instead of hanging.
struct EntryTreeFuzzTests {
  /// Two runs recording each other as their parent: a loop `ProjectTree` takes as it is.
  private static func loopedTree() -> ProjectTree {
    func node(time: Int64, tensorId: Int64, parent: Int64) -> TensorHistoryNode {
      ProjectMapping.node(
        for: ProjectMapping.Step(
          lineage: 0, logicalTime: time, model: "m", prompt: "run", negativePrompt: "", seed: 1, tensorId: tensorId,
          previewId: tensorId, wallClock: time, generationTime: 1, reason: .generate, parentTensorId: parent),
        settings: [:])
    }
    func layer(time: Int64, tensorId: Int64) -> ProjectFormat.TensorData {
      ProjectFormat.TensorData(
        lineage: 0, logicalTime: time, index: 0, x: 0, y: 0, width: 64, height: 64, scaleFactorBy120: 120,
        tensorId: tensorId)
    }
    return ProjectTree(
      nodes: [node(time: 1, tensorId: 101, parent: 102), node(time: 2, tensorId: 102, parent: 101)],
      layers: [layer(time: 1, tensorId: 101), layer(time: 2, tensorId: 102)])
  }

  @Test func loopedLinksEndTheWalks() throws {
    let tree = Self.loopedTree()
    let first = StepID(lineage: 0, logicalTime: 1), second = StepID(lineage: 0, logicalTime: 2)
    // The links really loop, so the walks below have something to stop at.
    try #require(tree.steps[first]?.parent == second && tree.steps[second]?.parent == first)
    #expect(tree.ancestry(of: second) == [second, first])
    #expect(tree.visibleAncestor(of: first) == first)
    #expect(tree.representative(of: first) == first)
    let items = try [Int64(101), 102].map { try #require(tree.items[tree.step(tensorId: $0) ?? first]) }
    #expect(HistoryStore.inputEntry(of: items[0], in: tree) == nil)
    // What `HistoryStore.reload` makes of the links, and the strip's line from each run.
    let parent = { (item: HistoryItem) in
      tree.steps[item.id]?.parent.flatMap(tree.visibleAncestor(of:)).flatMap { tree.items[$0] }
    }
    let child = { (item: HistoryItem) in items.first { parent($0) == item } }
    for item in items {
      let line = HistoryStore.lineage(of: item, parent: parent, firstChild: child)
      #expect(Set(line.map(\.tensorId)) == [101, 102] && line.count == 2)
      #expect(line.contains(item))
    }
  }

  @Test(arguments: 0..<40) func parentsNeverLoop(seed: Int) async throws {
    var rng = SeededRandom(seed: UInt64(seed + 1))
    let folder = FileManager.default.temporaryDirectory.appending(path: "EntryFuzz-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = Project(url: folder.appending(path: "Fuzz.sqlite3"))
    let image = try #require(ImageTensor.tensor(from: CanvasRefineTests.pattern(width: 8, height: 8)))
    var keys: [Int64] = []
    var runs: [Int64] = []
    for operation in 0..<150 {
      let parent = keys.isEmpty ? nil : keys[Int(rng.next() % UInt64(keys.count))]
      let kind = rng.next() % 6
      var description = ""
      if kind < 2 || runs.isEmpty {
        let run = try await project.append(
          tensor: image, model: "m", prompt: "run", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(),
          duration: 1, after: parent)
        keys.append(run.tensorId)
        runs.append(run.tensorId)
        description = "run after \(parent ?? 0)"
      } else if kind == 5, keys.count > 3 {
        let victim = keys.remove(at: Int(rng.next() % UInt64(keys.count)))
        runs.removeAll { $0 == victim }
        _ = try await project.delete(tensorId: victim)
        description = "delete \(victim)"
      } else {
        let reason: HistoryItem.EntryReason = [.moodboard, .cleared, .mask, .imported][Int(rng.next() % 4)]
        let canvas: Project.EntryCanvas = reason == .imported ? .image(image)
          : reason == .cleared || rng.next() % 2 == 0
          ? .empty : .step(tensorId: runs[Int(rng.next() % UInt64(runs.count))])
        let entry = try await project.appendEntry(
          reason: reason.reason, keyed: reason != .imported, canvas: canvas, mask: nil,
          moodboard: [Project.EntryMood(shuffleId: nil, tensor: image, weight: Float(rng.next() % 2))],
          thumbnail: nil, model: "m", prompt: "", negativePrompt: "", seed: 0, settings: [:], createdAt: Date(),
          after: parent)
        keys.append(entry.key)
        if reason == .imported { runs.append(entry.key) }
        description = "\(reason) after \(parent ?? 0)"
      }
      let tree = await project.read { $0.tree() }
      for id in tree.steps.keys {
        var seen: Set<StepID> = []
        var next: StepID? = id
        while let step = next {
          #expect(seen.insert(step).inserted, "seed \(seed) op \(operation) (\(description)): parent loop at \(step)")
          if !seen.contains(step) || seen.count > tree.steps.count { break }
          next = tree.steps[step]?.parent
          if let n = next, seen.contains(n) {
            Issue.record("seed \(seed) op \(operation) (\(description)): parent loop through \(n)")
            return
          }
        }
      }
    }
  }
}

private struct SeededRandom {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return state >> 33
  }
}
