import CoreGraphics
import Foundation

/// Choosing the frame for refining part of an image: the region around a box (a face, a mask's
/// bounds), the output size that shows it, and the canvas zoom and offset that put it in the
/// frame. Pure arithmetic over image pixels (from the top left), for callers that name what to
/// work on instead of moving the canvas.
nonisolated enum FrameSelection {
  /// The region to show for `box`: padded by `padding` pixels on every side, then grown about its
  /// centre to `aspect` (width over height), wider or taller, never cropped
  /// (`CanvasPlacement.grown`). With `inside`, the image's size, the region is moved (not cropped
  /// or shrunk) to lie inside the image along each side it fits in; along one it's larger than, it
  /// stays centred on the box and reaches past the image.
  static func region(around box: CGRect, padding: Double, aspect: Double, inside sourceSize: CGSize?) -> CGRect {
    var region = box.standardized.insetBy(dx: -padding, dy: -padding)
    if aspect > 0, aspect.isFinite {
      region = CanvasPlacement.grown(region, toShapeOf: CGSize(width: aspect, height: 1))
    }
    guard let sourceSize else { return region }
    if region.width <= sourceSize.width {
      region.origin.x = min(max(region.minX, 0), sourceSize.width - region.width)
    }
    if region.height <= sourceSize.height {
      region.origin.y = min(max(region.minY, 0), sourceSize.height - region.height)
    }
    return region
  }

  /// The output size for showing `region`, each side a multiple of 64 as the size setting takes,
  /// and the region the frame then shows. The size is `width` × `height` when both are given;
  /// else the region at `scale` frame pixels per image pixel; else the region's shape at about
  /// `pixelCount` pixels (`CanvasPlacement.frameSize`). With `scale`, the region returned is the
  /// size divided by it about the same centre, so the zoom is exactly `scale` (912×1152 at 4 is
  /// 3648×4608): a merging run keeps a whole zoom's pixels one for one (`RefineMerge.snapped`,
  /// `CanvasMerge.denseFrame`). A size from `scale` alone is rounded up to 64s, so that region
  /// always holds the one asked for: rounded to the nearest, a 200×200 region at 1 would show
  /// 192×192 of it, cropping what the caller padded. Where it can, the region starts on a whole
  /// image pixel: a merge that reaches past the image grows it to whole pixels, and a region
  /// starting on a third of one at 3× would grow it by a pixel more than its size. Without
  /// `scale`, the region is grown to the size's shape, which is what fitting it in the frame shows.
  static func frame(for region: CGRect, width: Int?, height: Int?, scale: Double?, pixelCount: Double) -> (size: CGSize, region: CGRect) {
    func units(_ value: Double) -> Double { max((value / 64).rounded(), 1) * 64 }
    // The slack is for a product a hair over a whole unit (912 × 4 must stay 57 units).
    func unitsUp(_ value: Double) -> Double { max((value / 64 - 1e-9).rounded(.up), 1) * 64 }
    let scale = scale.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
    let size: CGSize
    if let width, let height, width > 0, height > 0 {
      size = CGSize(width: units(Double(width)), height: units(Double(height)))
    } else if let scale {
      size = CGSize(width: unitsUp(region.width * scale), height: unitsUp(region.height * scale))
    } else {
      size = CanvasPlacement.frameSize(forRegion: region.size, pixelCount: pixelCount)
    }
    guard let scale else { return (size, CanvasPlacement.grown(region, toShapeOf: size)) }
    /// Where a side of `length` starts, centred on `low`…`high`: on a whole pixel when the side
    /// is whole pixels and still holds `low`…`high` from there.
    func start(_ low: Double, _ high: Double, _ length: Double) -> Double {
      let centred = (low + high) / 2 - length / 2
      guard length == length.rounded() else { return centred }
      for whole in [centred.rounded(), centred.rounded(.down)] where whole <= low + 1e-9 && whole + length >= high - 1e-9 {
        return whole
      }
      return centred
    }
    let shown = CGSize(width: size.width / scale, height: size.height / scale)
    return (
      size,
      CGRect(
        x: start(region.minX, region.maxX, shown.width), y: start(region.minY, region.maxY, shown.height), width: shown.width,
        height: shown.height))
  }

  /// The canvas zoom and offset (`CanvasState`) that show `region` of an image of `sourceSize` in
  /// a frame of `frameSize`, fitted and centred. A zoom beyond the canvas's range
  /// (`CanvasState.range`) is held at its end, about the same centre: `clamped` says so, and the
  /// frame then shows more or less than the region.
  static func placement(showing region: CGRect, sourceSize: CGSize, frameSize: CGSize) -> (scale: Double, offset: CGSize, clamped: Bool) {
    let wanted = CanvasPlacement.zoomAndOffset(showing: region, sourceSize: sourceSize, frameSize: frameSize)
    let scale = min(max(wanted.scale, CanvasState.range.lowerBound), CanvasState.range.upperBound)
    let offset = CanvasPlacement.offset(centering: CGPoint(x: region.midX, y: region.midY), scale: scale, sourceSize: sourceSize)
    return (scale, offset, scale != wanted.scale)
  }
}
