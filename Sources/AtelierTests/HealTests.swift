@testable import Atelier
import Foundation
import Testing

/// The Heal brush (`HealBrush`): the membrane solve, what a stroke does to pixels, its mask's
/// resampling, and the Aligned source rule (`Edit.HealSource`). Images are small, as a stroke's
/// work is its own box whatever the image's size.
@Suite(.tags(.smoke))
struct HealTests {
  /// A `width` × `height` RGBA8 image of `value(x, y)` in red, green and blue.
  static func image(width: Int, height: Int, _ value: (Int, Int) -> Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let v = UInt8(clamping: value(x, y))
        let index = (y * width + x) * 4
        pixels[index] = v
        pixels[index + 1] = UInt8(clamping: Int(v) - 20)
        pixels[index + 2] = UInt8(clamping: Int(v) - 40)
      }
    }
    return pixels
  }

  /// Skin-like texture: a gentle slope plus fixed pseudo-random noise of about ±12 levels.
  static func texture(_ x: Int, _ y: Int) -> Int {
    var h = UInt64(x &* 73_856_093 ^ y &* 19_349_663)
    h = (h ^ (h >> 13)) &* 0x5BD1_E995
    h ^= h >> 15
    return 170 + x / 16 + y / 32 + Int(h % 25) - 12
  }

  /// Red's mean and spread over the disc at `centre` of `radius`.
  private static func stats(_ pixels: [UInt8], width: Int, centre: SIMD2<Int>, radius: Int) -> (mean: Double, std: Double) {
    var sum = 0.0, squares = 0.0, count = 0.0
    for y in (centre.y - radius)...(centre.y + radius) {
      for x in (centre.x - radius)...(centre.x + radius) where (x - centre.x) * (x - centre.x) + (y - centre.y) * (y - centre.y) <= radius * radius {
        let v = Double(pixels[(y * width + x) * 4])
        sum += v
        squares += v * v
        count += 1
      }
    }
    let mean = sum / count
    return (mean, (squares / count - mean * mean).squareRoot())
  }

  // MARK: Membrane

  @Test func membraneOfAConstantEdgeIsTheConstant() {
    let size = 70
    var states = [HealBrush.State](repeating: .outside, count: size * size)
    var values = [SIMD4<Float>](repeating: .zero, count: size * size)
    let constant = SIMD4<Float>(12, -7, 3.5, 0)
    for y in 0..<size {
      for x in 0..<size {
        let edge = x == 0 || y == 0 || x == size - 1 || y == size - 1
        states[y * size + x] = edge ? .fixed : .unknown
        if edge { values[y * size + x] = constant }
      }
    }
    let solution = HealBrush.membrane(HealBrush.Grid(width: size, height: size, states: states, values: values))
    for value in solution { #expect(pointwiseMax(value - constant, constant - value).max() < 1e-3) }
  }

  @Test func membraneOfASlopeIsTheSlope() {
    // A linear edge is harmonic, so the fill is the same plane.
    let size = 50
    var states = [HealBrush.State](repeating: .outside, count: size * size)
    var values = [SIMD4<Float>](repeating: .zero, count: size * size)
    for y in 0..<size {
      for x in 0..<size {
        let edge = x == 0 || y == 0 || x == size - 1 || y == size - 1
        states[y * size + x] = edge ? .fixed : .unknown
        if edge { values[y * size + x] = SIMD4(repeating: Float(x) - Float(y) / 2) }
      }
    }
    let solution = HealBrush.membrane(HealBrush.Grid(width: size, height: size, states: states, values: values))
    var worst: Float = 0
    for y in 0..<size {
      for x in 0..<size { worst = max(worst, abs(solution[y * size + x].x - (Float(x) - Float(y) / 2))) }
    }
    #expect(worst < 0.5)
  }

  @Test func noEdgeMeansNoCorrection() {
    let grid = HealBrush.Grid(width: 8, height: 8, states: .init(repeating: .unknown, count: 64), values: .init(repeating: .zero, count: 64))
    #expect(HealBrush.membrane(grid).allSatisfy { $0 == .zero })
  }

  // MARK: Strokes on pixels

  @Test func flatImageStaysTheSame() {
    let original = Self.image(width: 128, height: 128) { _, _ in 150 }
    var pixels = original
    let region = HealBrush.apply(Edit.HealStroke(points: [SIMD2(64, 64), SIMD2(80, 70)], radius: 20, offset: SIMD2(-30, 25)),
                                 to: &pixels, width: 128, height: 128)
    #expect(region != nil)
    #expect(pixels == original)
  }

  @Test func spotIsRemovedFromTexture() {
    let width = 256, height = 192
    let centre = SIMD2(128, 96)
    var pixels = Self.image(width: width, height: height) { x, y in
      let dx = x - centre.x, dy = y - centre.y
      return Self.texture(x, y) - (dx * dx + dy * dy < 100 ? 70 : 0)
    }
    let around = Self.stats(pixels, width: width, centre: SIMD2(centre.x, centre.y + 50), radius: 10)
    #expect(Self.stats(pixels, width: width, centre: centre, radius: 8).mean < around.mean - 50)
    HealBrush.apply(Edit.HealStroke(points: [SIMD2(Float(centre.x), Float(centre.y))], radius: 18, offset: SIMD2(0, 50)),
                    to: &pixels, width: width, height: height)
    let healed = Self.stats(pixels, width: width, centre: centre, radius: 8)
    // Left and right of the spot together, so the texture's slope cancels.
    let left = Self.stats(pixels, width: width, centre: SIMD2(centre.x - 40, centre.y), radius: 10)
    let right = Self.stats(pixels, width: width, centre: SIMD2(centre.x + 40, centre.y), radius: 10)
    #expect(abs(healed.mean - (left.mean + right.mean) / 2) < 4)
    #expect(abs(healed.std - around.std) < around.std * 0.3)
  }

  @Test func sameStrokesGiveSameBytes() throws {
    let original = Self.image(width: 160, height: 160, Self.texture)
    let strokes = Edit.HealStrokes(strokes: [
      Edit.HealStroke(points: [SIMD2(40, 40), SIMD2(70, 55), SIMD2(90, 90)], radius: 12.5, offset: SIMD2(30.4, -12.6)),
      Edit.HealStroke(points: [SIMD2(100, 120)], radius: 20, offset: SIMD2(-45, -10), feather: 0.5),
    ])
    var first = original, second = original
    try HealBrush.apply(strokes, to: &first, width: 160, height: 160)
    try HealBrush.apply(strokes, to: &second, width: 160, height: 160)
    #expect(first == second)
    #expect(first != original)
  }

  @Test func pixelsOutsideTheBoxAreUntouched() throws {
    let width = 200, height = 150
    let original = Self.image(width: width, height: height, Self.texture)
    var pixels = original
    let stroke = Edit.HealStroke(points: [SIMD2(60, 70), SIMD2(110, 80)], radius: 15, offset: SIMD2(0, 40))
    let region = try #require(HealBrush.apply(stroke, to: &pixels, width: width, height: height))
    #expect(region == HealBrush.region(of: stroke, width: width, height: height))
    var changedInside = false
    for y in 0..<height {
      for x in 0..<width {
        let index = (y * width + x) * 4
        let inside = x >= region.x && x < region.x + region.width && y >= region.y && y < region.y + region.height
        if inside {
          changedInside = changedInside || pixels[index] != original[index]
        } else {
          #expect(pixels[index..<index + 4] == original[index..<index + 4])
        }
        #expect(pixels[index + 3] == 255)
      }
    }
    #expect(changedInside)
  }

  @Test func sourcePastTheEdgeClamps() {
    // Columns are their own x; a surface shifted left past the edge reads column 0.
    let pixels = Self.image(width: 64, height: 32) { x, _ in x + 100 }
    let region = HealBrush.Region(x: 4, y: 2, width: 10, height: 5)
    let surface = pixels.withUnsafeBufferPointer { HealBrush.HealSurface(rgba: $0, width: 64, height: 32, region: region, shift: SIMD2(-20, 100)) }
    for row in 0..<region.height {
      for column in 0..<region.width {
        #expect(surface.pixels[row * region.width + column].x == Float(max(region.x + column - 20, 0) + 100))
      }
    }
    // And a stroke whose source is off the image still heals, from the edge.
    var image = Self.image(width: 64, height: 64, Self.texture)
    #expect(HealBrush.apply(Edit.HealStroke(points: [SIMD2(10, 10)], radius: 6, offset: SIMD2(-200, -200)), to: &image, width: 64, height: 64) != nil)
  }

  @Test func sourceOverlappingTheStrokeReadsPreStrokePixels() throws {
    let width = 120, height = 120
    let original = Self.image(width: width, height: height, Self.texture)
    let stroke = Edit.HealStroke(points: [SIMD2(50, 60), SIMD2(70, 60)], radius: 16, offset: SIMD2(8, 3))
    var pixels = original
    let region = try #require(HealBrush.apply(stroke, to: &pixels, width: width, height: height))
    // The same heal worked out from untouched copies of the original.
    let (destination, source) = original.withUnsafeBufferPointer {
      (HealBrush.HealSurface(rgba: $0, width: width, height: height, region: region),
       HealBrush.HealSurface(rgba: $0, width: width, height: height, region: region, shift: SIMD2(8, 3)))
    }
    let mask = HealBrush.mask(of: stroke, in: region)
    let healed = HealBrush.heal(destination: destination, source: source, mask: mask)
    for row in 0..<region.height {
      for column in 0..<region.width where mask.coverage[row * region.width + column] > 0 {
        let want = UInt8(min(max(healed.pixels[row * region.width + column].x.rounded(), 0), 255))
        #expect(pixels[((region.y + row) * width + region.x + column) * 4] == want)
      }
    }
  }

  @Test func maskIsFullInsideAndSoftAtTheEdge() throws {
    let stroke = Edit.HealStroke(points: [SIMD2(20, 20)], radius: 10, offset: .zero)
    let region = try #require(HealBrush.region(of: stroke, width: 100, height: 100))
    #expect(region == HealBrush.Region(x: 8, y: 8, width: 24, height: 24))
    let mask = HealBrush.mask(of: stroke, in: region)
    func at(_ x: Int, _ y: Int) -> Float { mask.coverage[(y - region.y) * region.width + x - region.x] }
    #expect(at(20, 20) == 1)
    #expect(at(25, 19) == 1)
    #expect(at(28, 19) > 0 && at(28, 19) < 1)
    #expect(at(31, 19) == 0 && !mask.inside[(19 - region.y) * region.width + 31 - region.x])
  }

  @Test func strokeMissingTheImageDoesNothing() {
    var pixels = Self.image(width: 32, height: 32) { _, _ in 80 }
    let original = pixels
    #expect(HealBrush.apply(Edit.HealStroke(points: [SIMD2(-100, -100)], radius: 10, offset: .zero), to: &pixels, width: 32, height: 32) == nil)
    #expect(HealBrush.apply(Edit.HealStroke(points: [], radius: 10, offset: .zero), to: &pixels, width: 32, height: 32) == nil)
    #expect(pixels == original)
  }

  @Test func destinationRunningOffTheEdgeHeals() {
    // A spot in the corner, brushed with a disc reaching past both edges.
    let width = 128, height = 128
    var pixels = Self.image(width: width, height: height) { x, y in Self.texture(x, y) - (x * x + y * y < 100 ? 70 : 0) }
    let region = HealBrush.apply(Edit.HealStroke(points: [SIMD2(2, 2)], radius: 18, offset: SIMD2(50, 50)), to: &pixels, width: width, height: height)
    #expect(region == HealBrush.Region(x: 0, y: 0, width: 22, height: 22))
    let healed = Self.stats(pixels, width: width, centre: SIMD2(4, 4), radius: 3)
    let beside = Self.stats(pixels, width: width, centre: SIMD2(40, 40), radius: 6)
    #expect(abs(healed.mean - beside.mean) < 6)
  }

  @Test func highContrastEdgeKeepsNoHalo() {
    // A dark | light edge down the middle, a spot on it, and a source further down the same edge:
    // the edge stays where it was, with no glow bleeding either side.
    let width = 160, height = 200
    func level(_ x: Int, _ y: Int) -> Int { (x < 80 ? 40 : 220) + Self.texture(x, y) - 170 }
    var pixels = Self.image(width: width, height: height) { x, y in
      level(x, y) + ((x - 80) * (x - 80) + (y - 60) * (y - 60) < 64 ? 60 : 0)
    }
    HealBrush.apply(Edit.HealStroke(points: [SIMD2(80, 60)], radius: 16, offset: SIMD2(0, 80)), to: &pixels, width: width, height: height)
    var worst = 0
    for y in 44..<77 {
      for x in 64..<97 where abs(x - 80) >= 3 {
        worst = max(worst, abs(Int(pixels[(y * width + x) * 4]) - level(x, y)))
      }
    }
    // Texture differs between the spot and its source (±12 each), but no halo's tens of levels.
    #expect(worst <= 32)
  }

  @Test func strokeCoveringItsWholeBoxCopiesTheSource() throws {
    // No edge inside the image, so no correction: a straight (edge-clamped) copy.
    let width = 32, height = 24
    let original = HealTests.image(width: width, height: height, HealTests.texture)
    var pixels = original
    let region = try #require(HealBrush.apply(Edit.HealStroke(points: [SIMD2(16, 12)], radius: 100, offset: SIMD2(5, -3)),
                                              to: &pixels, width: width, height: height))
    #expect(region == HealBrush.Region(x: 0, y: 0, width: width, height: height))
    for y in 0..<height {
      for x in 0..<width {
        let from = (min(max(y - 3, 0), height - 1) * width + min(x + 5, width - 1)) * 4
        #expect(pixels[(y * width + x) * 4..<(y * width + x) * 4 + 4] == original[from..<from + 4])
      }
    }
  }

  @Test func nonFiniteStrokesDoNothing() {
    let width = 32, height = 32
    let original = HealTests.image(width: width, height: height, HealTests.texture)
    for bad in [Float.nan, .infinity, -.infinity] {
      for stroke in [Edit.HealStroke(points: [SIMD2(16, 16)], radius: bad, offset: SIMD2(5, 5)),
                     Edit.HealStroke(points: [SIMD2(16, 16)], radius: 6, offset: SIMD2(bad, 5)),
                     Edit.HealStroke(points: [SIMD2(16, 16)], radius: 6, offset: SIMD2(5, bad)),
                     Edit.HealStroke(points: [SIMD2(bad, 16), SIMD2(16, bad)], radius: 6, offset: SIMD2(5, 5))]
      {
        var pixels = original
        #expect(HealBrush.apply(stroke, to: &pixels, width: width, height: height) == nil)
        #expect(pixels == original)
      }
      // A bad point is dropped and a bad feather falls back, the rest still heals.
      var pixels = original
      #expect(HealBrush.apply(Edit.HealStroke(points: [SIMD2(16, 16), SIMD2(bad, 3)], radius: 6, offset: SIMD2(5, 5), feather: bad),
                              to: &pixels, width: width, height: height) != nil)
    }
  }

  @Test func clippingKeepsTheVisiblePart() {
    let paths = HealBrush.clip([SIMD2(-10, 5), SIMD2(10, 5), SIMD2(30, 5), SIMD2(30, 50), SIMD2(5, 50), SIMD2(5, 8)],
                               low: SIMD2(0, 0), high: SIMD2(20, 20))
    let want: [[SIMD2<Float>]] = [[SIMD2(0, 5), SIMD2(10, 5), SIMD2(20, 5)], [SIMD2(5, 20), SIMD2(5, 8)]]
    #expect(paths.count == want.count)
    for (path, expected) in zip(paths, want) {
      #expect(path.count == expected.count && zip(path, expected).allSatisfy { (($0 - $1) * ($0 - $1)).sum() < 1e-6 })
    }
    #expect(HealBrush.clip([SIMD2(50, 50)], low: .zero, high: SIMD2(20, 20)).isEmpty)
  }

  // MARK: Resampling

  @Test func resamplingKeepsEvenSpacingAcrossPoints() {
    let even = HealBrush.resample([SIMD2(0, 0), SIMD2(10, 0)], spacing: 2.5)
    #expect(even == [SIMD2(0, 0), SIMD2(2.5, 0), SIMD2(5, 0), SIMD2(7.5, 0), SIMD2(10, 0)])
    // A bend part way along carries the spacing over.
    let bent = HealBrush.resample([SIMD2(0, 0), SIMD2(3, 0), SIMD2(3, 0), SIMD2(10, 0)], spacing: 2.5)
    #expect(bent.count == even.count && zip(bent, even).allSatisfy { abs($0.x - $1.x) < 1e-4 && $0.y == $1.y })
    let corner = HealBrush.resample([SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4)], spacing: 2)
    #expect(corner == [SIMD2(0, 0), SIMD2(2, 0), SIMD2(4, 0), SIMD2(4, 2), SIMD2(4, 4)])
    #expect(HealBrush.resample([SIMD2(7, 7)], spacing: 3) == [SIMD2(7, 7)])
    #expect(HealBrush.resample([], spacing: 3).isEmpty)
    // The stroke's own spacing is a quarter of its radius.
    #expect(HealBrush.centres(of: Edit.HealStroke(points: [SIMD2(0, 0), SIMD2(16, 0)], radius: 16, offset: .zero)).count == 5)
  }

  // MARK: Aligned source

  @Test func alignedSourceRule() {
    var source: Edit.HealSource?
    #expect(Edit.HealSource.stroke(points: [SIMD2(10, 10)], radius: 8, source: &source) == nil)
    #expect(source == nil)

    source = .point(SIMD2(100, 50))
    let first = Edit.HealSource.stroke(points: [SIMD2(40, 30), SIMD2(45, 32)], radius: 8, source: &source)
    #expect(first?.offset == SIMD2(60, 20))
    #expect(source == .offset(SIMD2(60, 20)))
    let second = Edit.HealSource.stroke(points: [SIMD2(10, 90)], radius: 12, source: &source)
    #expect(second?.offset == SIMD2(60, 20))
    #expect(second?.radius == 12)

    source = .point(SIMD2(0, 0))
    let third = Edit.HealSource.stroke(points: [SIMD2(5, 5)], radius: 8, source: &source)
    #expect(third?.offset == SIMD2(-5, -5))

    // A stroke with no points doesn't fix the offset.
    source = .point(SIMD2(1, 1))
    #expect(Edit.HealSource.stroke(points: [], radius: 8, source: &source) == nil)
    #expect(source == .point(SIMD2(1, 1)))
  }
}

/// The heal's slower checks (a 200 px solve, a timed stroke), seconds unoptimized, so they run
/// with the Edit folder's suites rather than in the smoke set.
struct HealSolverTests {
  @Test func largeMembraneMatchesTheExactAnswer() {
    // A 200 px disc whose edge follows a discrete-harmonic quadratic (x² − y² + 2xy has a zero
    // five-point Laplacian), so the exact fill is the same function, the converged answer.
    let radius = 200, size = 2 * radius + 5
    let centre = Float(size) / 2
    func exact(_ x: Int, _ y: Int) -> Float {
      let dx = Float(x) - centre, dy = Float(y) - centre
      return (dx * dx - dy * dy + 2 * dx * dy) / Float(4 * radius)
    }
    var inside = [Bool](repeating: false, count: size * size)
    for y in 0..<size {
      for x in 0..<size {
        let dx = Float(x) + 0.5 - centre, dy = Float(y) + 0.5 - centre
        inside[y * size + x] = dx * dx + dy * dy < Float(radius * radius)
      }
    }
    var states = [HealBrush.State](repeating: .outside, count: size * size)
    var values = [SIMD4<Float>](repeating: .zero, count: size * size)
    for y in 1..<(size - 1) {
      for x in 1..<(size - 1) {
        let index = y * size + x
        if inside[index] {
          states[index] = .unknown
        } else if inside[index - 1] || inside[index + 1] || inside[index - size] || inside[index + size] {
          states[index] = .fixed
          values[index] = SIMD4(repeating: exact(x, y))
        }
      }
    }
    let solution = HealBrush.membrane(HealBrush.Grid(width: size, height: size, states: states, values: values))
    var worst: Float = 0
    for y in 0..<size {
      for x in 0..<size where states[y * size + x] == .unknown { worst = max(worst, abs(solution[y * size + x].x - exact(x, y))) }
    }
    // The edge spans about ±70 levels; under half a level rounds to the same bytes almost everywhere.
    #expect(worst < 0.5)
  }

  /// A typical 60 px spot, timed for the record (no assertion: unit tests run unoptimized).
  @Test func timesASixtyPixelStroke() {
    let width = 512, height = 512
    var pixels = HealTests.image(width: width, height: height, HealTests.texture)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      HealBrush.apply(Edit.HealStroke(points: [SIMD2(200, 250), SIMD2(260, 260)], radius: 60, offset: SIMD2(0, -130)),
                      to: &pixels, width: width, height: height)
    }
    print("HealTests: 60 px stroke (60 px drag) took \(elapsed)")
  }

  @Test func longStrokeIsHealedInSmallPieces() throws {
    // Corner to corner: each piece's box stays near the brush's size, not the image's.
    let width = 400, height = 300
    let stroke = Edit.HealStroke(points: [SIMD2(0, 0), SIMD2(400, 300)], radius: 10, offset: SIMD2(0, 30))
    let brush = try #require(HealBrush.Brush(stroke, width: width, height: height))
    let pieces = brush.pieces(width: width, height: height)
    #expect(pieces.count >= 7)
    for (piece, next) in zip(pieces, pieces.dropFirst()) { #expect(piece.last == next.first) }
    for piece in pieces {
      var low = piece[0], high = piece[0]
      for centre in piece {
        low = pointwiseMin(low, centre)
        high = pointwiseMax(high, centre)
      }
      #expect(max(high.x - low.x, high.y - low.y) <= 65)
    }
    var pixels = HealTests.image(width: width, height: height, HealTests.texture)
    let original = pixels
    let region = try #require(HealBrush.apply(stroke, to: &pixels, width: width, height: height))
    #expect(region == HealBrush.Region(x: 0, y: 0, width: width, height: height))
    #expect(pixels != original)
    // Far from the line nothing moves.
    #expect(pixels[(250 * width + 20) * 4] == original[(250 * width + 20) * 4])
  }

  @Test func extremeStrokesAreClampedNotFatal() throws {
    let width = 48, height = 40
    let original = HealTests.image(width: width, height: height, HealTests.texture)
    let extremes = [
      Edit.HealStroke(points: [SIMD2(-1e30, 1e30), SIMD2(24, 20), SIMD2(.greatestFiniteMagnitude, -.greatestFiniteMagnitude)],
                      radius: 1e30, offset: SIMD2(1e30, -1e30), feather: 1e9),
      Edit.HealStroke(points: [SIMD2(20, 20)], radius: 8, offset: SIMD2(-.greatestFiniteMagnitude, 3), feather: -5),
      Edit.HealStroke(points: (0..<200).map { SIMD2($0 % 2 == 0 ? -1e9 : 1e9, Float($0)) }, radius: 0.001, offset: SIMD2(4, 4)),
    ]
    for stroke in extremes {
      var pixels = original
      HealBrush.apply(stroke, to: &pixels, width: width, height: height)
      for index in stride(from: 3, to: pixels.count, by: 4) { #expect(pixels[index] == 255) }
    }
    // The radius stops at the cap; the offset at the image's size.
    let brush = try #require(HealBrush.Brush(extremes[0], width: width, height: height))
    #expect(brush.radius == min(HealBrush.maxRadius, Float(width * width + height * height).squareRoot()))
    #expect(brush.shift == SIMD2(width, -height) && brush.feather == 1)
  }
}
