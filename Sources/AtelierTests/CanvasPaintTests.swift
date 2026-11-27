@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// The paint layer (`CanvasPaint`): its strokes as JSON and stretched, the colours it draws where
/// it says, erasing and filling, how it lies in the run's frame at any zoom, and what painting
/// changes about a run's inputs (`RefineInputs`).
struct CanvasPaintTests {
  private static let red = CanvasPaint.Color(red: 1, green: 0, blue: 0)
  private static let blue = CanvasPaint.Color(red: 0, green: 0, blue: 1)

  private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let bytes = CanvasRefineTests.rgba(image)
    let index = (y * image.width + x) * 4
    return Array(bytes[index..<index + 4])
  }

  @Test func strokesRoundTripAsJSON() throws {
    var bytes = [UInt8](repeating: 0, count: 8 * 8)
    for index in 0..<32 { bytes[index] = 255 }
    let png = try #require(CanvasMask.grayPNG(bytes, width: 8, height: 8))
    let paint = CanvasPaint(strokes: [
      CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)], radius: 5, color: Self.red),
      CanvasPaint.Stroke(kind: .erase, points: [CGPoint(x: 2, y: 2)], radius: 1),
      .rect(CGRect(x: 0, y: 0, width: 4, height: 4), color: CanvasPaint.Color(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)),
      CanvasPaint.Stroke(kind: .fill, points: [CGPoint(x: 1, y: 1)], color: Self.blue, bitmap: png),
    ])
    let decoded = try JSONDecoder().decode(CanvasPaint.self, from: JSONEncoder().encode(paint))
    #expect(decoded == paint && decoded.hashValue == paint.hashValue)
    #expect(CanvasPaint.Color(hex: "#FF0000") == Self.red && Self.red.hex == "#FF0000")
    #expect(CanvasPaint.Color(hex: "00000080")?.alpha == 128.0 / 255 && CanvasPaint.Color(hex: "#12") == nil)
    // A colour picked again comes back a hair off: the same at 8 bits.
    #expect(Self.blue.matches(CanvasPaint.Color(red: 0.0004, green: 0, blue: 0.9996)) && !Self.blue.matches(Self.red))
  }

  @Test func strokesStretchLikeAMask() {
    let paint = CanvasPaint(strokes: [
      CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5)], radius: 3, color: Self.red),
    ])
    #expect(paint.scaled(sx: 1, sy: 1) == paint)
    let scaled = paint.scaled(sx: 2, sy: 8)
    #expect(scaled.strokes[0].points == [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 40)])
    #expect(scaled.strokes[0].radius == 12)
    let moved = paint.translated(by: CGPoint(x: 5, y: -1))
    #expect(moved.strokes[0].points == [CGPoint(x: 5, y: -1), CGPoint(x: 15, y: 4)])
  }

  @Test func aStrokeDrawsItsColorWhereItLies() throws {
    let paint = CanvasPaint(strokes: [.rect(CGRect(x: 4, y: 4, width: 8, height: 8), color: Self.red)])
    let layer = try #require(paint.layer(width: 32, height: 32))
    #expect(Self.pixel(layer, 8, 8) == [255, 0, 0, 255])
    #expect(Self.pixel(layer, 20, 20)[3] == 0)
    // Top left is the image's top left: the rows count down.
    #expect(Self.pixel(layer, 8, 24)[3] == 0)
    #expect(paint.bounds(width: 32, height: 32) == CGRect(x: 4, y: 4, width: 8, height: 8))
    #expect(CanvasPaint().layer(width: 4, height: 4) == nil)
    // Bounds come from the strokes' geometry, clipped to the image.
    let dot = CanvasPaint(strokes: [CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 2, y: 30)], radius: 4, color: Self.red)])
    #expect(dot.bounds(width: 32, height: 32) == CGRect(x: 0, y: 26, width: 6, height: 6))
  }

  @Test func aHairlineBrushHasBounds() throws {
    // A brush of radius 0 (an agent can send one) draws a pixel-wide line, and counts as such.
    let hairline = CanvasPaint(strokes: [CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 2, y: 8), CGPoint(x: 30, y: 8)], color: Self.red)])
    #expect(hairline.bounds(width: 32, height: 32) != nil)
    let layer = try #require(hairline.layer(width: 32, height: 32))
    #expect(Self.pixel(layer, 16, 8)[3] != 0)
  }

  @Test func newStrokesDrawOverTheLayerDrawnBefore() throws {
    let first = CanvasPaint.Stroke.rect(CGRect(x: 0, y: 0, width: 16, height: 16), color: Self.red)
    let second = CanvasPaint.Stroke(kind: .erase, points: [CGPoint(x: 8, y: 8)], radius: 4)
    let third = CanvasPaint.Stroke.ellipse(in: CGRect(x: 16, y: 16, width: 12, height: 12), color: Self.blue)
    let whole = try #require(CanvasPaint(strokes: [first, second, third]).layer(width: 32, height: 32))
    let base = try #require(CanvasPaint(strokes: [first]).layer(width: 32, height: 32))
    let added = try #require(CanvasPaint(strokes: [second, third]).layer(width: 32, height: 32, over: base))
    #expect(CanvasRefineTests.rgba(added) == CanvasRefineTests.rgba(whole))
  }

  @Test func erasingShowsTheImageAgain() throws {
    let image = try CanvasRefineTests.solid(width: 32, height: 32, red: 0, green: 200, blue: 0)
    var paint = CanvasPaint(strokes: [.rect(CGRect(x: 0, y: 0, width: 32, height: 32), color: Self.red)])
    paint.strokes.append(CanvasPaint.Stroke(kind: .erase, points: [CGPoint(x: 8, y: 8), CGPoint(x: 24, y: 8)], radius: 3))
    let layer = try #require(paint.layer(width: 32, height: 32))
    #expect(Self.pixel(layer, 16, 8)[3] == 0)
    #expect(Self.pixel(layer, 16, 24) == [255, 0, 0, 255])
    let baked = try #require(paint.baked(onto: image))
    #expect(Self.pixel(baked, 16, 8) == [0, 200, 0, 255])
    #expect(Self.pixel(baked, 16, 24) == [255, 0, 0, 255])
    // An eraser alone shows nothing.
    #expect(!CanvasPaint(strokes: [paint.strokes[1]]).mayHaveColor)
  }

  @Test func aFillStaysInsideItsSelection() throws {
    // A selection of a 16×16 image's left half.
    var bytes = [UInt8](repeating: 0, count: 16 * 16)
    for y in 0..<16 { for x in 0..<8 { bytes[y * 16 + x] = 255 } }
    let selection = try #require(CanvasMask.grayPNG(bytes, width: 16, height: 16))
    let mask = CanvasMask.Stroke(kind: .bitmap, points: [.zero], bitmap: selection)
    let fill = try #require(CanvasPaint.Stroke.fill(mask, color: Self.blue))
    let layer = try #require(CanvasPaint(strokes: [fill]).layer(width: 16, height: 16))
    for y in [0, 7, 15] {
      #expect(Self.pixel(layer, 3, y) == [0, 0, 255, 255])
      #expect(Self.pixel(layer, 12, y)[3] == 0)
    }
    // An erasing mask stroke fills nothing.
    #expect(CanvasPaint.Stroke.fill(CanvasMask.Stroke(kind: .bitmap, points: [.zero], erases: true, bitmap: selection), color: Self.blue) == nil)
    // Several fills compact into one image stroke that looks the same.
    let two = CanvasPaint(strokes: [fill, CanvasPaint.Stroke(kind: .fill, points: [CGPoint(x: 8, y: 0)], color: Self.red, bitmap: selection)])
    let compacted = two.compacted(for: CGSize(width: 16, height: 16))
    #expect(compacted.strokes.count == 1 && compacted.strokes[0].kind == .image)
    let before = try #require(two.layer(width: 16, height: 16)), after = try #require(compacted.layer(width: 16, height: 16))
    #expect(CanvasRefineTests.rgba(before) == CanvasRefineTests.rgba(after))
  }

  @Test func paintLiesInTheFrameAsTheImageDoes() throws {
    // A 32×32 image at 2× in a 32×32 frame, moved so its point (8, 8) is the frame's center.
    let image = try CanvasRefineTests.solid(width: 32, height: 32, red: 255, green: 255, blue: 255)
    let offset = CanvasPlacement.offset(centering: CGPoint(x: 8, y: 8), scale: 2, sourceSize: CGSize(width: 32, height: 32))
    let placement = CanvasPlacement(
      sourceSize: CGSize(width: 32, height: 32), frameSize: CGSize(width: 32, height: 32), scale: 2, offset: offset)
    let paint = CanvasPaint(strokes: [.rect(CGRect(x: 8, y: 8, width: 4, height: 4), color: Self.red)])
    let frame = try #require(CanvasState.render(image, placement: placement, paint: paint))
    // Image (8..12) lands on frame (16..24).
    #expect(Self.pixel(frame, 18, 18) == [255, 0, 0, 255])
    #expect(Self.pixel(frame, 14, 14) == [255, 255, 255, 255])
    #expect(Self.pixel(frame, 25, 25) == [255, 255, 255, 255])
    // Paint past the image's edge doesn't reach into the frame's empty part.
    let fitted = CanvasPlacement(
      sourceSize: CGSize(width: 32, height: 16), frameSize: CGSize(width: 32, height: 32), scale: nil, offset: .zero)
    let wide = try CanvasRefineTests.solid(width: 32, height: 16, red: 255, green: 255, blue: 255)
    let beyond = CanvasPaint(strokes: [.rect(CGRect(x: -10, y: -10, width: 60, height: 60), color: Self.red)])
    let bars = try #require(CanvasState.render(wide, placement: fitted, paint: beyond))
    #expect(Self.pixel(bars, 16, 2)[3] == 0 && Self.pixel(bars, 16, 16) == [255, 0, 0, 255])
  }

  @Test func aMaskedRunTakesPaintOnlyWhereItRegenerates() throws {
    // A white image, its middle masked and filled green right up to the mask's edge (Fill Mask).
    let image = try CanvasRefineTests.solid(width: 64, height: 64, red: 255, green: 255, blue: 255)
    let mask = CanvasMask(rects: [CGRect(x: 16, y: 16, width: 32, height: 32)])
    let flat = try #require(mask.flattenedStroke(width: 64, height: 64))
    let green = CanvasPaint.Color(red: 0, green: 1, blue: 0)
    let paint = CanvasPaint(strokes: [try #require(CanvasPaint.Stroke.fill(flat, color: green))])
    func canvas(_ mask: CanvasMask?, blur: Double) throws -> CGImage {
      try #require(
        RefineInputs.make(
          source: image, sourceTensorId: 1, isImported: false, scale: nil, offset: .zero, frame: CGSize(width: 64, height: 64),
          mask: mask, merge: true, paint: paint, maskBlur: blur, maskBlurOutset: 0)?.canvas)
    }
    func greenness(_ pixel: [UInt8]) -> Int { Int(pixel[1]) - Int(pixel[0]) }
    // Mask Blur 1.5: full paint deep inside, none in the soft band at the edge, where the run only
    // partly regenerates, rising to whole where it regenerates all but fully; none outside.
    let blurred = try canvas(mask, blur: 1.5)
    #expect(Self.pixel(blurred, 32, 32) == [0, 255, 0, 255] && Self.pixel(blurred, 22, 32) == [0, 255, 0, 255])
    #expect(Self.pixel(blurred, 16, 32) == [255, 255, 255, 255] && Self.pixel(blurred, 17, 32) == [255, 255, 255, 255])
    let ramp = greenness(Self.pixel(blurred, 18, 32))
    #expect(ramp > -255 && ramp < 255 && Self.pixel(blurred, 18, 32) != [255, 255, 255, 255])
    #expect(Self.pixel(blurred, 14, 32) == [255, 255, 255, 255] && Self.pixel(blurred, 8, 8) == [255, 255, 255, 255])
    // Mask Blur 0: the hard mask, paint exactly over it.
    let hard = try canvas(mask, blur: 0)
    #expect(Self.pixel(hard, 16, 32) == [0, 255, 0, 255] && Self.pixel(hard, 15, 32) == [255, 255, 255, 255])
    // No mask: the paint guides the whole frame, unfaded.
    #expect(Self.pixel(try canvas(nil, blur: 1.5), 16, 32) == [0, 255, 0, 255])
    // The Draw entry's image is faded the same way, at the image's pixels.
    let fade = CanvasPaint.Fade(mask: mask, maskBlur: 1.5, maskBlurOutset: 0)
    let baked = try #require(paint.baked(onto: image, fade: fade))
    #expect(CanvasRefineTests.rgba(baked) == CanvasRefineTests.rgba(blurred))
  }

  @Test func coloredAreasBecomeAMask() throws {
    // A soft-edged dab and a faint rectangle: any alpha counts; erased paint doesn't.
    let paint = CanvasPaint(strokes: [
      CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 10, y: 10)], radius: 4, color: Self.red),
      .rect(CGRect(x: 30, y: 30, width: 10, height: 10), color: CanvasPaint.Color(red: 0, green: 0, blue: 1, alpha: 0.1)),
      CanvasPaint.Stroke(kind: .erase, points: [CGPoint(x: 35, y: 35)], radius: 2),
    ])
    let stroke = try #require(paint.maskStroke(width: 64, height: 64))
    let mask = CanvasMask(strokes: [stroke]).coverage(width: 64, height: 64)
    let layer = try #require(paint.layer(width: 64, height: 64))
    let alpha = try #require(CanvasMask.alpha(of: layer, width: 64, height: 64))
    #expect(mask == alpha.map { $0 != 0 ? 255 : 0 })
    #expect(mask[10 * 64 + 10] == 255 && mask[32 * 64 + 32] == 255 && mask[35 * 64 + 35] == 0 && mask[50 * 64 + 50] == 0)
    #expect(CanvasPaint(strokes: [CanvasPaint.Stroke(kind: .erase, points: [.zero], radius: 4)]).maskStroke(width: 8, height: 8) == nil)
  }

  @Test func paintChangesWhatARunTakes() throws {
    let image = try CanvasRefineTests.pattern(width: 64, height: 64)
    let frame = CGSize(width: 64, height: 64)
    let paint = CanvasPaint(strokes: [.rect(CGRect(x: 0, y: 0, width: 16, height: 16), color: Self.red)])
    func inputs(
      _ paint: CanvasPaint?, mask: CanvasMask? = nil, merge: Bool = false, scale: Double? = nil, offset: CGSize = .zero
    ) throws -> RefineInputs {
      try #require(
        RefineInputs.make(
          source: image, sourceTensorId: 42, isImported: false, scale: scale, offset: offset, frame: frame, mask: mask,
          merge: merge, paint: paint))
    }
    let plain = try inputs(nil), painted = try inputs(paint)
    // The frame is the step's image as it is: reused, unless painted on.
    #expect(plain.canvasTensorId == 42 && painted.canvasTensorId == nil)
    #expect(plain.canvasKey != painted.canvasKey)
    let smaller = CanvasPaint(strokes: [.rect(CGRect(x: 0, y: 0, width: 8, height: 8), color: Self.red)])
    #expect(try inputs(smaller).canvasKey != painted.canvasKey)
    #expect(Self.pixel(painted.canvas, 4, 4) == [255, 0, 0, 255] && Self.pixel(plain.canvas, 4, 4) != [255, 0, 0, 255])
    // Paint that shows nothing is no paint.
    let erased = try inputs(CanvasPaint(strokes: [CanvasPaint.Stroke(kind: .erase, points: [.zero], radius: 4)]))
    #expect(erased.canvasTensorId == 42 && erased.canvasKey == plain.canvasKey)

    // Merging with a mask: paint is only the input. The merge goes back into the unpainted source,
    // its step kept for the bottom layer (the input is the painted frame, saved anew), so paint
    // outside the mask (here partly over it) is gone from the result.
    let mask = CanvasMask(rects: [CGRect(x: 8, y: 8, width: 16, height: 16)])
    let plainMerge = try #require(try inputs(nil, mask: mask, merge: true).merge)
    let merging = try inputs(paint, mask: mask, merge: true)
    let merge = try #require(merging.merge)
    #expect(!plainMerge.painted && plainMerge.unpaintedInput == nil)
    #expect(merge.painted && merge.source === image && merge.sourceTensorId == 42 && merging.canvasTensorId == nil)
    // The run takes the paint where the mask regenerates; outside it, the image as it was.
    #expect(Self.pixel(merging.canvas, 12, 12) == [255, 0, 0, 255] && Self.pixel(merging.canvas, 4, 4) == Self.pixel(image, 4, 4))
    let unpainted = try #require(merge.unpaintedInput)
    #expect(Self.pixel(unpainted, 4, 4) == Self.pixel(image, 4, 4))
    // Saved with a queued job, the record says it was painted; an older record decodes as not.
    let restored = RefineMerge(record: merge.record, source: merge.source, sameProject: true)
    #expect(restored.painted && restored.unpaintedInput == nil)
    let old = #"{"scale":null,"offsetX":0,"offsetY":0,"frameWidth":64,"frameHeight":64,"detailTensorId":42,"paint":{"strokes":[]}}"#
    let decoded = try JSONDecoder().decode(RefineMerge.Record.self, from: Data(old.utf8))
    #expect(decoded.painted == nil)
    let result = try CanvasRefineTests.solid(width: 64, height: 64, red: 0, green: 0, blue: 255)
    let merged = try #require(CanvasMerge.merge(result, into: merge, input: merge.unpaintedInput, maskBlur: 0, maskBlurOutset: 0))
    // Paint outside the mask: the source as it was. Inside: the result.
    #expect(Self.pixel(merged.image, 4, 4) == Self.pixel(image, 4, 4) && Self.pixel(merged.image, 12, 12) == [0, 0, 255, 255])
    #expect(merged.step.layers?.source === image)
    // Zoomed in (a dense frame) and without a mask (the whole frame generated): no paint either.
    let zoomed = try #require(try inputs(paint, mask: mask, merge: true, scale: 2, offset: CGSize(width: 32, height: 32)).merge)
    let zoomedMerge = try #require(CanvasMerge.merge(result, into: zoomed, input: zoomed.unpaintedInput, maskBlur: 2, maskBlurOutset: 0))
    #expect(Self.pixel(zoomedMerge.image, 4, 4) == Self.pixel(image, 4, 4))
    let whole = try #require(try inputs(paint, merge: true, scale: 2, offset: CGSize(width: 32, height: 32)).merge)
    let wholeMerge = try #require(CanvasMerge.merge(result, into: whole, input: whole.unpaintedInput, maskBlur: 0, maskBlurOutset: 0))
    #expect(Self.pixel(wholeMerge.image, 4, 4) == [0, 0, 255, 255] && Self.pixel(wholeMerge.image, 40, 40) == Self.pixel(image, 40, 40))
  }

  /// Add to Moodboard takes the canvas image with its paint baked in, unfaded (`moodboardImage`);
  /// without paint, or with paint that shows nothing, the image itself.
  @Test func moodboardImageBakesThePaint() throws {
    let image = try #require(CreateModel.blankImage(width: 16, height: 16))
    let paint = CanvasPaint(strokes: [.rect(CGRect(x: 0, y: 0, width: 8, height: 16), color: Self.red)])
    let baked = CreateModel.moodboardImage(image, paint: paint)
    #expect(baked !== image && baked.width == 16 && baked.height == 16)
    #expect(Self.pixel(baked, 2, 8) == [255, 0, 0, 255] && Self.pixel(baked, 12, 8) == [255, 255, 255, 255])
    #expect(CreateModel.moodboardImage(image, paint: nil) === image)
    #expect(CreateModel.moodboardImage(image, paint: CanvasPaint(strokes: [])) === image)
  }

  /// A layer read from a project file is drawn only when it holds up for the image
  /// (`CanvasPaint.validated`): non-finite or far-off points and radii, bad colours, too many
  /// strokes and bitmaps that don't read are rejected.
  @Test func storedPaintIsValidatedBeforeItsDrawn() throws {
    let good = CanvasPaint(strokes: [
      CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 1, y: 2), CGPoint(x: 30, y: 4)], radius: 3, color: Self.red),
      .rect(CGRect(x: -4, y: -4, width: 40, height: 40), color: Self.blue),
    ])
    #expect(good.validated(width: 32, height: 32) == good)
    #expect(good.validated(width: 0, height: 32) == nil)
    func with(_ stroke: CanvasPaint.Stroke) -> CanvasPaint { CanvasPaint(strokes: good.strokes + [stroke]) }
    #expect(with(CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: CGFloat.nan, y: 0)], radius: 1, color: Self.red)).validated(width: 32, height: 32) == nil)
    #expect(with(CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 1e9, y: 0)], radius: 1, color: Self.red)).validated(width: 32, height: 32) == nil)
    #expect(with(CanvasPaint.Stroke(kind: .brush, points: [.zero], radius: .infinity, color: Self.red)).validated(width: 32, height: 32) == nil)
    #expect(with(CanvasPaint.Stroke(kind: .brush, points: [.zero], radius: -1, color: Self.red)).validated(width: 32, height: 32) == nil)
    #expect(with(CanvasPaint.Stroke(kind: .brush, points: [.zero], radius: 1, color: CanvasPaint.Color(red: 5, green: 0, blue: 0))).validated(width: 32, height: 32) == nil)
    #expect(with(CanvasPaint.Stroke(kind: .fill, points: [.zero], color: Self.red, bitmap: Data([1, 2, 3]))).validated(width: 32, height: 32) == nil)
    let png = try #require(CanvasMask.grayPNG([UInt8](repeating: 255, count: 16), width: 4, height: 4))
    #expect(with(CanvasPaint.Stroke(kind: .fill, points: [.zero], color: Self.red, bitmap: png)).validated(width: 32, height: 32) != nil)
    #expect(with(CanvasPaint.Stroke(kind: .fill, points: [.zero], color: Self.red, bitmap: png, size: CGSize(width: 1e7, height: 4))).validated(width: 32, height: 32) == nil)
    let many = CanvasPaint(strokes: Array(repeating: good.strokes[0], count: CanvasPaint.maxStrokes + 1))
    #expect(many.validated(width: 32, height: 32) == nil)
  }

  /// A long sketch is kept flattened before it nears what a read takes (`compacted`), so what's
  /// stored always passes `validated` and the image matches its tile.
  @Test func aLongSketchIsKeptWithinTheLimits() throws {
    let dot = CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 4, y: 4)], radius: 2, color: Self.red)
    let long = CanvasPaint(strokes: Array(repeating: dot, count: CanvasPaint.maxStrokes / 2 + 1))
    let kept = long.compacted(for: CGSize(width: 16, height: 16), flatteningLong: true)
    #expect(kept.strokes.count == 1 && kept.strokes.first?.kind == .image)
    #expect(kept.validated(width: 16, height: 16) != nil)
    let layer = try #require(kept.layer(width: 16, height: 16))
    #expect(Self.pixel(layer, 4, 4)[0] > 200)
    // Other images' paint isn't flattened for its length (that happens off the main actor, for sketches).
    #expect(long.compacted(for: CGSize(width: 16, height: 16)) == long)
    let short = CanvasPaint(strokes: [dot])
    #expect(short.compacted(for: CGSize(width: 16, height: 16)) == short)
  }
}
