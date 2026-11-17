import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Colour painted onto the canvas image (Brush and Eraser on the Color layer, Select's Fill, Fill Mask with Color,
/// agents' `set_canvas_paint`): a layer of its own over the image, as vector strokes in the image's
/// pixels (from its top left) like `CanvasMask`, so it stays sharp at any zoom and each stroke
/// undoes on its own. Called the paint layer, and its strokes colours: elsewhere "painted" means
/// masked (`CanvasMask.Code.painted`). It isn't the mask and adds nothing to it. A run takes it
/// as part of its input only (`CanvasState.render`): the result has none of it, even outside the
/// mask (`RefineMerge.painted`). Generate records the image with it baked in as a Draw entry first, as Draw Things records a canvas drawn on (`Reason.draw`). The same
/// rendering (`layer`) draws it on screen and for a run.
nonisolated struct CanvasPaint: Codable, Sendable, Hashable {
  /// An sRGB colour, each component 0–1, with straight (not premultiplied) alpha.
  nonisolated struct Color: Codable, Sendable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
      self.red = red
      self.green = green
      self.blue = blue
      self.alpha = alpha
    }

    /// `color` in sRGB; nil when it can't be converted (a pattern).
    init?(_ color: CGColor) {
      guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
            let components = converted.components, components.count >= 4
      else { return nil }
      self.init(
        red: min(max(Double(components[0]), 0), 1), green: min(max(Double(components[1]), 0), 1),
        blue: min(max(Double(components[2]), 0), 1), alpha: min(max(Double(components[3]), 0), 1))
    }

    /// `#RRGGBB` or `#RRGGBBAA` (the `#` optional).
    init?(hex: String) {
      var text = hex.trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("#") { text.removeFirst() }
      guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
      let bytes = text.count == 8 ? value : value << 8 | 0xFF
      self.init(
        red: Double(bytes >> 24 & 0xFF) / 255, green: Double(bytes >> 16 & 0xFF) / 255,
        blue: Double(bytes >> 8 & 0xFF) / 255, alpha: Double(bytes & 0xFF) / 255)
    }

    /// The same colour at 8 bits a component: what the picker gives back for a colour picked
    /// again can differ in the last digits.
    func matches(_ other: Color) -> Bool {
      func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
      return byte(red) == byte(other.red) && byte(green) == byte(other.green) && byte(blue) == byte(other.blue)
        && byte(alpha) == byte(other.alpha)
    }

    static let black = Color(red: 0, green: 0, blue: 0)
    static let white = Color(red: 1, green: 1, blue: 1)

    var cgColor: CGColor {
      CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// `#RRGGBB`, with `AA` when it isn't opaque.
    var hex: String {
      func byte(_ value: Double) -> String { String(format: "%02X", Int((value * 255).rounded())) }
      return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }
  }

  /// One change to the paint layer, applied in order over what came before.
  nonisolated struct Stroke: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
      /// A brush stroke through `points`, `radius` wide on each side, in `color`.
      case brush
      /// Takes paint away along `points` (`radius` wide on each side), showing the image again;
      /// with a `bitmap`, wherever it's light, as `fill` paints.
      case erase
      /// The rectangle spanned by its two points.
      case rect
      /// The ellipse inside the rectangle spanned by its two points.
      case ellipse
      /// The polygon through its points.
      case polygon
      /// `color` wherever `bitmap` (a PNG, white filled, as `CanvasMask.grayPNG` writes it) is
      /// light, its top left at the one point, drawn at `size` when set: a Select selection or the
      /// mask, filled.
      case fill
      /// `bitmap` as a colour image (RGBA PNG) with its top left at the one point, drawn at `size`
      /// when set: earlier strokes flattened (`compacted`).
      case image
    }

    var kind: Kind
    var points: [CGPoint] = []
    /// Half the brush width, in image pixels.
    var radius: Double = 0
    var color: Color?
    var bitmap: Data?
    /// The rectangle size a bitmap is drawn at, image pixels; nil is its own size.
    var size: CGSize?

    init(kind: Kind, points: [CGPoint] = [], radius: Double = 0, color: Color? = nil, bitmap: Data? = nil, size: CGSize? = nil) {
      self.kind = kind
      self.points = points
      self.radius = radius
      self.color = color
      self.bitmap = bitmap
      self.size = size
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(kind)
      for point in points {
        hasher.combine(point.x)
        hasher.combine(point.y)
      }
      hasher.combine(radius)
      hasher.combine(color)
      hasher.combine(bitmap)
      hasher.combine(size?.width)
      hasher.combine(size?.height)
    }

    static func rect(_ rect: CGRect, color: Color) -> Stroke {
      Stroke(kind: .rect, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], color: color)
    }

    static func ellipse(in rect: CGRect, color: Color) -> Stroke {
      Stroke(kind: .ellipse, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], color: color)
    }

    static func polygon(_ points: [CGPoint], color: Color) -> Stroke {
      Stroke(kind: .polygon, points: points, color: color)
    }

    /// `mask`'s bitmap stroke (`CanvasMask.Stroke.bitmap`, white where selected) filled with
    /// `color`, where it lies: Select's Fill.
    static func fill(_ mask: CanvasMask.Stroke, color: Color) -> Stroke? {
      guard mask.kind == .bitmap, !mask.erases, let bitmap = mask.bitmap else { return nil }
      return Stroke(kind: .fill, points: [mask.points.first ?? .zero], color: color, bitmap: bitmap, size: mask.size)
    }

    /// The size a bitmap stroke is drawn at: `size`, else its PNG's pixel size (read from the
    /// header, without decoding it).
    var bitmapSize: CGSize? {
      if let size { return size }
      guard let bitmap, let source = CGImageSourceCreateWithData(bitmap as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
      else { return nil }
      return CGSize(width: width, height: height)
    }
  }

  var strokes: [Stroke] = []

  init(strokes: [Stroke] = []) {
    self.strokes = strokes
  }

  /// Whether anything can show: a layer of only erasing shows nothing.
  var mayHaveColor: Bool {
    strokes.contains { $0.kind != .erase }
  }

  /// The layer stretched by `sx` across and `sy` down, as `CanvasMask.scaled` stretches a mask.
  func scaled(sx: Double, sy: Double) -> CanvasPaint {
    guard sx != 1 || sy != 1 else { return self }
    var scaled = self
    for index in scaled.strokes.indices {
      var stroke = scaled.strokes[index]
      if stroke.bitmap != nil, let size = stroke.bitmapSize {
        stroke.size = CGSize(width: size.width * sx, height: size.height * sy)
      }
      stroke.points = stroke.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
      stroke.radius *= (sx * sy).squareRoot()
      scaled.strokes[index] = stroke
    }
    return scaled
  }

  /// The layer scaled from an image of `from` to one of `to`.
  func scaled(from: CGSize, to: CGSize) -> CanvasPaint {
    guard from.width > 0, from.height > 0 else { return self }
    return scaled(sx: to.width / from.width, sy: to.height / from.height)
  }

  func translated(by delta: CGPoint) -> CanvasPaint {
    var moved = self
    for index in moved.strokes.indices {
      moved.strokes[index].points = moved.strokes[index].points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }
    return moved
  }

  /// The layer to keep with an image of `size` (`HistoryStore.setPaint`): as it is, unless it
  /// holds several bitmaps (each Fill adds one, often a whole-image PNG), which are flattened,
  /// with everything else, into one colour image so the project doesn't keep a stack of them.
  func compacted(for size: CGSize?) -> CanvasPaint {
    guard let size, strokes.count(where: { $0.bitmap != nil }) > 1,
          let layer = layer(width: Int(size.width), height: Int(size.height)),
          let png = Self.png(layer)
    else { return self }
    return CanvasPaint(strokes: [Stroke(kind: .image, points: [.zero], bitmap: png)])
  }

  /// The layer over a `width` × `height` grid, as a transparent sRGB image (premultiplied alpha)
  /// with the colours where they lie, antialiased. An image point p lands on (p.x × scale.x +
  /// origin.x, p.y × scale.y + origin.y), as in `CanvasMask.coverage`. Nil when it shows nothing.
  /// With `base` (a layer drawn before, the same size and placement), the strokes go over it
  /// instead of a clear grid: the canvas adds a new stroke to the layer it shows this way, without
  /// drawing (and decoding) the earlier ones again.
  ///
  /// With `fade`, each pixel's colour is faded by how strongly a run with that mask regenerates
  /// it (`Fade`).
  func layer(
    width: Int, height: Int, scale: (x: Double, y: Double) = (1, 1), origin: CGPoint = .zero, over base: CGImage? = nil,
    fade: Fade? = nil
  ) -> CGImage? {
    if let fade {
      guard let layer = layer(width: width, height: height, scale: scale, origin: origin, over: base) else { return nil }
      return fade.applied(to: layer, scale: scale, origin: origin)
    }
    guard width > 0, height > 0, base != nil || mayHaveColor,
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    if let base { context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height)) }
    // Image pixels counting down, onto the grid's rows top to bottom.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: origin.x, y: origin.y)
    context.scaleBy(x: scale.x, y: scale.y)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.interpolationQuality = .high
    for stroke in strokes {
      // Erasing takes the paint away where it covers, by its own coverage (antialiased edges too).
      context.setBlendMode(stroke.kind == .erase ? .destinationOut : .normal)
      let color = stroke.kind == .erase ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) : (stroke.color ?? .black).cgColor
      context.setStrokeColor(color)
      context.setFillColor(color)
      func spanned() -> CGRect? {
        guard stroke.points.count == 2 else { return nil }
        return CGRect(
          x: stroke.points[0].x, y: stroke.points[0].y,
          width: stroke.points[1].x - stroke.points[0].x, height: stroke.points[1].y - stroke.points[0].y
        ).standardized
      }
      func drawBitmap() {
        guard let point = stroke.points.first, let data = stroke.bitmap,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        let rect = CGRect(origin: .zero, size: stroke.size ?? CGSize(width: image.width, height: image.height))
        context.saveGState()
        // Upright: the flip above would turn it over.
        context.translateBy(x: point.x, y: point.y + rect.height)
        context.scaleBy(x: 1, y: -1)
        if stroke.kind == .image {
          context.draw(image, in: rect)
        } else if let mask = CanvasMask.grayAlpha(of: image) {
          context.clip(to: rect, mask: mask)
          context.fill(rect)
        }
        context.restoreGState()
      }
      switch stroke.kind {
      case .erase where stroke.bitmap != nil:
        drawBitmap()
      case .brush, .erase:
        // At least a pixel wide (an agent can send radius 0), as `reach` reckons it.
        let radius = max(stroke.radius, 0.5)
        context.setLineWidth(radius * 2)
        if stroke.points.count == 1, let point = stroke.points.first {
          // A dot: Core Graphics draws nothing for a zero-length line.
          context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        } else if stroke.points.count > 1 {
          context.addLines(between: stroke.points)
          context.strokePath()
        }
      case .rect:
        if let rect = spanned() { context.fill(rect) }
      case .ellipse:
        if let rect = spanned() { context.fillEllipse(in: rect) }
      case .polygon:
        guard stroke.points.count > 2 else { continue }
        context.addLines(between: stroke.points)
        context.closePath()
        context.fillPath()
      case .fill, .image:
        drawBitmap()
      }
    }
    return context.makeImage()
  }

  /// How a masked run takes the paint: only where it regenerates. The engine grows the mask by
  /// Mask Blur Outset and feathers it by Mask Blur (`LocalImageGenerator.imageWithMask`: dilate,
  /// then blur), so in the soft band at its edge it regenerates only partly and keeps the input
  /// there, paint and all, which would leave an outline of paint around the regenerated area
  /// (Fill Mask paints right up to the edge). So the paint's alpha is scaled by that same grown
  /// and feathered mask (`MaskFilter`), weight w: none where w is below 0.9, rising to whole at 1,
  /// so it shows only where the run regenerates (all but) fully; the soft band starts from the
  /// original pixels, and outside the mask there's none. (Scaling by w itself would leave up to a
  /// quarter of the paint in the band: the run keeps 1 − w of an input painted by w.) `maskBlur`
  /// and `maskBlurOutset` are in the pixels of the grid the layer is drawn on.
  nonisolated struct Fade: Codable, Hashable, Sendable {
    var mask: CanvasMask
    var maskBlur: Double
    var maskBlurOutset: Int

    /// The regeneration weight paint starts to show at.
    static let fullFrom: Float = 0.9

    /// `layer` (premultiplied sRGB, drawn with `scale` and `origin`) faded by the mask's weight.
    func applied(to layer: CGImage, scale: (x: Double, y: Double), origin: CGPoint) -> CGImage? {
      let width = layer.width, height = layer.height
      var bytes = [UInt8](repeating: 0, count: width * height * 4)
      let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(layer, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }
      guard drawn else { return nil }
      var weight = mask.coverage(width: width, height: height, scale: scale, origin: origin).map { Float($0 != 0 ? 1 : 0) }
      weight = MaskFilter.outset(weight, width: width, height: height, by: maskBlurOutset)
      weight = MaskFilter.blur(weight, width: width, height: height, sigma: maskBlur)
      for index in weight.indices where weight[index] < 1 {
        let amount = min(max((weight[index] - Self.fullFrom) / (1 - Self.fullFrom), 0), 1)
        // Premultiplied: fading is scaling every channel.
        for c in 0..<4 { bytes[index * 4 + c] = UInt8((Float(bytes[index * 4 + c]) * amount).rounded()) }
      }
      guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
      return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
  }

  /// `image` with the layer drawn over it at its own pixels, opaque where `image` is (faded by
  /// `fade` for a masked run): the canvas image as its Draw entry records it.
  func baked(onto image: CGImage, fade: Fade? = nil) -> CGImage? {
    let width = image.width, height = image.height
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(image, in: rect)
    if let layer = layer(width: width, height: height, fade: fade) { context.draw(layer, in: rect) }
    return context.makeImage()
  }

  /// Where the colours can lie, from the strokes' own geometry (points and brush radius, a
  /// bitmap's rectangle), without drawing them: whole image pixels, clipped to a `width` ×
  /// `height` image; nil when nothing that paints lies on it. Erasing isn't subtracted, so it may
  /// be larger than what shows.
  func bounds(width: Int, height: Int) -> CGRect? {
    let union = strokes.filter { $0.kind != .erase }.compactMap(Self.reach).reduce(CGRect.null) { $0.union($1) }
    let clipped = union.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
    return clipped.isNull || clipped.isEmpty ? nil : clipped
  }

  /// Where one stroke can change pixels (image pixels): a brush's or eraser's points grown by its
  /// radius (at least half a pixel, as `layer` draws it), a shape's
  /// points, a bitmap's rectangle.
  private static func reach(_ stroke: Stroke) -> CGRect? {
    guard let first = stroke.points.first else { return nil }
    if stroke.bitmap != nil {
      guard let size = stroke.bitmapSize else { return nil }
      return CGRect(origin: first, size: size).standardized
    }
    var rect = stroke.points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    if stroke.kind == .brush || stroke.kind == .erase {
      let radius = max(stroke.radius, 0.5)
      rect = rect.insetBy(dx: -radius, dy: -radius)
    }
    return rect.standardized
  }

  static func png(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
