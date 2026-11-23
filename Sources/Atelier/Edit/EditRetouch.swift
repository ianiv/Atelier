import CoreGraphics
import Foundation

// The retouch: what's done to the source's own pixels before the look (`EditPipeline`'s step 0),
// per image. Heal strokes first (the Heal tool, still to come: `Retouch.heal`), then the crop.
// It isn't part of `EditOptions`: the look is remembered from image to image and becomes grain
// profiles, and a crop carried to the next image or into a `.grain.json` would be wrong.

extension Edit {
  /// A crop in the source's pixels: whole pixels, inside the image, at least `minimumSide` on a
  /// side. `aspect` is the ratio it was held to (nil for Free), so opening the step again locks
  /// it the same way; `swapped` turns that ratio on its side (4:5 to 5:4).
  nonisolated struct Crop: Codable, Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var aspect: CropAspect?
    var swapped = false

    /// The smallest side a crop can have, in source pixels.
    static let minimumSide = 16

    init(x: Int, y: Int, width: Int, height: Int, aspect: CropAspect? = nil, swapped: Bool = false) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
      self.aspect = aspect
      self.swapped = swapped
    }

    /// The nearest whole-pixel crop to `rect` (source pixels) inside a `width` × `height` image;
    /// nil for a rectangle that isn't finite or leaves less than `minimumSide` on a side. What the
    /// overlay's drags, the MCP tool and a decoded record all go through, so nothing outside the
    /// image (or a NaN from a bad file) reaches `CGImage.cropping`.
    init?(rect: CGRect, imageWidth: Int, imageHeight: Int, aspect: CropAspect? = nil, swapped: Bool = false) {
      let values = [rect.minX, rect.minY, rect.maxX, rect.maxY]
      guard imageWidth >= Self.minimumSide, imageHeight >= Self.minimumSide, values.allSatisfy(\.isFinite) else { return nil }
      // Clamped as Doubles before any Int conversion: a huge value would trap there.
      let w = Double(imageWidth), h = Double(imageHeight)
      let x0 = min(max(rect.minX, 0), w).rounded(), y0 = min(max(rect.minY, 0), h).rounded()
      let x1 = min(max(rect.maxX, 0), w).rounded(), y1 = min(max(rect.maxY, 0), h).rounded()
      guard x1 - x0 >= Double(Self.minimumSide), y1 - y0 >= Double(Self.minimumSide) else { return nil }
      self.init(x: Int(x0), y: Int(y0), width: Int(x1 - x0), height: Int(y1 - y0), aspect: aspect, swapped: swapped)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// This crop, made whole and kept inside a `width` × `height` image (`init(rect:…)`): nil
    /// when nothing of it is left. A record from a file, or one saved from a larger image, goes
    /// through this before it's applied.
    func clamped(imageWidth: Int, imageHeight: Int) -> Crop? {
      Crop(rect: rect, imageWidth: imageWidth, imageHeight: imageHeight, aspect: aspect, swapped: swapped)
    }

    /// Whether it takes the whole image, which is no crop at all.
    func isWhole(imageWidth: Int, imageHeight: Int) -> Bool {
      x == 0 && y == 0 && width == imageWidth && height == imageHeight
    }

    /// The width-to-height ratio it's held to, for a `width` × `height` image; nil for Free.
    func ratio(imageWidth: Int, imageHeight: Int) -> Double? {
      aspect.map { $0.ratio(imageWidth: imageWidth, imageHeight: imageHeight, swapped: swapped) }
    }

    /// What makes the image: the rectangle, not the ratio it was held to.
    var renderKey: Crop { Crop(x: x, y: y, width: width, height: height) }

    private enum CodingKeys: String, CodingKey { case x, y, width, height, aspect, swapped }

    /// Lenient for the ratio (an unknown one reads as Free), strict for the rectangle: a crop
    /// without one isn't a crop. Bounds are checked where it's applied (`clamped`).
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      x = try c.decode(Int.self, forKey: .x)
      y = try c.decode(Int.self, forKey: .y)
      width = try c.decode(Int.self, forKey: .width)
      height = try c.decode(Int.self, forKey: .height)
      aspect = (try? c.decodeIfPresent(String.self, forKey: .aspect)).flatMap { $0.flatMap(CropAspect.init(rawValue:)) }
      swapped = ((try? c.decodeIfPresent(Bool.self, forKey: .swapped)) ?? nil) ?? false
    }
  }

  /// The crop's ratio presets (D3): Original is the image's own; the others as their names say,
  /// each as the Aspect menu lists it. `swapped` (the Orientation button) turns one on its side.
  nonisolated enum CropAspect: String, Codable, CaseIterable, Sendable {
    case original, square, r4x5, r2x3, r3x4, r9x16, r16x9

    var title: String {
      switch self {
      case .original: "Original"
      case .square: "1:1"
      case .r4x5: "4:5"
      case .r2x3: "2:3"
      case .r3x4: "3:4"
      case .r9x16: "9:16"
      case .r16x9: "16:9"
      }
    }

    /// Width and height parts; nil for Original, which is the image's.
    var parts: (width: Int, height: Int)? {
      switch self {
      case .original: nil
      case .square: (1, 1)
      case .r4x5: (4, 5)
      case .r2x3: (2, 3)
      case .r3x4: (3, 4)
      case .r9x16: (9, 16)
      case .r16x9: (16, 9)
      }
    }

    /// Whether Orientation can turn it: not 1:1, which is the same either way.
    var canSwap: Bool { self != .square }

    /// Width over height for a `width` × `height` image, turned on its side when `swapped`.
    func ratio(imageWidth: Int, imageHeight: Int, swapped: Bool) -> Double {
      let (w, h) = parts.map { (Double($0.width), Double($0.height)) } ?? (Double(max(imageWidth, 1)), Double(max(imageHeight, 1)))
      return swapped ? h / w : w / h
    }

    /// The ratio as the menu and readout say it ("5:4" when 4:5 is swapped; Original's "Original").
    func label(swapped: Bool) -> String {
      guard let parts else { return swapped ? "Original, Rotated" : "Original" }
      return swapped ? "\(parts.height):\(parts.width)" : title
    }

    /// The preset and orientation for this one turned on its side: a preset whose turned ratio is
    /// another preset (9:16 and 16:9) becomes that one, so the menu shows the ratio as it is.
    func swapping(_ swapped: Bool) -> (aspect: CropAspect, swapped: Bool) {
      switch self {
      case .r9x16: (.r16x9, swapped)
      case .r16x9: (.r9x16, swapped)
      default: (self, !swapped)
      }
    }
  }

  /// What's done to the source's pixels before the look, in order: Heal strokes (the Heal tool,
  /// to come), then the crop. Per image: cleared when another image opens, brought back from a
  /// saved step's record.
  nonisolated struct Retouch: Hashable, Sendable {
    var crop: Crop?
    // Heal (branch edit-heal) goes here: `var heal: HealStrokes = .empty`, applied before the crop.

    static let none = Retouch()

    var isIdentity: Bool { crop == nil }
  }
}

/// Applying the retouch to a source (step 0 of `EditPipeline`): what the screen, Save to History
/// and Export render the look over. Heal, when it lands, goes first here; the crop is
/// `CGImage.cropping(to:)`, which shares the source's pixels rather than copying them.
nonisolated enum EditRetouch {
  /// `source` with `retouch`: the source itself when there's nothing to do (or the crop takes it
  /// all, or nothing of it is left in this image), so the renderer's caches for it still serve.
  static func apply(_ retouch: Edit.Retouch, to source: CGImage) -> CGImage {
    // Heal strokes go on here, before the crop: they're in the source's coordinates.
    guard let crop = retouch.crop?.clamped(imageWidth: source.width, imageHeight: source.height),
          !crop.isWhole(imageWidth: source.width, imageHeight: source.height)
    else { return source }
    return source.cropping(to: crop.rect) ?? source
  }

  /// The crop that applies to a `width` × `height` source: nil for none, or one that takes it all.
  static func effectiveCrop(_ crop: Edit.Crop?, imageWidth: Int, imageHeight: Int) -> Edit.Crop? {
    guard let crop = crop?.clamped(imageWidth: imageWidth, imageHeight: imageHeight),
          !crop.isWhole(imageWidth: imageWidth, imageHeight: imageHeight)
    else { return nil }
    return crop
  }
}

/// The crop rectangle's geometry, in source pixels (Doubles, so a drag moves smoothly; whole
/// pixels come at the end, `Edit.Crop(rect:…)`): its handles, dragging them with or without a
/// ratio held, moving it, drawing a new one, and fitting a ratio. Pure, so `CropTests` checks it.
nonisolated enum CropGeometry {
  /// What a drag on the crop holds: a corner, an edge, or the inside (which moves it).
  enum Handle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside

    /// Which sides it moves: -1 the low side (left/top), 1 the high, 0 neither.
    var sides: (x: Int, y: Int) {
      switch self {
      case .topLeft: (-1, -1)
      case .top: (0, -1)
      case .topRight: (1, -1)
      case .right: (1, 0)
      case .bottomRight: (1, 1)
      case .bottom: (0, 1)
      case .bottomLeft: (-1, 1)
      case .left: (-1, 0)
      case .inside: (0, 0)
      }
    }

    var isCorner: Bool { sides.x != 0 && sides.y != 0 }

    /// Where it sits on `rect`.
    func point(in rect: CGRect) -> CGPoint {
      let (sx, sy) = sides
      return CGPoint(x: sx < 0 ? rect.minX : sx > 0 ? rect.maxX : rect.midX, y: sy < 0 ? rect.minY : sy > 0 ? rect.maxY : rect.midY)
    }

    /// The eight handles drawn on the rectangle.
    static let grabbable: [Handle] = allCases.filter { $0 != .inside }
  }

  /// The handle at `point` on `rect` (both in view points), within `reach` of it: corners first,
  /// then edges, then the inside; nil outside (a drag there draws a new rectangle).
  static func handle(at point: CGPoint, rect: CGRect, reach: Double) -> Handle? {
    func near(_ handle: Handle) -> Bool {
      let p = handle.point(in: rect)
      return abs(p.x - point.x) <= reach && abs(p.y - point.y) <= reach
    }
    if let corner = Handle.grabbable.first(where: { $0.isCorner && near($0) }) { return corner }
    if let edge = Handle.grabbable.first(where: { !$0.isCorner && near($0) }) { return edge }
    // Along an edge, not only at its midpoint.
    let inX = point.x >= rect.minX - reach && point.x <= rect.maxX + reach
    let inY = point.y >= rect.minY - reach && point.y <= rect.maxY + reach
    if inY, abs(point.x - rect.minX) <= reach { return .left }
    if inY, abs(point.x - rect.maxX) <= reach { return .right }
    if inX, abs(point.y - rect.minY) <= reach { return .top }
    if inX, abs(point.y - rect.maxY) <= reach { return .bottom }
    return rect.contains(point) ? .inside : nil
  }

  /// `start` with `handle` dragged by `delta`, inside `bounds`, no side under `minimum`. With a
  /// `ratio` (width over height) a corner drag keeps the opposite corner where it is and the
  /// ratio held, and an edge drag keeps the opposite edge and the rectangle's centre across it.
  /// Without one each side follows the pointer on its own.
  static func drag(_ handle: Handle, from start: CGRect, by delta: CGSize, ratio: Double?, bounds: CGSize, minimum: Double) -> CGRect {
    if handle == .inside { return move(start, by: delta, bounds: bounds) }
    let (sx, sy) = handle.sides
    // The pointer's corner or edge, where it's been dragged to, inside the image.
    var x0 = start.minX, y0 = start.minY, x1 = start.maxX, y1 = start.maxY
    if sx < 0 { x0 = min(max(start.minX + delta.width, 0), x1 - minimum) }
    if sx > 0 { x1 = max(min(start.maxX + delta.width, bounds.width), x0 + minimum) }
    if sy < 0 { y0 = min(max(start.minY + delta.height, 0), y1 - minimum) }
    if sy > 0 { y1 = max(min(start.maxY + delta.height, bounds.height), y0 + minimum) }
    guard let ratio, ratio > 0, ratio.isFinite else { return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }

    let minimumWidth = max(minimum, minimum * ratio), minimumHeight = minimumWidth / ratio
    if handle.isCorner {
      // The opposite corner stays; the size is the larger the pointer asks for, held to the
      // ratio, then made to fit between that corner and the image's edges.
      let anchor = CGPoint(x: sx < 0 ? start.maxX : start.minX, y: sy < 0 ? start.maxY : start.minY)
      var width = max(x1 - x0, (y1 - y0) * ratio, minimumWidth)
      let roomX = sx < 0 ? anchor.x : bounds.width - anchor.x
      let roomY = sy < 0 ? anchor.y : bounds.height - anchor.y
      width = min(width, roomX, roomY * ratio)
      let height = width / ratio
      return CGRect(x: sx < 0 ? anchor.x - width : anchor.x, y: sy < 0 ? anchor.y - height : anchor.y, width: width, height: height)
    }
    if sx != 0 {
      // Left or right edge: the width from the pointer, the height from the ratio about the centre.
      let anchorX = sx < 0 ? start.maxX : start.minX, midY = start.midY
      var width = max(x1 - x0, minimumWidth)
      let roomX = sx < 0 ? anchorX : bounds.width - anchorX
      width = min(width, roomX, bounds.height * ratio)
      let height = width / ratio
      let top = min(max(midY - height / 2, 0), bounds.height - height)
      return CGRect(x: sx < 0 ? anchorX - width : anchorX, y: top, width: width, height: height)
    }
    // Top or bottom edge.
    let anchorY = sy < 0 ? start.maxY : start.minY, midX = start.midX
    var height = max(y1 - y0, minimumHeight)
    let roomY = sy < 0 ? anchorY : bounds.height - anchorY
    height = min(height, roomY, bounds.width / ratio)
    let width = height * ratio
    let left = min(max(midX - width / 2, 0), bounds.width - width)
    return CGRect(x: left, y: sy < 0 ? anchorY - height : anchorY, width: width, height: height)
  }

  /// `rect` moved by `delta`, kept inside `bounds` at its size.
  static func move(_ rect: CGRect, by delta: CGSize, bounds: CGSize) -> CGRect {
    let x = min(max(rect.minX + delta.width, 0), max(0, bounds.width - rect.width))
    let y = min(max(rect.minY + delta.height, 0), max(0, bounds.height - rect.height))
    return CGRect(x: x, y: y, width: rect.width, height: rect.height)
  }

  /// A new rectangle drawn from `start` to `end` (a drag outside the crop), inside `bounds`, held
  /// to `ratio` when there is one; nil while it's under `minimum` on a side (a click, not a drag).
  static func drawn(from start: CGPoint, to end: CGPoint, ratio: Double?, bounds: CGSize, minimum: Double) -> CGRect? {
    let s = CGPoint(x: min(max(start.x, 0), bounds.width), y: min(max(start.y, 0), bounds.height))
    let e = CGPoint(x: min(max(end.x, 0), bounds.width), y: min(max(end.y, 0), bounds.height))
    guard abs(e.x - s.x) >= minimum || abs(e.y - s.y) >= minimum else { return nil }
    // A drag from `s` is the bottom-right corner of a minimal rectangle there, dragged.
    let sx: Double = e.x < s.x ? -1 : 1, sy: Double = e.y < s.y ? -1 : 1
    let seed = CGRect(x: sx < 0 ? s.x - minimum : s.x, y: sy < 0 ? s.y - minimum : s.y, width: minimum, height: minimum)
    let handle: Handle = sx < 0 ? (sy < 0 ? .topLeft : .bottomLeft) : (sy < 0 ? .topRight : .bottomRight)
    let corner = handle.point(in: seed)
    return drag(handle, from: seed, by: CGSize(width: e.x - corner.x, height: e.y - corner.y), ratio: ratio, bounds: bounds, minimum: minimum)
  }

  /// The largest rectangle of `ratio` in `bounds`, centred: what choosing a ratio with no crop
  /// gives.
  static func largest(ratio: Double, in bounds: CGSize) -> CGRect {
    guard ratio > 0, ratio.isFinite else { return CGRect(origin: .zero, size: bounds) }
    let width = min(bounds.width, bounds.height * ratio), height = width / ratio
    return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
  }

  /// `rect` held to `ratio`: the same area about the same centre, made smaller if it doesn't fit,
  /// then moved inside `bounds`. What choosing a ratio, or turning it, does to a crop there is.
  static func fitting(_ rect: CGRect, ratio: Double, in bounds: CGSize) -> CGRect {
    guard ratio > 0, ratio.isFinite, rect.width > 0, rect.height > 0 else { return largest(ratio: ratio, in: bounds) }
    let area = rect.width * rect.height
    var width = (area * ratio).squareRoot(), height = width / ratio
    let shrink = min(1, bounds.width / width, bounds.height / height)
    width *= shrink
    height *= shrink
    let x = min(max(rect.midX - width / 2, 0), bounds.width - width)
    let y = min(max(rect.midY - height / 2, 0), bounds.height - height)
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
