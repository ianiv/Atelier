@testable import Atelier
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC
import Testing

/// Deleting a clip in one transaction (`Project.deleteClip`) leaves the project file exactly as
/// deleting its frames one by one, last first, as Draw Things does (`deleteFrameByFrame`).
struct ClipDeleteTests {
  /// A built project: its file, each clip's frames and each image's tensor, by name.
  struct Built {
    var folder: URL
    var url: URL
    var clips: [String: [Int64]] = [:]
    var images: [String: Int64] = [:]
  }

  private static func tensor() throws -> Tensor<FloatType> {
    try #require(ImageTensor.tensor(from: CanvasRefineTests.pattern(width: 8, height: 8)))
  }

  private static func audio() -> Tensor<Float> {
    var audio = Tensor<Float>(.CPU, .NC(1, 16))
    for index in 0..<16 { audio[0, index] = Float(index) / 16 }
    return audio
  }

  private static func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ClipDeleteTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  @discardableResult
  private static func image(_ project: Project, _ name: String, after parent: Int64?, into built: inout Built) async throws
    -> Int64
  {
    let item = try await project.append(
      tensor: tensor(), model: "m", prompt: name, negativePrompt: "", seed: 1, settings: [:], createdAt: Date(),
      duration: 0, after: parent)
    built.images[name] = item.tensorId
    return item.tensorId
  }

  @discardableResult
  private static func clip(
    _ project: Project, _ name: String, frames: Int, after parent: Int64?, audio withAudio: Bool = false,
    inputAudio: Bool = false, moodboard: Bool = false, into built: inout Built
  ) async throws -> [Int64] {
    let item = try await project.appendClip(
      frames: Array(repeating: tensor(), count: frames),
      clip: Project.ClipContent(
        framesPerSecond: 24, audio: withAudio ? audio() : nil, audioInput: inputAudio ? audio() : nil),
      model: "v", prompt: name, negativePrompt: "", seed: 1, settings: [:], createdAt: Date(), duration: 0,
      moodboard: moodboard ? [Project.MoodboardTensor(tensor: tensor(), weight: 1)] : [], after: parent)
    let listed = await project.read { $0.items() }.first { $0.tensorId == item.tensorId }
    let ids = try #require(listed?.clip?.frames)
    #expect(ids.count == frames)
    built.clips[name] = ids
    return ids
  }

  /// Clips first, in the middle and last; images between; a branch from a clip's middle frame
  /// that runs on a higher lineage past the clip's step numbers; another from a clip's second
  /// frame; a clip on a branch.
  private static func build() async throws -> Built {
    let folder = try folder()
    var built = Built(folder: folder, url: folder.appending(path: "Template.sqlite3"))
    let project = Project(url: built.url)
    let c0 = try await clip(project, "C0", frames: 3, after: nil, audio: true, inputAudio: true, into: &built)
    let a = try await image(project, "A", after: c0.last, into: &built)
    let c1 = try await clip(project, "C1", frames: 4, after: a, audio: true, moodboard: true, into: &built)
    let b = try await image(project, "B", after: c1.last, into: &built)
    let c2 = try await clip(project, "C2", frames: 5, after: b, inputAudio: true, into: &built)
    let d = try await image(project, "D", after: c2.last, into: &built)
    let c3 = try await clip(project, "C3", frames: 3, after: d, audio: true, into: &built)
    try await image(project, "F", after: c3.last, into: &built)
    var e = try await image(project, "E", after: c2[2], into: &built)
    for index in 2...5 { e = try await image(project, "E\(index)", after: e, into: &built) }
    let g = try await image(project, "G", after: c1[1], into: &built)
    try await image(project, "G2", after: g, into: &built)
    try await clip(project, "C4", frames: 3, after: e, audio: true, into: &built)
    try await image(project, "H", after: built.images["F"], into: &built)
    await project.close()
    return built
  }

  /// A copy of the template, opened.
  private static func copy(_ built: Built, _ name: String) throws -> Project {
    let url = built.folder.appending(path: "\(name).sqlite3")
    try FileManager.default.copyItem(at: built.url, to: url)
    return Project(url: url)
  }

  /// Deletes `clips` in order from two copies, one frame by frame and one at once, comparing the
  /// files after each.
  private static func expectSameDeletes(_ clips: [String], in built: Built, unlinked: Bool = false) async throws {
    let old = try copy(built, "old-\(clips.joined())-\(unlinked)")
    let new = try copy(built, "new-\(clips.joined())-\(unlinked)")
    if unlinked {
      // As Draw Things writes them: no parent recorded.
      await old.forgetParentLinks()
      await new.forgetParentLinks()
    }
    #expect(old.contents() == new.contents())
    for name in clips {
      let frames = try #require(built.clips[name])
      let before = new.contents()
      let oldParent = try await old.deleteFrameByFrame(frames)
      let newParent = try await new.deleteClip(frames: frames)
      #expect(oldParent == newParent, "\(name)")
      let (a, b) = (old.contents(), new.contents())
      #expect(a.nodes.count == before.nodes.count - frames.count, "\(name)")
      // Every step left keeps its layers.
      for contents in [a, b] {
        let steps = Set(contents.nodes.map { [$0.lineage, $0.logicalTime] })
        #expect(steps == Set(contents.layers.map { [$0.lineage, $0.logicalTime] }), "\(name) layers")
      }
      #expect(a.nodes == b.nodes, "\(name) nodes")
      #expect(a.layers == b.layers, "\(name) layers")
      #expect(a.moods == b.moods, "\(name) moodboard")
      #expect(a.clips == b.clips, "\(name) clips")
      #expect(a.thumbnails == b.thumbnails && a.halfThumbnails == b.halfThumbnails, "\(name) thumbnails")
      #expect(a.tensorNames == b.tensorNames, "\(name) tensors")
      #expect(a.tensorNames.count < before.tensorNames.count, "\(name)")
    }
    await old.close()
    await new.close()
  }

  @Test func deletingAClipAtOnceMatchesDeletingItFrameByFrame() async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    // First in the project, with audio and an input audio file.
    try await Self.expectSameDeletes(["C0"], in: built)
    // In the middle, a branch from its second frame, a moodboard.
    try await Self.expectSameDeletes(["C1"], in: built)
    // A branch from its middle frame running past its step numbers on a higher lineage.
    try await Self.expectSameDeletes(["C2"], in: built)
    // Higher lineages overlap its step numbers.
    try await Self.expectSameDeletes(["C3"], in: built)
    // Last, on a branch.
    try await Self.expectSameDeletes(["C4"], in: built)
    // One after another.
    try await Self.expectSameDeletes(["C2", "C0", "C4", "C1", "C3"], in: built)
  }

  @Test func projectsWithoutParentLinksDeleteTheSame() async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    try await Self.expectSameDeletes(["C1", "C2"], in: built, unlinked: true)
  }

  @Test func framesThatArentARunDeleteFrameByFrame() async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let old = try Self.copy(built, "old")
    let new = try Self.copy(built, "new")
    // Out of order, and from two clips.
    let frames = try [#require(built.clips["C2"])[3], #require(built.clips["C1"])[2], #require(built.clips["C2"])[1]]
    let oldParent = try await old.deleteFrameByFrame(frames)
    let newParent = try await new.deleteClip(frames: frames)
    #expect(oldParent == newParent)
    #expect(old.contents() == new.contents())
    await old.close()
    await new.close()
  }

  /// 30 clips of 50 frames: deleting an early one renumbers nearly every step.
  @Test func deletingAClipInALargeProjectIsQuick() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var built = Built(folder: folder, url: folder.appending(path: "Large.sqlite3"))
    let project = Project(url: built.url)
    var last: Int64?
    for index in 0..<30 {
      last = try await Self.clip(project, "C\(index)", frames: 50, after: last, audio: true, into: &built).last
    }
    let start = ContinuousClock.now
    _ = try await project.deleteClip(frames: #require(built.clips["C1"]))
    let elapsed = ContinuousClock.now - start
    print("Deleting a 50-frame clip from 30: \(elapsed)")
    #expect(project.contents().nodes.count == 29 * 50)
    #expect(elapsed < .seconds(10))
    await project.close()
  }
}
