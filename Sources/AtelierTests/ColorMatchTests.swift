import Accelerate
@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// Match Colors to Original's color math (`ColorMatch`): the sRGB ↔ Lab conversion against known
/// values and round trips, and the Reinhard transfer on synthetic shifts.
struct ColorMatchTests {
  /// A fixed sequence, so failures repeat.
  private struct Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state
    }
  }

  /// `count` random opaque mid-tone pixels (kept away from the gamut's edges, so shifting them
  /// doesn't clip).
  private func pixels(_ count: Int, seed: UInt64 = 1) -> [UInt8] {
    var generator = Generator(state: seed)
    var out: [UInt8] = []
    for _ in 0..<count {
      for _ in 0..<3 { out.append(UInt8.random(in: 50...200, using: &generator)) }
      out.append(255)
    }
    return out
  }

  /// The pixels with `delta` added to their Lab channels (L, a, b).
  private func shifted(_ rgba: [UInt8], by delta: SIMD3<Double>) -> [UInt8] {
    var planes = ColorMatch.lab(rgba: rgba)
    planes.l = planes.l.map { $0 + delta.x }
    planes.a = planes.a.map { $0 + delta.y }
    planes.b = planes.b.map { $0 + delta.z }
    return ColorMatch.encoded(lab: planes, alpha: stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] })
  }

  private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
  }

  @Test func labRoundTripsWithinOneLevel() {
    var colors: [UInt8] = []
    for level in 0...255 { colors += [UInt8(level), UInt8(level), UInt8(level), 255] }
    var generator = Generator(state: 7)
    for _ in 0..<2000 {
      for _ in 0..<3 { colors.append(UInt8.random(in: 0...255, using: &generator)) }
      colors.append(255)
    }
    let back = ColorMatch.encoded(lab: ColorMatch.lab(rgba: colors), alpha: [UInt8](repeating: 255, count: colors.count / 4))
    #expect(maxDifference(colors, back) <= 1)
  }

  @Test func knownLabValues() {
    let lab = ColorMatch.lab(rgba: [255, 255, 255, 255, 255, 0, 0, 255, 0, 0, 0, 255])
    // White.
    #expect(abs(lab.l[0] - 100) < 0.01 && abs(lab.a[0]) < 0.01 && abs(lab.b[0]) < 0.01)
    // sRGB red.
    #expect(abs(lab.l[1] - 53.24) < 0.05 && abs(lab.a[1] - 80.09) < 0.05 && abs(lab.b[1] - 67.20) < 0.05)
    // Black.
    #expect(abs(lab.l[2]) < 0.01 && abs(lab.a[2]) < 0.01 && abs(lab.b[2]) < 0.01)
  }

  @Test func removesAWarmShift() {
    let original = pixels(4096)
    let warm = shifted(original, by: SIMD3(0, 1, 6))
    let target = ColorMatch.stats(rgba: warm)
    let reference = ColorMatch.stats(rgba: original)
    let shift = ColorMatch.shift(target: target, reference: reference)
    #expect(abs(shift.b - 6) < 0.3 && abs(shift.a - 1) < 0.3)
    #expect(shift.summary.contains("warmer"))
    let matched = ColorMatch.transferred(rgba: warm, target: target, reference: reference, options: .init())
    let result = ColorMatch.stats(rgba: matched)
    #expect(abs(result.mean.z - reference.mean.z) < 0.2)
    #expect(abs(result.mean.y - reference.mean.y) < 0.2)
    // A uniform shift is undone pixel by pixel, not only on average.
    #expect(maxDifference(matched, original) <= 2)
  }

  @Test func strengthZeroLeavesTheImage() {
    let original = pixels(1000, seed: 3)
    let warm = shifted(original, by: SIMD3(0, -2, 5))
    let matched = ColorMatch.transferred(
      rgba: warm, target: ColorMatch.stats(rgba: warm), reference: ColorMatch.stats(rgba: original),
      options: .init(tint: 0, saturation: 0))
    #expect(maxDifference(matched, warm) <= 1)
  }

  @Test func lightnessIsMatchedOnlyWhenAsked() {
    let original = pixels(2048, seed: 5)
    let brighter = shifted(original, by: SIMD3(8, 0, 4))
    let target = ColorMatch.stats(rgba: brighter)
    let reference = ColorMatch.stats(rgba: original)
    let kept = ColorMatch.stats(rgba: ColorMatch.transferred(rgba: brighter, target: target, reference: reference, options: .init()))
    #expect(abs(kept.mean.x - target.mean.x) < 0.3)
    #expect(abs(kept.mean.z - reference.mean.z) < 0.3)
    let matched = ColorMatch.stats(
      rgba: ColorMatch.transferred(rgba: brighter, target: target, reference: reference, options: .init(brightness: 1, contrast: 1)))
    #expect(abs(matched.mean.x - reference.mean.x) < 0.3)
  }

  @Test func alphaPassesThroughAndTransparentPixelsDontCount() {
    var original = pixels(512, seed: 9)
    for index in stride(from: 3, to: original.count, by: 4) { original[index] = UInt8((index / 4) % 256) }
    let warm = shifted(original, by: SIMD3(0, 0, 5))
    let matched = ColorMatch.transferred(
      rgba: warm, target: ColorMatch.stats(rgba: warm), reference: ColorMatch.stats(rgba: original), options: .init())
    #expect(stride(from: 3, to: matched.count, by: 4).allSatisfy { matched[$0] == warm[$0] })
    // Bright green under alpha 0 changes nothing.
    let visible = pixels(256, seed: 11)
    var hidden = visible
    for _ in 0..<256 { hidden += [0, 255, 0, 0] }
    #expect(ColorMatch.stats(rgba: hidden) == ColorMatch.stats(rgba: visible))
  }

  @Test func matchesWholeImagesThroughTheirThumbnails() throws {
    // Larger than 512 on one side, so the statistics come from the downsampled image.
    let width = 900
    let height = 300
    var original: [UInt8] = []
    for y in 0..<height {
      for x in 0..<width {
        original += [UInt8(60 + x * 120 / width), UInt8(70 + y * 100 / height), UInt8(90 + (x + y) % 80), 255]
      }
    }
    let warm = shifted(original, by: SIMD3(0, 0, 6))
    let originalImage = try #require(ColorMatch.cgImage(rgba: original, width: width, height: height))
    let warmImage = try #require(ColorMatch.cgImage(rgba: warm, width: width, height: height))
    let (matched, shift, counted) = try #require(ColorMatch.matched(warmImage, to: originalImage))
    #expect(matched.width == width && matched.height == height && counted == nil)
    #expect(abs(shift.b - 6) < 0.5)
    let back = try #require(ColorMatch.rgba(matched))
    #expect(abs(ColorMatch.stats(rgba: back).mean.z - ColorMatch.stats(rgba: original).mean.z) < 0.3)
  }

  /// The Queue shows a match's progress from `transferred`, which reports after each slice.
  @Test func transferProgressOnlyGrowsAndEndsAtOne() {
    // Several slices of 65,536 pixels, the last one short.
    let original = pixels(65536 * 3 + 1000)
    let warm = shifted(original, by: SIMD3(0, 0, 4))
    var reports: [Double] = []
    _ = ColorMatch.transferred(
      rgba: warm, target: ColorMatch.stats(rgba: warm), reference: ColorMatch.stats(rgba: original), options: .init()
    ) { reports.append($0) }
    #expect(reports.count >= 4)
    #expect(zip(reports, reports.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(reports.last == 1)
  }

  /// A throw from `progress` stops the transfer, as Stop does to a running match.
  @Test func transferStopsWhenProgressThrows() {
    let original = pixels(65536 * 2)
    var reports = 0
    #expect(throws: CancellationError.self) {
      try ColorMatch.transferred(
        rgba: original, target: ColorMatch.stats(rgba: original), reference: ColorMatch.stats(rgba: original), options: .init()
      ) { _ in
        reports += 1
        throw CancellationError()
      }
    }
    #expect(reports == 1)
  }

  /// What a step records survives `profile_data`'s snake-case coding, shift included.
  @Test func recordRoundTripsWithItsShift() throws {
    let record = ColorMatch.Record(
      options: .init(tint: 0.5, saturation: 0.75, brightness: 0.25, contrast: 0.1, unchangedOnly: true), counted: 0.82,
      originalTensorId: 7, shift: .init(l: 1, a: -2, b: 3.5))
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    #expect(try decoder.decode(ColorMatch.Record.self, from: encoder.encode(record)) == record)
    // Saved before the shift was recorded.
    let old = try decoder.decode(ColorMatch.Record.self, from: Data(#"{"strength":1,"luminance":false}"#.utf8))
    #expect(old.shift == nil && old.originalTensorId == nil && old.counted == nil && old.options == ColorMatch.Options())
  }

  /// The default options (the one-click item's) make the bytes they made when there was one
  /// strength and lightness was on or off: a and b moved by the full transfer, L not touched.
  @Test func defaultOptionsMakeTheSamePixelsAsBefore() {
    let original = pixels(3000, seed: 13)
    let edited = shifted(original, by: SIMD3(5, -1.5, 6))
    let target = ColorMatch.stats(rgba: edited)
    let reference = ColorMatch.stats(rgba: original)
    // The transfer as it was written then, at strength 1 with lightness off.
    var planes = ColorMatch.lab(rgba: edited)
    func moved(_ values: [Double], _ channel: Int) -> [Double] {
      let k = reference.std[channel] / target.std[channel]
      let scale = 1 + 1.0 * (k - 1)
      let offset = 1.0 * (reference.mean[channel] - k * target.mean[channel])
      return vDSP.add(offset, vDSP.multiply(scale, values))
    }
    planes.a = moved(planes.a, 1)
    planes.b = moved(planes.b, 2)
    let before = ColorMatch.encoded(lab: planes, alpha: [UInt8](repeating: 255, count: planes.l.count))
    #expect(ColorMatch.transferred(rgba: edited, target: target, reference: reference, options: .init()) == before)
    #expect(ColorMatch.Options() == ColorMatch.Options(strength: 1, luminance: 0))
    #expect(ColorMatch.Options() == ColorMatch.Options(tint: 1, saturation: 1, brightness: 0, contrast: 0, unchangedOnly: false))
  }

  @Test func halfStrengthTakesOutHalfTheShift() {
    let original = pixels(4096, seed: 15)
    let warm = shifted(original, by: SIMD3(0, 2, 8))
    let target = ColorMatch.stats(rgba: warm)
    let reference = ColorMatch.stats(rgba: original)
    let half = ColorMatch.stats(
      rgba: ColorMatch.transferred(rgba: warm, target: target, reference: reference, options: .init(strength: 0.5)))
    #expect(abs((half.mean.z - reference.mean.z) - 4) < 0.3)
    #expect(abs((half.mean.y - reference.mean.y) - 1) < 0.3)
    #expect(abs(half.mean.x - target.mean.x) < 0.3)
  }

  /// The two settings there were before (`Options.init(strength:luminance:)`): half the lightness
  /// moves mean L halfway, and all of it is what matching lightness did when it was on or off
  /// (the same coefficients, so the same bytes).
  @Test func lightnessMovesByItsAmount() {
    let original = pixels(4096, seed: 17)
    let brighter = shifted(original, by: SIMD3(8, 0, 4))
    let target = ColorMatch.stats(rgba: brighter)
    let reference = ColorMatch.stats(rgba: original)
    let half = ColorMatch.stats(
      rgba: ColorMatch.transferred(rgba: brighter, target: target, reference: reference, options: .init(strength: 1, luminance: 0.5)))
    #expect(abs((half.mean.x - reference.mean.x) - 4) < 0.3)
    // Colors still move all the way.
    #expect(abs(half.mean.z - reference.mean.z) < 0.3)
    // Lightness moves by strength × luminance.
    let quarter = ColorMatch.stats(
      rgba: ColorMatch.transferred(
        rgba: brighter, target: target, reference: reference, options: .init(strength: 0.5, luminance: 0.5)))
    #expect(abs((quarter.mean.x - reference.mean.x) - 6) < 0.3)
    // All of it, as it was written when it was on: every channel by `strength`.
    let strength = 0.75
    var planes = ColorMatch.lab(rgba: brighter)
    func moved(_ values: [Double], _ channel: Int) -> [Double] {
      let k = reference.std[channel] / target.std[channel]
      let scale = 1 + strength * (k - 1)
      let offset = strength * (reference.mean[channel] - k * target.mean[channel])
      return vDSP.add(offset, vDSP.multiply(scale, values))
    }
    planes.l = moved(planes.l, 0)
    planes.a = moved(planes.a, 1)
    planes.b = moved(planes.b, 2)
    let before = ColorMatch.encoded(lab: planes, alpha: [UInt8](repeating: 255, count: planes.l.count))
    let full = ColorMatch.transferred(
      rgba: brighter, target: target, reference: reference, options: .init(strength: strength, luminance: 1))
    #expect(full == before)
  }

  /// The sheet's preview is the job's transfer on the small image, with the full images' statistics.
  @Test func previewRendersAsTheTransferDoes() async throws {
    // Larger than the preview on one side and than the statistics' 512, so both are downsampled.
    let width = 1000
    let height = 400
    var original: [UInt8] = []
    for y in 0..<height {
      for x in 0..<width {
        original += [UInt8(60 + x * 120 / width), UInt8(70 + y * 100 / height), UInt8(90 + (x + y) % 80), 255]
      }
    }
    let warm = shifted(original, by: SIMD3(3, 0, 6))
    let originalImage = try #require(ColorMatch.cgImage(rgba: original, width: width, height: height))
    let warmImage = try #require(ColorMatch.cgImage(rgba: warm, width: width, height: height))
    let preview = try #require(await ColorMatch.Preview.make(edited: warmImage, original: originalImage))
    #expect(preview.width == ColorMatch.Preview.side && preview.height == 307)
    #expect(preview.original.width == preview.width && preview.original.height == preview.height)
    // The statistics the job takes.
    let warmPixels = try #require(ColorMatch.rgba(warmImage))
    let originalPixels = try #require(ColorMatch.rgba(originalImage))
    #expect(preview.measurements.reason == nil && preview.measurements.unchanged?.counted == 1)
    #expect(preview.target == ColorMatch.stats(rgba: ColorMatch.downsampled(warmPixels, width: width, height: height)))
    #expect(preview.reference == ColorMatch.stats(rgba: ColorMatch.downsampled(originalPixels, width: width, height: height)))
    #expect(abs(preview.shift.b - 6) < 0.5)
    for options in [ColorMatch.Options(), ColorMatch.Options(tint: 0.4, saturation: 0.9, brightness: 0.7, contrast: 0.2)] {
      let rendered = try #require(preview.render(options))
      let expected = ColorMatch.transferred(rgba: preview.pixels, target: preview.target, reference: preview.reference, options: options)
      #expect(ColorMatch.rgba(rendered) == expected)
      let concurrent = try #require(try await preview.rendering(options))
      #expect(ColorMatch.rgba(concurrent) == expected)
    }
  }

  /// Steps saved while there were two settings hold `strength`, and `luminance` as true, false or
  /// an amount: they read as the four the same match is made with now.
  @Test func recordReadsTheSettingsThereWereBefore() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    func options(_ luminance: String) throws -> ColorMatch.Options {
      let record = try decoder.decode(
        ColorMatch.Record.self, from: Data(#"{"strength":0.5,"luminance":\#(luminance),"original_tensor_id":7}"#.utf8))
      #expect(record.originalTensorId == 7 && record.counted == nil)
      return record.options
    }
    #expect(try options("true") == ColorMatch.Options(tint: 0.5, saturation: 0.5, brightness: 0.5, contrast: 0.5))
    #expect(try options("false") == ColorMatch.Options(tint: 0.5, saturation: 0.5, brightness: 0, contrast: 0))
    #expect(try options("0.5") == ColorMatch.Options(tint: 0.5, saturation: 0.5, brightness: 0.25, contrast: 0.25))
    // The four, where they're there, are what counts.
    let both = try decoder.decode(
      ColorMatch.Record.self,
      from: Data(#"{"strength":0.5,"luminance":true,"tint":0.2,"saturation":0.3,"brightness":0.4,"contrast":0.6,"unchanged_only":true,"counted":0.8}"#.utf8))
    #expect(both.options == ColorMatch.Options(tint: 0.2, saturation: 0.3, brightness: 0.4, contrast: 0.6, unchangedOnly: true))
    #expect(both.counted == 0.8)
  }

  /// A copy of Atelier from before the four settings reads a step's record as this (and fails to
  /// read the step's whole profile if it can't): `strength` a number, `luminance` true or false.
  /// Whatever the settings, what's written now still reads that way.
  @Test func newRecordsStillReadAsTheOldShape() throws {
    struct OldRecord: Codable {
      var strength: Double
      var luminance: Bool
      var originalTensorId: Int64?
      var shift: ColorMatch.Shift?
    }
    struct OldJob: Codable {
      var project: String
      var sourceTensorId: Int64
      var strength: Double
      var luminance: Bool
      var record: OldRecord?
    }
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let cases: [(ColorMatch.Options, Double, Bool)] = [
      (.init(), 1, false),
      (.init(tint: 0.4, saturation: 0.9, brightness: 0.35, contrast: 0, unchangedOnly: true), 0.4, true),
      (.init(tint: 0.7, saturation: 0, brightness: 0, contrast: 0.2), 0.7, true),
      (.init(strength: 1, luminance: 1), 1, true),
    ]
    for (options, strength, luminance) in cases {
      let record = ColorMatch.Record(options: options, counted: 0.6, originalTensorId: 9, shift: .init(l: 0, a: 1, b: 2))
      let old = try decoder.decode(OldRecord.self, from: encoder.encode(record))
      #expect(old.strength == strength && old.luminance == luminance && old.originalTensorId == 9 && old.shift == record.shift)
      // The saved queue's coding, with plain keys.
      let job = ColorMatch.Job(project: "P", sourceTensorId: 4, options: options, record: record)
      let oldJob = try JSONDecoder().decode(OldJob.self, from: JSONEncoder().encode(job))
      #expect(oldJob.strength == strength && oldJob.luminance == luminance && oldJob.record?.strength == strength)
      // And as itself.
      #expect(try decoder.decode(ColorMatch.Record.self, from: encoder.encode(record)) == record)
    }
  }

  /// The same step with other settings is another match, and may queue beside the first; the same
  /// settings, however their numbers were arrived at, are the same match.
  @Test func isSameMatchComparesSettings() {
    func job(_ options: ColorMatch.Options = .init(), project: String = "P", tensor: Int64 = 4) -> ColorMatch.Job {
      ColorMatch.Job(project: project, sourceTensorId: tensor, options: options)
    }
    let match = job()
    #expect(match.isSameMatch(as: match))
    #expect(!match.isSameMatch(as: job(.init(tint: 0.5))))
    #expect(!match.isSameMatch(as: job(.init(saturation: 0.5))))
    #expect(!match.isSameMatch(as: job(.init(brightness: 0.5))))
    #expect(!match.isSameMatch(as: job(.init(contrast: 0.5))))
    #expect(!match.isSameMatch(as: job(.init(unchangedOnly: true))))
    #expect(!match.isSameMatch(as: job(tensor: 5)))
    #expect(!match.isSameMatch(as: job(project: "Q")))
    // Within the same whole percent.
    let third = job(.init(tint: 0.1 + 0.2, saturation: 0.7, brightness: 0.2, contrast: 0.4))
    #expect(third.isSameMatch(as: job(.init(tint: 0.3, saturation: 0.7000001, brightness: 0.2001, contrast: 0.3999))))
    #expect(ColorMatch.Options(tint: 1.4, saturation: -1, brightness: 2, contrast: -0.2).snapped == ColorMatch.Options(tint: 1, saturation: 0, brightness: 1, contrast: 0))
    #expect(
      ColorMatch.Options(tint: 0.256, saturation: 0.254, brightness: 0.016, contrast: 0.994, unchangedOnly: true).snapped
        == ColorMatch.Options(tint: 0.26, saturation: 0.25, brightness: 0.02, contrast: 0.99, unchangedOnly: true))
  }

  // MARK: The four amounts

  /// An edit whose colors and light both moved and spread: every channel's mean shifted and its
  /// range stretched (within the caps), measured against its original.
  private func stretched() -> (edited: [UInt8], target: ColorMatch.Stats, reference: ColorMatch.Stats) {
    // Low-chroma mid tones, so the stretch stays in gamut.
    var generator = Generator(state: 21)
    var original: [UInt8] = []
    for _ in 0..<4096 {
      let grey = Int.random(in: 90...160, using: &generator)
      for _ in 0..<3 { original.append(UInt8(grey + Int.random(in: -12...12, using: &generator))) }
      original.append(255)
    }
    var planes = ColorMatch.lab(rgba: original)
    func moved(_ values: [Double], scale: Double, by offset: Double) -> [Double] {
      let mean = vDSP.mean(values)
      return values.map { mean + ($0 - mean) * scale + offset }
    }
    planes.l = moved(planes.l, scale: 1.25, by: 5)
    planes.a = moved(planes.a, scale: 1.4, by: 3)
    planes.b = moved(planes.b, scale: 1.4, by: 6)
    let edited = ColorMatch.encoded(lab: planes, alpha: [UInt8](repeating: 255, count: planes.l.count))
    return (edited, ColorMatch.stats(rgba: edited), ColorMatch.stats(rgba: original))
  }

  /// Tint moves the color's mean and leaves its spread; saturation the spread and not the mean.
  @Test func tintAndSaturationMoveMeanAndSpreadApart() {
    let (edited, target, reference) = stretched()
    func result(_ options: ColorMatch.Options) -> ColorMatch.Stats {
      ColorMatch.stats(rgba: ColorMatch.transferred(rgba: edited, target: target, reference: reference, options: options))
    }
    // The edit really differs in both.
    #expect(abs(target.mean.z - reference.mean.z) > 4 && target.std.z / reference.std.z > 1.25)
    let tint = result(.init(tint: 1, saturation: 0))
    for channel in 1...2 {
      #expect(abs(tint.mean[channel] - reference.mean[channel]) < 0.2)
      #expect(abs(tint.std[channel] - target.std[channel]) < 0.1)
    }
    let saturation = result(.init(tint: 0, saturation: 1))
    for channel in 1...2 {
      #expect(abs(saturation.mean[channel] - target.mean[channel]) < 0.2)
      #expect(abs(saturation.std[channel] - reference.std[channel]) < 0.1)
    }
    // Neither touches L.
    #expect(abs(tint.mean.x - target.mean.x) < 0.1 && abs(saturation.std.x - target.std.x) < 0.1)
    // Halfway each.
    let half = result(.init(tint: 0.5, saturation: 0.5))
    #expect(abs(half.mean.z - (target.mean.z + reference.mean.z) / 2) < 0.2)
    #expect(abs(half.std.z - (target.std.z + reference.std.z) / 2) < 0.1)
  }

  /// Brightness moves L's mean and leaves its spread; contrast the spread and not the mean.
  @Test func brightnessAndContrastMoveMeanAndSpreadApart() {
    let (edited, target, reference) = stretched()
    func result(_ options: ColorMatch.Options) -> ColorMatch.Stats {
      ColorMatch.stats(rgba: ColorMatch.transferred(rgba: edited, target: target, reference: reference, options: options))
    }
    #expect(abs(target.mean.x - reference.mean.x) > 4 && target.std.x / reference.std.x > 1.15)
    let brightness = result(.init(tint: 0, saturation: 0, brightness: 1, contrast: 0))
    #expect(abs(brightness.mean.x - reference.mean.x) < 0.2)
    #expect(abs(brightness.std.x - target.std.x) < 0.1)
    let contrast = result(.init(tint: 0, saturation: 0, brightness: 0, contrast: 1))
    #expect(abs(contrast.mean.x - target.mean.x) < 0.2)
    #expect(abs(contrast.std.x - reference.std.x) < 0.1)
    // Neither touches the colors.
    #expect(abs(brightness.mean.z - target.mean.z) < 0.15 && abs(contrast.std.z - target.std.z) < 0.15)
  }

  /// The spread's ratio is capped: 2× (and ½) for a and b, 1.5× (and 0.67) for L. Within the
  /// caps it's used as it is.
  @Test func spreadRatioIsCapped() {
    let target = ColorMatch.Stats(mean: SIMD3(50, 4, 8), std: SIMD3(10, 6, 6))
    func scale(_ reference: SIMD3<Double>, _ channel: Int) -> Double {
      ColorMatch.coefficients(
        target: target, reference: ColorMatch.Stats(mean: SIMD3(52, 1, 2), std: reference), channel: channel, mean: 1, spread: 1
      ).scale
    }
    let wide = SIMD3<Double>(50, 30, 30)
    #expect(scale(wide, 0) == 1.5 && scale(wide, 1) == 2.0 && scale(wide, 2) == 2.0)
    let narrow = SIMD3<Double>(1, 0.6, 0.6)
    #expect(scale(narrow, 0) == 0.67 && scale(narrow, 1) == 0.5 && scale(narrow, 2) == 0.5)
    // In range: the ratio itself, as it was computed before there was a cap.
    let near = SIMD3<Double>(13, 9, 4)
    for channel in 0...2 {
      #expect(scale(near, channel) == 1 + 1.0 * (near[channel] / target.std[channel] - 1))
    }
    // The mean still goes all the way to the reference's under a capped spread.
    let capped = ColorMatch.coefficients(
      target: target, reference: ColorMatch.Stats(mean: SIMD3(52, 1, 2), std: wide), channel: 2, mean: 1, spread: 1)
    #expect(abs(target.mean.z * capped.scale + capped.offset - 2) < 1e-9)
    // A flat edit (spread near 0) no longer blows up.
    let flat = ColorMatch.coefficients(
      target: ColorMatch.Stats(mean: SIMD3(50, 4, 8), std: SIMD3(1e-6, 1e-6, 1e-6)),
      reference: ColorMatch.Stats(mean: SIMD3(52, 1, 2), std: wide), channel: 1, mean: 1, spread: 1)
    #expect(flat.scale == 2.0)
  }

  // MARK: Unchanged areas

  /// A smooth picture of mid tones, `width`×`height`.
  private func picture(width: Int, height: Int) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        out += [UInt8(70 + x * 100 / width), UInt8(80 + y * 80 / height), UInt8(90 + (x + y) * 70 / (width + height)), 255]
      }
    }
    return out
  }

  /// `rgba` with a saturated green block over its left `fraction`.
  private func pasted(_ rgba: [UInt8], width: Int, height: Int, over fraction: Double) -> [UInt8] {
    var out = rgba
    let edge = Int((Double(width) * fraction).rounded())
    for y in 0..<height {
      for x in 0..<edge {
        out.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 3, with: [20, 220, 40])
      }
    }
    return out
  }

  /// An edit that pasted something colorful over a fifth of a warm-shifted copy: measured whole,
  /// the block reads as a shift of the whole image; measured where nothing changed, the shift is
  /// the one put in.
  @Test func unchangedAreasLeaveOutWhatTheEditAdded() throws {
    let width = 640
    let height = 480
    let original = picture(width: width, height: height)
    let edited = pasted(shifted(original, by: SIMD3(0, 1, 6)), width: width, height: height, over: 0.2)
    let both = ColorMatch.measurements(edited: edited, width: width, height: height, original: original, width: width, height: height)
    let unchanged = try #require(both.unchanged)
    #expect(both.reason == nil)
    #expect(abs(unchanged.shift.b - 6) < 0.5 && abs(unchanged.shift.a - 1) < 0.5)
    #expect(abs(both.whole.shift.b - 6) > 2 && both.whole.counted == nil)
    #expect(abs(try #require(unchanged.counted) - 0.8) < 0.02)
    // `measure` picks between them, and the job's match reports the same.
    let measured = ColorMatch.measure(
      edited: edited, width: width, height: height, original: original, width: width, height: height, unchangedOnly: true)
    #expect(measured == unchanged)
    #expect(
      ColorMatch.measure(edited: edited, width: width, height: height, original: original, width: width, height: height, unchangedOnly: false)
        == both.whole)
    let editedImage = try #require(ColorMatch.cgImage(rgba: edited, width: width, height: height))
    let originalImage = try #require(ColorMatch.cgImage(rgba: original, width: width, height: height))
    let matched = try #require(ColorMatch.matched(editedImage, to: originalImage, options: .init(unchangedOnly: true)))
    #expect(matched.counted == unchanged.counted && matched.shift == unchanged.shift)
    // The background is back to the original's colors (a column well clear of the block).
    let back = try #require(ColorMatch.rgba(matched.image))
    func column(_ rgba: [UInt8]) -> [UInt8] {
      var out: [UInt8] = []
      for y in 0..<height { out += rgba[(y * width + 400) * 4..<(y * width + 500) * 4] }
      return out
    }
    let difference = ColorMatch.stats(rgba: column(back)).mean - ColorMatch.stats(rgba: column(original)).mean
    #expect(abs(difference.y) < 0.5 && abs(difference.z) < 0.5)
    let whole = try #require(ColorMatch.matched(editedImage, to: originalImage))
    #expect(whole.counted == nil && whole.shift == both.whole.shift)
  }

  /// Too little unchanged, or an original of another shape: the whole image is measured, and
  /// the reason is kept for the sheet to say.
  @Test func unchangedAreasFallBackToTheWholeImage() {
    let width = 640
    let height = 480
    let original = picture(width: width, height: height)
    let covered = pasted(shifted(original, by: SIMD3(0, 1, 6)), width: width, height: height, over: 0.8)
    let mostly = ColorMatch.measurements(edited: covered, width: width, height: height, original: original, width: width, height: height)
    #expect(mostly.unchanged == nil)
    if case .mostlyChanged(let fraction) = mostly.reason { #expect(fraction < 0.25) } else { Issue.record("\(String(describing: mostly.reason))") }
    #expect(mostly.measurement(unchangedOnly: true) == mostly.whole)
    #expect(
      ColorMatch.measure(edited: covered, width: width, height: height, original: original, width: width, height: height, unchangedOnly: true)
        == mostly.whole)
    // Another shape.
    let square = picture(width: 480, height: 480)
    let other = ColorMatch.measurements(edited: covered, width: width, height: height, original: square, width: 480, height: 480)
    #expect(other.unchanged == nil && other.reason == .shape && other.measurement(unchangedOnly: true) == other.whole)
    // The same shape at another size lines up: both are measured at 512.
    let large = picture(width: 1280, height: 960)
    let warm = shifted(original, by: SIMD3(0, 0, 5))
    let scaled = ColorMatch.measurements(edited: warm, width: width, height: height, original: large, width: 1280, height: 960)
    #expect(scaled.reason == nil && (scaled.unchanged?.counted ?? 0) > 0.95)
    // Not asked for: not taken.
    let plain = ColorMatch.measurements(
      edited: warm, width: width, height: height, original: original, width: width, height: height, unchanged: false)
    #expect(plain.unchanged == nil && plain.reason == nil)
  }

  /// The sheet's preview with the toggle on draws the job's transfer: the same measurement, from
  /// the same function.
  @Test func previewRendersTheUnchangedAreasMatchAsTheJobDoes() async throws {
    let width = 1000
    let height = 750
    let original = picture(width: width, height: height)
    let edited = pasted(shifted(original, by: SIMD3(2, 1, 6)), width: width, height: height, over: 0.2)
    let editedImage = try #require(ColorMatch.cgImage(rgba: edited, width: width, height: height))
    let originalImage = try #require(ColorMatch.cgImage(rgba: original, width: width, height: height))
    let preview = try #require(await ColorMatch.Preview.make(edited: editedImage, original: originalImage))
    let options = ColorMatch.Options(tint: 1, saturation: 0.6, brightness: 0.5, contrast: 0.2, unchangedOnly: true)
    // What the job measures.
    let measured = ColorMatch.measure(
      edited: try #require(ColorMatch.rgba(editedImage)), width: width, height: height,
      original: try #require(ColorMatch.rgba(originalImage)), width: width, height: height, unchangedOnly: true)
    #expect(measured.counted != nil && preview.measurements.unchanged == measured)
    let expected = ColorMatch.transferred(rgba: preview.pixels, target: measured.target, reference: measured.reference, options: options)
    #expect(ColorMatch.rgba(try #require(preview.render(options))) == expected)
    #expect(ColorMatch.rgba(try #require(try await preview.rendering(options))) == expected)
    // And with it off, the whole images'.
    var whole = options
    whole.unchangedOnly = false
    let plain = ColorMatch.transferred(rgba: preview.pixels, target: preview.target, reference: preview.reference, options: whole)
    #expect(ColorMatch.rgba(try #require(preview.render(whole))) == plain && plain != expected)
    // The job's result at full size is that transfer too.
    let job = try #require(ColorMatch.matched(editedImage, to: originalImage, options: options))
    #expect(
      ColorMatch.rgba(job.image)
        == ColorMatch.transferred(
          rgba: try #require(ColorMatch.rgba(editedImage)), target: measured.target, reference: measured.reference, options: options))
  }
}
