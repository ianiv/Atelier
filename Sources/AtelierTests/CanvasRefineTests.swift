@testable import Atelier
import CoreGraphics
import Foundation
@preconcurrency import LocalImageGenerator
@preconcurrency import NNC
import Testing

/// The canvas mask and the merge of a refined region back into its image: pure pixel math, with
/// the mask read back the way the engine reads it.
struct CanvasRefineTests {
  /// An opaque image whose every pixel differs from its neighbours, so a moved or resampled
  /// pixel shows.
  static func pattern(width: Int, height: Int) throws -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let index = (y * width + x) * 4
        bytes[index] = UInt8((x * 7 + y * 3) % 256)
        bytes[index + 1] = UInt8((x * 2 + y * 11) % 256)
        bytes[index + 2] = UInt8((x * 13 + y * 5) % 256)
      }
    }
    return try #require(image(bytes, width: width, height: height))
  }

  static func solid(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for index in 0..<(width * height) {
      bytes[index * 4] = red
      bytes[index * 4 + 1] = green
      bytes[index * 4 + 2] = blue
    }
    return try #require(image(bytes, width: width, height: height))
  }

  private static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// RGBA bytes of `image`, drawn into sRGB as the merge draws.
  static func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { raw in
      let context = CGContext(
        data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  private static func pixel(_ bytes: [UInt8], width: Int, _ x: Int, _ y: Int) -> [UInt8] {
    Array(bytes[((y * width + x) * 4)..<((y * width + x) * 4 + 4)])
  }

  // MARK: - Mask codes

  /// The engine reads Atelier's mask PNG through MGK's `maskDataToTensor`: `cgImage(from:)`,
  /// `resize` to the run's size, `grayscaleTensor`. Every byte must come out as one of the codes
  /// written, in the same place.
  @Test func maskCodesSurviveTheEnginesDecoding() throws {
    let source = CGSize(width: 512, height: 384)
    let frame = CGSize(width: 256, height: 256)
    // At 1×, the frame's right part past the image's right edge.
    let placement = CanvasPlacement(sourceSize: source, frameSize: frame, scale: 1, offset: CGSize(width: -200, height: 0))
    #expect(placement.imageRect == CGRect(x: -328, y: -64, width: 512, height: 384))
    let mask = CanvasMask(rects: [CGRect(x: 380, y: 150, width: 100, height: 40)])
    let png = try #require(mask.frameMask(placement))
    let decoded = try #require(ImageConverter.cgImage(from: png))
    let context = try #require(ImageConverter.resize(from: decoded, imageWidth: 256, imageHeight: 256))
    let tensor = try #require(ImageConverter.grayscaleTensor(from: context))
    var counts: [UInt8: Int] = [:]
    for y in 0..<256 {
      for x in 0..<256 {
        counts[tensor[y, x], default: 0] += 1
      }
    }
    #expect(Set(counts.keys) == [0, 1, 2])
    // The image's right edge is at frame x 184; the rectangle covers frame x 52..<152, y 86..<126.
    #expect(counts[CanvasMask.Code.empty] == (256 - 184) * 256)
    #expect(counts[CanvasMask.Code.painted] == 100 * 40)
    #expect(tensor[128, 200] == CanvasMask.Code.empty)
    #expect(tensor[128, 10] == CanvasMask.Code.keep)
    #expect(tensor[100, 72] == CanvasMask.Code.painted)
  }

  @Test func noMaskWhenNothingPaintedIsInsideTheFrame() {
    let placement = CanvasPlacement(
      sourceSize: CGSize(width: 512, height: 512), frameSize: CGSize(width: 256, height: 256), scale: 1, offset: .zero)
    // The frame shows image pixels 128..<384; this is in the corner.
    let mask = CanvasMask(rects: [CGRect(x: 0, y: 0, width: 60, height: 20)])
    #expect(mask.frameMask(placement) == nil)
  }

  @Test func shapesAddAndSubtractInOrder() {
    var mask = CanvasMask(strokes: [
      .init(kind: .brush, points: [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)], radius: 10),
      .init(kind: .brush, points: [CGPoint(x: 50, y: 50)], radius: 5, erases: true),
    ])
    var coverage = mask.coverage(width: 100, height: 100)
    #expect(coverage[50 * 100 + 20] == 255)
    #expect(coverage[50 * 100 + 50] == 0)
    #expect(coverage[10 * 100 + 50] == 0)
    mask.strokes.append(.invert)
    coverage = mask.coverage(width: 100, height: 100)
    #expect(coverage[50 * 100 + 20] == 0)
    #expect(coverage[50 * 100 + 50] == 255)
    #expect(coverage[10 * 100 + 50] == 255)
    #expect(Set(coverage) == [0, 255])

    let ellipse = CanvasMask(strokes: [.ellipse(in: CGRect(x: 0, y: 0, width: 100, height: 100))])
      .coverage(width: 100, height: 100)
    #expect(ellipse[50 * 100 + 50] == 255 && ellipse[2 * 100 + 2] == 0)
    let triangle = CanvasMask(strokes: [.polygon([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)])])
      .coverage(width: 100, height: 100)
    #expect(triangle[10 * 100 + 10] == 255 && triangle[90 * 100 + 90] == 0)
  }

  @Test func bitmapsPaintWhereLightAndEraseTheSame() throws {
    // Left half white, right half black.
    var bytes = [UInt8](repeating: 255, count: 40 * 20 * 4)
    for y in 0..<20 {
      for x in 20..<40 {
        let index = (y * 40 + x) * 4
        bytes[index] = 0
        bytes[index + 1] = 0
        bytes[index + 2] = 0
      }
    }
    let image = try #require(Self.image(bytes, width: 40, height: 20))
    let stroke = try #require(CanvasMask.Stroke.bitmap(image, at: CGPoint(x: 10, y: 30)))
    var mask = CanvasMask(strokes: [stroke])
    var coverage = mask.coverage(width: 100, height: 100)
    #expect(coverage[35 * 100 + 15] == 255)
    #expect(coverage[35 * 100 + 45] == 0)
    #expect(coverage[25 * 100 + 15] == 0)
    mask = CanvasMask(strokes: [.rect(CGRect(x: 0, y: 0, width: 100, height: 100)), try #require(CanvasMask.Stroke.bitmap(image, erases: true))])
    coverage = mask.coverage(width: 100, height: 100)
    #expect(coverage[5 * 100 + 5] == 0)
    #expect(coverage[5 * 100 + 25] == 255)
    #expect(coverage[50 * 100 + 50] == 255)
  }

  @Test func coverageScalesAndMoves() {
    let mask = CanvasMask(rects: [CGRect(x: 10, y: 10, width: 20, height: 10)])
    let coverage = mask.coverage(width: 100, height: 100, scale: (2, 2), origin: CGPoint(x: 5, y: 7))
    // Image (20, 15) → (45, 37).
    #expect(coverage[37 * 100 + 45] == 255)
    #expect(coverage[15 * 100 + 20] == 0)
    #expect(mask.translated(by: CGPoint(x: 5, y: 5)).coverage(width: 100, height: 100)[20 * 100 + 20] == 255)
  }

  // MARK: - Placement

  @Test func placementOfAZoomedQuadrantAndARegion() {
    // 2× on the top-left quadrant of a 512 image in a 512 frame: the image's center is 256 frame
    // pixels right and down of the frame's.
    let size = CGSize(width: 512, height: 512)
    let placement = CanvasPlacement(sourceSize: size, frameSize: size, scale: 2, offset: CGSize(width: 256, height: 256))
    #expect(placement.cropRect == CGRect(x: 0, y: 0, width: 256, height: 256))
    #expect(!placement.showsWholeImage)
    let region = CanvasPlacement(sourceSize: size, frameSize: size, showing: CGRect(x: 0, y: 0, width: 256, height: 256))
    #expect(region == placement)
    let fitted = CanvasPlacement(
      sourceSize: CGSize(width: 1024, height: 1024), frameSize: size, scale: nil, offset: .zero)
    #expect(fitted.showsWholeImage)
    #expect(fitted.cropRect == CGRect(x: 0, y: 0, width: 1024, height: 1024))
  }

  // MARK: - Merge

  @Test func aZoomedQuadrantMergesIntoItWithoutMovingTheRest() throws {
    let source = try Self.pattern(width: 256, height: 256)
    let result = try Self.solid(width: 256, height: 256, red: 255, green: 0, blue: 0)
    // 2× on the bottom-right quadrant.
    let merge = RefineMerge(
      source: source, sourceTensorId: nil, scale: 2, offset: CGSize(width: -128, height: -128),
      frameSize: CGSize(width: 256, height: 256), mask: nil)
    let merged = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 0, maskBlurOutset: 0))
    #expect(merged.image.width == 256 && merged.image.height == 256)
    #expect(merged.sourceOrigin == .zero)
    #expect(merged.step.record.rect == [128, 128, 128, 128])
    let out = Self.rgba(merged.image), original = Self.rgba(source)
    for (x, y) in [(10, 10), (200, 10), (10, 200), (127, 127)] {
      #expect(Self.pixel(out, width: 256, x, y) == Self.pixel(original, width: 256, x, y))
    }
    #expect(Self.pixel(out, width: 256, 200, 200) == [255, 0, 0, 255])
    #expect(Self.pixel(out, width: 256, 128, 128) == [255, 0, 0, 255])
  }

  @Test func featheringOnlyTouchesEdgesInsideTheImage() throws {
    let source = try Self.solid(width: 256, height: 256, red: 0, green: 0, blue: 255)
    let result = try Self.solid(width: 256, height: 256, red: 255, green: 0, blue: 0)
    let merge = RefineMerge(
      source: source, sourceTensorId: nil, scale: 2, offset: CGSize(width: -128, height: -128),
      frameSize: CGSize(width: 256, height: 256), mask: nil)
    let merged = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 8, maskBlurOutset: 0))
    let out = Self.rgba(merged.image)
    // The frame's left edge (x 128) is inside the image: blended there, red further in.
    let edge = Self.pixel(out, width: 256, 128, 200)
    #expect(edge[0] > 0 && edge[0] < 255 && edge[2] > 0)
    #expect(Self.pixel(out, width: 256, 140, 200) == [255, 0, 0, 255])
    // Its right edge is the image's: no feather.
    #expect(Self.pixel(out, width: 256, 255, 200) == [255, 0, 0, 255])
    #expect(Self.pixel(out, width: 256, 120, 200) == [0, 0, 255, 255])
  }

  @Test func aFramePastTheEdgeGrowsTheImage() throws {
    let source = try Self.pattern(width: 256, height: 256)
    let result = try Self.solid(width: 128, height: 128, red: 0, green: 255, blue: 0)
    // At 1×, a 128 frame centered on the image's right edge, vertically centered.
    let merge = RefineMerge(
      source: source, sourceTensorId: nil, scale: 1, offset: CGSize(width: -128, height: 0),
      frameSize: CGSize(width: 128, height: 128), mask: nil)
    let merged = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 0, maskBlurOutset: 0))
    #expect(merged.image.width == 320 && merged.image.height == 256)
    #expect(merged.step.record.rect == [192, 64, 128, 128])
    let out = Self.rgba(merged.image), original = Self.rgba(source)
    #expect(Self.pixel(out, width: 320, 300, 128) == [0, 255, 0, 255])
    #expect(Self.pixel(out, width: 320, 200, 128) == [0, 255, 0, 255])
    #expect(Self.pixel(out, width: 320, 100, 128) == Self.pixel(original, width: 256, 100, 128))
    // Neither the image nor the frame covers the corner: transparent.
    #expect(Self.pixel(out, width: 320, 300, 10) == [0, 0, 0, 0])
  }

  @Test func growingLeftMovesTheSource() throws {
    let source = try Self.pattern(width: 128, height: 128)
    let result = try Self.solid(width: 128, height: 128, red: 0, green: 255, blue: 0)
    let merge = RefineMerge(
      source: source, sourceTensorId: nil, scale: 1, offset: CGSize(width: 64, height: 0),
      frameSize: CGSize(width: 128, height: 128), mask: nil)
    let merged = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 0, maskBlurOutset: 0))
    #expect(merged.image.width == 192 && merged.sourceOrigin == CGPoint(x: 64, y: 0))
    let out = Self.rgba(merged.image), original = Self.rgba(source)
    #expect(Self.pixel(out, width: 192, 64 + 100, 10) == Self.pixel(original, width: 128, 100, 10))
  }

  @Test func aMaskedMergeLeavesUnmaskedPixelsExactly() throws {
    let source = try Self.pattern(width: 256, height: 256)
    let result = try Self.solid(width: 256, height: 256, red: 255, green: 255, blue: 255)
    let mask = CanvasMask(rects: [CGRect(x: 100, y: 100, width: 40, height: 40)])
    let merge = RefineMerge(
      source: source, sourceTensorId: 7, scale: nil, offset: .zero, frameSize: CGSize(width: 256, height: 256), mask: mask)
    let merged = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 4, maskBlurOutset: 2))
    #expect(merged.image.width == 256)
    let out = Self.rgba(merged.image), original = Self.rgba(source)
    #expect(Self.pixel(out, width: 256, 120, 120) == [255, 255, 255, 255])
    // Outset 2 and blur 4 reach well under 30 pixels.
    var changedFar = 0
    for y in 0..<256 {
      for x in 0..<256 where x < 70 || x >= 170 || y < 70 || y >= 170 {
        if Self.pixel(out, width: 256, x, y) != Self.pixel(original, width: 256, x, y) { changedFar += 1 }
      }
    }
    #expect(changedFar == 0)
    // Just outside the rectangle, the outset and blur blend a little in.
    #expect(Self.pixel(out, width: 256, 141, 120) != Self.pixel(original, width: 256, 141, 120))
    // A mask makes it two layers: the source with the paint under the frame.
    let layers = try #require(merged.step.layers)
    let paint = try #require(layers.paint)
    #expect(paint[120 * 256 + 120] == 255 && paint[10 * 256 + 10] == 0)
    #expect(layers.sourceTensorId == 7 && layers.frameX == 0 && layers.frameY == 0 && layers.frame.width == 256)
  }

  @Test func aFittedCenteredImageDoesntMergeWithoutAMask() {
    // A 4:3 image fitted in a square frame leaves bars, but merging would only blur it.
    let placement = CanvasPlacement(
      sourceSize: CGSize(width: 400, height: 300), frameSize: CGSize(width: 256, height: 256), scale: nil, offset: .zero)
    #expect(!placement.showsWholeImage)
    #expect(!RefineMerge.applies(placement: placement, scale: nil, offset: .zero, hasMask: false))
    #expect(RefineMerge.applies(placement: placement, scale: nil, offset: .zero, hasMask: true))
    #expect(RefineMerge.applies(placement: placement, scale: nil, offset: CGSize(width: 4, height: 0), hasMask: false))
  }

  @Test func transparentCanvasPixelsAreOutpaintedInTheMask() throws {
    // The left half of the canvas image is transparent (a grown image's empty corner).
    var bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
    for y in 0..<64 {
      for x in 0..<32 {
        for c in 0..<4 { bytes[(y * 64 + x) * 4 + c] = 0 }
      }
    }
    let image = try #require(Self.image(bytes, width: 64, height: 64))
    let placement = CanvasPlacement(sourceSize: CGSize(width: 64, height: 64), frameSize: CGSize(width: 64, height: 64), scale: nil, offset: .zero)
    let rendered = try #require(CanvasState.render(image, placement: placement))
    let png = try #require(CanvasMask(rects: [CGRect(x: 0, y: 0, width: 64, height: 64)]).frameMask(placement, canvas: rendered))
    let codes = Self.rgba(try #require(ImageLoader.image(from: png)))
    #expect(codes[(10 * 64 + 10) * 4] == CanvasMask.Code.empty)
    #expect(codes[(10 * 64 + 50) * 4] == CanvasMask.Code.painted)
  }

  @Test func storedCodesFollowDrawThings() {
    #expect(CanvasMask.Stored.code(alpha: 255) == 3)
    #expect(CanvasMask.Stored.code(alpha: 0) == 1)
    #expect(CanvasMask.Stored.alpha(CanvasMask.Stored.painted) == 0xF8)
    #expect(CanvasMask.Stored.alpha(3) == 255 && CanvasMask.Stored.alpha(0) == 255 && CanvasMask.Stored.alpha(1) == 0)
  }

  // MARK: - Layered steps in the project

  /// A grown, masked merge is written as Draw Things writes a canvas (the source's own tensor
  /// under the frame, the paint as 0xF9 on it) and reads back composited, empty where neither
  /// layer reaches; its preview id sums every layer's tensor and mask.
  @Test func aGrownMergeIsStoredAsTwoLayersAndReadBackWhole() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CanvasRefineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(url: folder.appending(path: "Layers.sqlite3"))
    let source = try Self.pattern(width: 128, height: 128)
    let sourceTensor = try #require(ImageTensor.tensor(from: source))
    let first = try await project.append(
      tensor: sourceTensor, model: "m", prompt: "", negativePrompt: "", seed: 1, settings: [:], createdAt: Date(),
      duration: 0, reason: .imported, generated: false)
    // At 1× a 128 frame centered on the right edge, 32 above the top: grows right and up.
    let mask = CanvasMask(rects: [CGRect(x: 100, y: 20, width: 20, height: 20)])
    let merge = RefineMerge(
      source: source, sourceTensorId: first.tensorId, scale: 1, offset: CGSize(width: -64, height: 32),
      frameSize: CGSize(width: 128, height: 128), mask: mask)
    let result = try Self.solid(width: 128, height: 128, red: 0, green: 255, blue: 0)
    let merged = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 0, maskBlurOutset: 0))
    #expect(merged.image.width == 192 && merged.image.height == 160)
    let layers = try #require(merged.step.layers)
    #expect(layers.frameX == 64 && layers.frameY == -32)
    let item = try await project.append(
      tensor: try #require(ImageTensor.tensor(from: layers.frame)), model: "m", prompt: "", negativePrompt: "", seed: 1,
      settings: [:], createdAt: Date(), duration: 0, inputTensorId: first.tensorId, after: first.tensorId,
      refined: merged.step)

    let rows = await project.read { $0.layerSummary(tensorId: item.tensorId) }
    #expect(rows.count == 2)
    #expect(rows.first?.tensorId == first.tensorId && (rows.first?.maskId ?? 0) > 0)
    #expect(rows.last?.x == 64 && rows.last?.y == -32)
    #expect(item.previewId == rows.reduce(0) { $0 &+ $1.tensorId &+ $1.maskId })

    let read = try #require(await project.read { $0.image(for: item) })
    #expect(read.width == 192 && read.height == 160)
    let bytes = Self.rgba(read)
    // Top left (above the source, left of the frame): empty. Inside the frame past the source:
    // the result. Inside the source, away from the frame: the source, exactly.
    #expect(Self.pixel(bytes, width: 192, 10, 10) == [0, 0, 0, 0])
    #expect(Self.pixel(bytes, width: 192, 180, 150) == [0, 0, 0, 0])
    #expect(Self.pixel(bytes, width: 192, 180, 40) == [0, 255, 0, 255])
    let original = Self.rgba(source)
    #expect(Self.pixel(bytes, width: 192, 10, 100) == Self.pixel(original, width: 128, 10, 68))
    // The source step itself is unchanged, and still one plain layer.
    let firstRows = await project.read { $0.layerSummary(tensorId: first.tensorId) }
    #expect(firstRows.count == 1 && firstRows[0].maskId == 0)
    await project.close()
  }

  @Test func blurKeepsItsTotal() {
    var values = [Float](repeating: 0, count: 50 * 50)
    values[25 * 50 + 25] = 1
    let blurred = MaskFilter.blur(values, width: 50, height: 50, sigma: 3)
    #expect(abs(blurred.reduce(0, +) - 1) < 0.01)
    #expect(blurred[25 * 50 + 25] < 0.1 && blurred[25 * 50 + 28] > 0)
    let grown = MaskFilter.outset(values, width: 50, height: 50, by: 2)
    #expect(grown.reduce(0, +) == 25)
  }
}
