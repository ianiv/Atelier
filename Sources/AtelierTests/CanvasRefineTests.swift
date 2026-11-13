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

  /// The region math behind agents' `set_canvas_region`: a region of another shape grows about its
  /// center to the frame's (never cropped), and fitting it shows exactly the grown region.
  @Test func aRegionGrowsToTheFrameShapeAndShowsWhole() {
    let wide = CGSize(width: 1024, height: 512)
    // A square region in a 2:1 frame grows sideways about its center.
    let grown = CanvasPlacement.grown(CGRect(x: 100, y: 100, width: 200, height: 200), toShapeOf: wide)
    #expect(grown == CGRect(x: 0, y: 100, width: 400, height: 200))
    // A wide region in a square frame grows up and down.
    let tall = CanvasPlacement.grown(CGRect(x: 0, y: 50, width: 400, height: 100), toShapeOf: CGSize(width: 512, height: 512))
    #expect(tall == CGRect(x: 0, y: -100, width: 400, height: 400))
    // Already the frame's shape: unchanged.
    let same = CGRect(x: 10, y: 20, width: 300, height: 150)
    #expect(CanvasPlacement.grown(same, toShapeOf: wide) == same)
    // Fitting the original region shows the grown one.
    let region = CGRect(x: 128, y: 128, width: 256, height: 256)
    let placement = CanvasPlacement(sourceSize: CGSize(width: 1024, height: 768), frameSize: wide, showing: region)
    #expect(placement.cropRect == CanvasPlacement.grown(region, toShapeOf: wide))
    #expect(placement.cropRect == CGRect(x: 0, y: 128, width: 512, height: 256))
  }

  @Test func centeringAPointAtAScale() {
    let source = CGSize(width: 512, height: 512)
    // The image's center at any scale is no offset.
    #expect(CanvasPlacement.offset(centering: CGPoint(x: 256, y: 256), scale: 3, sourceSize: source) == .zero)
    // The top-left quadrant's center at 2×: the image's center sits 256 frame pixels right and down.
    let offset = CanvasPlacement.offset(centering: CGPoint(x: 128, y: 128), scale: 2, sourceSize: source)
    #expect(offset == CGSize(width: 256, height: 256))
    let placement = CanvasPlacement(sourceSize: source, frameSize: source, scale: 2, offset: offset)
    #expect(placement.cropRect == CGRect(x: 0, y: 0, width: 256, height: 256))
  }

  @Test func frameSizeForARegionKeepsItsShapeInWholeUnits() {
    // A 2:1 region at about a megapixel.
    #expect(CanvasPlacement.frameSize(forRegion: CGSize(width: 400, height: 200), pixelCount: 1024 * 1024) == CGSize(width: 1472, height: 704))
    // Square stays square.
    #expect(CanvasPlacement.frameSize(forRegion: CGSize(width: 33, height: 33), pixelCount: 512 * 512) == CGSize(width: 512, height: 512))
    #expect(CanvasPlacement.frameSize(forRegion: .zero, pixelCount: 512 * 512) == .zero)
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
    // At 1× a 128 frame centered on the right edge, 32 above the top: grows right and up. One
    // rectangle is under the frame, one outside it.
    let mask = CanvasMask(rects: [CGRect(x: 100, y: 20, width: 20, height: 20), CGRect(x: 10, y: 10, width: 20, height: 20)])
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
    // Opaque wherever the source was, the paint outside the frame included.
    for y in 32..<160 {
      for x in 0..<128 where bytes[(y * 192 + x) * 4 + 3] != 255 {
        Issue.record("composite pixel \(x), \(y) isn't opaque")
        return
      }
    }
    // The stored paint is only what's under the frame.
    let paint = try #require(layers.paint)
    #expect(paint[30 * 128 + 110] == 255 && paint[20 * 128 + 20] == 0)
    // The source step itself is unchanged, and still one plain layer.
    let firstRows = await project.read { $0.layerSummary(tensorId: first.tensorId) }
    #expect(firstRows.count == 1 && firstRows[0].maskId == 0)
    await project.close()
  }

  // MARK: - Detail layers

  static func layer(_ image: CGImage, x: Int, y: Int, s: Int, mask: [UInt8]? = nil) -> Project.CompositeLayer {
    Project.CompositeLayer(
      image: image, mask: mask, maskWidth: mask == nil ? 0 : image.width, maskHeight: mask == nil ? 0 : image.height,
      x: x, y: y, scaleFactorBy120: s)
  }

  /// A layer at density s covers width·120/s units (`TensorData`): composited at 120 it shrinks
  /// into its units, at its own density it lands pixel for pixel, and nothing goes past the
  /// finest layer.
  @Test func layersCompositeAtAnyDensity() throws {
    let base = try Self.solid(width: 100, height: 80, red: 0, green: 0, blue: 255)
    let twice = try Self.pattern(width: 40, height: 40)
    let fine = try Self.solid(width: 27, height: 27, red: 255, green: 0, blue: 0)
    let layers = [
      Self.layer(base, x: 0, y: 0, s: 120), Self.layer(twice, x: 10, y: 20, s: 240), Self.layer(fine, x: 50, y: 30, s: 324),
    ]
    for (density, width, height) in [(120, 100, 80), (240, 200, 160), (324, 270, 216), (Project.finestDensity, 270, 216), (1000, 270, 216)] {
      let image = try #require(Project.composite(layers, density: density))
      #expect(image.width == width && image.height == height, "density \(density)")
    }
    // At 240 the 240 layer is its own pixels, at 2 × (10, 20).
    let at240 = Self.rgba(try #require(Project.composite(layers, density: 240)))
    let original = Self.rgba(twice)
    for (x, y) in [(0, 0), (13, 7), (39, 39)] {
      #expect(Self.pixel(at240, width: 200, 20 + x, 40 + y) == Self.pixel(original, width: 40, x, y))
    }
    // The 324 layer covers 10 × 10 units from (50, 30); at 120 the base shows around it.
    let at120 = Self.rgba(try #require(Project.composite(layers)))
    #expect(Self.pixel(at120, width: 100, 55, 35) == [255, 0, 0, 255])
    #expect(Self.pixel(at120, width: 100, 61, 35) == [0, 0, 255, 255])
    // The detail to draw over the image: the finer layers, in its pixels.
    let detail = Project.detailLayers(layers)
    #expect(detail.map(\.rect) == [CGRect(x: 10, y: 20, width: 20, height: 20), CGRect(x: 50, y: 30, width: 10, height: 10)])
    #expect(Project.detailLayers([layers[0]]).isEmpty)
    // A painted mask stays in the image's pixels by default.
    var codes = [UInt8](repeating: CanvasMask.Stored.opaque, count: 40 * 40)
    for y in 0..<4 { for x in 0..<4 { codes[y * 40 + x] = CanvasMask.Stored.painted } }
    let masked = [layers[0], Self.layer(twice, x: 10, y: 20, s: 240, mask: codes)]
    let mask = try #require(Project.paintedMask(masked))
    let coverage = mask.coverage(width: 100, height: 80)
    #expect(coverage[20 * 100 + 10] == 255 && coverage[25 * 100 + 15] == 0)
  }

  /// Draw Things' upscaled steps are one layer at the origin with width = the tensor's pixels and
  /// scale_factor_by_120 = 120 × the scale (`ImageHistoryManager.imageData`): read at 120 they're
  /// the image's own size, at full detail the tensor's.
  @Test func aDrawThingsUpscaledLayerReadsAtTheImagesSize() throws {
    let upscaled = try Self.pattern(width: 256, height: 192)
    let layers = [Self.layer(upscaled, x: 0, y: 0, s: 240)]
    let base = try #require(Project.composite(layers))
    #expect(base.width == 128 && base.height == 96)
    let full = try #require(Project.composite(layers, density: Project.finestDensity))
    #expect(full.width == 256 && full.height == 192)
    #expect(Self.rgba(full) == Self.rgba(upscaled))
  }

  /// A zoomed refine's frame is stored at its own density, as Draw Things keeps an upscaled layer:
  /// width and height its pixels, scale_factor_by_120 above 120, the step's own scale the same.
  /// Read at 120 it's the source's size; at full detail it's twice that, the frame pixel for pixel.
  @Test func aDenseLayerRoundTrips() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CanvasRefineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(url: folder.appending(path: "Dense.sqlite3"))
    let source = try Self.pattern(width: 128, height: 128)
    let first = try await project.append(
      tensor: try #require(ImageTensor.tensor(from: source)), model: "m", prompt: "", negativePrompt: "", seed: 1,
      settings: [:], createdAt: Date(), duration: 0, reason: .imported, generated: false)
    let frame = try Self.solid(width: 128, height: 128, red: 255, green: 0, blue: 0)
    var step = RefinedStep(record: RefineRecord(rect: [32, 32, 64, 64], scale: 2, offset: [0, 0]), composite: source)
    step.layers = RefinedStep.Layers(
      source: source, sourceTensorId: first.tensorId, paint: nil, frame: frame, frameX: 32, frameY: 32,
      frameScaleFactorBy120: 240)
    let item = try await project.append(
      tensor: try #require(ImageTensor.tensor(from: frame)), model: "m", prompt: "", negativePrompt: "", seed: 1,
      settings: [:], createdAt: Date(), duration: 0, inputTensorId: first.tensorId, after: first.tensorId, refined: step)
    let rows = await project.read { $0.layerSummary(tensorId: item.tensorId) }
    #expect(rows.count == 2)
    #expect(rows.first?.tensorId == first.tensorId && rows.first?.scale == 120)
    #expect(rows.last?.x == 32 && rows.last?.y == 32 && rows.last?.width == 128 && rows.last?.height == 128 && rows.last?.scale == 240)
    #expect(await project.read { $0.stepScale(tensorId: item.tensorId) } == 240)
    let base = try #require(await project.read { $0.image(for: item) })
    #expect(base.width == 128 && base.height == 128)
    let baseBytes = Self.rgba(base)
    #expect(Self.pixel(baseBytes, width: 128, 64, 64) == [255, 0, 0, 255])
    #expect(Self.pixel(baseBytes, width: 128, 10, 10) == Self.pixel(Self.rgba(source), width: 128, 10, 10))
    let full = try #require(await project.read { $0.image(tensorId: item.tensorId, density: Project.finestDensity) })
    #expect(full.width == 256 && full.height == 256)
    #expect(Self.pixel(Self.rgba(full), width: 256, 64, 64) == [255, 0, 0, 255])
    #expect(Self.pixel(Self.rgba(full), width: 256, 191, 191) == [255, 0, 0, 255])
    let detail = await project.read { $0.detailLayers(tensorId: item.tensorId) }
    #expect(detail.map(\.rect) == [CGRect(x: 32, y: 32, width: 64, height: 64)])
    #expect(await project.read { $0.hasDetail(tensorId: item.tensorId) })
    #expect(await project.read { !$0.hasDetail(tensorId: first.tensorId) })
    await project.close()
  }

  /// A full-detail canvas past 16384 pixels a side goes coarser, never below the image's own.
  @Test func aHugeFullDetailCanvasGoesCoarser() throws {
    // 25 pixels at s = 1 cover 3000 units; the 960 layer asks for 8 pixels per unit.
    let wide = try Self.solid(width: 25, height: 25, red: 0, green: 0, blue: 0)
    let detail = try Self.solid(width: 16, height: 16, red: 0, green: 0, blue: 0)
    let layers = [Self.layer(wide, x: 0, y: 0, s: 1), Self.layer(detail, x: 0, y: 0, s: 960)]
    let size = try #require(Project.canvasSize(layers, density: Project.finestDensity))
    #expect(size.width <= 16384 && size.width > 16000 && size.scale > 5)
    #expect(try #require(Project.canvasSize(layers)).width == 3000)
  }

  // MARK: - Zoomed refines keep their detail

  @Test func frameDensityFollowsTheZoom() {
    #expect(CanvasMerge.frameDensity(zoom: 4) == 480)
    #expect(CanvasMerge.frameDensity(zoom: 2.7) == 324)
    #expect(CanvasMerge.frameDensity(zoom: 3.97) == 480)
    #expect(CanvasMerge.frameDensity(zoom: 4.1) == 492)
    #expect(CanvasMerge.frameDensity(zoom: 1.01) == 120)
    #expect(CanvasMerge.frameDensity(zoom: 0.5) == 120)
    #expect(CanvasMerge.frameDensity(zoom: 12) == 960)
  }

  /// A refine at 4× on part of a source: the frame is kept at 480, its pixels the merged
  /// result's one for one, over whole source pixels around the crop.
  @Test func aFourTimesRefineKeepsTheFramesPixels() throws {
    let source = try Self.pattern(width: 128, height: 128)
    let result = try Self.pattern(width: 128, height: 128)
    let region = CGRect(x: 32, y: 32, width: 32, height: 32)
    let placement = CanvasPlacement(sourceSize: CGSize(width: 128, height: 128), frameSize: CGSize(width: 128, height: 128), showing: region)
    #expect(placement.cropRect == region)
    let merge = RefineMerge(
      source: source, sourceTensorId: nil, scale: 4, offset: CGSize(width: 64, height: 64),
      frameSize: CGSize(width: 128, height: 128), mask: nil)
    let merged = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 0, maskBlurOutset: 0))
    #expect(merged.image.width == 128 && merged.image.height == 128)
    let layers = try #require(merged.step.layers)
    #expect(layers.frameScaleFactorBy120 == 480 && layers.frameX == 32 && layers.frameY == 32)
    #expect(layers.frame.width == 128 && layers.frame.height == 128)
    #expect(Self.rgba(layers.frame) == Self.rgba(result))
    // Outside the crop the source is untouched.
    let out = Self.rgba(merged.image), original = Self.rgba(source)
    #expect(Self.pixel(out, width: 128, 10, 100) == Self.pixel(original, width: 128, 10, 100))

    // Half a source pixel off: the layer grows to whole pixels, the frame still lands 1:1.
    let shifted = RefineMerge(
      source: source, sourceTensorId: nil, scale: 4, offset: CGSize(width: 66, height: 64),
      frameSize: CGSize(width: 128, height: 128), mask: nil)
    #expect(shifted.placement.cropRect.minX == 31.5)
    let offset = try #require(CanvasMerge.merge(result, into: shifted, maskBlur: 0, maskBlurOutset: 0)?.step.layers)
    #expect(offset.frameX == 31 && offset.frame.width == 33 * 4 && offset.frame.height == 128)
    let frameBytes = Self.rgba(offset.frame), resultBytes = Self.rgba(result)
    for (x, y) in [(0, 0), (50, 77), (127, 127)] {
      #expect(Self.pixel(frameBytes, width: 132, x + 2, y) == Self.pixel(resultBytes, width: 128, x, y))
    }
  }

  /// A masked refine at 4×: the layer is see-through wherever the mask doesn't reach, so the
  /// source there is exactly as it was, at its own pixels, both as merged and as read back.
  @Test func aMaskedZoomedRefineLeavesTheRestExactly() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CanvasRefineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(url: folder.appending(path: "Masked.sqlite3"))
    let source = try Self.pattern(width: 128, height: 128)
    let first = try await project.append(
      tensor: try #require(ImageTensor.tensor(from: source)), model: "m", prompt: "", negativePrompt: "", seed: 1,
      settings: [:], createdAt: Date(), duration: 0, reason: .imported, generated: false)
    let result = try Self.solid(width: 128, height: 128, red: 255, green: 0, blue: 0)
    let maskRect = CGRect(x: 40, y: 40, width: 12, height: 12)
    let merge = RefineMerge(
      source: source, sourceTensorId: first.tensorId, scale: 4, offset: CGSize(width: 64, height: 64),
      frameSize: CGSize(width: 128, height: 128), mask: CanvasMask(rects: [maskRect]))
    let merged = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 4, maskBlurOutset: 2))
    let layers = try #require(merged.step.layers)
    #expect(layers.frameScaleFactorBy120 == 480)
    let alpha = try #require(layers.frameAlpha)
    // Layer pixels: (base - 32) × 4. Far from the mask, transparent; inside it, opaque.
    let corner = 2 * 128 + 2, away = 100 * 128 + 100, inside = 56 * 128 + 56
    #expect(alpha[corner] == 0)
    #expect(alpha[away] == 0)
    #expect(alpha[inside] == 255)
    let item = try await project.append(
      tensor: try #require(ImageTensor.tensor(from: layers.frame)), model: "m", prompt: "", negativePrompt: "", seed: 1,
      settings: [:], createdAt: Date(), duration: 0, inputTensorId: first.tensorId, after: first.tensorId,
      refined: merged.step)
    let rows = await project.read { $0.layerSummary(tensorId: item.tensorId) }
    #expect(rows.count == 2 && (rows.last?.maskId ?? 0) > 0 && rows.last?.scale == 480)
    let read = try #require(await project.read { $0.image(for: item) })
    let original = Self.rgba(source)
    // The mask with Outset 2 and Mask Blur 4 frame pixels reaches about 4 source pixels past it.
    let far = maskRect.insetBy(dx: -6, dy: -6)
    for (name, image) in [("merged", merged.image), ("read back", read)] {
      let bytes = Self.rgba(image)
      var changed = 0
      for y in 0..<128 {
        for x in 0..<128 where !far.contains(CGPoint(x: x, y: y)) {
          if Self.pixel(bytes, width: 128, x, y) != Self.pixel(original, width: 128, x, y) { changed += 1 }
        }
      }
      #expect(changed == 0, "\(name): \(changed) pixels away from the mask changed")
      #expect(Self.pixel(bytes, width: 128, 46, 46) == [255, 0, 0, 255], "\(name)")
    }
    await project.close()
  }

  /// A zoom of 3.97 runs at 4×, about the same point, its image edge on a whole frame pixel: the
  /// kept layer is the result's pixels one for one.
  @Test func aNearWholeZoomSnapsThePlacement() throws {
    let size = CGSize(width: 128, height: 128)
    let snapped = RefineMerge.snapped(scale: 3.97, offset: CGSize(width: 63.3, height: 64.9), sourceSize: size, frameSize: size)
    #expect(snapped.scale == 4)
    let expectedX = 63.3 * 4 / 3.97, expectedY = 64.9 * 4 / 3.97
    #expect(abs(snapped.offset.width - expectedX) < 1)
    #expect(abs(snapped.offset.height - expectedY) < 1)
    #expect(RefineMerge.snapped(scale: 2.7, offset: CGSize(width: 3.3, height: 0), sourceSize: size, frameSize: size).scale == 2.7)
    #expect(RefineMerge.snapped(scale: nil, offset: .zero, sourceSize: size, frameSize: size).scale == nil)
    let source = try Self.pattern(width: 128, height: 128)
    let result = try Self.pattern(width: 128, height: 128)
    let merge = RefineMerge(
      source: source, sourceTensorId: nil, scale: snapped.scale, offset: snapped.offset, frameSize: size, mask: nil)
    let placement = merge.placement
    #expect(placement.zoom.x == 4 && placement.zoom.y == 4)
    let layers = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 0, maskBlurOutset: 0)?.step.layers)
    #expect(layers.frameScaleFactorBy120 == 480)
    let crop = placement.cropRect
    let dx = Int(((crop.minX - crop.minX.rounded(.down)) * 4).rounded())
    let dy = Int(((crop.minY - crop.minY.rounded(.down)) * 4).rounded())
    let frameBytes = Self.rgba(layers.frame), resultBytes = Self.rgba(result)
    for (x, y) in [(0, 0), (50, 77), (120, 120)] {
      #expect(Self.pixel(frameBytes, width: layers.frame.width, x + dx, y + dy) == Self.pixel(resultBytes, width: 128, x, y))
    }
  }

  @Test func otherZoomsPickTheirDensity() throws {
    let source = try Self.pattern(width: 256, height: 256)
    let result = try Self.solid(width: 128, height: 128, red: 255, green: 0, blue: 0)
    func layers(scale: Double) throws -> RefinedStep.Layers? {
      let merge = RefineMerge(
        source: source, sourceTensorId: nil, scale: scale, offset: .zero, frameSize: CGSize(width: 128, height: 128), mask: nil)
      return try #require(CanvasMerge.merge(result, into: merge, maskBlur: 0, maskBlurOutset: 0)).step.layers
    }
    #expect(try layers(scale: 2.7)?.frameScaleFactorBy120 == 324)
    #expect(try layers(scale: 3.97)?.frameScaleFactorBy120 == 480)
    // Zoomed out, the frame shows the whole image: nothing to keep finer, nothing layered.
    #expect(try layers(scale: 0.5) == nil)
  }

  /// A refine of a refined step keeps the earlier detail under its own frame; a refine covering
  /// that detail wholly at the same density drops it.
  @Test func earlierDetailIsCarriedForward() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CanvasRefineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(url: folder.appending(path: "Carry.sqlite3"))
    let source = try Self.pattern(width: 128, height: 128)
    let first = try await project.append(
      tensor: try #require(ImageTensor.tensor(from: source)), model: "m", prompt: "", negativePrompt: "", seed: 1,
      settings: [:], createdAt: Date(), duration: 0, reason: .imported, generated: false)
    let red = try Self.solid(width: 128, height: 128, red: 255, green: 0, blue: 0)
    func refine(_ parent: HistoryItem, scale: Double, offset: CGSize) async throws -> HistoryItem {
      let image = try #require(await project.read { $0.image(for: parent) })
      let merge = RefineMerge(
        source: image, sourceTensorId: parent.tensorId, scale: scale, offset: offset, frameSize: CGSize(width: 128, height: 128), mask: nil)
      let merged = try #require(CanvasMerge.merge(red, into: merge, maskBlur: 0, maskBlurOutset: 0))
      let frame = try #require(merged.step.layers?.frame)
      return try await project.append(
        tensor: try #require(ImageTensor.tensor(from: frame)), model: "m", prompt: "", negativePrompt: "", seed: 1,
        settings: [:], createdAt: Date(), duration: 0, inputTensorId: parent.tensorId, after: parent.tensorId, refined: merged.step)
    }
    // 4× on (32, 32, 32, 32), then 2× on the bottom-right quadrant.
    let a = try await refine(first, scale: 4, offset: CGSize(width: 64, height: 64))
    let b = try await refine(a, scale: 2, offset: CGSize(width: -64, height: -64))
    let rows = await project.read { $0.layerSummary(tensorId: b.tensorId) }
    #expect(rows.map(\.scale) == [120, 480, 240])
    #expect(rows[1].tensorId == a.tensorId && rows[1].x == 32 && rows[1].y == 32)
    #expect(rows[0].tensorId != first.tensorId)
    #expect(await project.read { $0.detailLayers(tensorId: b.tensorId) }.count == 2)
    // 2× over the top-left quadrant covers a's frame opaquely: dropped, though it was finer
    // (it could never show again).
    let c = try await refine(a, scale: 2, offset: CGSize(width: 64, height: 64))
    #expect(await project.read { $0.layerSummary(tensorId: c.tensorId) }.map(\.scale) == [120, 240])
    // 4× over the same region at the same density: dropped.
    let d = try await refine(a, scale: 4, offset: CGSize(width: 64, height: 64))
    #expect(await project.read { $0.layerSummary(tensorId: d.tensorId) }.map(\.scale) == [120, 480])
    let full = try #require(await project.read { $0.image(tensorId: b.tensorId, density: Project.finestDensity) })
    #expect(full.width == 512 && full.height == 512)
    await project.close()
  }

  /// The next run's frame takes the canvas image's detail layers at their own resolution: at 2×
  /// over a 240 layer, the frame is that layer's pixels.
  @Test func theFrameRendersWithDetail() throws {
    let base = try Self.solid(width: 64, height: 64, red: 0, green: 0, blue: 255)
    let fine = try Self.pattern(width: 64, height: 64)
    let detail = [Project.DetailLayer(image: fine, rect: CGRect(x: 16, y: 16, width: 32, height: 32))]
    let placement = CanvasPlacement(
      sourceSize: CGSize(width: 64, height: 64), frameSize: CGSize(width: 64, height: 64),
      showing: CGRect(x: 16, y: 16, width: 32, height: 32))
    let plain = try #require(CanvasState.render(base, placement: placement))
    #expect(Self.pixel(Self.rgba(plain), width: 64, 30, 30) == [0, 0, 255, 255])
    let rendered = try #require(CanvasState.render(base, placement: placement, detail: detail))
    #expect(Self.rgba(rendered) == Self.rgba(fine))
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
