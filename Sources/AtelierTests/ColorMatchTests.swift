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
      rgba: ColorMatch.transferred(rgba: brighter, target: target, reference: reference, options: .init(matchLuminance: true)))
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
}
