@testable import Atelier
import Foundation
import Testing

/// `SavedQueue.load` on a saved queue's files. MGK's `Configuration` has no public initializer and
/// comes only from a loaded model, so a `GenerationEngine.Request` can't be made here and `save`
/// isn't run; `--queue-check` covers the two together with a real model.
struct SavedQueueTests {
  func entry(
    _ id: UUID = UUID(), model: String = "m.ckpt", project: String = "P", hasCanvas: Bool = false,
    weights: [Float] = [], upscale: String? = nil
  ) -> String {
    let weightList = weights.map { "\($0)" }.joined(separator: ",")
    let upscaleField = upscale.map { #","upscale":\#($0)"# } ?? ""
    return """
    {"id":"\(id.uuidString)","model":"\(model)","prompt":"p","negativePrompt":"n","seed":5,\
    "settings":{"steps":{"number":{"_0":4}}},"project":"\(project)","parentTensorId":9,\
    "hasCanvas":\(hasCanvas),"canvasIsImported":false,"moodboardWeights":[\(weightList)]\(upscaleField)}
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
}
