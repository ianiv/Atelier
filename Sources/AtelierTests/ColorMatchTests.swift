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
      options: .init(strength: 0))
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
      rgba: ColorMatch.transferred(rgba: brighter, target: target, reference: reference, options: .init(luminance: 1)))
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
    let (matched, shift) = try #require(ColorMatch.matched(warmImage, to: originalImage))
    #expect(matched.width == width && matched.height == height)
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
    let record = ColorMatch.Record(strength: 0.5, luminance: 0.25, originalTensorId: 7, shift: .init(l: 1, a: -2, b: 3.5))
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    #expect(try decoder.decode(ColorMatch.Record.self, from: encoder.encode(record)) == record)
    // Saved before the shift was recorded.
    let old = try decoder.decode(ColorMatch.Record.self, from: Data(#"{"strength":1,"luminance":false}"#.utf8))
    #expect(old.shift == nil && old.originalTensorId == nil)
  }

  /// The default options (the one-click item's) make the bytes they made before lightness became
  /// an amount: a and b moved by the full transfer, L not touched.
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

  /// Lightness is an amount: half of it moves mean L halfway, and all of it is what matching
  /// lightness did when it was on or off (the same coefficients, so the same bytes).
  @Test func lightnessMovesByItsAmount() {
    let original = pixels(4096, seed: 17)
    let brighter = shifted(original, by: SIMD3(8, 0, 4))
    let target = ColorMatch.stats(rgba: brighter)
    let reference = ColorMatch.stats(rgba: original)
    let half = ColorMatch.stats(
      rgba: ColorMatch.transferred(rgba: brighter, target: target, reference: reference, options: .init(luminance: 0.5)))
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
    #expect(preview.target == ColorMatch.stats(rgba: ColorMatch.downsampled(warmPixels, width: width, height: height)))
    #expect(preview.reference == ColorMatch.stats(rgba: ColorMatch.downsampled(originalPixels, width: width, height: height)))
    #expect(abs(preview.shift.b - 6) < 0.5)
    for options in [ColorMatch.Options(), ColorMatch.Options(strength: 0.4, luminance: 0.7)] {
      let rendered = try #require(preview.render(options))
      let expected = ColorMatch.transferred(rgba: preview.pixels, target: preview.target, reference: preview.reference, options: options)
      #expect(ColorMatch.rgba(rendered) == expected)
      let concurrent = try #require(try await preview.rendering(options))
      #expect(ColorMatch.rgba(concurrent) == expected)
    }
  }

  /// Steps saved while lightness was on or off hold `luminance` as true or false; they read as
  /// all or none of it. All and none are still written that way, for copies of Atelier from then.
  @Test func recordReadsLuminanceAsBoolOrAmount() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    func record(_ luminance: String) throws -> ColorMatch.Record {
      try decoder.decode(
        ColorMatch.Record.self, from: Data(#"{"strength":0.5,"luminance":\#(luminance),"original_tensor_id":7}"#.utf8))
    }
    #expect(try record("true") == ColorMatch.Record(strength: 0.5, luminance: 1, originalTensorId: 7))
    #expect(try record("false") == ColorMatch.Record(strength: 0.5, luminance: 0, originalTensorId: 7))
    #expect(try record("0.35") == ColorMatch.Record(strength: 0.5, luminance: 0.35, originalTensorId: 7))
    func written(_ luminance: Double) throws -> String {
      try #require(String(data: JSONEncoder().encode(ColorMatch.Record(strength: 1, luminance: luminance)), encoding: .utf8))
    }
    #expect(try written(0).contains(#""luminance":false"#))
    #expect(try written(1).contains(#""luminance":true"#))
    #expect(try written(0.35).contains(#""luminance":0.35"#))
  }

  /// The same step with other settings is another match, and may queue beside the first; the same
  /// settings, however their numbers were arrived at, are the same match.
  @Test func isSameMatchComparesSettings() {
    let match = ColorMatch.Job(project: "P", sourceTensorId: 4, strength: 1, luminance: 0)
    #expect(match.isSameMatch(as: match))
    #expect(!match.isSameMatch(as: ColorMatch.Job(project: "P", sourceTensorId: 4, strength: 0.5, luminance: 0)))
    #expect(!match.isSameMatch(as: ColorMatch.Job(project: "P", sourceTensorId: 4, strength: 1, luminance: 0.5)))
    #expect(!match.isSameMatch(as: ColorMatch.Job(project: "P", sourceTensorId: 5, strength: 1, luminance: 0)))
    #expect(!match.isSameMatch(as: ColorMatch.Job(project: "Q", sourceTensorId: 4, strength: 1, luminance: 0)))
    // Within the same whole percent.
    let third = ColorMatch.Job(project: "P", sourceTensorId: 4, strength: 0.1 + 0.2, luminance: 0.7)
    #expect(third.isSameMatch(as: ColorMatch.Job(project: "P", sourceTensorId: 4, strength: 0.3, luminance: 0.7000001)))
    #expect(ColorMatch.Options(strength: 1.4, luminance: -1).snapped == ColorMatch.Options(strength: 1, luminance: 0))
    #expect(ColorMatch.Options(strength: 0.256, luminance: 0.254).snapped == ColorMatch.Options(strength: 0.26, luminance: 0.25))
  }
}
