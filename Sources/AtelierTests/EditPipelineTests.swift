@testable import Atelier
import CoreGraphics
import CryptoKit
import Foundation
import Testing

/// The Edit screen's render (`EditPipeline`) and its steps: the grade and vignette (`Grade`),
/// the Reinhard and histogram matches (`ReferenceMatch`, `HistogramMatch`) and halation.
struct EditPipelineTests {
  @Test func identityLeavesTheImageAlone() async throws {
    let width = 8
    let height = 4
    let pixels: [UInt8] = (0..<width * height).flatMap { (index: Int) -> [UInt8] in [UInt8(index * 7 % 256), UInt8(index * 3 % 256), UInt8(index % 256), 255] }
    let source = try #require(ColorMatch.cgImage(rgba: pixels, width: width, height: height))
    let rendered = try await EditPipeline.render(source: source, options: .identity)
    #expect(ColorMatch.rgba(rendered) == pixels)
    let window = EditPipeline.Window(x: 2, y: 1, width: 4, height: 2)
    let part = try await EditPipeline.render(source: source, options: .identity, window: window)
    let expected = EditPipeline.Planes(rgba: pixels, width: width, height: height).cropped(x: 2, y: 1, width: 4, height: 2).rgba
    #expect(part.width == 4 && part.height == 2 && ColorMatch.rgba(part) == expected)
  }

  // MARK: - Helpers

  /// Planes of `pixels` (RGB triples, opaque), `width` wide.
  private func planes(_ pixels: [SIMD3<Float>], width: Int? = nil) -> EditPipeline.Planes {
    let width = width ?? pixels.count
    return EditPipeline.Planes(
      width: width, height: pixels.count / width, r: pixels.map(\.x), g: pixels.map(\.y), b: pixels.map(\.z),
      alpha: [UInt8](repeating: 255, count: pixels.count))
  }

  private func pixel(_ planes: EditPipeline.Planes, _ index: Int) -> SIMD3<Float> {
    SIMD3(planes.r[index], planes.g[index], planes.b[index])
  }

  private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-3) -> Bool {
    max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) <= tolerance
  }

  /// A fixed sequence, so failures repeat.
  private struct Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state
    }
  }

  private func randomPixels(_ count: Int, in range: ClosedRange<UInt8> = 0...255, seed: UInt64 = 1) -> [UInt8] {
    var generator = Generator(state: seed)
    var out: [UInt8] = []
    for _ in 0..<count {
      for _ in 0..<3 { out.append(UInt8.random(in: range, using: &generator)) }
      out.append(255)
    }
    return out
  }

  /// HSV hue in degrees.
  private func hue(_ p: SIMD3<Float>) -> Float {
    let high = max(p.x, p.y, p.z)
    let chroma = high - min(p.x, p.y, p.z)
    guard chroma > 0 else { return 0 }
    var h: Float
    if high == p.x {
      h = (p.y - p.z) / chroma
    } else if high == p.y {
      h = 2 + (p.z - p.x) / chroma
    } else {
      h = 4 + (p.x - p.y) / chroma
    }
    h *= 60
    return h < 0 ? h + 360 : h
  }

  /// The lowest level whose CDF reaches `q`.
  private func quantile(_ cdf: [Double], _ q: Double) -> Int { cdf.firstIndex { $0 >= q } ?? 255 }

  // MARK: - Grade

  @Test func gradeDefaultsAreTheIdentity() {
    let pixels = randomPixels(500)
    let source = EditPipeline.Planes(rgba: pixels, width: 25, height: 20)
    var graded = source
    Grade.apply(EditOptions.Grade(), to: &graded)
    Grade.vignette(EditOptions.Vignette(), to: &graded, fullWidth: 25, fullHeight: 20)
    #expect(graded.r == source.r && graded.g == source.g && graded.b == source.b)
  }

  @Test func gradeControlsGiveKnownValues() {
    func graded(_ grade: EditOptions.Grade, _ p: SIMD3<Float>) -> SIMD3<Float> {
      var planes = planes([p])
      Grade.apply(grade, to: &planes)
      return pixel(planes, 0)
    }
    // Exposure: 2^stops (grain.py's expo).
    #expect(close(graded(.init(exposure: 1), [100, 50, 20]), [200, 100, 40]))
    #expect(close(graded(.init(exposure: -1), [100, 50, 20]), [50, 25, 10]))
    // Temperature: red ×2^0.25, blue ×2^−0.25 at 100.
    #expect(close(graded(.init(temperature: 100), [100, 100, 100]), [100 * pow(2, 0.25), 100, 100 * pow(2, -0.25)]))
    #expect(close(graded(.init(temperature: -50), [100, 100, 100]), [100 * pow(2, -0.125), 100, 100 * pow(2, 0.125)]))
    // Tint: grain.py's formula, green − t/2, red and blue + t/4, after exposure.
    #expect(close(graded(.init(tint: 10), [100, 100, 100]), [102.5, 95, 102.5]))
    #expect(close(graded(.init(exposure: 1, tint: -20), [100, 100, 100]), [195, 210, 195]))
    // Contrast around 127.5.
    #expect(close(graded(.init(contrast: 0.5), [100, 127.5, 200]), [86.25, 127.5, 236.25]))
    #expect(close(graded(.init(contrast: -1), [10, 90, 250]), [127.5, 127.5, 127.5]))
    // Saturation around Rec. 601 luma.
    #expect(close(graded(.init(saturation: -1), [200, 100, 50]), [124.2, 124.2, 124.2]))
    #expect(close(graded(.init(saturation: 1), [200, 100, 50]), [275.8, 75.8, -24.2]))
  }

  @Test func vibranceFavorsMutedColorsAndSkin() {
    func spread(_ p: SIMD3<Float>) -> Float { max(p.x, p.y, p.z) - min(p.x, p.y, p.z) }
    func graded(_ p: SIMD3<Float>) -> SIMD3<Float> {
      var planes = planes([p])
      Grade.apply(EditOptions.Grade(vibrance: 1), to: &planes)
      return pixel(planes, 0)
    }
    // Grey stays grey.
    #expect(close(graded([90, 90, 90]), [90, 90, 90]))
    // A muted blue's spread grows by 1 + (1 − 30/255); a saturated one's by 1 + (1 − 220/255).
    let muted: SIMD3<Float> = [100, 110, 130]
    let saturated: SIMD3<Float> = [20, 40, 240]
    #expect(abs(spread(graded(muted)) / spread(muted) - (2 - 30.0 / 255)) < 1e-4)
    #expect(abs(spread(graded(saturated)) / spread(saturated) - (2 - 220.0 / 255)) < 1e-4)
    // Skin (hue 22.5°) is pushed less than a non-skin color as muted.
    let skin: SIMD3<Float> = [220, 170, 140]
    let skinWeight: Float = (1 - 80.0 / 255) * (1 - 0.6 * (1 - 2.5 / 20))
    #expect(abs(spread(graded(skin)) / spread(skin) - (1 + skinWeight)) < 1e-4)
    // Vibrance keeps the luma.
    let out = graded(muted)
    #expect(abs(Grade.luma(out.x, out.y, out.z) - Grade.luma(muted.x, muted.y, muted.z)) < 1e-3)
  }

  @Test func vignetteDarkensTheCornersOnly() {
    let width = 21
    let height = 15
    let grey = [SIMD3<Float>](repeating: [200, 200, 200], count: width * height)
    var full = planes(grey, width: width)
    let vignette = EditOptions.Vignette(amount: 0.8, size: 0.4, softness: 0.5)
    Grade.vignette(vignette, to: &full, fullWidth: width, fullHeight: height)
    let centre = (height / 2) * width + width / 2
    #expect(pixel(full, centre) == [200, 200, 200])
    for corner in [0, width - 1, (height - 1) * width, width * height - 1] {
      #expect(full.r[corner] < 200 * 0.5 && full.r[corner] == full.b[corner])
    }
    // A window darkens as that part of the full render.
    var part = planes(Array(repeating: SIMD3<Float>(200, 200, 200), count: 6 * 5), width: 6)
    Grade.vignette(vignette, to: &part, fullWidth: width, fullHeight: height, window: .init(x: 15, y: 10, width: 6, height: 5))
    let crop = full.cropped(x: 15, y: 10, width: 6, height: 5)
    #expect(zip(part.r, crop.r).allSatisfy { abs($0 - $1) < 1e-3 })
    // Lightening goes toward white.
    var light = planes(grey, width: width)
    Grade.vignette(.init(amount: -1, size: 0.4, softness: 0.5), to: &light, fullWidth: width, fullHeight: height)
    #expect(light.r[centre] == 200 && light.r[0] > 200 && light.r[0] <= 255)
  }

  // MARK: - Reference match

  @Test func reinhardMatchesColorMatch() throws {
    let width = 48
    let height = 40
    let pixels = randomPixels(width * height, in: 40...210, seed: 3)
    // A warmer, flatter reference.
    let referencePixels = randomPixels(width * height, in: 70...240, seed: 9).enumerated().map { index, value -> UInt8 in
      switch index % 4 {
      case 0: UInt8(min(255, Int(value) + 15))
      case 2: UInt8(Int(value) * 3 / 4)
      default: value
      }
    }
    let image = try #require(ColorMatch.cgImage(rgba: pixels, width: width, height: height))
    let reference = try #require(ColorMatch.cgImage(rgba: referencePixels, width: width, height: height))
    let match = EditOptions.Match(tint: 0.8, saturation: 0.6, brightness: 0.5, contrast: 0.3)
    let matchedImage = try #require(ColorMatch.matched(image, to: reference, options: match.colorMatchOptions)?.image)
    let expected = try #require(ColorMatch.rgba(matchedImage))
    let stats = try #require(ReferenceMatch.labStats(of: reference))
    let source = EditPipeline.Planes(rgba: pixels, width: width, height: height)
    var planes = source
    ReferenceMatch.apply(match, to: &planes, reference: stats)
    var worst: Float = 0
    for index in 0..<width * height {
      worst = max(
        worst, abs(planes.r[index] - Float(expected[index * 4])), abs(planes.g[index] - Float(expected[index * 4 + 1])),
        abs(planes.b[index] - Float(expected[index * 4 + 2])))
    }
    #expect(worst <= 1)
    #expect(planes.r != source.r)
    // No amounts leave it alone.
    var untouched = source
    ReferenceMatch.apply(EditOptions.Match(), to: &untouched, reference: stats)
    #expect(untouched.r == source.r)
    // Measuring planes is measuring the image.
    #expect(ReferenceMatch.labStats(of: EditPipeline.Planes(rgba: referencePixels, width: width, height: height)) == stats)
  }

  // MARK: - Histogram match

  @Test func histogramMatchRGBReachesTheReference() {
    let count = 64 * 64
    // A dark-skewed source and a bright-skewed reference, each channel its own.
    // Smooth distributions, none piling a large share into one level (which no curve can split).
    func wave(_ t: Float) -> Float { t - 0.1 * sin(2 * .pi * t) }
    let source = planes(
      (0..<count).map { i in
        let t = Float(i) / Float(count - 1)
        return SIMD3(40 + 150 * wave(t), 10 + 120 * t, 90 + 160 * wave(1 - t))
      }, width: 64)
    let referencePlanes = planes(
      (0..<count).map { i in
        let t = Float((i * 7) % count) / Float(count - 1)
        return SIMD3(20 + 220 * pow(t, 0.7), 60 + 190 * wave(t), 5 + 200 * pow(t, 1.4))
      }, width: 64)
    let reference = HistogramMatch.table(of: referencePlanes)
    var matched = source
    HistogramMatch.apply(.init(amount: 1, space: .rgb), to: &matched, reference: reference)
    let result = HistogramMatch.table(of: matched)
    for q in stride(from: 0.05, through: 0.95, by: 0.05) {
      #expect(abs(quantile(result.red, q) - quantile(reference.red, q)) <= 1)
      #expect(abs(quantile(result.green, q) - quantile(reference.green, q)) <= 1)
      #expect(abs(quantile(result.blue, q) - quantile(reference.blue, q)) <= 1)
    }
    // An image matched to itself stays put; amount 0 is untouched.
    var same = referencePlanes
    HistogramMatch.apply(.init(amount: 1, space: .rgb), to: &same, reference: reference)
    #expect(zip(same.r, referencePlanes.r).allSatisfy { abs($0 - $1) <= 0.5 })
    var none = source
    HistogramMatch.apply(.init(amount: 0), to: &none, reference: reference)
    #expect(none.r == source.r)
  }

  @Test func histogramMatchLumaKeepsHue() {
    let count = 64 * 64
    let source = planes(
      (0..<count).map { i in
        let t = Float(i) / Float(count - 1)
        let y = 40 + 120 * (t - 0.1 * sin(2 * .pi * t))
        return SIMD3(y * 1.1, y * 0.95, y * 0.7)
      }, width: 64)
    let referencePlanes = planes(
      (0..<count).map { i in
        let y = 60 + 150 * pow(Float((i * 5) % count) / Float(count - 1), 0.7)
        return SIMD3(y, y, y)
      }, width: 64)
    let reference = HistogramMatch.table(of: referencePlanes)
    var matched = source
    HistogramMatch.apply(.init(amount: 1, space: .luma), to: &matched, reference: reference)
    let result = HistogramMatch.table(of: matched)
    for q in stride(from: 0.05, through: 0.95, by: 0.05) {
      #expect(abs(quantile(result.luma, q) - quantile(reference.luma, q)) <= 1)
    }
    for index in stride(from: 0, to: count, by: 37) {
      #expect(abs(hue(pixel(matched, index)) - hue(pixel(source, index))) < 0.01)
    }
    // Half the amount lands between.
    var half = source
    HistogramMatch.apply(.init(amount: 0.5, space: .luma), to: &half, reference: reference)
    let i = 1000
    #expect(abs(half.r[i] - (source.r[i] + matched.r[i]) / 2) < 0.6)
  }

  // MARK: - Halation

  @Test func halationGlowsOnlyFromHighlights() {
    let width = 40
    let height = 40
    let dark = [SIMD3<Float>](repeating: [60, 60, 60], count: width * height)
    let halation = EditOptions.Halation(amount: 1, threshold: 0.8, radius: 4, warmth: 0.6)
    // Zero amount, and an image with nothing above the threshold, are left alone.
    var zero = planes(dark, width: width)
    Halation.apply(.init(amount: 0), to: &zero)
    #expect(zero.r == planes(dark, width: width).r)
    var belowValues = dark
    belowValues[820] = [200, 200, 200] // luma 0.78, just under 0.8
    let belowSource = planes(belowValues, width: width)
    var below = belowSource
    Halation.apply(halation, to: &below)
    #expect(below.r == belowSource.r && below.g == belowSource.g && below.b == belowSource.b)
    // A highlight glows around itself, warm, and far pixels stay as they were.
    var spot = dark
    for y in 18..<22 {
      for x in 18..<22 { spot[y * width + x] = [255, 255, 255] }
    }
    var lit = planes(spot, width: width)
    Halation.apply(halation, to: &lit)
    let near = 20 * width + 24
    #expect(lit.r[near] > 61 && lit.r[near] > lit.g[near] && lit.g[near] > lit.b[near])
    #expect(lit.r[0] == 60 && lit.g[0] == 60 && lit.b[0] == 60)
    #expect(lit.r.allSatisfy { $0 <= 255 })
  }

  /// A bright half (sRGB 0.9) beside a dark one: the glow shows on the dark side, strongest at
  /// the edge and fading with distance, while the bright area itself barely changes.
  @Test func halationGlowsIntoDarkerSurroundings() {
    let width = 160
    let height = 16
    var pixels = [SIMD3<Float>](repeating: [40, 40, 40], count: width * height)
    for y in 0..<height {
      for x in 0..<80 { pixels[y * width + x] = [230, 230, 230] }
    }
    let source = planes(pixels, width: width)
    var lit = source
    Halation.apply(.init(amount: 1, threshold: 0.8, radius: 8, warmth: 0.6), to: &lit)
    let row = 8 * width
    func change(_ x: Int) -> Float { lit.r[row + x] - source.r[row + x] }
    // The bright interior moves little (red most, the warm tint's); just outside the edge it
    // moves most.
    #expect(abs(change(40)) < 5)
    #expect(change(80) > 20)
    #expect(change(80) > change(79) + 10)
    // Then it falls off with distance, to nothing far away.
    #expect(change(80) > change(88) && change(88) > change(96) && change(96) > change(110))
    #expect(change(159) == 0)
  }

  /// At 60% warmth the glow on a dark background reads orange-red, and deeper at 100%.
  @Test func halationWarmthTintsTheGlow() {
    let width = 160
    var pixels = [SIMD3<Float>](repeating: [40, 40, 40], count: width * 16)
    for y in 0..<16 {
      for x in 0..<80 { pixels[y * width + x] = [242, 242, 242] }
    }
    let source = planes(pixels, width: width)
    func edge(_ warmth: Double) -> SIMD3<Float> {
      var lit = source
      Halation.apply(.init(amount: 1, threshold: 0.8, radius: 8, warmth: warmth), to: &lit)
      return pixel(lit, 8 * width + 82) - pixel(source, 8 * width + 82)
    }
    let neutral = edge(0)
    let warm = edge(0.6)
    let warmest = edge(1)
    #expect(abs(neutral.x - neutral.y) < 0.01 && abs(neutral.y - neutral.z) < 0.01)
    #expect(warm.x > 1.5 * warm.y && warm.y > warm.z)
    #expect(warmest.y / warmest.x < warm.y / warm.x && warmest.z / warmest.x < warm.z / warm.x)
  }

  /// Values a grade leaves outside 0–255 keep their offset where the glow lands: on a −20
  /// background the glow adds what it adds on a 0 one, so nothing jumps where its reach ends.
  /// Past white nothing changes at all.
  @Test func halationKeepsOutOfRangeValues() {
    let width = 120
    func row(background: Float) -> [Float] {
      var pixels = [SIMD3<Float>](repeating: [background, background, background], count: width * 8)
      for y in 0..<8 {
        for x in 0..<20 { pixels[y * width + x] = [255, 255, 255] }
      }
      var lit = planes(pixels, width: width)
      Halation.apply(.init(amount: 1, threshold: 0.8, radius: 6, warmth: 0.6), to: &lit)
      return Array(lit.r[4 * width + 20..<5 * width])
    }
    let below = row(background: -20)
    let black = row(background: 0)
    #expect(below[0] > 0 && below.last == -20)
    #expect(zip(below, black).allSatisfy { abs($0 - ($1 - 20)) < 1e-3 })
    // On a background past white, nothing takes any glow.
    let over = [SIMD3<Float>](repeating: [300, 300, 300], count: 40 * 40)
    let overSource = planes(over, width: 40)
    var overLit = overSource
    Halation.apply(.init(amount: 1, threshold: 0.5, radius: 4, warmth: 0.6), to: &overLit)
    #expect(overLit.r == overSource.r && overLit.g == overSource.g && overLit.b == overSource.b)
  }

  /// A uniform midtone is below any reasonable threshold and stays exactly as it was.
  @Test func halationLeavesMidtonesAlone() {
    let pixels = [SIMD3<Float>](repeating: [127.5, 127.5, 127.5], count: 32 * 32)
    let source = planes(pixels, width: 32)
    var lit = source
    Halation.apply(.init(amount: 1, threshold: 0.8, radius: 6, warmth: 0.6), to: &lit)
    #expect(lit.r == source.r && lit.g == source.g && lit.b == source.b)
  }

  /// The glow starts from nothing just over the threshold and grows with the highlight's
  /// brightness: no step where light crosses the threshold.
  @Test func halationGrowsContinuouslyWithBrightness() {
    let width = 40
    func glow(_ value: Float) -> Float {
      var pixels = [SIMD3<Float>](repeating: [40, 40, 40], count: width * width)
      for y in 16..<24 {
        for x in 16..<24 { pixels[y * width + x] = [value, value, value] }
      }
      var lit = planes(pixels, width: width)
      Halation.apply(.init(amount: 1, threshold: 0.8, radius: 4, warmth: 0.6), to: &lit)
      return lit.r[20 * width + 26] - 40
    }
    let values: [Float] = [205, 210, 220, 235, 255]
    let glows = values.map(glow)
    // 205 is just over 0.8 (204): a trace, under a level.
    #expect(glows[0] >= 0 && glows[0] < 1)
    #expect(zip(glows, glows.dropFirst()).allSatisfy { $0 < $1 })
    #expect(glows[4] > 10)
  }

  /// At the default threshold, radius and warmth, a white spot on a mid-dark background glows
  /// without clipping any channel around it, even at full amount.
  @Test func halationDoesNotClipAroundASpot() {
    let width = 120
    var pixels = [SIMD3<Float>](repeating: [70, 70, 70], count: width * width)
    for y in 50..<70 {
      for x in 50..<70 { pixels[y * width + x] = [255, 255, 255] }
    }
    for amount in [0.5, 1.0] {
      var lit = planes(pixels, width: width)
      Halation.apply(.init(amount: amount), to: &lit)
      var brightest: Float = 0
      for y in 0..<width {
        for x in 0..<width where !(50..<70).contains(x) || !(50..<70).contains(y) {
          brightest = max(brightest, lit.r[y * width + x], lit.g[y * width + x], lit.b[y * width + x])
        }
      }
      #expect(brightest > 75 && brightest < 250, "amount \(amount): brightest surrounding channel \(brightest)")
    }
  }

  // MARK: - Pipeline assembly (Slice F)

  /// A look with every step on, and a context holding everything those steps use.
  private func everything() -> (options: EditOptions, context: EditPipeline.Context) {
    var options = EditOptions()
    options.lens = .init(motion: 6, angle: 20, blur: 2)
    options.match = .init(target: .reference, tint: 0.6, saturation: 0.5, brightness: 0.4, contrast: 0.5, colour: 0.4)
    options.histogram = .init(amount: 0.5, space: .luma)
    options.grade = .init(exposure: 0.2, temperature: 15, tint: 3, contrast: 0.1, saturation: 0.1, vibrance: 0.2)
    let lut = CubeLUT.bake(size: 17, name: "Test") { planes in
      for i in 0..<planes.r.count {
        planes.r[i] = 255 * pow(planes.r[i] / 255, 0.9)
        planes.b[i] = 255 * pow(planes.b[i] / 255, 1.1)
      }
    }
    options.lut = .init(name: "Test", digest: lut.digest, strength: 0.7)
    options.halation = .init(amount: 0.6, threshold: 0.6, radius: 6, warmth: 0.6)
    options.vignette = .init(amount: 0.4, size: 0.4, softness: 0.6)
    options.grain = .init(lum: 9, size: 1.3, chroma: 3, csize: 2, real: 0.8, seed: 11)
    let reference = GrainTests.picture(width: 90, height: 70)
    var shifted = reference
    for i in 0..<shifted.r.count {
      shifted.r[i] = shifted.r[i] * 0.8 + 30
      shifted.b[i] = shifted.b[i] * 0.9
    }
    let context = EditPipeline.Context(
      refWidth: 300, curve: [0.6, 1, 0.9, 0.7], refStats: Grain.channelStats(shifted), realNoise: realNoise(),
      referenceLab: ReferenceMatch.labStats(of: shifted), referenceHistogram: HistogramMatch.table(of: shifted), lut: lut)
    return (options, context)
  }

  /// A few 8 px patches of made-up real noise.
  private func realNoise() -> GrainProfile.RealNoise {
    var generator = Generator(state: 5)
    let bytes = (0..<4 * 8 * 8 * 3).map { _ in UInt8.random(in: 100...156, using: &generator) }
    return GrainProfile.RealNoise(patch: 8, count: 4, enc: 24, curve: [0.5, 1, 0.8, 0.6], data: Data(bytes))
  }

  private func image(_ planes: EditPipeline.Planes) throws -> CGImage {
    try #require(planes.cgImage)
  }

  private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
  }

  /// The render is the steps run by hand in the plan's order, and the identity look leaves the
  /// image alone with everything loaded.
  @Test func stepsRunInOrder() async throws {
    let (options, context) = everything()
    let source = GrainTests.picture(width: 120, height: 90)
    let rendered = try await EditPipeline.render(source: image(source), options: options, context: context)

    var a = Grain.motionSmear(source, length: 6, angle: 20)
    a = Grain.blur(a, sigma: 2)
    let target = ReferenceMatch.labStats(of: a)
    ReferenceMatch.apply(options.match.colorMatchOptions, to: &a, target: try #require(target.stats), reference: try #require(context.referenceLab?.stats))
    HistogramMatch.apply(options.histogram, to: &a, reference: try #require(context.referenceHistogram), source: HistogramMatch.table(of: a))
    a = Grain.colourMatch(a, source: Grain.channelStats(source), reference: try #require(context.refStats), amount: 0.4)
    Grade.apply(options.grade, to: &a)
    CubeLUT.apply(try #require(context.lut), to: &a, strength: 0.7)
    Halation.apply(options.halation, to: &a)
    Grade.vignette(options.vignette, to: &a, fullWidth: 120, fullHeight: 90)
    let l = Grain.luminance(a)
    let layout = Grain.Layout.whole(width: 120, height: 90)
    Grain.addGrain(&a, luminance: l, lum: 9, chroma: 3, size: 1.3, csize: 2, seed: 11, refWidth: 300, curve: context.curve, layout: layout)
    Grain.addRealNoise(&a, luminance: l, real: realNoise(), amount: 0.8, refWidth: 300, seed: 11, layout: layout)
    #expect(ColorMatch.rgba(rendered) == a.rgba)

    let untouched = try await EditPipeline.render(source: image(source), options: .identity, context: context)
    #expect(ColorMatch.rgba(untouched) == source.rgba)
  }

  /// With only grain.py's controls set, the render is grain.py's `process`, pixel for pixel.
  @Test func grainControlsAloneAreGrainPy() async throws {
    var settings = GrainProfile.Settings()
    settings.blur = 2
    settings.motion = 5
    settings.angle = 30
    settings.lum = 9
    settings.chroma = 3
    settings.size = 1.3
    settings.csize = 2
    settings.colour = 0.5
    settings.tint = 4
    settings.expo = 0.3
    settings.real = 0.8
    settings.seed = 11
    let reference = GrainTests.picture(width: 50, height: 50)
    let context = EditPipeline.Context(refWidth: 260, curve: [0.6, 1, 0.9, 0.7], refStats: Grain.channelStats(reference), realNoise: realNoise())
    let source = GrainTests.picture(width: 160, height: 110)
    let options = settings.applied(to: .identity)
    let rendered = try await EditPipeline.render(source: image(source), options: options, context: context)
    let expected = Grain.process(source, settings: settings, context: context)
    #expect(ColorMatch.rgba(rendered) == expected.rgba)
    // And the renderer's cached path gives the same.
    let renderer = EditRenderer()
    let first = try await renderer.full(source: image(source), options: options, context: context)
    #expect(ColorMatch.rgba(first) == expected.rgba)
  }

  /// A window at 100% is that part of the full render, at an edge and inside, with every step on.
  @Test func windowIsACropOfTheFullRender() async throws {
    let (options, context) = everything()
    let width = 260
    let height = 180
    let source = try image(GrainTests.picture(width: width, height: height))
    let renderer = EditRenderer()
    let fullImage = try await renderer.full(source: source, options: options, context: context)
    let full = try #require(ColorMatch.rgba(fullImage))
    let fullPlanes = EditPipeline.Planes(rgba: full, width: width, height: height)
    for window in [
      EditPipeline.Window(x: 83, y: 57, width: 90, height: 60), EditPipeline.Window(x: 0, y: 120, width: 70, height: 60),
      EditPipeline.Window(x: 200, y: 0, width: 60, height: 50),
    ] {
      let part = try await renderer.window(source: source, options: options, context: context, window: window)
      #expect(part.width == window.width && part.height == window.height)
      let expected = fullPlanes.cropped(x: window.x, y: window.y, width: window.width, height: window.height).rgba
      let partPixels = try #require(ColorMatch.rgba(part))
      #expect(maxDifference(partPixels, expected) <= 1)
    }
  }

  /// Steps 1–9 of a window, read with exactly the margins `Geometry.withReach` gives, are that
  /// part of the full image's steps 1–9 as floats (not just within a level once truncated to
  /// bytes), for smears along, across and diagonal to the rows; with one pixel less of either
  /// margin they aren't, so a margin that came up short would show.
  @Test func windowPreGrainIsACropOfTheFullPreGrain() async throws {
    var (options, context) = everything()
    let width = 240
    let height = 180
    let planes = GrainTests.picture(width: width, height: height)
    let source = try image(planes)
    let renderer = EditRenderer()
    // Inside, so neither margin is cut short by the image's edges.
    let window = EditPipeline.Window(x: 90, y: 70, width: 60, height: 40)
    func difference(_ a: EditPipeline.Planes, _ b: EditPipeline.Planes) -> Float {
      guard a.width == b.width, a.height == b.height else { return .infinity }
      return zip([a.r, a.g, a.b], [b.r, b.g, b.b]).reduce(0) { worst, pair in
        zip(pair.0, pair.1).reduce(worst) { max($0, abs($1.0 - $1.1)) }
      }
    }
    for angle in [20.0, 90, 135] {
      options.lens.angle = angle
      let stats = try await renderer.sourceStats(source: source, options: options, context: context)
      func preGrain(_ geometry: EditRenderer.Geometry) throws -> EditPipeline.Planes {
        let read = geometry.read
        return try EditRenderer.preGrain(
          base: planes.cropped(x: read.x, y: read.y, width: read.width, height: read.height), geometry: geometry, options: options,
          context: context, stats: stats)
      }
      let whole = try preGrain(EditRenderer.Geometry(width: width, height: height, window: nil).withReach(options))
      let geometry = EditRenderer.Geometry(width: width, height: height, window: window).withReach(options)
      let expected = whole.cropped(x: window.x, y: window.y, width: window.width, height: window.height)
      #expect(difference(try preGrain(geometry), expected) <= 1e-3, "angle \(angle)")

      // The margins the steps truly read: the smear's longest shift (as `Grain.motionSmear` lays
      // its copies) plus the blur's box radii, and halation's box radii. `withReach` gives each
      // a pixel or more to spare, so its margins less one still match; these exact ones match,
      // and one pixel short of either doesn't, so the comparison would catch a margin that came
      // up short.
      let n = max(2, Grain.round(options.lens.motion))
      let t = angle * Double.pi / 180
      let smear = (0..<n).map { i -> Int in
        let d = Double(i) - Double(n - 1) / 2
        return max(abs(Grain.round(d * sin(t))), abs(Grain.round(d * cos(t))))
      }.max() ?? 0
      func radii(_ sigma: Double) -> Int { Blur.boxSizes(sigma: sigma).reduce(0) { $0 + ($1 - 1) / 2 } }
      let lensNeed = smear + radii(options.lens.blur)
      let haloNeed = radii(options.halation.radius)
      #expect(EditPipeline.lensReach(options.lens, scale: 1) >= lensNeed && EditPipeline.halationReach(options.halation, scale: 1) >= haloNeed)
      func margins(lens: Int, halo: Int) -> EditRenderer.Geometry {
        var geometry = EditRenderer.Geometry(width: width, height: height, window: window)
        geometry.glow = geometry.grown(geometry.region, by: halo)
        geometry.read = geometry.grown(geometry.glow, by: lens)
        return geometry
      }
      #expect(difference(try preGrain(margins(lens: lensNeed, halo: haloNeed)), expected) <= 1e-3, "angle \(angle): exact margins")
      #expect(difference(try preGrain(margins(lens: lensNeed, halo: haloNeed - 1)), expected) > 1e-3, "angle \(angle): halation margin one short")
      // Halation's glow spreads a short lens margin's error thinner than the tolerance, so the
      // lens margin's control runs without it, where the output's edge is the lens's own.
      let lit = options
      options.halation.amount = 0
      defer { options = lit }
      let unlit = try preGrain(EditRenderer.Geometry(width: width, height: height, window: nil).withReach(options))
        .cropped(x: window.x, y: window.y, width: window.width, height: window.height)
      #expect(difference(try preGrain(margins(lens: lensNeed, halo: 0)), unlit) <= 1e-3, "angle \(angle): exact lens margin")
      #expect(difference(try preGrain(margins(lens: lensNeed - 1, halo: 0)), unlit) > 1e-3, "angle \(angle): lens margin one short")
    }
  }

  /// The context's digests are its data's, however it was made or changed, and a record's
  /// context keeps the record's.
  @Test func contextDigestsFollowTheData() {
    var (_, context) = everything()
    func check(_ context: EditPipeline.Context) {
      #expect(context.digests.realNoise == context.realNoise?.digest)
      #expect(context.digests.referenceHistogram == context.referenceHistogram?.digest)
      #expect(context.digests.lut == context.lut?.digest)
    }
    check(context)
    #expect(context.digests.lut != nil && context.digests.realNoise != nil && context.digests.referenceHistogram != nil)
    let record = Edit.Record(options: .identity, sourceTensorId: 1, context: context)
    let restored = record.context(with: Edit.Blobs(context))
    #expect(restored == context)
    check(restored)
    // Data that doesn't match the record's digest is left out, and so is its digest.
    let partial = record.context(with: Edit.Blobs(realNoise: context.realNoise, referenceHistogram: nil, lut: nil))
    #expect(partial.realNoise != nil && partial.lut == nil && partial.referenceHistogram == nil)
    check(partial)
    context.lut = nil
    context.referenceHistogram = HistogramMatch.table(of: GrainTests.picture(width: 20, height: 20))
    check(context)
    check(EditPipeline.Context.empty)
  }

  /// Changing only the grain reruns steps 10–12 from the kept pre-grain image; changing the seed
  /// makes new fields; changing an earlier step renders again.
  @Test func grainChangesReuseThePreGrainImage() async throws {
    var (options, context) = everything()
    let source = try image(GrainTests.picture(width: 200, height: 150))
    let renderer = EditRenderer()
    _ = try await renderer.preview(source: source, options: options, context: context, fitting: 100, height: 100)
    var counters = await renderer.counters
    #expect(counters.preGrainMisses == 1 && counters.preGrainHits == 0)
    let fieldMisses = counters.fieldMisses

    options.grain.lum = 14
    options.grain.real = 1.2
    _ = try await renderer.preview(source: source, options: options, context: context, fitting: 100, height: 100)
    counters = await renderer.counters
    #expect(counters.preGrainMisses == 1 && counters.preGrainHits == 1)
    #expect(counters.fieldMisses == fieldMisses)

    options.grain.seed = 12
    _ = try await renderer.preview(source: source, options: options, context: context, fitting: 100, height: 100)
    counters = await renderer.counters
    #expect(counters.preGrainHits == 2 && counters.fieldMisses > fieldMisses)

    options.grade.exposure = 0.5
    _ = try await renderer.preview(source: source, options: options, context: context, fitting: 100, height: 100)
    counters = await renderer.counters
    #expect(counters.preGrainMisses == 2)
  }

  /// A fitted preview is the full render made smaller: its size follows the fit, and with the
  /// blur, smear and halation scaled to it, it's close to the full render scaled down (closer
  /// than leaving the lengths in full-size pixels would be).
  @Test func previewScalesTheLengths() async throws {
    var options = EditOptions.identity
    options.lens = .init(motion: 12, angle: 0, blur: 6)
    options.halation = .init(amount: 0.8, threshold: 0.5, radius: 16, warmth: 0.6)
    let width = 400
    let height = 300
    // Hard-edged squares, which the blur and smear soften by their lengths.
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let on = (x / 25 + y / 25) % 2 == 0
        let i = (y * width + x) * 4
        rgba[i] = on ? 240 : 20
        rgba[i + 1] = on ? 230 : 30
        rgba[i + 2] = on ? 220 : 40
      }
    }
    let source = try #require(ColorMatch.cgImage(rgba: rgba, width: width, height: height))
    let renderer = EditRenderer()
    let preview = try await renderer.preview(source: source, options: options, fitting: 200, height: 200)
    #expect(preview.width == 200 && preview.height == 150)
    let full = try await renderer.full(source: source, options: options)
    let fullPixels = try #require(ColorMatch.rgba(full))
    let shrunk = try #require(ColorMatch.scaled(fullPixels, width: width, height: height, toWidth: 200, height: 150))
    var unscaled = options
    unscaled.lens = .init(motion: 24, angle: 0, blur: 12)
    unscaled.halation.radius = 32
    let wrong = try await renderer.preview(source: source, options: unscaled, fitting: 200, height: 200)
    func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
      Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }
    let previewPixels = try #require(ColorMatch.rgba(preview))
    let wrongPixels = try #require(ColorMatch.rgba(wrong))
    let near = meanDifference(previewPixels, shrunk)
    let far = meanDifference(wrongPixels, shrunk)
    #expect(near < 3)
    #expect(near < far / 2)
  }

  /// Export LUT's table, applied to the image, gives the render of steps 3–7 within two levels,
  /// except where the render clips: a table stores 0–1, so between a grid point past white and
  /// one inside, interpolation bends where the render's end clip does (a level or two more).
  /// Histogram matching is RGB here: Luma's near-black scaling (new luma / old luma, below a
  /// few levels) is steeper than a 33-point grid follows.
  @Test func bakedLUTReproducesTheGrade() async throws {
    var (options, context) = everything()
    options.lens = .identity
    options.halation = .init()
    options.vignette = .init()
    options.grain = .identity
    options.histogram.space = .rgb
    let picture = GrainTests.picture(width: 160, height: 120)
    let source = try image(picture)
    let renderer = EditRenderer()
    let renderedImage = try await renderer.full(source: source, options: options, context: context)
    let rendered = try #require(ColorMatch.rgba(renderedImage))
    let table = try await renderer.bakeLUT(source: source, options: options, context: context, name: "Look")
    #expect(table.size == 33)
    var baked = picture
    CubeLUT.apply(table, to: &baked)
    let bakedPixels = baked.rgba
    var inside = 0
    var all = 0
    for i in 0..<rendered.count where i % 4 != 3 {
      let d = abs(Int(rendered[i]) - Int(bakedPixels[i]))
      all = max(all, d)
      let pixel = i / 4 * 4
      if (0..<3).allSatisfy({ (4...251).contains(rendered[pixel + $0]) }) { inside = max(inside, d) }
    }
    #expect(inside <= 2)
    #expect(all <= 4)
  }

  /// Measure Reference gives what the context needs in one call.
  @Test func measureReferenceFillsTheContext() async throws {
    let reference = GrainTests.picture(width: 80, height: 60)
    let referenceImage = try image(reference)
    let measurement = try await EditPipeline.measureReference(referenceImage, name: "Ref", profile: false)
    let measured = try #require(measurement)
    #expect(measured.lab == ReferenceMatch.labStats(of: reference))
    #expect(measured.histogram == HistogramMatch.table(of: reference))
    let context = measured.applied(to: .empty)
    #expect(context.referenceLab == measured.lab && context.referenceHistogram == measured.histogram && context.refStats == nil)
  }

  // MARK: - Review fixes

  /// Histogram matching keeps headroom: values past white stay past it, by as much.
  @Test func histogramMatchKeepsHeadroom() {
    let curve = (0..<256).map { Float($0) * 0.9 }
    #expect(HistogramMatch.mapped(300, curve) == curve[255] + 45)
    #expect(HistogramMatch.mapped(-10, curve) == curve[0] - 10)
    #expect(HistogramMatch.mapped(.nan, curve) == 0)
  }

  /// An exposure that overflows doesn't spread NaN through halation and grain: the render is
  /// white where the image had light and finite everywhere.
  @Test func overflowingGradeIsSanitized() async throws {
    var options = EditOptions.identity
    options.grade.exposure = 200
    options.halation = .init(amount: 0.5, threshold: 0.5, radius: 4, warmth: 0.5)
    options.grain = .init(lum: 9, chroma: 3)
    let source = GrainTests.picture(width: 64, height: 48)
    var planes = source
    EditPipeline.color(&planes, options: options, context: .empty, stats: .init())
    #expect(planes.r.allSatisfy(\.isFinite) && planes.g.allSatisfy(\.isFinite) && planes.b.allSatisfy(\.isFinite))
    let rendered = try await EditPipeline.render(source: image(source), options: options)
    let pixels = try #require(ColorMatch.rgba(rendered))
    // The brightest corner is white, not NaN's black.
    #expect(pixels[(47 * 64 + 63) * 4] == 255)
  }

  /// A resize region outside the output gives zeros instead of reading past the plane.
  @Test func resizeRegionOutsideIsZeros() {
    let plane = [Float](repeating: 1, count: 4 * 3)
    let out = Resample.resize(plane, width: 4, height: 3, toWidth: 4, height: 3, region: Resample.Region(x: 2, y: 0, width: 4, height: 3))
    #expect(out == [Float](repeating: 0, count: 12))
  }

  /// Fields made a row at a time for a region are the whole field's, resized whole and then cut:
  /// enlarged, shrunk (every row read, the region off centre), and with the region's cells starting
  /// past the first noise chunks of a row, so a chunk made on its own matches the whole row's.
  @Test func streamedFieldsAreTheWholeFields() {
    func crop(_ plane: [Float], width: Int, _ region: Resample.Region) -> [Float] {
      var out: [Float] = []
      for y in region.y..<region.y + region.height {
        out += plane[y * width + region.x..<y * width + region.x + region.width]
      }
      return out
    }
    for (cells, output, region) in [
      ((width: 97, height: 68), (width: 300, height: 200), Resample.Region(x: 40, y: 30, width: 120, height: 90)),
      ((width: 400, height: 300), (width: 120, height: 90), Resample.Region(x: 71, y: 9, width: 37, height: 52)),
      ((width: 700, height: 60), (width: 1400, height: 120), Resample.Region(x: 1100, y: 20, width: 260, height: 40)),
    ] {
      let layout = Grain.Layout(width: output.width, height: output.height, aspect: 0.7, region: region)
      let whole = Resample.resize(
        Grain.noiseField(width: cells.width, height: cells.height, seed: 5), width: cells.width, height: cells.height,
        toWidth: output.width, height: output.height)
      #expect(Grain.field(cells: cells, seed: 5, layout: layout) == crop(whole, width: output.width, region), "\(cells) → \(output)")
    }
    // A part of a row is the same cells as the whole row, at a chunk's edge and inside one.
    let base = Grain.Random.mix(5)
    var row = [Float](repeating: 0, count: 700)
    Grain.noiseRow(3, base: base, columns: 0..<700, into: &row)
    for columns in [255..<258, 256..<512, 300..<301, 511..<700] {
      var part = [Float](repeating: 0, count: columns.count)
      Grain.noiseRow(3, base: base, columns: columns, into: &part)
      #expect(part == Array(row[columns]), "\(columns)")
    }

    let layout = Grain.Layout(width: 300, height: 200, aspect: 0.7, region: Resample.Region(x: 40, y: 30, width: 120, height: 90))
    let real = realNoise()
    let texture = Grain.realNoiseTexture(real, refWidth: 50, aspect: 0.7, seed: 5)
    let expected = texture.planes.map {
      crop(Resample.resize($0, width: texture.width, height: texture.height, toWidth: 300, height: 200), width: 300, layout.region)
    }
    #expect(Grain.realNoiseField(real, refWidth: 50, seed: 5, layout: layout) == expected)
  }
}

extension EditPipelineTests {
  /// The renders' bytes are exactly what they were before the steps learned to stop when
  /// cancelled (`EditPipeline.Cancel`): every step, at full size, fitted and as a window. The
  /// digest is of the renders made by the code before the change.
  @Test func cancellationChecksLeaveTheRenderAlone() async throws {
    let (options, context) = everything()
    let source = try image(GrainTests.picture(width: 300, height: 200))
    let renderer = EditRenderer()
    let full = try await renderer.full(source: source, options: options, context: context)
    let fitted = try await renderer.preview(source: source, options: options, context: context, fitting: 170, height: 170)
    let window = try await renderer.window(
      source: source, options: options, context: context, window: EditPipeline.Window(x: 40, y: 30, width: 120, height: 90, scale: 0.75))
    var bytes: [UInt8] = []
    for image in [full, fitted, window] { bytes += try #require(ColorMatch.rgba(image)) }
    let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    #expect(digest == "93599b90c1cd9d6c48836f5c11995a2a104e7749d4669d2b77ad6274a16da682", "digest \(digest)")
  }
}

/// A render stops soon after its task is cancelled (`EditPipeline.Cancel`, checked in every
/// step's bands), and keeps nothing it made.
struct EditRenderCancelTests {
  @Test func neverCantBeCancelled() throws {
    EditPipeline.Cancel.never.cancel()
    #expect(!EditPipeline.Cancel.never.isCancelled)
    let cancel = EditPipeline.Cancel()
    #expect(!cancel.isCancelled)
    cancel.cancel()
    #expect(cancel.isCancelled)
    #expect(throws: CancellationError.self) { try cancel.check() }
  }

  /// A full-size 4000 × 4000 render with halation, cancelled 20 ms in, throws within 100 ms of
  /// the cancel, and the same look rendered after misses the pre-grain cache: nothing half-made
  /// was kept. (`cancellationChecksLeaveTheRenderAlone` checks the bytes of renders that finish.)
  @Test func cancelledHalationRenderStopsQuickly() async throws {
    let side = 4000
    let source = try #require(GrainTests.picture(width: side, height: side).cgImage)
    let renderer = EditRenderer()
    // The source's pixels are read once, beforehand: that part can't stop midway.
    _ = try await renderer.preview(source: source, options: .grainDefaults, fitting: 64, height: 64)
    var options = EditOptions.grainDefaults
    options.halation = .init(amount: 0.7, threshold: 0.5, radius: 30, warmth: 0.6)
    let task = Task { try await renderer.full(source: source, options: options) }
    try await Task.sleep(for: .milliseconds(20))
    let clock = ContinuousClock()
    let cancelled = clock.now
    task.cancel()
    let result = await task.result
    let elapsed = clock.now - cancelled
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(elapsed < .milliseconds(100), "took \(elapsed) to stop")

    let missesBefore = await renderer.counters.preGrainMisses
    _ = try await renderer.full(source: source, options: options)
    #expect(await renderer.counters.preGrainMisses == missesBefore + 1)
  }

  /// Each step with a cancel that's never set gives exactly what it gives with `.never`, and
  /// once set, stops (a cancelled blur leaves most of a big plane unwritten).
  @Test func stepsHonourTheCancel() {
    let planes = GrainTests.picture(width: 160, height: 120)
    let live = EditPipeline.Cancel()
    var options = EditOptions.grainDefaults
    options.lens = .init(motion: 5, angle: 30, blur: 2)
    options.grade = .init(exposure: 0.3, temperature: 20, tint: 2, contrast: 0.1, saturation: 0.2, vibrance: 0.3)
    #expect(EditPipeline.lens(planes, options.lens, cancel: live).r == EditPipeline.lens(planes, options.lens).r)
    var a = planes, b = planes
    Grade.apply(options.grade, to: &a, cancel: live)
    Grade.apply(options.grade, to: &b)
    #expect(a.r == b.r && a.g == b.g && a.b == b.b)
    Halation.apply(.init(amount: 0.6, threshold: 0.5, radius: 8, warmth: 0.5), to: &a, cancel: live)
    Halation.apply(.init(amount: 0.6, threshold: 0.5, radius: 8, warmth: 0.5), to: &b)
    #expect(a.r == b.r && a.g == b.g && a.b == b.b)
    let stats = Grain.channelStats(planes)
    let reference = GrainProfile.ChannelStats(m: [120, 110, 100], s: [40, 50, 60])
    #expect(Grain.colourMatch(planes, source: stats, reference: reference, amount: 0.6, cancel: live).g
      == Grain.colourMatch(planes, source: stats, reference: reference, amount: 0.6).g)
    #expect(Grain.luminance(planes, cancel: live) == Grain.luminance(planes))

    let stopped = EditPipeline.Cancel()
    stopped.cancel()
    let plane = [Float](repeating: 1, count: 512 * 512)
    let blurred = Blur.gauss(plane, width: 512, height: 512, sigma: 4, cancel: stopped)
    #expect(blurred == plane)
    #expect(Blur.boxBlur(plane, width: 512, height: 512, radius: 3, horizontal: true, cancel: stopped).allSatisfy { $0 == 0 })
  }
}

/// The Edit panes' render lanes, behind their busy spinners.
@MainActor
struct EditRenderLaneTests {
  @Test func lanesArePerPane() {
    let edit = EditModel()
    let left = UUID(), right = UUID()
    #expect(!edit.isRendering)
    edit.beginRender(.init(pane: left, kind: .fitted))
    edit.beginRender(.init(pane: left, kind: .fitted))
    #expect(edit.isRendering && edit.isRendering(pane: left) && !edit.isRendering(pane: right))
    edit.beginRender(.init(pane: left, kind: .window))
    edit.beginRender(.init(pane: right, kind: .slider))
    // One lane ending leaves the pane's other one, and the other pane's.
    edit.endRender(.init(pane: left, kind: .fitted))
    #expect(edit.isRendering(pane: left) && edit.isRendering(pane: right))
    edit.endRender(.init(pane: left, kind: .window))
    #expect(!edit.isRendering(pane: left) && edit.isRendering(pane: right))
    // Ending a lane that isn't running changes nothing.
    edit.endRender(.init(pane: left, kind: .window))
    #expect(edit.pendingRenders.count == 1)
    // A pane that goes away ends all of its lanes.
    edit.beginRender(.init(pane: left, kind: .fitted))
    edit.beginRender(.init(pane: left, kind: .window))
    edit.endRenders(pane: left)
    #expect(!edit.isRendering(pane: left) && edit.isRendering(pane: right))
    edit.endRenders(pane: right)
    #expect(!edit.isRendering)
  }
}
