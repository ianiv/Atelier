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

  @Test func colorIsFoundOnlyWhereItLies() {
    // Two dabs in opposite corners: a rectangle between them has none.
    let paint = CanvasPaint(strokes: [
      CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 4, y: 4)], radius: 3, color: Self.red),
      CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 60, y: 60)], radius: 3, color: Self.red),
    ])
    #expect(paint.showsColor(in: CGRect(x: 0, y: 0, width: 10, height: 10)))
    #expect(paint.showsColor(in: CGRect(x: 56, y: 56, width: 8, height: 8)))
    #expect(!paint.showsColor(in: CGRect(x: 20, y: 20, width: 24, height: 24)))
    #expect(!paint.showsColor(in: CGRect(x: 50, y: 0, width: 14, height: 14)))
    // A brush of radius 0 still draws a hairline, so it counts.
    let hairline = CanvasPaint(strokes: [CanvasPaint.Stroke(kind: .brush, points: [CGPoint(x: 2, y: 8), CGPoint(x: 30, y: 8)], color: Self.red)])
    #expect(hairline.bounds(width: 32, height: 32) != nil && hairline.showsColor(in: CGRect(x: 10, y: 6, width: 4, height: 4)))
    // Erased paint isn't there.
    var erased = paint
    erased.strokes.append(CanvasPaint.Stroke(kind: .erase, points: [CGPoint(x: 4, y: 4)], radius: 6))
    #expect(!erased.showsColor(in: CGRect(x: 0, y: 0, width: 10, height: 10)))
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

  @Test func aSavedJobKeepsItsFillsCompacted() throws {
    // Two fills of a 32×32 image's halves: a queued job's record keeps one image of them.
    var bytes = [UInt8](repeating: 0, count: 16 * 32)
    for index in bytes.indices { bytes[index] = 255 }
    let half = try #require(CanvasMask.grayPNG(bytes, width: 16, height: 32))
    let paint = CanvasPaint(strokes: [
      CanvasPaint.Stroke(kind: .fill, points: [.zero], color: Self.red, bitmap: half),
      CanvasPaint.Stroke(kind: .fill, points: [CGPoint(x: 16, y: 0)], color: Self.blue, bitmap: half),
      CanvasPaint.Stroke(kind: .erase, points: [CGPoint(x: 8, y: 8)], radius: 2),
    ])
    let source = try CanvasRefineTests.pattern(width: 32, height: 32)
    let merge = RefineMerge(
      source: source, sourceTensorId: nil, scale: 2, offset: .zero, frameSize: CGSize(width: 32, height: 32), mask: nil,
      detailTensorId: 7, paint: paint)
    let data = try JSONEncoder().encode(merge.record)
    let record = try JSONDecoder().decode(RefineMerge.Record.self, from: data)
    #expect(record.paint?.strokes.count == 1 && record.paint?.strokes.first?.kind == .image)
    let restored = RefineMerge(record: record, source: source, sameProject: true)
    let before = try #require(paint.layer(width: 32, height: 32))
    let after = try #require(restored.paint?.layer(width: 32, height: 32))
    #expect(CanvasRefineTests.rgba(before) == CanvasRefineTests.rgba(after))
    #expect(restored.detailTensorId == 7 && Self.pixel(after, 8, 8)[3] == 0 && Self.pixel(after, 4, 20) == [255, 0, 0, 255])
  }

  @Test func paintChangesWhatARunTakes() throws {
    let image = try CanvasRefineTests.pattern(width: 64, height: 64)
    let frame = CGSize(width: 64, height: 64)
    let paint = CanvasPaint(strokes: [.rect(CGRect(x: 0, y: 0, width: 16, height: 16), color: Self.red)])
    func inputs(_ paint: CanvasPaint?, mask: CanvasMask? = nil, merge: Bool = false) throws -> RefineInputs {
      try #require(
        RefineInputs.make(
          source: image, sourceTensorId: 42, isImported: false, scale: nil, offset: .zero, frame: frame, mask: mask,
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

    // Merging with a mask: the source has the paint baked in at its own pixels and is no step's
    // image, but the detail of the step it was painted on is still carried, clear of the paint.
    let mask = CanvasMask(rects: [CGRect(x: 32, y: 32, width: 16, height: 16)])
    let plainMerge = try #require(try inputs(nil, mask: mask, merge: true).merge)
    let merging = try inputs(paint, mask: mask, merge: true)
    let merge = try #require(merging.merge)
    #expect(plainMerge.sourceTensorId == 42 && plainMerge.detailTensorId == nil && plainMerge.paint == nil)
    #expect(merge.sourceTensorId == nil && merging.canvasTensorId == nil && merge.detailTensorId == 42)
    #expect(merge.paint == paint)
    // A source baked by the caller (its Draw entry's) is the one the merge takes.
    let shared = try #require(paint.baked(onto: image))
    #expect(try #require(RefineInputs.make(
      source: image, sourceTensorId: 42, isImported: false, scale: nil, offset: .zero, frame: frame, mask: mask,
      merge: true, paint: paint, baked: shared)).merge?.source === shared)
    #expect(merge.source.width == 64 && Self.pixel(merge.source, 4, 4) == [255, 0, 0, 255])
    #expect(Self.pixel(merge.source, 40, 4) == Self.pixel(image, 40, 4))
    // Saved with a queued job, the record keeps them.
    let restored = RefineMerge(record: merge.record, source: merge.source, sameProject: true)
    #expect(restored.detailTensorId == 42 && restored.paint == paint)
    #expect(RefineMerge(record: merge.record, source: merge.source, sameProject: false).detailTensorId == nil)
    // The merged result keeps the paint outside the mask.
    let result = try CanvasRefineTests.solid(width: 64, height: 64, red: 0, green: 0, blue: 255)
    let merged = try #require(CanvasMerge.merge(result, into: merge, maskBlur: 0, maskBlurOutset: 0))
    #expect(Self.pixel(merged.image, 4, 4) == [255, 0, 0, 255] && Self.pixel(merged.image, 40, 40) == [0, 0, 255, 255])
    #expect(merged.step.layers?.detailTensorId == 42 && merged.step.layers?.paintLayer == paint)
  }
}
