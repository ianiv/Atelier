import CoreGraphics
import Foundation

/// What a Select drag does: Smart asks SAM (a click a point, a drag a box), Rectangle and Lasso
/// select the shape drawn exactly, with no model. Remembered (`AutoMaskSession.selectMode`).
nonisolated enum SelectMode: String, CaseIterable, Sendable {
  case smart, rectangle, lasso

  var title: String {
    switch self {
    case .smart: "Smart"
    case .rectangle: "Rectangle"
    case .lasso: "Lasso"
    }
  }

  var systemImage: String {
    switch self {
    case .smart: "wand.and.sparkles"
    case .rectangle: "rectangle.dashed"
    case .lasso: "lasso"
    }
  }

  /// What the canvas's gestures do in this mode, for the Select bar's help.
  var gestureHelp: String {
    #if os(iOS)
      switch self {
      case .smart:
        "Tap to mark what to select (or what to leave out, with − chosen); drag a box with Apple Pencil. Fingers move and zoom."
      case .rectangle:
        "Drag a rectangle with Apple Pencil or one finger. Two fingers move and zoom."
      case .lasso:
        "Draw around what to select with Apple Pencil or one finger; letting go closes the shape. Two fingers move and zoom."
      }
    #else
      switch self {
      case .smart:
        "Click to mark what to select, Option-click what to leave out, or drag a box. Hold Space to drag the image."
      case .rectangle:
        "Drag a rectangle to select it. Hold Space to drag the image."
      case .lasso:
        "Draw around what to select; letting go closes the shape. Hold Space to drag the image."
      }
    #endif
  }

  /// The mode stored under `key`, Smart when there's none or it's unknown (a later version's).
  static func stored(_ raw: String?) -> SelectMode {
    raw.flatMap(SelectMode.init(rawValue:)) ?? .smart
  }
}

/// A Rectangle or Lasso selection, in the canvas image's pixels (from its top left). It becomes
/// the same whole-image bitmap a SAM selection is (`CreateModel.shapeSelection`), so the preview,
/// Add / Subtract / Replace, Fill and Generate's auto-add treat it as they treat SAM's.
nonisolated enum SelectionShape: Equatable, Sendable {
  case rect(CGRect)
  case polygon([CGPoint])

  /// Most points a lasso keeps: past this a drag stops adding them (decimated at a few view
  /// points apart, that's a very long outline already), so rasterizing stays quick.
  static let maxLassoPoints = 4096

  /// The rectangle dragged from `start` to `end`, cut to the image (`SAMGeometry.clampedBox`, as
  /// Smart's box); nil when less than a pixel of it is on the image.
  static func rect(from start: CGPoint, to end: CGPoint, imageSize: CGSize) -> SelectionShape? {
    SAMGeometry.clampedBox(from: start, to: end, imageSize: imageSize).map { .rect($0) }
  }

  /// The lasso through `points` (closed back to the first), or nil when it selects nothing: fewer
  /// than three points, no area (a line drawn back on itself, `spread`), or wholly off the image. Points
  /// past the image are kept: the coverage grid clips them, so a lasso run off the edge keeps
  /// its shape.
  static func lasso(_ points: [CGPoint], imageSize: CGSize) -> SelectionShape? {
    guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), spread(points) >= 1 else { return nil }
    let bounds = Self.bounds(points)
    let overlap = bounds.intersection(CGRect(origin: .zero, size: imageSize))
    guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
    return .polygon(points)
  }

  /// `points` with `point` added when it's at least `minSpacing` from the last one (a drag's many
  /// tiny moves add nothing to the outline), up to `maxLassoPoints`.
  static func appending(_ point: CGPoint, to points: [CGPoint], minSpacing: Double) -> [CGPoint] {
    guard point.x.isFinite, point.y.isFinite else { return points }
    guard let last = points.last else { return [point] }
    guard points.count < maxLassoPoints, hypot(point.x - last.x, point.y - last.y) >= minSpacing else { return points }
    return points + [point]
  }

  /// The shoelace area (signed) of the polygon through `points`.
  static func area(_ points: [CGPoint]) -> Double {
    guard points.count >= 3 else { return 0 }
    var sum = 0.0
    for index in points.indices {
      let a = points[index], b = points[(index + 1) % points.count]
      sum += a.x * b.y - b.x * a.y
    }
    return sum / 2
  }

  /// The area the triangles fanning out from the first point cover, each counted positive: no
  /// more than a line has when the points are all in a row. Not the signed area, which a figure
  /// 8 with even loops cancels to nothing though both loops select.
  static func spread(_ points: [CGPoint]) -> Double {
    guard let first = points.first, points.count >= 3 else { return 0 }
    var sum = 0.0
    for index in 1..<(points.count - 1) {
      let a = points[index], b = points[index + 1]
      sum += abs((a.x - first.x) * (b.y - first.y) - (b.x - first.x) * (a.y - first.y))
    }
    return sum / 2
  }

  private static func bounds(_ points: [CGPoint]) -> CGRect {
    let xs = points.map(\.x), ys = points.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// The shape as a mask stroke, drawn by the mask's own rasterizer (`CanvasMask.coverage`).
  var stroke: CanvasMask.Stroke {
    switch self {
    case .rect(let rect): .rect(rect)
    case .polygon(let points): .polygon(points)
    }
  }

  /// The undo step setting it makes.
  var actionName: String {
    switch self {
    case .rect: "Select Rectangle"
    case .polygon: "Select Lasso"
    }
  }

  /// One byte per pixel of a `width` × `height` image, top row first: 255 inside. The mask's own
  /// rasterizer, so a committed shape is exactly what Brush tools' rectangles and polygons paint
  /// (hard-edged; a crossing lasso fills every lobe, nonzero winding).
  func coverage(width: Int, height: Int) -> [UInt8] {
    CanvasMask(strokes: [stroke]).coverage(width: width, height: height)
  }
}
