@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// Choosing a frame for part of an image (`FrameSelection`): the region around a box, the output
/// size for it, and the canvas placement that shows it.
@Suite(.tags(.smoke))
struct FrameSelectionTests {
  @Test func paddingGoesOnEverySide() {
    let box = CGRect(x: 100, y: 120, width: 100, height: 100)
    #expect(FrameSelection.region(around: box, padding: 25, aspect: 1, inside: nil) == CGRect(x: 75, y: 95, width: 150, height: 150))
    #expect(FrameSelection.region(around: box, padding: 0, aspect: 1, inside: nil) == box)
  }

  @Test func theRegionGrowsToTheShapeWithoutCropping() {
    let box = CGRect(x: 100, y: 100, width: 100, height: 100)
    #expect(FrameSelection.region(around: box, padding: 0, aspect: 2, inside: nil) == CGRect(x: 50, y: 100, width: 200, height: 100))
    #expect(FrameSelection.region(around: box, padding: 0, aspect: 0.5, inside: nil) == CGRect(x: 100, y: 50, width: 100, height: 200))
    // Padded first, then grown: the padding is kept on the short side.
    let padded = FrameSelection.region(around: box, padding: 10, aspect: 2, inside: nil)
    #expect(padded == CGRect(x: 30, y: 90, width: 240, height: 120))
  }

  @Test func theRegionMovesInsideTheImage() {
    let size = CGSize(width: 1000, height: 800)
    // Near the top left: moved, the same size.
    #expect(
      FrameSelection.region(around: CGRect(x: 0, y: 10, width: 100, height: 100), padding: 50, aspect: 1, inside: size)
        == CGRect(x: 0, y: 0, width: 200, height: 200))
    // Near the bottom right.
    #expect(
      FrameSelection.region(around: CGRect(x: 950, y: 750, width: 50, height: 50), padding: 25, aspect: 1, inside: size)
        == CGRect(x: 900, y: 700, width: 100, height: 100))
    // Already inside: left alone.
    let middle = CGRect(x: 400, y: 300, width: 100, height: 100)
    #expect(FrameSelection.region(around: middle, padding: 0, aspect: 1, inside: size) == middle)
    // Taller than the image: moved across, centred on the box down, reaching past the image.
    #expect(
      FrameSelection.region(around: CGRect(x: 0, y: 350, width: 100, height: 100), padding: 400, aspect: 1, inside: size)
        == CGRect(x: 0, y: -50, width: 900, height: 900))
  }

  @Test func aScaleIsKeptExactly() {
    // The face-fix case: 912×1152 at 4× is already whole units of 64.
    let region = CGRect(x: 1100, y: 640, width: 912, height: 1152)
    let exact = FrameSelection.frame(for: region, width: nil, height: nil, scale: 4, pixelCount: 1024 * 1024)
    #expect(exact.size == CGSize(width: 3648, height: 4608) && exact.region == region)
    // A region that isn't: the size rounds to 64s and the region follows, about the same centre.
    let loose = CGRect(x: 100, y: 200, width: 900, height: 1150)
    let frame = FrameSelection.frame(for: loose, width: nil, height: nil, scale: 4, pixelCount: 1024 * 1024)
    #expect(frame.size == CGSize(width: 3584, height: 4608))
    #expect(frame.region == CGRect(x: 102, y: 199, width: 896, height: 1152))
    let placement = FrameSelection.placement(showing: frame.region, sourceSize: CGSize(width: 3200, height: 5056), frameSize: frame.size)
    #expect(placement.scale == 4 && !placement.clamped)
    // The merge then takes it as it is (`RefineMerge.snapped`).
    let snapped = RefineMerge.snapped(
      scale: placement.scale, offset: placement.offset, sourceSize: CGSize(width: 3200, height: 5056), frameSize: frame.size)
    #expect(snapped.scale == 4 && snapped.offset == placement.offset)
  }

  @Test func sizesAreMultiplesOf64() {
    let region = CGRect(x: 10, y: 20, width: 300, height: 300)
    // A given size, rounded; the region grows to its shape.
    let given = FrameSelection.frame(for: region, width: 1000, height: 500, scale: nil, pixelCount: 1024 * 1024)
    #expect(given.size == CGSize(width: 1024, height: 512))
    #expect(given.region == CGRect(x: -140, y: 20, width: 600, height: 300))
    // A size and a scale: the region is the size over the scale.
    let both = FrameSelection.frame(for: region, width: 1024, height: 512, scale: 2, pixelCount: 1024 * 1024)
    #expect(both.size == CGSize(width: 1024, height: 512) && both.region == CGRect(x: -96, y: 42, width: 512, height: 256))
    // Neither: the region's shape at the pixel count.
    let neither = FrameSelection.frame(for: region, width: nil, height: nil, scale: nil, pixelCount: 1024 * 1024)
    #expect(neither.size == CGSize(width: 1024, height: 1024) && neither.region == region)
    let wide = FrameSelection.frame(for: CGRect(x: 0, y: 0, width: 400, height: 200), width: nil, height: nil, scale: nil, pixelCount: 1024 * 1024)
    #expect(wide.size.width.truncatingRemainder(dividingBy: 64) == 0 && wide.size.height.truncatingRemainder(dividingBy: 64) == 0)
    #expect(wide.size.width > wide.size.height)
    // A tiny region at a small scale still gets one unit.
    let tiny = FrameSelection.frame(for: CGRect(x: 0, y: 0, width: 10, height: 10), width: nil, height: nil, scale: 1, pixelCount: 1024 * 1024)
    #expect(tiny.size == CGSize(width: 64, height: 64) && tiny.region == CGRect(x: -27, y: -27, width: 64, height: 64))
  }

  @Test func theZoomIsHeldToTheCanvasRange() {
    let source = CGSize(width: 1000, height: 1000), frame = CGSize(width: 1024, height: 1024)
    // Fits: the zoom that shows the region, its centre in the middle of the frame.
    let fits = FrameSelection.placement(showing: CGRect(x: 0, y: 0, width: 512, height: 512), sourceSize: source, frameSize: frame)
    #expect(fits.scale == 2 && !fits.clamped && fits.offset == CGSize(width: 488, height: 488))
    #expect(CanvasPlacement(sourceSize: source, frameSize: frame, scale: fits.scale, offset: fits.offset).cropRect == CGRect(x: 0, y: 0, width: 512, height: 512))
    // Too small a region: held at the most the canvas zooms in, about the same centre.
    let near = FrameSelection.placement(showing: CGRect(x: 495, y: 495, width: 10, height: 10), sourceSize: source, frameSize: frame)
    #expect(near.scale == CanvasState.range.upperBound && near.clamped && near.offset == .zero)
    // Too large: held at the least.
    let far = FrameSelection.placement(showing: CGRect(x: -50_000, y: -50_000, width: 101_000, height: 101_000), sourceSize: source, frameSize: frame)
    #expect(far.scale == CanvasState.range.lowerBound && far.clamped && far.offset == .zero)
  }
}
