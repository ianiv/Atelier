@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// The Edit screen's shared contracts: its options, queued job and saved record coding and
/// comparing as the queue and project files need, and grain.py's box blur (`Blur`).
struct EditJobTests {
  /// A look with every section away from its defaults.
  private static let look = EditOptions(
    match: .init(target: .original, tint: 0.5, saturation: 0.25, brightness: 0.1, contrast: 0.2, colour: 0.6),
    histogram: .init(amount: 0.4, space: .rgb),
    grade: .init(exposure: 0.5, temperature: -20, tint: 6, contrast: 0.1, saturation: -0.2, vibrance: 0.3),
    lut: .init(name: "Film.cube", digest: "abc", strength: 0.7),
    halation: .init(amount: 0.3, threshold: 0.7, radius: 30, warmth: 0.9),
    lens: .init(motion: 18, angle: 10, blur: 2),
    vignette: .init(amount: 0.4, size: 0.6, softness: 0.3),
    grain: .init(lum: 11, size: 1.3, chroma: 3.5, csize: 2.4, real: 1.4, seed: 42))

  /// A context with everything loaded: real-noise bytes, a LUT, reference measurements.
  static func context(noiseByte: UInt8 = 0, lutValue: Float? = nil) -> EditPipeline.Context {
    let patch = 4
    var bytes = Data((0..<2 * patch * patch * 3).map { UInt8($0 % 256) })
    bytes[0] = noiseByte
    return EditPipeline.Context(
      refWidth: 1080, curve: [0.8, 1, 0.9, 0.7], refStats: .init(m: [100, 90, 80], s: [40, 41, 42]),
      realNoise: .init(patch: patch, count: 2, curve: [2, 3, 3, 2], data: bytes),
      referenceLab: .init(mean: [50, 1, 2], std: [20, 5, 6]),
      referenceHistogram: .init(luma: [0.5, 1], red: [0.25, 1], green: [0.75, 1], blue: [1, 1]),
      lut: .init(name: "Film.cube", size: 2, values: lutValue.map { [Float](repeating: $0, count: 24) } ?? (0..<24).map { Float($0) / 24 }))
  }

  static func job(project: String = "Scratch", source: Int64 = 12, options: EditOptions = look, context: EditPipeline.Context = context())
    -> Edit.Job
  {
    Edit.Job(
      project: project, sourceTensorId: source, options: options, profileName: "night", referenceTensorId: 9,
      referenceName: "ref.jpg", context: context)
  }

  /// A record with every field set.
  private static func record() -> Edit.Record { job().record }

  @Test func defaultsAreGrainPyAndIdentityIsANoOp() {
    let defaults = EditOptions()
    // grain.py's DEFAULTS.
    #expect(defaults.lens.blur == 3 && defaults.lens.motion == 0 && defaults.lens.angle == 0)
    #expect(defaults.grain == EditOptions.Grain(lum: 9, size: 1, chroma: 3, csize: 1, real: 0, seed: 7))
    #expect(defaults.match.colour == 0 && defaults.grade.tint == 0 && defaults.grade.exposure == 0)
    #expect(!defaults.isIdentity && !defaults.grain.isIdentity && !defaults.lens.isIdentity)
    // Every other section does nothing at its defaults.
    #expect(defaults.match.isIdentity && defaults.histogram.isIdentity && defaults.grade.isIdentity)
    #expect(defaults.lut.isIdentity && defaults.halation.isIdentity && defaults.vignette.isIdentity)
    #expect(defaults.histogram.space == .luma)
    #expect(EditOptions.identity.isIdentity && EditOptions.identity.grain.seed == 7)
    // grain.py's thresholds: no smear at 1 px, no blur below sigma 0.3.
    #expect(EditOptions.Lens(motion: 1, blur: 0.29).isIdentity && !EditOptions.Lens(motion: 1.5, blur: 0).isIdentity)
    #expect(!Self.look.isIdentity)
  }

  @Test func optionsRoundTripAndReadMissingKeysAsNoChange() throws {
    let data = try JSONEncoder().encode(Self.look)
    #expect(try JSONDecoder().decode(EditOptions.self, from: data) == Self.look)
    #expect(EditOptions.grainDefaults == EditOptions())
    // Saved before a section (or a setting) existed, or an agent's partial look: what isn't
    // named does nothing, not grain.py's blur and grain.
    let partial = #"{"grain": {"lum": 5}, "histogram": {}}"#
    let read = try JSONDecoder().decode(EditOptions.self, from: Data(partial.utf8))
    var expected = EditOptions.identity
    expected.grain.lum = 5
    #expect(read == expected)
    #expect(try JSONDecoder().decode(EditOptions.self, from: Data("{}".utf8)) == .identity)
    // Laid over another look, the rest stays that look's.
    var over = Self.look
    over.grain.lum = 5
    #expect(try EditOptions.decoded(from: Data(partial.utf8), over: Self.look) == over)
    // A LUT key replaces the name and digest together.
    let lut = try EditOptions.decoded(from: Data(#"{"lut": {"name": "Other.cube"}}"#.utf8), over: Self.look)
    #expect(lut.lut.name == "Other.cube" && lut.lut.digest == nil && lut.lut.strength == Self.look.lut.strength)
    // A bad value or an unknown case is no change, not a failure.
    let odd = #"{"match": {"target": "somewhere", "tint": 0.5}, "histogram": {"space": "lab", "amount": "lots"}, "grain": 3}"#
    let lenient = try JSONDecoder().decode(EditOptions.self, from: Data(odd.utf8))
    #expect(lenient.match.target == .reference && lenient.match.tint == 0.5)
    #expect(lenient.histogram == EditOptions.Histogram() && lenient.grain == EditOptions.Grain.identity)
  }

  /// Blends keep to 0–1; grain.py's own settings are only rounded (and kept from going
  /// below zero where that means nothing), as grain.py doesn't cap them.
  @Test func snappedRoundsAndClampsOnlyBlends() {
    var options = EditOptions()
    options.match.tint = 0.3 + 1e-9
    options.match.saturation = 3
    options.grade.exposure = 9
    options.grade.tint = -45.04
    options.lens.motion = 1_000
    options.lens.angle = 270.04
    options.grain.lum = 75
    options.grain.chroma = -2
    options.grain.size = 0
    let snapped = options.snapped
    #expect(snapped.match.tint == 0.3 && snapped.match.saturation == 1)
    #expect(snapped.grade.exposure == 9 && snapped.grade.tint == -45)
    #expect(snapped.lens.motion == 1_000 && snapped.lens.angle == 270)
    #expect(snapped.grain.lum == 75 && snapped.grain.chroma == 0 && snapped.grain.size == EditOptions.Grain.smallestSize)
    #expect(snapped.snapped == snapped)
    options.grade.exposure = .nan
    #expect(options.snapped.grade.exposure == 0)
  }

  /// The queued job carries the data itself (the queue file keeps it), the record only digests.
  @Test func jobAndRecordRoundTrip() throws {
    let job = Self.job()
    let decoded = try JSONDecoder().decode(Edit.Job.self, from: JSONEncoder().encode(job))
    #expect(decoded == job)
    #expect(decoded.blobs.realNoise?.data == Self.context().realNoise?.data)
    #expect(decoded.blobs.lut?.values == Self.context().lut?.values)
    #expect(decoded.context == Self.context())
    // The job's fields are the record's.
    #expect(job.sourceTensorId == 12 && job.record.options == Self.look && job.profileName == "night" && job.referenceTensorId == 9)
    var moved = job
    moved.sourceTensorId = 4
    #expect(moved.record.sourceTensorId == 4)
    #expect(job.record.realNoise?.digest == Self.context().realNoise?.digest && job.record.realNoise?.id == nil)
    #expect(job.record.lut?.name == "Film.cube" && job.record.lut?.size == 2)
    // Data that isn't what the record names is left out of the context.
    #expect(job.record.context(with: Edit.Blobs(Self.context(noiseByte: 9))).realNoise == nil)
  }

  /// The record as a step's `profile_data` keeps it: snake-case keys, small, with the data's
  /// digests and none of the data.
  @Test func recordRoundTripsThroughProfileDataWithoutItsData() throws {
    var record = Self.record()
    record.realNoise?.id = 3_000_000_001
    record.lut?.id = 3_000_000_002
    record.referenceHistogram?.id = 3_000_000_003
    var profile = ProjectMapping.Profile(duration: 1, inputTensorId: 12, parentTensorId: 12)
    profile.edit = record
    let read = try #require(ProjectMapping.Profile(profile.bytes))
    #expect(read.edit == record)
    let text = String(decoding: profile.bytes, as: UTF8.self)
    #expect(text.contains(#""edit":"#) && text.contains(#""real_noise":"#) && text.contains(#""version":1"#))
    #expect(!text.contains(#""data":"#) && profile.bytes.count < 4_000)
    #expect(record.tensorNames == ["edit_noise_3000000001", "edit_histogram_3000000003", "edit_lut_3000000002"])
    // A step without one reads as none.
    let plain = try #require(ProjectMapping.Profile(ProjectMapping.Profile(duration: 1, inputTensorId: nil, parentTensorId: 0).bytes))
    #expect(plain.edit == nil)
  }

  /// A record written by a later version, with a setting this one doesn't know, reads as well
  /// as it can, and never costs the step its parent or input.
  @Test func anUnreadableEditKeepsTheRestOfTheProfile() throws {
    var profile = ProjectMapping.Profile(duration: 2, inputTensorId: 12, parentTensorId: 7)
    profile.edit = Self.record()
    var object = try #require(try JSONSerialization.jsonObject(with: Data(profile.bytes)) as? [String: Any])
    var edit = try #require(object["edit"] as? [String: Any])
    var options = try #require(edit["options"] as? [String: Any])
    var histogram = try #require(options["histogram"] as? [String: Any])
    histogram["space"] = "oklab"
    options["histogram"] = histogram
    edit["options"] = options
    edit["version"] = 9
    edit["future"] = ["anything": true]
    object["edit"] = edit
    let read = try #require(ProjectMapping.Profile([UInt8](JSONSerialization.data(withJSONObject: object))))
    #expect(read.parentTensorId == 7 && read.inputTensorId == 12)
    #expect(read.edit?.options.histogram.space == .luma && read.edit?.options.histogram.amount == Self.look.histogram.amount)
    #expect(read.edit?.options.grain == Self.look.grain && read.edit?.version == 9)
    // An edit that can't be read at all (no source step) is left out; the profile stays.
    object["edit"] = ["options": [:] as [String: Any]]
    let noSource = try #require(ProjectMapping.Profile([UInt8](JSONSerialization.data(withJSONObject: object))))
    #expect(noSource.edit == nil && noSource.parentTensorId == 7)
    // So does a colour match of the wrong shape.
    object["color_match"] = "nonsense"
    let badMatch = try #require(ProjectMapping.Profile([UInt8](JSONSerialization.data(withJSONObject: object))))
    #expect(badMatch.colorMatch == nil && badMatch.parentTensorId == 7)
    // A record without options does nothing.
    let bare = try JSONDecoder().decode(Edit.Record.self, from: Data(#"{"sourceTensorId": 3}"#.utf8))
    #expect(bare.options == .identity && bare.version == Edit.Record.currentVersion)
  }

  /// What exported PNGs, shares and `get_image` carry: the slim record, none of the data.
  @Test func theSidecarLeavesOutTheData() throws {
    var item = makeItem(5)
    item.sidecar.edit = Self.record()
    let json = try JSONEncoder().encode(item.sidecar)
    let text = String(decoding: json, as: UTF8.self)
    let noise = try #require(Self.context().realNoise?.data.base64EncodedString())
    let lut = try #require(Self.context().lut?.data.base64EncodedString())
    #expect(text.contains(#""edit":"#) && !text.contains(noise) && !text.contains(lut) && !text.contains(#""data":"#))
    #expect(json.count < 4_000)
    let read = try JSONDecoder().decode(HistoryStore.Sidecar.self, from: json)
    #expect(read.edit == Self.record())
  }

  @Test func sameEditComparesWhatMakesTheImage() {
    let job = Self.job(project: "P", source: 1)
    // Numbers that snap to the same look are the same edit.
    var nudged = Self.look
    nudged.match.tint += 1e-6
    #expect(job.isSameEdit(as: Self.job(project: "P", source: 1, options: nudged)))
    // Saved data (an id) doesn't change the image.
    var saved = Self.job(project: "P", source: 1)
    saved.record.realNoise?.id = 3_000_000_000
    #expect(job.isSameEdit(as: saved))
    var other = Self.look
    other.grain.seed = 8
    #expect(!job.isSameEdit(as: Self.job(project: "P", source: 1, options: other)))
    #expect(!job.isSameEdit(as: Self.job(project: "Q", source: 1)))
    #expect(!job.isSameEdit(as: Self.job(project: "P", source: 2)))
    // Another LUT table or other real noise under the same names makes another image.
    #expect(!job.isSameEdit(as: Self.job(project: "P", source: 1, context: Self.context(lutValue: 0.5))))
    #expect(!job.isSameEdit(as: Self.job(project: "P", source: 1, context: Self.context(noiseByte: 200))))
  }

  /// grain.py's `box_sizes`, worked by hand: sigma 3 has ideal width √37 ≈ 6.08, so 5 and 7, with
  /// m = round(−36 / −24) = round(1.5) = 2 (half to even) passes of 5.
  @Test func boxSizesMatchGrainPy() {
    #expect(Blur.boxSizes(sigma: 3) == [5, 5, 7])
    #expect(Blur.boxSizes(sigma: 1) == [1, 1, 3])
    #expect(Blur.boxSizes(sigma: 2) == [3, 3, 5])
    // √26 ≈ 5.10: 5 and 7, m = round(69 / 24) = round(2.875) = 3.
    #expect(Blur.boxSizes(sigma: 2.5) == [5, 5, 5])
    #expect(Blur.boxSizes(sigma: 6) == [11, 11, 13])
    #expect(Blur.boxSizes(sigma: 8) == [15, 15, 17])
    #expect(Blur.boxSizes(sigma: 0.3) == [1, 1, 1])
  }

  @Test func boxBlurClampsItsEdges() {
    // Radius 1 along a row of 5: [3, 0, 0, 0, 0] has edge pixel 3 repeated on the left.
    let row: [Float] = [3, 0, 0, 0, 6]
    #expect(Blur.boxBlur(row, width: 5, height: 1, radius: 1, horizontal: true) == [2, 1, 0, 2, 4])
    // The same along a column.
    #expect(Blur.boxBlur(row, width: 1, height: 5, radius: 1, horizontal: false) == [2, 1, 0, 2, 4])
    // Radius 0 is no blur, and a flat plane stays flat.
    #expect(Blur.boxBlur(row, width: 5, height: 1, radius: 0, horizontal: true) == row)
    let flat = [Float](repeating: 7, count: 30 * 20)
    #expect(Blur.gauss(flat, width: 30, height: 20, sigma: 3).allSatisfy { abs($0 - 7) < 1e-5 })
    #expect(Blur.gauss(row, width: 5, height: 1, sigma: 0.2) == row)
  }

  /// A centred impulse keeps its total away from the edges, and spreads symmetrically.
  @Test func gaussSpreadsAnImpulseEvenly() {
    let side = 41
    var plane = [Float](repeating: 0, count: side * side)
    plane[20 * side + 20] = 1
    let blurred = Blur.gauss(plane, width: side, height: side, sigma: 3)
    #expect(abs(blurred.reduce(0, +) - 1) < 1e-4)
    #expect(abs(blurred[20 * side + 17] - blurred[20 * side + 23]) < 1e-7)
    #expect(abs(blurred[17 * side + 20] - blurred[20 * side + 17]) < 1e-7)
  }
}

/// An Edit step's real noise, histograms and LUT in the project's tensor store: written once per
/// project for the same data, read back exactly, and gone with the last step naming them.
struct EditProjectDataTests {
  private static func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "EditProjectDataTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private static func append(_ project: Project, after parent: Int64?, _ job: Edit.Job? = nil) async throws -> HistoryItem {
    let tensor = try #require(ImageTensor.tensor(from: CanvasRefineTests.pattern(width: 8, height: 8)))
    return try await project.append(
      tensor: tensor, model: "m", prompt: "p", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(), duration: 0,
      after: parent, edit: job?.record, editBlobs: job?.blobs ?? Edit.Blobs())
  }

  private static func editData(_ project: Project) -> [String] {
    project.contents().tensorNames.filter { $0.hasPrefix("edit_") }
  }

  /// Three edits of one image: the first two with the same profile, reference and LUT, the third
  /// with another LUT. Returns the project and the three steps' images.
  private static func build(_ folder: URL) async throws -> (Project, [Int64]) {
    let project = Project(url: folder.appending(path: "Edits.sqlite3"))
    let source = try await append(project, after: nil)
    let shared = EditJobTests.context()
    let e1 = try await append(project, after: source.tensorId, EditJobTests.job(source: source.tensorId, context: shared))
    let e2 = try await append(project, after: e1.tensorId, EditJobTests.job(source: source.tensorId, context: shared))
    let e3 = try await append(project, after: e2.tensorId, EditJobTests.job(source: source.tensorId, context: EditJobTests.context(lutValue: 0.25)))
    return (project, [e1.tensorId, e2.tensorId, e3.tensorId])
  }

  @Test func theSameDataIsStoredOnceAndReadBackExactly() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (project, edits) = try await Self.build(folder)
    // One noise, one histogram, two LUTs.
    let names = Self.editData(project)
    #expect(names.count { $0.hasPrefix(Edit.StoredNoise.prefix) } == 1)
    #expect(names.count { $0.hasPrefix(Edit.StoredHistogram.prefix) } == 1)
    #expect(names.count { $0.hasPrefix(Edit.StoredLUT.prefix) } == 2)
    let items = await project.read { $0.items() }
    let records = edits.compactMap { id in items.first { $0.tensorId == id }?.sidecar.edit }
    #expect(records.count == 3)
    #expect(records[0].realNoise?.id != nil && records[0].realNoise?.id == records[2].realNoise?.id)
    #expect(records[0].lut?.id == records[1].lut?.id && records[0].lut?.id != records[2].lut?.id)
    // Each renders with exactly what it was queued with.
    #expect(try project.editContext(for: records[0]) == EditJobTests.context())
    #expect(try project.editContext(for: records[2]) == EditJobTests.context(lutValue: 0.25))
    // A record whose data isn't there (or isn't what it names) says so.
    var wrong = records[0]
    wrong.lut?.digest = "00"
    #expect(throws: ProjectError.self) { try project.editContext(for: wrong) }
    var unsaved = records[0]
    unsaved.realNoise?.id = nil
    #expect(throws: ProjectError.self) { try project.editContext(for: unsaved) }
    // A step without any data needs nothing from the store.
    let plain = Edit.Record(options: .identity, sourceTensorId: 1)
    #expect(try project.editContext(for: plain) == EditPipeline.Context())
    await project.close()
  }

  /// Each piece of a record's data is read on its own (`Project.editData(for:)`): a lost LUT
  /// leaves the real noise and histograms, and opening the step turns off only the LUT.
  @Test func eachPieceOfDataIsMissingOnItsOwn() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (project, edits) = try await Self.build(folder)
    let items = await project.read { $0.items() }
    var record = try #require(items.first { $0.tensorId == edits[0] }?.sidecar.edit)
    record.options.match.target = .reference
    let shared = EditJobTests.context()
    let whole = project.editData(for: record)
    #expect(whole.missing.isEmpty && record.context(with: whole.blobs) == shared)

    var noLUT = record
    noLUT.lut?.digest = "00"
    let lutGone = project.editData(for: noLUT)
    #expect(lutGone.missing == .lut)
    #expect(lutGone.blobs.realNoise == shared.realNoise && lutGone.blobs.referenceHistogram == shared.referenceHistogram && lutGone.blobs.lut == nil)
    let look = noLUT.options(without: noLUT.lost(lutGone.missing))
    #expect(look.lut.isIdentity && look.grain.real == record.options.grain.real && look.histogram.amount == record.options.histogram.amount)
    #expect(noLUT.lost(lutGone.missing).note("This edit's") == "This edit's LUT data is missing from the project, so the LUT is off.")

    var noHistogram = record
    noHistogram.referenceHistogram?.id = nil
    let histogramGone = project.editData(for: noHistogram)
    #expect(histogramGone.missing == .referenceHistogram && histogramGone.blobs.lut == shared.lut && histogramGone.blobs.realNoise != nil)
    let unmatched = noHistogram.options(without: noHistogram.lost(histogramGone.missing))
    #expect(unmatched.histogram.amount == 0 && unmatched.grain.real == record.options.grain.real && unmatched.lut == record.options.lut)
    // Matched to the original, which is measured again on opening: nothing is lost.
    var toOriginal = noHistogram
    toOriginal.options.match.target = .original
    #expect(toOriginal.lost(histogramGone.missing).isEmpty)

    var noNoise = record
    noNoise.realNoise?.id = nil
    let noiseGone = project.editData(for: noNoise)
    #expect(noiseGone.missing == .realNoise && noiseGone.blobs.lut == shared.lut)
    #expect(noNoise.options(without: noiseGone.missing).grain.real == 0)

    let plain = Edit.Record(options: .identity, sourceTensorId: 1)
    #expect(project.editData(for: plain).missing.isEmpty)
    await project.close()
  }

  @Test func dataGoesWithTheLastStepNamingIt() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (project, edits) = try await Self.build(folder)
    let all = Self.editData(project)
    _ = try await project.delete(tensorId: edits[0])
    #expect(Self.editData(project) == all)
    _ = try await project.delete(tensorId: edits[1])
    let afterSecond = Self.editData(project)
    #expect(afterSecond.count == 3 && afterSecond.count { $0.hasPrefix(Edit.StoredLUT.prefix) } == 1)
    _ = try await project.delete(tensorId: edits[2])
    #expect(Self.editData(project).isEmpty)
    await project.close()
  }

  /// A run of steps deleted at once (`deleteRun`, as a clip's frames) counts the same way.
  @Test func aDeletedRunCountsTheSteps() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (project, edits) = try await Self.build(folder)
    let items = await project.read { $0.items() }
    let firstLUT = try #require(items.first { $0.tensorId == edits[0] }?.sidecar.edit?.lut?.tensorName)
    #expect(try await project.deleteRun(tensorIds: [edits[1], edits[2]]) != nil)
    let left = Self.editData(project)
    #expect(left.count == 3 && left.contains(firstLUT))
    await project.close()
  }
}

/// The Edit screen's model, the parts that need no window: remembered settings, which step an
/// edited step opens as, and what the zoomed preview renders.
struct EditModelTests {
  @Test func rememberedOptionsRoundTripSnapped() throws {
    var look = EditOptions.grainDefaults
    look.grade.exposure = 0.123456
    look.grain.seed = 99
    look.lut = EditOptions.LUTRef(name: "Film.cube", digest: "abc", strength: 0.5)
    let data = try #require(EditModel.encodeRemembered(look))
    #expect(EditModel.decodeRemembered(data) == look.snapped)
    // A setting missing from what was remembered starts as the default look has it.
    let partial = Data(#"{"grade":{"exposure":1}}"#.utf8)
    var expected = EditOptions.grainDefaults
    expected.grade.exposure = 1
    #expect(EditModel.decodeRemembered(partial) == expected)
    #expect(EditModel.decodeRemembered(Data("not json".utf8)) == EditOptions.grainDefaults)
  }

  @Test func anEditedStepOpensAsItsSource() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "EditModelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(url: folder.appending(path: "Reopen.sqlite3"))
    func append(after parent: Int64?, _ job: Edit.Job? = nil) async throws -> HistoryItem {
      let tensor = try #require(ImageTensor.tensor(from: CanvasRefineTests.pattern(width: 8, height: 8)))
      return try await project.append(
        tensor: tensor, model: "m", prompt: "p", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(), duration: 0,
        after: parent, edit: job?.record, editBlobs: job?.blobs ?? Edit.Blobs())
    }
    let source = try await append(after: nil)
    let edited = try await append(after: source.tensorId, EditJobTests.job(source: source.tensorId))
    let tree = await project.read { $0.tree() }
    let record = try #require(tree.items.values.first { $0.tensorId == edited.tensorId }?.sidecar.edit)
    #expect(EditModel.reopening(record, in: tree)?.tensorId == source.tensorId)
    #expect(record.options == EditJobTests.job().options)
    // Its source gone, there's nothing to go back to.
    _ = try await project.delete(tensorId: source.tensorId)
    let after = await project.read { $0.tree() }
    #expect(EditModel.reopening(record, in: after) == nil)
    await project.close()
  }

  /// An edited step whose record names another edited step (an agent's, or older data) opens
  /// as the first step with no record, so its look isn't put over a look.
  @Test func anEditOfAnEditOpensAsTheFirstSource() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "EditModelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(url: folder.appending(path: "Chain.sqlite3"))
    func append(after parent: Int64?, _ job: Edit.Job? = nil) async throws -> HistoryItem {
      let tensor = try #require(ImageTensor.tensor(from: CanvasRefineTests.pattern(width: 8, height: 8)))
      return try await project.append(
        tensor: tensor, model: "m", prompt: "p", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(), duration: 0,
        after: parent, edit: job?.record, editBlobs: job?.blobs ?? Edit.Blobs())
    }
    let source = try await append(after: nil)
    let first = try await append(after: source.tensorId, EditJobTests.job(source: source.tensorId))
    let second = try await append(after: first.tensorId, EditJobTests.job(source: first.tensorId))
    let tree = await project.read { $0.tree() }
    let record = try #require(tree.items.values.first { $0.tensorId == second.tensorId }?.sidecar.edit)
    #expect(EditModel.reopening(record, in: tree)?.tensorId == source.tensorId)
    let edited = try #require(tree.items.values.first { $0.tensorId == second.tensorId })
    #expect(EditModel.editSource(of: edited, in: tree).tensorId == source.tensorId)
    // With the first source gone, the chain stops at the last step still there.
    _ = try await project.delete(tensorId: source.tensorId)
    let after = await project.read { $0.tree() }
    #expect(EditModel.reopening(record, in: after)?.tensorId == first.tensorId)
    await project.close()
  }

  /// Records that name each other stop at the first step met twice instead of going round.
  @Test func anEditChainStopsAtACycle() {
    var a = makeItem(1), b = makeItem(2), c = makeItem(3)
    a.sidecar.edit = Edit.Record(options: .identity, sourceTensorId: 2)
    b.sidecar.edit = Edit.Record(options: .identity, sourceTensorId: 1)
    c.sidecar.edit = Edit.Record(options: .identity, sourceTensorId: 99)
    let items = [Int64(1): a, 2: b, 3: c]
    #expect(EditModel.editSource(of: a) { items[$0] }.tensorId == 2)
    #expect(EditModel.editSource(of: b) { items[$0] }.tensorId == 1)
    // A source that isn't there leaves the step itself.
    #expect(EditModel.editSource(of: c) { items[$0] }.tensorId == 3)
    #expect(EditModel.editSource(of: makeItem(4)) { items[$0] }.tensorId == 4)
  }

  /// Only the latest open's result goes up: one started earlier is stale once another begins.
  @Test func onlyTheLatestOpenIsCurrent() {
    var opens = OpenGenerations()
    #expect(!opens.anyRequested)
    let restore = opens.begin()
    #expect(opens.isCurrent(restore) && opens.anyRequested)
    let picked = opens.begin()
    #expect(!opens.isCurrent(restore) && opens.isCurrent(picked))
  }

  @Test func missingDataNotesNameEachSetting() {
    #expect(Edit.MissingData().note("x") == nil)
    #expect(
      Edit.MissingData([.realNoise, .lut]).note("Step 3's")
        == "Step 3's real noise and LUT data is missing from the project, so Real Noise and the LUT are off.")
    #expect(
      Edit.MissingData([.realNoise, .referenceHistogram, .lut]).note("This edit's")
        == "This edit's real noise, reference histogram and LUT data is missing from the project, so Real Noise, the histogram match and the LUT are off.")
  }

  /// The look is remembered a while after the last change, not on every one, and at once when
  /// asked (a slider let go, the app going to the background or quitting).
  @MainActor @Test func rememberingWaitsForTheLastChangeAndFlushes() async throws {
    // A wait far longer than the test: only a flush saves.
    var saved: [Int] = []
    let save = DebouncedSave<Int>(delay: .seconds(60)) { saved.append($0) }
    for value in 1...5 { save.schedule(value) }
    await Task.yield()
    #expect(saved.isEmpty && save.hasPending)
    save.flush()
    #expect(saved == [5] && !save.hasPending)
    // Nothing waiting: a flush saves nothing.
    save.flush()
    #expect(saved == [5])
    save.schedule(6)
    save.flush()
    #expect(saved == [5, 6])

    // A short wait: the last value is saved once by itself, and nothing after.
    var waited: [Int] = []
    let quick = DebouncedSave<Int>(delay: .milliseconds(30)) { waited.append($0) }
    quick.schedule(1)
    quick.schedule(2)
    let start = ContinuousClock.now
    while waited.isEmpty, ContinuousClock.now - start < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(waited == [2] && !quick.hasPending)
    try await Task.sleep(for: .milliseconds(100))
    #expect(waited == [2])
  }

  /// The original's side zoomed in draws the part in view: the source's pixels there, at the
  /// window's scale.
  @Test func theOriginalsWindowIsThePartInView() async throws {
    let source = try CanvasRefineTests.pattern(width: 64, height: 48)
    let window = EditPipeline.Window(x: 8, y: 4, width: 32, height: 20)
    let part = try await EditOriginal.window(source, window)
    #expect(part.width == 32 && part.height == 20)
    let whole = try #require(ColorMatch.rgba(source)), cropped = try #require(ColorMatch.rgba(part))
    var differs = 0
    for y in 0..<20 {
      for x in 0..<32 {
        for channel in 0..<4 where whole[((y + 4) * 64 + x + 8) * 4 + channel] != cropped[(y * 32 + x) * 4 + channel] { differs += 1 }
      }
    }
    #expect(differs == 0)
    let half = try await EditOriginal.window(source, EditPipeline.Window(x: 0, y: 0, width: 64, height: 48, scale: 0.5))
    #expect(half.width == 32 && half.height == 24)
    // A deeper source keeps its depth.
    let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let deepContext = try #require(CGContext(
      data: nil, width: 16, height: 16, bitsPerComponent: 16, bytesPerRow: 0, space: p3,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
    deepContext.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
    deepContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let deepSource = try #require(deepContext.makeImage())
    let deep = try await EditOriginal.window(deepSource, EditPipeline.Window(x: 4, y: 4, width: 8, height: 8))
    #expect(deep.bitsPerComponent == 16 && deep.width == 8 && deep.colorSpace?.name == CGColorSpace.displayP3)
  }

  /// The original's window is on a coarser grid, so it covers the edit's and a pan leaves it less often.
  @Test func theOriginalsWindowIsOnACoarserGrid() throws {
    let viewport = EditViewport(
      imageWidth: 6000, imageHeight: 4000, viewSize: CGSize(width: 1280, height: 1410), displayScale: 2, scale: 1, offset: CGSize(width: -333, height: 77))
    let fine = try #require(viewport.window), coarse = try #require(viewport.window(grid: 512))
    #expect(coarse.x % 512 == 0 && coarse.y % 512 == 0)
    #expect(coarse.x <= fine.x && coarse.y <= fine.y)
    #expect(coarse.x + coarse.width >= fine.x + fine.width && coarse.y + coarse.height >= fine.y + fine.height)
  }

  @Test func theFittedPreviewIsEnoughUntilZoomedPastIt() {
    var viewport = EditViewport(imageWidth: 4000, imageHeight: 3000, viewSize: CGSize(width: 800, height: 600), displayScale: 2)
    #expect(viewport.fitScale == 0.4)
    #expect(viewport.fitPixels.width == 1600 && viewport.fitPixels.height == 1200)
    #expect(viewport.window == nil)
    viewport.scale = 1
    // 100%: the middle 1600 × 1200 image pixels are in view, rendered 1:1 with a margin on a grid.
    let window = try? #require(viewport.window)
    #expect(window?.scale == 1)
    #expect(window.map { $0.x <= 1200 && $0.x + $0.width >= 2800 && $0.x % 64 == 0 } == true)
    #expect(window.map { $0.y <= 900 && $0.y + $0.height >= 2100 } == true)
    // Drawn where that part of the image is.
    if let window {
      let frame = viewport.frame(of: window)
      #expect(abs(frame.minX - (400 - 1000 + Double(window.x) / 2)) < 1e-9)
    }
    // A small image already shown 1:1 fitted needs no window when zoomed to 100%.
    let small = EditViewport(imageWidth: 400, imageHeight: 300, viewSize: CGSize(width: 800, height: 600), displayScale: 2, scale: 1)
    #expect(small.window == nil)
  }
}
