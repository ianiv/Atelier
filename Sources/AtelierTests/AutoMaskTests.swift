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
