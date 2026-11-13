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
      // The run itself, not deleteClip, so a fallback can't pass as it.
      let deleted = try await new.deleteRun(tensorIds: frames)
      #expect(deleted != nil, "\(name) took the fallback")
      #expect(oldParent == deleted?.parentTensorId, "\(name)")
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

  /// Changes the template the copies are made from.
  private static func edit(_ built: Built, _ body: (Project) async throws -> Void) async throws {
    let template = Project(url: built.url)
    try await body(template)
    await template.close()
  }

  /// Clip C3's first frame as a refined canvas: over a source layer of its own (a new tensor and
  /// paint mask), or over its parent D's image, as a refine of D reuses it.
  @Test(arguments: [false, true], [false, true])
  func refinedClipsDeleteAtOnce(reusedSource: Bool, unlinked: Bool) async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips["C3"])
    let source = try reusedSource ? #require(built.images["D"]) : 1_500_000_001
    try await Self.edit(built) {
      try await $0.addLayerForTests(
        tensorId: source, index: -1, toStepOf: frames[0], maskId: 400_000_001, writing: !reusedSource)
    }
    try await Self.expectSameDeletes(["C3"], in: built, unlinked: unlinked)
  }

  /// Deletes `frames` from two copies, expecting the run to decline, and compares the fallback
  /// with deleting frame by frame.
  private static func expectFallback(_ frames: [Int64], in built: Built) async throws {
    let old = try copy(built, "old")
    let new = try copy(built, "new")
    #expect(try await new.deleteRun(tensorIds: frames) == nil)
    let oldParent = try await old.deleteFrameByFrame(frames)
    let newParent = try await new.deleteClip(frames: frames)
    #expect(oldParent == newParent)
    #expect(old.contents() == new.contents())
    await old.close()
    await new.close()
  }

  /// A clip frame's image also on another step: on top, that step's image, so the frame-by-frame
  /// deletes decide; below, a canvas drawn over it (F, which no step recording the frame can sit
  /// right after), so the clip goes at once.
  @Test(arguments: [1, -1] as [Int64])
  func sharedFrameTensors(index: Int64) async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips["C2"])
    let image = try #require(built.images["F"])
    try await Self.edit(built) { try await $0.addLayerForTests(tensorId: frames[1], index: index, toStepOf: image) }
    if index > 0 {
      try await Self.expectFallback(frames, in: built)
    } else {
      try await Self.expectSameDeletes(["C2"], in: built)
    }
  }

  /// A frame's image is also another step's through that step's own field, with no layer
  /// shared: two steps answer for the image.
  @Test func aFrameImageOnTwoStepsDeletesFrameByFrame() async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips["C2"])
    let image = try #require(built.images["F"])
    try await Self.edit(built) { await $0.setNodeImageForTests(tensorId: frames[1], ofStepOf: image) }
    let tree = Project(url: built.url).tree(items: false)
    #expect(tree.steps(tensorId: frames[1]).count == 2)
    try await Self.expectFallback(frames, in: built)
  }

  /// A frame drawn over an image that isn't its parent's: whether a step recording that image
  /// finds the frame depends on where things sit, so the frame-by-frame deletes decide.
  @Test func aFrameOverAnotherStepsImageDeletesFrameByFrame() async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips["C3"])
    let image = try #require(built.images["A"])
    try await Self.edit(built) { try await $0.addLayerForTests(tensorId: image, index: -1, toStepOf: frames[0]) }
    try await Self.expectFallback(frames, in: built)
  }

  /// A step after C2 on its lineage records a parent that's no step's image: its parent is the
  /// rule's step alone, which a renumbering can make one of C2's frames, so the frame-by-frame
  /// deletes decide.
  @Test func aLostParentAfterTheClipDeletesFrameByFrame() async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips["C2"])
    let image = try #require(built.images["D"])
    try await Self.edit(built) { await $0.setRecordedParentForTests(123_456_789, ofStepOf: image) }
    try await Self.expectFallback(frames, in: built)
  }

  /// One before the clip, or on a lower lineage past it, never has a frame for the rule's step:
  /// the clip goes at once.
  @Test(arguments: [("C2", "A"), ("C3", "F")])
  func aLostParentElsewhereDeletesAtOnce(clip: String, step: String) async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips[clip])
    let image = try #require(built.images[step])
    let tree = Project(url: built.url).tree(items: false)
    let (first, other) = try (#require(tree.step(tensorId: frames[0])), #require(tree.step(tensorId: image)))
    // Before the clip's start, or below its lineage past it.
    #expect(other.logicalTime <= first.logicalTime || (other.lineage < first.lineage && other.logicalTime > first.logicalTime))
    try await Self.edit(built) { await $0.setRecordedParentForTests(123_456_789, ofStepOf: image) }
    try await Self.expectSameDeletes([clip], in: built)
  }

  /// Appends a zoomed refine (its frame at 2× density, as Create's merge writes it) of the step
  /// whose image is `source`, reusing that image as the bottom layer and carrying its detail.
  @discardableResult
  private static func refine(
    _ project: Project, _ name: String, of source: Int64, at offset: Int32 = 2, into built: inout Built
  ) async throws
    -> Int64
  {
    let image = try CanvasRefineTests.pattern(width: 8, height: 8)
    let frame = try CanvasRefineTests.solid(width: 8, height: 8, red: 255, green: 0, blue: 0)
    var step = RefinedStep(record: RefineRecord(rect: [Double(offset), Double(offset), 4, 4], scale: 2, offset: [0, 0]), composite: image)
    step.layers = RefinedStep.Layers(
      source: image, sourceTensorId: source, paint: nil, frame: frame, frameX: offset, frameY: offset, frameScaleFactorBy120: 240)
    let item = try await project.append(
      tensor: tensor(), model: "m", prompt: name, negativePrompt: "", seed: 1, settings: [:], createdAt: Date(),
      duration: 0, inputTensorId: source, after: source, refined: step)
    built.images[name] = item.tensorId
    return item.tensorId
  }

  /// Zoomed refines after C3 on its lineage, the second carrying the first's dense frame (one
  /// tensor on two steps), move down with their density and shared tensors as frame by frame.
  @Test(arguments: [false, true])
  func refinesAfterAClipMoveTheSame(unlinked: Bool) async throws {
    var built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let template = Project(url: built.url)
    let first = try await Self.refine(template, "R1", of: #require(built.images["H"]), into: &built)
    try await Self.refine(template, "R2", of: first, at: 4, into: &built)
    let rows = template.contents().layers
    let r1Frame = try #require(rows.first { $0.tensorId == first })
    #expect(r1Frame.scaleFactorBy120 == 240)
    // R2 holds R1's dense frame as carried detail.
    #expect(rows.filter { $0.tensorId == first }.count == 2)
    await template.close()
    try await Self.expectSameDeletes(["C3"], in: built, unlinked: unlinked)
  }

  /// Refines of clip frames (Use Last Frame as Input, then Edit with an image model) keep the
  /// frame's image as their bottom layer: of C2's last frame, of a middle one, a chain of refines
  /// off a middle one, and of a newest clip's last frame (the refine on the clip's own lineage).
  /// The clip goes at once, the frame's image staying for the refine.
  @Test(arguments: ["last", "middle", "chain", "newest"], [false, true])
  func refinedClipFramesDeleteAtOnce(shape: String, unlinked: Bool) async throws {
    var built: Built
    let clip: String
    if shape == "newest" {
      let folder = try Self.folder()
      built = Built(folder: folder, url: folder.appending(path: "Template.sqlite3"))
      let project = Project(url: built.url)
      let a = try await Self.image(project, "A", after: nil, into: &built)
      let frames = try await Self.clip(project, "X", frames: 4, after: a, audio: true, into: &built)
      let refined = try await Self.refine(project, "R", of: #require(frames.last), into: &built)
      try await Self.image(project, "B", after: refined, into: &built)
      await project.close()
      clip = "X"
    } else {
      built = try await Self.build()
      clip = "C2"
      let frames = try #require(built.clips[clip])
      let template = Project(url: built.url)
      let source = shape == "last" ? frames[4] : frames[2]
      var refined = try await Self.refine(template, "R1", of: source, into: &built)
      if shape == "chain" {
        refined = try await Self.refine(template, "R2", of: refined, at: 4, into: &built)
        try await Self.refine(template, "R3", of: refined, into: &built)
      }
      await template.close()
    }
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips[clip])
    let refine = try #require(built.images[shape == "newest" ? "R" : "R1"])
    try await Self.expectSameDeletes([clip], in: built, unlinked: unlinked)
    // The refine still holds the frame's image after the delete, as frame by frame.
    let after = try Self.copy(built, "after")
    _ = try await after.deleteClip(frames: frames)
    let source = shape == "last" || shape == "newest" ? frames.last! : frames[2]
    #expect(after.contents().tensorNames.contains("tensor_history_\(source)"))
    #expect(after.contents().layers.contains { $0.tensorId == source })
    #expect(await after.read { $0.tree(items: false).step(tensorId: refine) } != nil)
    await after.close()
  }

  /// A step recording a refined frame's image, right after the refine on its lineage, would find
  /// the refine (which holds the image) rather than the frame: the frame-by-frame deletes decide.
  @Test func aStepRecordingARefinedFrameNextToTheRefineDeletesFrameByFrame() async throws {
    var built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips["C2"])
    let template = Project(url: built.url)
    let first = try await Self.refine(template, "R1", of: frames[4], into: &built)
    let second = try await Self.refine(template, "R2", of: first, at: 4, into: &built)
    await template.setRecordedParentForTests(frames[4], ofStepOf: second)
    await template.close()
    try await Self.expectFallback(frames, in: built)
  }

  /// Clip X (frames at 1...4 on lineage 0) and branches whose renumbering differs: P on lineage 1
  /// (3...5) and C on lineage 4 (3...7) have steps at 3, where X's third frame goes, and B on
  /// lineage 2 (4...7) doesn't, so deleting that frame moves B down and not P or C; D on lineage
  /// 3 (6...7), below C, has none at 4, where X's last frame goes, so deleting that one moves D
  /// down and not C.
  private static func buildStaged() async throws -> Built {
    let folder = try folder()
    var built = Built(folder: folder, url: folder.appending(path: "Template.sqlite3"))
    let project = Project(url: built.url)
    let a = try await image(project, "A", after: nil, into: &built)
    let frames = try await clip(project, "X", frames: 4, after: a, into: &built)
    var last = try await image(project, "P1", after: frames[1], into: &built)
    for index in 2...3 { last = try await image(project, "P\(index)", after: last, into: &built) }
    last = try await image(project, "B1", after: built.images["P1"], into: &built)
    for index in 2...4 { last = try await image(project, "B\(index)", after: last, into: &built) }
    last = try await image(project, "D1", after: built.images["B2"], into: &built)
    try await image(project, "D2", after: last, into: &built)
    last = try await image(project, "C1", after: frames[1], into: &built)
    for index in 2...5 { last = try await image(project, "C\(index)", after: last, into: &built) }
    await project.close()
    return built
  }

  /// Where `names`' images sit before X's frames go, then after each frame-by-frame delete down
  /// to (not including) the first frame: the trees the deletes read up to the first frame's.
  private static func stages(of names: [String], in built: Built) async throws -> [[StepID]] {
    let project = try copy(built, "stages-\(UUID().uuidString)")
    let frames = try #require(built.clips["X"])
    var stages: [[StepID]] = []
    for frame in [nil] + frames.dropFirst().reversed().map(Optional.some) {
      if let frame { _ = try await project.delete(tensorId: frame) }
      let tree = await project.read { $0.tree(items: false) }
      var stage: [StepID] = []
      for name in names {
        let image = try #require(built.images[name])
        stage.append(try #require(tree.step(tensorId: image)))
      }
      stages.append(stage)
    }
    await project.close()
    return stages
  }

  /// Whether `recorder` sits one number past `holder` on a lineage at or above it: where the
  /// holder could be its rule's step.
  private static func adjacent(_ recorder: StepID, after holder: StepID) -> Bool {
    recorder.lineage >= holder.lineage && recorder.logicalTime == holder.logicalTime + 1
  }

  /// P3 holds X's first frame's image (a refine of it), and B4 records that image: they're
  /// apart at first, but once X's third frame goes B4 sits right after P3, so B4 could find P3.
  /// The frame-by-frame deletes decide. Without B4's record the clip goes at once.
  @Test func adjacencyOnlyPartwayFallsBack() async throws {
    let built = try await Self.buildStaged()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips["X"])
    let stages = try await Self.stages(of: ["B4", "P3"], in: built)
    #expect(stages.first.map { !Self.adjacent($0[0], after: $0[1]) } == true)
    #expect(stages.contains { Self.adjacent($0[0], after: $0[1]) })
    let holder = try #require(built.images["P3"]), recorder = try #require(built.images["B4"])
    try await Self.edit(built) { try await $0.addLayerForTests(tensorId: frames[0], index: -1, toStepOf: holder) }
    let control = try Self.copy(built, "control")
    #expect(try await control.deleteRun(tensorIds: frames) != nil)
    await control.close()
    try await Self.edit(built) { await $0.setRecordedParentForTests(frames[0], ofStepOf: recorder) }
    try await Self.expectFallback(frames, in: built)
  }

  /// The mirror: D1 holds the image and C5 records it, right after D1 at first; once X's last
  /// frame goes, D1 moves down and C5 doesn't, and they never meet again. Still frame by frame.
  @Test func adjacencyOnlyAtFirstFallsBack() async throws {
    let built = try await Self.buildStaged()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let frames = try #require(built.clips["X"])
    let stages = try await Self.stages(of: ["C5", "D1"], in: built)
    #expect(stages.first.map { Self.adjacent($0[0], after: $0[1]) } == true)
    #expect(!stages.dropFirst().contains { Self.adjacent($0[0], after: $0[1]) })
    let holder = try #require(built.images["D1"]), recorder = try #require(built.images["C5"])
    try await Self.edit(built) { try await $0.addLayerForTests(tensorId: frames[0], index: -1, toStepOf: holder) }
    let control = try Self.copy(built, "control")
    #expect(try await control.deleteRun(tensorIds: frames) != nil)
    await control.close()
    try await Self.edit(built) { await $0.setRecordedParentForTests(frames[0], ofStepOf: recorder) }
    try await Self.expectFallback(frames, in: built)
  }

  /// A deleted step that recorded no parent isn't written back: the last step on its lineage, so
  /// no step moves into its key to cover it.
  @Test func deletingAStepWithoutAParentLinkLeavesItGone() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var built = Built(folder: folder, url: folder.appending(path: "Steps.sqlite3"))
    let project = Project(url: built.url)
    let a = try await Self.image(project, "A", after: nil, into: &built)
    let b = try await Self.image(project, "B", after: a, into: &built)
    await project.forgetParentLinks()
    _ = try await project.delete(tensorId: b)
    let contents = project.contents()
    #expect(contents.nodes.map(\.textPrompt) == ["A"])
    #expect(!contents.nodes.contains { $0.lineage == 0 && $0.logicalTime == 1 })
    #expect(contents.layers.map(\.tensorId) == [a])
    #expect(!contents.tensorNames.contains("tensor_history_\(b)"))
    await project.close()
  }

  /// And one in the middle: the step moving into its key keeps it.
  @Test func deletingAStepWithoutAParentLinkKeepsTheNextStep() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var built = Built(folder: folder, url: folder.appending(path: "Steps.sqlite3"))
    let project = Project(url: built.url)
    var last: Int64?
    for name in ["A", "B", "C", "D"] {
      last = try await Self.image(project, name, after: last, into: &built)
    }
    await project.forgetParentLinks()
    let b = try #require(built.images["B"])
    _ = try await project.delete(tensorId: b)
    let contents = project.contents()
    #expect(contents.nodes.map(\.textPrompt) == ["A", "C", "D"])
    #expect(contents.nodes.map(\.logicalTime) == [0, 1, 2])
    #expect(contents.layers.map(\.tensorId) == ["A", "C", "D"].map { built.images[$0] })
    #expect(!contents.tensorNames.contains("tensor_history_\(b)"))
    await project.close()
  }

  @Test func framesThatArentARunDeleteFrameByFrame() async throws {
    let built = try await Self.build()
    defer { try? FileManager.default.removeItem(at: built.folder) }
    let old = try Self.copy(built, "old")
    let new = try Self.copy(built, "new")
    // Out of order, and from two clips.
    let c2 = try #require(built.clips["C2"])
    #expect(try await new.deleteRun(tensorIds: [c2[1], c2[0]]) == nil)
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
