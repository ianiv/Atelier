@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// Auto masking's pure parts: mapping clicks and boxes from the canvas to the image and to SAM's
/// input, turning SAM's logits into a mask, committing a selection, and the encoder cache's key.
/// None of it needs the models.
struct AutoMaskTests {
  // MARK: Coordinates

  @Test func framePointsMapToImagePixelsAtAnyZoom() {
    let source = CGSize(width: 1000, height: 500)
    // Fitted: a 1000×500 frame shows it all, a pixel for a pixel.
    let fitted = CanvasPlacement(sourceSize: source, frameSize: source, scale: nil, offset: .zero)
    #expect(fitted.sourcePoint(fromFrame: CGPoint(x: 250, y: 100)) == CGPoint(x: 250, y: 100))
    // 2× on the top-left quadrant: frame pixel (0, 0) is image (0, 0), (500, 250) is (250, 125).
    let zoomed = CanvasPlacement(sourceSize: source, frameSize: source, showing: CGRect(x: 0, y: 0, width: 500, height: 250))
    #expect(zoomed.sourcePoint(fromFrame: .zero) == .zero)
    #expect(zoomed.sourcePoint(fromFrame: CGPoint(x: 500, y: 250)) == CGPoint(x: 250, y: 125))
    // Panned right by 100 frame pixels at 1×: the frame's (100, 0) shows the image's left edge.
    let panned = CanvasPlacement(sourceSize: source, frameSize: source, scale: 1, offset: CGSize(width: 100, height: 0))
    #expect(panned.sourcePoint(fromFrame: CGPoint(x: 100, y: 40)) == CGPoint(x: 0, y: 40))
    // And back.
    let point = CGPoint(x: 321, y: 123)
    #expect(zoomed.sourcePoint(fromFrame: zoomed.framePoint(fromSource: point)) == point)
  }

  @Test func clicksPastTheImageAreIgnoredAndBoxesCut() {
    let size = CGSize(width: 100, height: 50)
    #expect(SAMGeometry.clickPoint(CGPoint(x: 10, y: 10), imageSize: size) == CGPoint(x: 10, y: 10))
    #expect(SAMGeometry.clickPoint(CGPoint(x: -1, y: 10), imageSize: size) == nil)
    #expect(SAMGeometry.clickPoint(CGPoint(x: 10, y: 50), imageSize: size) == nil)
    // Dragged up and left from past the bottom right: cut to the image.
    #expect(
      SAMGeometry.clampedBox(from: CGPoint(x: 150, y: 80), to: CGPoint(x: 60, y: 20), imageSize: size)
        == CGRect(x: 60, y: 20, width: 40, height: 30))
    // Wholly off the image.
    #expect(SAMGeometry.clampedBox(from: CGPoint(x: 120, y: 0), to: CGPoint(x: 200, y: 40), imageSize: size) == nil)
  }

  @Test func imagePointsStretchIntoSAMsSquareInput() {
    let size = CGSize(width: 2048, height: 512)
    #expect(SAMGeometry.modelPoint(CGPoint(x: 1024, y: 256), sourceSize: size) == CGPoint(x: 512, y: 512))
    #expect(SAMGeometry.modelPoint(CGPoint(x: 2048, y: 0), sourceSize: size) == CGPoint(x: 1024, y: 0))
  }

  @Test func promptPutsTheBoxFirstAndKeepsTheLatestClicks() {
    let size = CGSize(width: 1024, height: 1024)
    var prompt = SAMSegmenter.Prompt(
      points: [.init(location: CGPoint(x: 10, y: 20), positive: true), .init(location: CGPoint(x: 30, y: 40), positive: false)],
      box: CGRect(x: 300, y: 400, width: -100, height: -100))
    let inputs = SAMGeometry.promptInputs(prompt, sourceSize: size)
    // The box standardized to its top-left and bottom-right corners, labelled 2 and 3.
    #expect(inputs.points == [CGPoint(x: 200, y: 300), CGPoint(x: 300, y: 400), CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)])
    #expect(inputs.labels == [2, 3, 1, 0])
    // Past the decoder's limit the earliest clicks go; the box stays.
    prompt.points = (0..<20).map { .init(location: CGPoint(x: Double($0), y: 0), positive: true) }
    let limited = SAMGeometry.promptInputs(prompt, sourceSize: size)
    #expect(limited.points.count == SAMGeometry.maxPromptPoints)
    #expect(limited.labels.prefix(2) == [2, 3])
    #expect(limited.points.last == CGPoint(x: 19, y: 0))
    #expect(limited.points[2] == CGPoint(x: Double(20 - (SAMGeometry.maxPromptPoints - 2)), y: 0))
  }

  // MARK: Logits to mask

  @Test func logitsUpsampleAndThresholdOntoTheImage() throws {
    // A 4×4 grid, positive in its left half: upsampled to 8×6, the left half is selected.
    let side = 4
    let logits: [Float] = (0..<(side * side)).map { $0 % side < 2 ? 5 : -5 }
    let upsampled = SAMGeometry.upsample(logits, side: side, width: 8, height: 6)
    #expect(upsampled.count == 48)
    let mask = SAMGeometry.threshold(upsampled)
    for y in 0..<6 {
      #expect(Array(mask[(y * 8)..<(y * 8 + 8)]) == [255, 255, 255, 255, 0, 0, 0, 0])
    }
    // Centers aligned: an even grid resampled to its own size is unchanged.
    #expect(SAMGeometry.upsample(logits, side: side, width: 4, height: 4) == logits)
    // A single positive cell grows to the matching block, bilinear in between.
    var dot = [Float](repeating: -1, count: side * side)
    dot[1 * side + 2] = 3
    let grown = SAMGeometry.threshold(SAMGeometry.upsample(dot, side: side, width: 16, height: 16))
    #expect(grown[6 * 16 + 10] == 255)
    #expect(grown[0] == 0 && grown[15 * 16 + 15] == 0)

    // The mask image reads back as a bitmap stroke that paints those pixels.
    let image = try #require(SAMGeometry.grayImage(mask, width: 8, height: 6))
    let stroke = try #require(CanvasMask.Stroke.bitmap(image))
    #expect(CanvasMask(strokes: [stroke]).coverage(width: 8, height: 6) == mask)
  }

  @Test func bestMaskIsTheHighestScore() {
    #expect(SAMGeometry.bestMask(scores: [0.7, 0.91, 0.3]) == 1)
    #expect(SAMGeometry.bestMask(scores: []) == 0)
  }

  // MARK: Merging into the mask

  @Test func addSubtractReplaceMerge() throws {
    let width = 10, height = 10
    func coverage(_ rect: CGRect) -> [UInt8] {
      CanvasMask(rects: [rect]).coverage(width: width, height: height)
    }
    func selection(_ rect: CGRect) throws -> CanvasMask.Stroke {
      let image = try #require(SAMGeometry.grayImage(coverage(rect), width: width, height: height))
      return try #require(CanvasMask.Stroke.bitmap(image))
    }
    let left = CGRect(x: 0, y: 0, width: 5, height: 10)
    let top = CGRect(x: 0, y: 0, width: 10, height: 5)
    let existing = CanvasMask(rects: [left])
    let picked = try selection(top)

    let added = try #require(AutoMaskMode.add.applied(picked, to: existing))
    #expect(added.coverage(width: width, height: height) == zip(coverage(left), coverage(top)).map { max($0, $1) })

    let subtracted = try #require(AutoMaskMode.subtract.applied(picked, to: existing))
    #expect(subtracted.coverage(width: width, height: height) == coverage(CGRect(x: 0, y: 5, width: 5, height: 5)))
    // Subtracting what was just added gives back the mask before, where they didn't overlap.
    let away = try selection(CGRect(x: 6, y: 0, width: 4, height: 4))
    let restored = try #require(AutoMaskMode.subtract.applied(away, to: AutoMaskMode.add.applied(away, to: existing)))
    #expect(restored.coverage(width: width, height: height) == existing.coverage(width: width, height: height))

    let replaced = try #require(AutoMaskMode.replace.applied(picked, to: existing))
    #expect(replaced.coverage(width: width, height: height) == coverage(top))
    #expect(replaced.strokes.count == 1)

    #expect(AutoMaskMode.subtract.applied(picked, to: nil) == nil)
    #expect(AutoMaskMode.add.applied(picked, to: nil)?.coverage(width: width, height: height) == coverage(top))
  }

  // MARK: Rectangle and Lasso

  @Test func rectangleIsStandardizedAndCutToTheImage() {
    let size = CGSize(width: 100, height: 50)
    // Dragged up and left from past the bottom right.
    #expect(
      SelectionShape.rect(from: CGPoint(x: 150, y: 80), to: CGPoint(x: 60, y: 20), imageSize: size)
        == .rect(CGRect(x: 60, y: 20, width: 40, height: 30)))
    // Less than a pixel, or off the image: nothing.
    #expect(SelectionShape.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.5, y: 30), imageSize: size) == nil)
    #expect(SelectionShape.rect(from: CGPoint(x: 120, y: 0), to: CGPoint(x: 200, y: 40), imageSize: size) == nil)
  }

  @Test func rectangleCoversExactlyItsPixels() {
    let shape = SelectionShape.rect(CGRect(x: 3, y: 2, width: 5, height: 4))
    let coverage = shape.coverage(width: 12, height: 10)
    #expect(coverage.count(where: { $0 != 0 }) == 20)
    #expect(coverage[2 * 12 + 3] == 255 && coverage[5 * 12 + 7] == 255)
    #expect(coverage[1 * 12 + 3] == 0 && coverage[2 * 12 + 8] == 0)
    #expect(shape.actionName == "Select Rectangle")
  }

  @Test func lassoNeedsAreaOnTheImage() {
    let size = CGSize(width: 100, height: 100)
    #expect(SelectionShape.lasso([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], imageSize: size) == nil)
    // Collinear: no area.
    #expect(SelectionShape.lasso([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)], imageSize: size) == nil)
    // Wholly off the image.
    #expect(SelectionShape.lasso([CGPoint(x: 200, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 250, y: 50)], imageSize: size) == nil)
    #expect(SelectionShape.lasso([CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 5, y: 5)], imageSize: size) == nil)
    // Partly off it is kept as drawn.
    let partly = [CGPoint(x: -20, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 60)]
    #expect(SelectionShape.lasso(partly, imageSize: size) == .polygon(partly))
    #expect(SelectionShape.lasso(partly, imageSize: size)?.actionName == "Select Lasso")
  }

  @Test func lassoPointsAreSpacedAndCapped() {
    var points: [CGPoint] = []
    for x in stride(from: 0.0, through: 10, by: 0.5) {
      points = SelectionShape.appending(CGPoint(x: x, y: 0), to: points, minSpacing: 2)
    }
    // The first, then every 2 px.
    #expect(points.first == .zero)
    #expect(points.map(\.x) == [0, 2, 4, 6, 8, 10])
    #expect(SelectionShape.appending(CGPoint(x: CGFloat.infinity, y: 0), to: points, minSpacing: 2) == points)
    let full = (0..<SelectionShape.maxLassoPoints).map { CGPoint(x: Double($0) * 3, y: 0) }
    #expect(SelectionShape.appending(CGPoint(x: -100, y: 0), to: full, minSpacing: 2).count == SelectionShape.maxLassoPoints)
  }

  @Test func lassoTriangleCoversAboutItsArea() throws {
    let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)]
    let shape = try #require(SelectionShape.lasso(triangle, imageSize: CGSize(width: 100, height: 100)))
    #expect(abs(SelectionShape.area(triangle)) == 5000)
    let count = shape.coverage(width: 100, height: 100).count(where: { $0 != 0 })
    #expect(abs(count - 5000) <= 110)
  }

  @Test func crossingLassoFillsBothLobes() throws {
    // A figure 8: the two loops wind opposite ways, and both are selected.
    let eight = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 40), CGPoint(x: 40, y: 0), CGPoint(x: 0, y: 40)]
    // Its signed area is nothing (the loops cancel), but it isn't a line.
    #expect(SelectionShape.area(eight) == 0)
    let shape = try #require(SelectionShape.lasso(eight, imageSize: CGSize(width: 40, height: 40)))
    let coverage = shape.coverage(width: 40, height: 40)
    #expect(coverage[20 * 40 + 5] == 255)
    #expect(coverage[20 * 40 + 35] == 255)
    #expect(coverage[3 * 40 + 20] == 0)
  }

  @Test func shapeSelectionCommitsLikeSAMs() throws {
    let width = 10, height = 10
    let shape = SelectionShape.rect(CGRect(x: 0, y: 0, width: 10, height: 5))
    let image = try #require(SAMGeometry.grayImage(shape.coverage(width: width, height: height), width: width, height: height))
    let picked = try #require(CanvasMask.Stroke.bitmap(image))
    let existing = CanvasMask(rects: [CGRect(x: 0, y: 0, width: 5, height: 10)])
    let added = try #require(AutoMaskMode.add.applied(picked, to: existing))
    #expect(added.coverage(width: width, height: height).count(where: { $0 != 0 }) == 75)
    let subtracted = try #require(AutoMaskMode.subtract.applied(picked, to: existing))
    #expect(subtracted.coverage(width: width, height: height).count(where: { $0 != 0 }) == 25)
    let replaced = try #require(AutoMaskMode.replace.applied(picked, to: existing))
    #expect(replaced.coverage(width: width, height: height) == shape.coverage(width: width, height: height))
  }

  @Test func lassoPointsMapThroughTheCanvasPlacement() throws {
    // At 2× with the image moved: the 2000×1000 drawing's left edge is 400 frame pixels left of
    // the frame's, its top 200 above, so frame (0, 0) is image (200, 100).
    let source = CGSize(width: 1000, height: 500)
    let placement = CanvasPlacement(sourceSize: source, frameSize: source, scale: 2, offset: CGSize(width: 100, height: 50))
    let frame = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 100)]
    let image = frame.map { placement.sourcePoint(fromFrame: $0) }
    #expect(image == [CGPoint(x: 200, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 200, y: 150)])
    let shape = try #require(SelectionShape.lasso(image, imageSize: source))
    let coverage = shape.coverage(width: 1000, height: 500)
    #expect(coverage[110 * 1000 + 210] == 255)
    #expect(coverage[140 * 1000 + 290] == 0)
    #expect(coverage[90 * 1000 + 210] == 0)
  }

  // MARK: iPad touches for Rectangle and Lasso

  typealias Tracker = ShapeTouchTracker<Int>

  static func finger(_ id: Int, _ x: Double, _ y: Double, _ phase: Tracker.Phase = .active) -> Tracker.Touch {
    Tracker.Touch(id: id, isPencil: false, phase: phase, location: CGPoint(x: x, y: y))
  }

  static func pencil(_ id: Int, _ x: Double, _ y: Double, _ phase: Tracker.Phase = .active) -> Tracker.Touch {
    Tracker.Touch(id: id, isPencil: true, phase: phase, location: CGPoint(x: x, y: y))
  }

  static func draws(_ actions: [Tracker.Action]) -> Bool {
    actions.contains { if case .draw = $0 { true } else if case .end = $0 { true } else { false } }
  }

  @Test func oneFingerDrawsAndEndsOneShape() {
    var tracker = Tracker()
    #expect(tracker.update([Self.finger(1, 0, 0)]) == [.draw(start: .zero, to: .zero)])
    #expect(tracker.update([Self.finger(1, 50, 40)]) == [.draw(start: .zero, to: CGPoint(x: 50, y: 40))])
    #expect(tracker.end([Self.finger(1, 60, 40, .ended)]) == [
      .draw(start: .zero, to: CGPoint(x: 60, y: 40)), .end(start: .zero, to: CGPoint(x: 60, y: 40), pencil: false),
    ])
    // Lifted in `onChanged` instead: ended there, nothing more at the gesture's end.
    var lifted = Tracker()
    _ = lifted.update([Self.finger(1, 0, 0)])
    #expect(lifted.update([Self.finger(1, 10, 10, .ended)]).last == .end(start: .zero, to: CGPoint(x: 10, y: 10), pencil: false))
    #expect(lifted.end([]).isEmpty)
  }

  @Test func aSecondFingerCancelsAndPinches() {
    var tracker = Tracker()
    _ = tracker.update([Self.finger(1, 0, 0)])
    _ = tracker.update([Self.finger(1, 20, 0)])
    let actions = tracker.update([Self.finger(1, 20, 0), Self.finger(2, 100, 100)])
    #expect(actions == [.cancel, .pinch(ids: [1, 2], a: CGPoint(x: 20, y: 0), b: CGPoint(x: 100, y: 100))])
    #expect(tracker.end([Self.finger(1, 20, 0, .ended), Self.finger(2, 100, 100, .ended)]).isEmpty)
  }

  @Test func theFingerLeftAfterAPinchDrawsNothing() {
    // The drawing finger lifts first and drops out of the events; the other keeps moving.
    var tracker = Tracker()
    _ = tracker.update([Self.finger(1, 0, 0)])
    _ = tracker.update([Self.finger(1, 0, 0), Self.finger(2, 50, 50)])
    _ = tracker.update([Self.finger(1, 0, 0, .ended), Self.finger(2, 60, 60)])
    #expect(!Self.draws(tracker.update([Self.finger(2, 90, 90)])))
    #expect(!Self.draws(tracker.update([Self.finger(2, 140, 140)])))
    #expect(tracker.end([Self.finger(2, 150, 150, .ended)]).isEmpty)
    // And the other way round: both landing together.
    var together = Tracker()
    _ = together.update([Self.finger(1, 0, 0), Self.finger(2, 50, 50)])
    #expect(!Self.draws(together.update([Self.finger(2, 90, 90)])))
    #expect(together.end([Self.finger(2, 90, 90, .ended)]).isEmpty)
  }

  @Test func pencilDrawsPastARestingFingerWhichThenDrawsNothing() {
    var tracker = Tracker()
    _ = tracker.update([Self.finger(9, 300, 300), Self.pencil(1, 0, 0)])
    #expect(tracker.update([Self.finger(9, 300, 300), Self.pencil(1, 40, 40)]) == [.draw(start: .zero, to: CGPoint(x: 40, y: 40))])
    #expect(tracker.update([Self.finger(9, 300, 300), Self.pencil(1, 50, 50, .ended)]).last
      == .end(start: .zero, to: CGPoint(x: 50, y: 50), pencil: true))
    // The Pencil has dropped out; the resting finger moving draws nothing.
    #expect(!Self.draws(tracker.update([Self.finger(9, 320, 330)])))
    #expect(!Self.draws(tracker.update([Self.finger(9, 360, 380)])))
    #expect(tracker.end([Self.finger(9, 360, 380, .ended)]).isEmpty)
  }

  @Test func aPinchCancelsAndAnUnseenEndStartsOver() {
    var tracker = Tracker()
    _ = tracker.update([Self.finger(1, 0, 0)])
    let wasDrawing = tracker.cancel()
    #expect(wasDrawing)
    #expect(!Self.draws(tracker.update([Self.finger(1, 30, 30)])))
    // A new gesture whose start came without the last one's end: none of its touches were seen.
    #expect(tracker.update([Self.finger(5, 10, 10)]) == [.draw(start: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10))])
    // A cancelled touch drops the shape.
    #expect(tracker.update([Self.finger(5, 20, 20, .cancelled)]) == [.cancel])
    #expect(tracker.end([]).isEmpty)
  }

  @Test func selectModeRawValuesStayPut() {
    #expect(SelectMode.allCases.map(\.rawValue) == ["smart", "rectangle", "lasso"])
    #expect(SelectMode.stored("lasso") == .lasso)
    #expect(SelectMode.stored("polygon") == .smart)
    #expect(SelectMode.stored(nil) == .smart)
  }

  // MARK: Encoder cache

  @Test func encoderCacheKeyChangesWithTheImageAndModel() throws {
    let first = try CanvasRefineTests.pattern(width: 8, height: 8)
    let second = try CanvasRefineTests.pattern(width: 8, height: 8)
    var cache = SAMEmbeddingCache<String>(capacity: 2)
    let firstSmall = SAMEmbeddingCache<String>.Key(image: first, size: .small)
    cache.insert("first", for: firstSmall)
    #expect(cache.value(for: SAMEmbeddingCache<String>.Key(image: first, size: .small)) == "first")
    // Same pixels, another image: encoded again.
    #expect(cache.value(for: SAMEmbeddingCache<String>.Key(image: second, size: .small)) == nil)
    // Another SAM size: its encoder differs.
    #expect(cache.value(for: SAMEmbeddingCache<String>.Key(image: first, size: .large)) == nil)
    // Two at most, the least recently used going first.
    cache.insert("second", for: SAMEmbeddingCache<String>.Key(image: second, size: .small))
    _ = cache.value(for: firstSmall)
    cache.insert("first large", for: SAMEmbeddingCache<String>.Key(image: first, size: .large))
    #expect(cache.entries.count == 2)
    #expect(cache.contains(firstSmall))
    #expect(!cache.contains(SAMEmbeddingCache<String>.Key(image: second, size: .small)))
    cache.removeAll()
    #expect(!cache.contains(firstSmall))
  }

  @Test func listingKeepsOnlyPackageFiles() throws {
    let listing = """
    [{"type":"directory","path":"A.mlpackage","size":0},
     {"type":"file","path":"README.md","size":10},
     {"type":"file","path":"A.mlpackage/Data/com.apple.CoreML/model.mlmodel","size":12},
     {"type":"file","path":"A.mlpackage/Manifest.json","size":3}]
    """
    let files = try SAMFiles.packageFiles(inListing: Data(listing.utf8))
    #expect(files == [
      SAMFiles.ListedFile(path: "A.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 12),
      SAMFiles.ListedFile(path: "A.mlpackage/Manifest.json", size: 3),
    ])
  }
}
