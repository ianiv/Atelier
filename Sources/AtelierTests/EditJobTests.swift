@testable import Atelier
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

  /// A record with every field set: real-noise bytes, a LUT, reference measurements.
  private static func record() -> Edit.Record {
    let patch = 4
    let bytes = Data((0..<2 * patch * patch * 3).map { UInt8($0 % 256) })
    return Edit.Record(
      options: look, sourceTensorId: 12, profileName: "night", referenceTensorId: 9, referenceName: "ref.jpg", refWidth: 1080,
      curve: [0.8, 1, 0.9, 0.7], refStats: .init(m: [100, 90, 80], s: [40, 41, 42]),
      realNoise: .init(patch: patch, count: 2, curve: [2, 3, 3, 2], data: bytes),
      referenceLab: .init(mean: [50, 1, 2], std: [20, 5, 6]),
      referenceHistogram: .init(luma: [0.5, 1], red: [0.25, 1], green: [0.75, 1], blue: [1, 1]),
      lut: .init(name: "Film.cube", size: 2, values: (0..<24).map { Float($0) / 24 }))
  }

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

  @Test func optionsRoundTripAndReadMissingKeysAsDefaults() throws {
    let data = try JSONEncoder().encode(Self.look)
    #expect(try JSONDecoder().decode(EditOptions.self, from: data) == Self.look)
    // Saved before a section (or a setting) existed.
    let partial = #"{"grain": {"lum": 5}, "histogram": {}}"#
    let read = try JSONDecoder().decode(EditOptions.self, from: Data(partial.utf8))
    var expected = EditOptions()
    expected.grain.lum = 5
    #expect(read == expected)
  }

  @Test func snappedRoundsAndClamps() {
    var options = EditOptions()
    options.match.tint = 0.3 + 1e-9
    options.grade.exposure = 9
    options.lens.motion = 1_000
    options.lens.angle = 10.04
    options.grain.lum = -2
    let snapped = options.snapped
    #expect(snapped.match.tint == 0.3)
    #expect(snapped.grade.exposure == EditOptions.Grade.exposureRange.upperBound)
    #expect(snapped.lens.motion == EditOptions.Lens.motionRange.upperBound)
    #expect(snapped.lens.angle == 10)
    #expect(snapped.grain.lum == 0)
    #expect(snapped.snapped == snapped)
  }

  @Test func jobAndRecordRoundTrip() throws {
    let job = Edit.Job(project: "Scratch", sourceTensorId: 12, options: Self.look, profileName: "night", referenceTensorId: 9, record: Self.record())
    let decoded = try JSONDecoder().decode(Edit.Job.self, from: JSONEncoder().encode(job))
    #expect(decoded == job)
    #expect(decoded.record.realNoise?.data == Self.record().realNoise?.data)
    #expect(decoded.record.lut?.values == Self.record().lut?.values)
    // A job made without a record starts one from its own fields.
    let plain = Edit.Job(project: "Scratch", sourceTensorId: 3, options: Self.look, profileName: "night")
    #expect(plain.record.sourceTensorId == 3 && plain.record.options == Self.look && plain.record.profileName == "night")
  }

  /// The record as a step's `profile_data` keeps it: snake-case keys, the real noise's and LUT's
  /// bytes back exactly.
  @Test func recordRoundTripsThroughProfileData() throws {
    var profile = ProjectMapping.Profile(duration: 1, inputTensorId: 12, parentTensorId: 12)
    profile.edit = Self.record()
    let read = try #require(ProjectMapping.Profile(profile.bytes))
    #expect(read.edit == Self.record())
    let text = String(decoding: profile.bytes, as: UTF8.self)
    #expect(text.contains(#""edit":"#) && text.contains(#""real_noise":"#))
    // A step without one reads as none.
    let plain = try #require(ProjectMapping.Profile(ProjectMapping.Profile(duration: 1, inputTensorId: nil, parentTensorId: 0).bytes))
    #expect(plain.edit == nil)
  }

  @Test func sameEditComparesWhatMakesTheImage() {
    let job = Edit.Job(project: "P", sourceTensorId: 1, options: Self.look, profileName: "night", record: Self.record())
    // Numbers that snap to the same look are the same edit.
    var nudged = Self.look
    nudged.match.tint += 1e-6
    let same = Edit.Job(project: "P", sourceTensorId: 1, options: nudged, profileName: "night", record: Self.record())
    #expect(job.isSameEdit(as: same))
    var other = Self.look
    other.grain.seed = 8
    #expect(!job.isSameEdit(as: Edit.Job(project: "P", sourceTensorId: 1, options: other, profileName: "night", record: Self.record())))
    #expect(!job.isSameEdit(as: Edit.Job(project: "Q", sourceTensorId: 1, options: Self.look, profileName: "night", record: Self.record())))
    #expect(!job.isSameEdit(as: Edit.Job(project: "P", sourceTensorId: 2, options: Self.look, profileName: "night", record: Self.record())))
    // Another LUT table or other real noise under the same names makes another image.
    var otherLUT = Self.record()
    otherLUT.lut = Edit.LUTTable(name: "Film.cube", size: 2, values: [Float](repeating: 0.5, count: 24))
    #expect(!job.isSameEdit(as: Edit.Job(project: "P", sourceTensorId: 1, options: Self.look, profileName: "night", record: otherLUT)))
    var otherNoise = Self.record()
    otherNoise.realNoise?.data[0] = 200
    #expect(!job.isSameEdit(as: Edit.Job(project: "P", sourceTensorId: 1, options: Self.look, profileName: "night", record: otherNoise)))
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
