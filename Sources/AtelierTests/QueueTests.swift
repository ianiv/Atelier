@testable import Atelier
import Foundation
import Testing

/// `SavedQueue.load` on a saved queue's files. Each entry names its own project, whose ids it keeps
/// whichever project is open at load; a project that's gone loses its entries (`projectExists`). MGK's `Configuration` has no public initializer and
/// comes only from a loaded model, so a `GenerationEngine.Request` can't be made here and `save`
/// isn't run; `--queue-check` covers the two together with a real model.
@Suite(.tags(.smoke))
struct SavedQueueTests {
  func entry(
    _ id: UUID = UUID(), model: String = "m.ckpt", project: String = "P", hasCanvas: Bool = false,
    weights: [Float] = [], upscale: String? = nil, target: String? = nil, colorMatch: String? = nil, edit: String? = nil
  ) -> String {
    let weightList = weights.map { "\($0)" }.joined(separator: ",")
    let upscaleField = upscale.map { #","upscale":\#($0)"# } ?? ""
    let targetField = (target.map { #","target":\#($0)"# } ?? "") + (colorMatch.map { #","colorMatch":\#($0)"# } ?? "")
      + (edit.map { #","edit":\#($0)"# } ?? "")
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
    withTestFolder { folder in #expect(SavedQueue.load(from: folder, projectExists: { _ in true }).isEmpty) }
  }

  @Test func aBrokenIndexIsNoJobs() throws {
    try withTestFolder { folder in
      try "not json".write(to: folder.appending(path: "index.json"), atomically: true, encoding: .utf8)
      #expect(SavedQueue.load(from: folder, projectExists: { _ in true }).isEmpty)
    }
  }

  @Test func jobsComeBackInOrderWithModelAndSettings() throws {
    try withTestFolder { folder in
      try write([entry(model: "one.ckpt"), entry(model: "two.ckpt")], to: folder)
      let jobs = SavedQueue.load(from: folder, projectExists: { _ in true })
      #expect(jobs.map(\.model) == ["one.ckpt", "two.ckpt"])
      #expect(jobs.first?.settings["steps"] != nil)
    }
  }

  @Test func aQueueSavedWithoutTargetsRunsLocally() throws {
    try withTestFolder { folder in
      try write([entry()], to: folder)
      #expect(SavedQueue.load(from: folder, projectExists: { _ in true }).map(\.target) == [.local])
    }
  }

  @Test func aJobKeepsItsServer() throws {
    try withTestFolder { folder in
      let server = UUID()
      let data = try JSONEncoder().encode(JobTarget.remote(serverID: server))
      let target = try #require(String(data: data, encoding: .utf8))
      try write([entry(target: target)], to: folder)
      #expect(SavedQueue.load(from: folder, projectExists: { _ in true }).map(\.target) == [.remote(serverID: server)])
    }
  }

  @Test func aJobWhoseCanvasIsMissingIsDropped() throws {
    try withTestFolder { folder in
      let kept = UUID()
      try png(at: folder.appending(path: "\(kept)-canvas.png"))
      try write([entry(kept, hasCanvas: true), entry(hasCanvas: true)], to: folder)
      #expect(SavedQueue.load(from: folder, projectExists: { _ in true }).count == 1)
    }
  }

  /// An upscale's source clip is a step of its own project, which it reads whichever is open.
  @Test func anUpscaleComesBackForItsOwnProject() throws {
    try withTestFolder { folder in
      let upscale = #"{"method":"system","scale":2,"sourceTensorId":1}"#
      try write([entry(upscale: upscale)], to: folder)
      let jobs = SavedQueue.load(from: folder, projectExists: { _ in true })
      #expect(jobs.count == 1 && jobs.first?.project == "P")
      // Loading forgets what was saved.
      #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
  }

  /// A reference video's clip is a step of the project it was queued in: the job comes back for
  /// that project, its clip with it.
  @Test func aReferenceVideoComesBackForItsOwnProject() throws {
    try withTestFolder { folder in
      let withReference = entry().replacingOccurrences(of: #""moodboardWeights":[]"#, with: #""moodboardWeights":[],"referenceTensorId":42"#)
      #expect(withReference.contains("referenceTensorId"))
      try write([withReference, entry()], to: folder)
      #expect(SavedQueue.load(from: folder, projectExists: { _ in true }).count == 2)
    }
  }

  /// Each entry keeps its own project and the step it follows there, whichever project is open.
  @Test func eachJobKeepsItsOwnProjectAndSteps() throws {
    try withTestFolder { folder in
      try write([entry(model: "a.ckpt", project: "A"), entry(model: "b.ckpt", project: "B")], to: folder)
      let jobs = SavedQueue.load(from: folder, projectExists: { _ in true })
      #expect(jobs.map(\.project) == ["A", "B"])
      #expect(jobs.allSatisfy { $0.parentTensorId == 9 })
    }
  }

  /// A job whose project is gone (deleted or renamed outside Atelier since) is dropped, and the
  /// rest come back; so is one whose project name couldn't be a project's.
  @Test func aJobWhoseProjectIsGoneIsDropped() throws {
    try withTestFolder { folder in
      try write([entry(model: "a.ckpt", project: "A"), entry(model: "b.ckpt", project: "Gone"), entry(model: "c.ckpt", project: "../x")], to: folder)
      let jobs = SavedQueue.load(from: folder, projectExists: { $0 != "Gone" })
      #expect(jobs.map(\.model) == ["a.ckpt"])
    }
  }

  /// A job saved on a line keeps it and the step that line had reached; one saved before lines
  /// were kept has none, and comes back as before.
  @Test func aLineComesBackWithItsTip() throws {
    try withTestFolder { folder in
      let line = UUID()
      let onLine = entry().replacingOccurrences(of: #""parentTensorId":9"#, with: #""line":"\#(line.uuidString)","lineTip":7"#)
      try write([onLine, entry()], to: folder)
      let jobs = SavedQueue.load(from: folder, projectExists: { _ in true })
      #expect(jobs.first?.line?.id == line && jobs.first?.line?.tip == 7 && jobs.first?.parentTensorId == nil)
      #expect(jobs.last?.line == nil)
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
      let jobs = SavedQueue.load(from: folder, projectExists: { _ in true })
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
      let jobs = SavedQueue.load(from: folder, projectExists: { _ in true })
      #expect(jobs.count == 2)
      #expect(
        jobs.first?.colorMatch
          == ColorMatch.Job(
            project: "P", sourceTensorId: 12, options: .init(tint: 0.75, saturation: 0.75, brightness: 0.75, contrast: 0.75),
            record: ColorMatch.Record(options: .init(strength: 0.75, luminance: 1), originalTensorId: 3)))
      #expect(jobs.last?.colorMatch == ColorMatch.Job(project: "P", sourceTensorId: 13, options: .init()))
    }
  }

  /// An Edit job names its own project, so it comes back whichever project is open, with the step
  /// after which it saves and the data it renders with, embedded in the queue file.
  @Test func anEditComesBackInAnyProjectWithItsData() throws {
    try withTestFolder { folder in
      let edit = EditJobTests.job(project: "P")
      let json = try #require(String(data: JSONEncoder().encode(edit), encoding: .utf8))
      try write([entry(model: "a.ckpt"), entry(edit: json)], to: folder)
      let jobs = SavedQueue.load(from: folder, projectExists: { _ in true })
      #expect(jobs.count == 2)
      #expect(jobs.last?.edit == edit && jobs.last?.edit?.context == EditJobTests.context())
      // Every job's step follows it to its own project.
      #expect(jobs.last?.parentTensorId == 9 && jobs.first?.parentTensorId == 9)
    }
  }

  /// A queue saved before every job named its project stamped each entry with the project open
  /// at the quit: a job naming its own inside (Match Colors, Edit, Extract Depth Map) comes back
  /// for that one, checked like any other; one naming two that disagree is dropped.
  @Test func anOldEntryComesBackForTheProjectItsJobNames() throws {
    try withTestFolder { folder in
      let match = #"{"project":"Own","sourceTensorId":12,"strength":1,"luminance":false}"#
      let depth = #"{"project":"Third","sourceTensorId":12}"#
      let disagreeing = entry(project: "Open", colorMatch: match).replacingOccurrences(
        of: #""moodboardWeights":[]"#, with: #""moodboardWeights":[],"depthMap":\#(depth)"#)
      try write([entry(model: "own.ckpt", project: "Open", colorMatch: match), disagreeing], to: folder)
      var asked: [String] = []
      let jobs = SavedQueue.load(from: folder, projectExists: { asked.append($0); return true })
      #expect(jobs.map(\.project) == ["Own"] && jobs.first?.model == "own.ckpt")
      #expect(asked == ["Own"], "its own project is the one checked")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try write([entry(project: "Open", colorMatch: match)], to: folder)
      #expect(SavedQueue.load(from: folder, projectExists: { $0 == "Open" }).isEmpty, "dropped when its own project is gone")
    }
  }

  /// An entry that doesn't read (an edit of a later version's shape, say) is dropped alone, not
  /// run as a generation, and the rest of the queue comes back.
  @Test func anUnreadableEditDropsOnlyItsJob() throws {
    try withTestFolder { folder in
      try write([entry(model: "a.ckpt"), entry(edit: #"{"project":"P"}"#), entry(model: "b.ckpt")], to: folder)
      let jobs = SavedQueue.load(from: folder, projectExists: { _ in true })
      #expect(jobs.map(\.model) == ["a.ckpt", "b.ckpt"] && jobs.allSatisfy { $0.edit == nil })
    }
  }
}
