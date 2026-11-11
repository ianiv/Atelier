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
      let match = ColorMatch.Job(
        project: "P", sourceTensorId: 12, options: .init(tint: 0.75, saturation: 0.5, brightness: 0.4, contrast: 0.2, unchangedOnly: true))
      let json = try #require(String(data: JSONEncoder().encode(match), encoding: .utf8))
      try write([entry(colorMatch: json)], to: folder)
      let jobs = SavedQueue.load(project: "Other", from: folder)
      #expect(jobs.count == 1)
      #expect(jobs.first?.colorMatch == match)
    }
  }

  /// `ColorMatch.Job` round-trips through the queue's JSON, its record and shift included.
  @Test func aColorMatchJobRoundTrips() throws {
    var match = ColorMatch.Job(project: "My Project", sourceTensorId: 3)
    match.record = ColorMatch.Record(options: .init(), originalTensorId: 2, shift: .init(l: 0, a: 1, b: -4))
    #expect(try JSONDecoder().decode(ColorMatch.Job.self, from: JSONEncoder().encode(match)) == match)
    match.options = .init(tint: 0.9, saturation: 0.3, brightness: 0.6, contrast: 0.1, unchangedOnly: true)
    match.record?.options = match.options
    match.record?.counted = 0.82
    #expect(try JSONDecoder().decode(ColorMatch.Job.self, from: JSONEncoder().encode(match)) == match)
  }

  /// A queue saved while there were only strength and lightness (on or off) holds `strength` and
  /// `luminance` as true or false, in the job and in its record: the colors read as the strength,
  /// the light as all or none of it.
  @Test func aColorMatchSavedWithLuminanceOnOrOffComesBack() throws {
    try withTestFolder { folder in
      let on = #"{"project":"P","sourceTensorId":12,"strength":0.75,"luminance":true,"record":{"strength":0.75,"luminance":true,"originalTensorId":3}}"#
      let off = #"{"project":"P","sourceTensorId":13,"strength":1,"luminance":false}"#
      try write([entry(colorMatch: on), entry(colorMatch: off)], to: folder)
      let jobs = SavedQueue.load(project: "Other", from: folder)
      #expect(jobs.count == 2)
      #expect(
        jobs.first?.colorMatch
          == ColorMatch.Job(
            project: "P", sourceTensorId: 12, options: .init(tint: 0.75, saturation: 0.75, brightness: 0.75, contrast: 0.75),
            record: ColorMatch.Record(options: .init(strength: 0.75, luminance: 1), originalTensorId: 3)))
      #expect(jobs.last?.colorMatch == ColorMatch.Job(project: "P", sourceTensorId: 13, options: .init()))
    }
  }
}
