@testable import Atelier
import Foundation
import Testing

/// `SavedQueue.load` on a saved queue's files. MGK's `Configuration` has no public initializer and
/// comes only from a loaded model, so a `GenerationEngine.Request` can't be made here and `save`
/// isn't run; `--queue-check` covers the two together with a real model.
struct SavedQueueTests {
  func entry(
    _ id: UUID = UUID(), model: String = "m.ckpt", project: String = "P", hasCanvas: Bool = false,
    weights: [Float] = [], upscale: String? = nil, target: String? = nil, colorMatch: String? = nil
  ) -> String {
    let weightList = weights.map { "\($0)" }.joined(separator: ",")
    let upscaleField = upscale.map { #","upscale":\#($0)"# } ?? ""
    let targetField = (target.map { #","target":\#($0)"# } ?? "") + (colorMatch.map { #","colorMatch":\#($0)"# } ?? "")
    return """
    {"id":"\(id.uuidString)","model":"\(model)","prompt":"p","negativePrompt":"n","seed":5,\
    "settings":{"steps":{"number":{"_0":4}}},"project":"\(project)","parentTensorId":9,\
    "hasCanvas":\(hasCanvas),"canvasIsImported":false,"moodboardWeights":[\(weightList)]\(upscaleField)\(targetField)}
    """
  }

  func write(_ entries: [String], to folder: URL) throws {
    try "[\(entries.joined(separator: ","))]".write(
      to: folder.appending(path: "index.json"), atomically: true, encoding: .utf8)
  }

  func png(at url: URL) throws {
    try #require(ImageTensor.png(smallImage())).write(to: url)
  }

  @Test func nothingSavedIsNoJobs() {
    withTestFolder { folder in #expect(SavedQueue.load(project: "P", from: folder).isEmpty) }
  }

  @Test func aBrokenIndexIsNoJobs() throws {
    try withTestFolder { folder in
      try "not json".write(to: folder.appending(path: "index.json"), atomically: true, encoding: .utf8)
      #expect(SavedQueue.load(project: "P", from: folder).isEmpty)
    }
  }

  @Test func jobsComeBackInOrderWithModelAndSettings() throws {
    try withTestFolder { folder in
      try write([entry(model: "one.ckpt"), entry(model: "two.ckpt")], to: folder)
      let jobs = SavedQueue.load(project: "P", from: folder)
      #expect(jobs.map(\.model) == ["one.ckpt", "two.ckpt"])
      #expect(jobs.first?.settings["steps"] != nil)
    }
  }

  @Test func aQueueSavedWithoutTargetsRunsLocally() throws {
    try withTestFolder { folder in
      try write([entry()], to: folder)
      #expect(SavedQueue.load(project: "P", from: folder).map(\.target) == [.local])
    }
  }

  @Test func aJobKeepsItsServer() throws {
    try withTestFolder { folder in
      let server = UUID()
      let data = try JSONEncoder().encode(JobTarget.remote(serverID: server))
      let target = try #require(String(data: data, encoding: .utf8))
      try write([entry(target: target)], to: folder)
      #expect(SavedQueue.load(project: "P", from: folder).map(\.target) == [.remote(serverID: server)])
    }
  }

  @Test func aJobWhoseCanvasIsMissingIsDropped() throws {
    try withTestFolder { folder in
      let kept = UUID()
      try png(at: folder.appending(path: "\(kept)-canvas.png"))
      try write([entry(kept, hasCanvas: true), entry(hasCanvas: true)], to: folder)
      #expect(SavedQueue.load(project: "P", from: folder).count == 1)
    }
  }

  @Test func anUpscaleOnlyComesBackInItsOwnProject() throws {
    try withTestFolder { folder in
      let upscale = #"{"method":"system","scale":2,"sourceTensorId":1}"#
      try write([entry(upscale: upscale)], to: folder)
      #expect(SavedQueue.load(project: "Other", from: folder).isEmpty)
      // Loading forgets what was saved.
      #expect(!FileManager.default.fileExists(atPath: folder.path))
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try write([entry(upscale: upscale)], to: folder)
      #expect(SavedQueue.load(project: "P", from: folder).count == 1)
    }
  }

  /// A Match Colors to Original job names its own project, so it comes back whichever project is
  /// open, with its step, options and the step after which it saves.
  @Test func aColorMatchComesBackInAnyProject() throws {
    try withTestFolder { folder in
      let match = ColorMatch.Job(project: "P", sourceTensorId: 12, strength: 0.75, luminance: true)
      let json = try #require(String(data: JSONEncoder().encode(match), encoding: .utf8))
      try write([entry(colorMatch: json)], to: folder)
      let jobs = SavedQueue.load(project: "Other", from: folder)
      #expect(jobs.count == 1)
      #expect(jobs.first?.colorMatch == match)
    }
  }

  /// `ColorMatch.Job` round-trips through the queue's JSON, its record and shift included.
  @Test func aColorMatchJobRoundTrips() throws {
    var match = ColorMatch.Job(project: "My Project", sourceTensorId: 3, strength: 1, luminance: false)
    match.record = ColorMatch.Record(strength: 1, luminance: false, originalTensorId: 2, shift: .init(l: 0, a: 1, b: -4))
    #expect(try JSONDecoder().decode(ColorMatch.Job.self, from: JSONEncoder().encode(match)) == match)
  }
}
