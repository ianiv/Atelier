import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the canvas image lies in the generation frame, as `CanvasState.render` draws it: the
/// image at the canvas zoom, its center moved from the frame's by the offset, grown to whole
/// pixels. Everything that maps between the frame and the image (the run's canvas, its mask, the
/// merge back) goes through this one rectangle, so they line up to the pixel.
nonisolated struct CanvasPlacement: Sendable, Equatable {
  var sourceSize: CGSize
  var frameSize: CGSize
  /// The image's rectangle in frame pixels, counted from the frame's top left.
  var imageRect: CGRect

  /// `scale` is frame pixels per image pixel (nil fits the image to the frame); `offset` is the
  /// image's center relative to the frame's, in frame pixels, y counting down (`CanvasState`).
  init(sourceSize: CGSize, frameSize: CGSize, scale: Double?, offset: CGSize) {
    self.sourceSize = sourceSize
    self.frameSize = frameSize
    let fit = min(frameSize.width / sourceSize.width, frameSize.height / sourceSize.height)
    let zoom = scale ?? fit
    let drawn = CGSize(width: sourceSize.width * zoom, height: sourceSize.height * zoom)
    // `integral` grows the rect to whole pixels, so an image that covers the frame leaves no
    // transparent sliver. Rounding the y-down rect is the same as rounding the y-up one.
    imageRect = CGRect(
      x: frameSize.width / 2 + offset.width - drawn.width / 2,
      y: frameSize.height / 2 + offset.height - drawn.height / 2,
      width: drawn.width, height: drawn.height
    ).integral
  }

  /// The canvas zoom and offset that show `region` (image pixels, from the top left) in the
  /// frame, fitted, centered: for callers that name a region instead of moving the canvas.
  static func zoomAndOffset(showing region: CGRect, sourceSize: CGSize, frameSize: CGSize) -> (scale: Double, offset: CGSize) {
    let zoom = min(frameSize.width / max(region.width, 1), frameSize.height / max(region.height, 1))
    return (
      zoom,
      CGSize(width: (sourceSize.width / 2 - region.midX) * zoom, height: (sourceSize.height / 2 - region.midY) * zoom)
    )
  }

  init(sourceSize: CGSize, frameSize: CGSize, showing region: CGRect) {
    let placement = Self.zoomAndOffset(showing: region, sourceSize: sourceSize, frameSize: frameSize)
    self.init(sourceSize: sourceSize, frameSize: frameSize, scale: placement.scale, offset: placement.offset)
  }

  /// Frame pixels per image pixel, across and down (they differ slightly once rounded).
  var zoom: (x: Double, y: Double) {
    (imageRect.width / sourceSize.width, imageRect.height / sourceSize.height)
  }

  /// The frame in image pixels, from the image's top left: partly or wholly outside the image
  /// when the frame reaches past it.
  var cropRect: CGRect {
    let zoom = zoom
    return CGRect(
      x: -imageRect.minX / zoom.x, y: -imageRect.minY / zoom.y,
      width: frameSize.width / zoom.x, height: frameSize.height / zoom.y)
  }

  /// The frame shows exactly the whole image, so a run's result can stand for it as is.
  var showsWholeImage: Bool {
    imageRect == CGRect(origin: .zero, size: frameSize)
  }

  /// The image's rect in Core Graphics' y-up frame coordinates, for drawing.
  var imageRectYUp: CGRect {
    CGRect(
      x: imageRect.minX, y: frameSize.height - imageRect.maxY, width: imageRect.width, height: imageRect.height)
  }
}

/// The inpainting mask painted on the canvas image, as vector strokes in the image's pixels (from
/// its top left), so it stays sharp at any zoom and each stroke undoes on its own. Draw Things
/// keeps its canvas mask as a bitmap; Atelier rasterizes this when a run needs one: as the frame's
/// mask codes for the engine (`frameMask`), and at image resolution to merge the result back
/// (`CanvasMerge`) and to store with the step (`binary_mask_<id>`).
nonisolated struct CanvasMask: Codable, Sendable, Hashable {
  /// One change to the mask, applied in order over what came before.
  nonisolated struct Stroke: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
      /// A brush stroke through `points`, `radius` wide on each side.
      case brush
      /// Flips everything so far (Invert Mask); it has no points.
      case invert
      /// The rectangle spanned by its two points.
      case rect
      /// The ellipse inside the rectangle spanned by its two points.
      case ellipse
      /// The polygon through its points.
      case polygon
      /// A bitmap (`bitmap`, a PNG: white painted) with its top left at the one point.
      case bitmap
    }

    var kind: Kind
    var points: [CGPoint] = []
    /// Half the brush width, in image pixels.
    var radius: Double = 0
    /// Takes away from the mask instead of adding to it (the eraser, or a subtracted shape).
    var erases = false
    var bitmap: Data?

    init(kind: Kind, points: [CGPoint] = [], radius: Double = 0, erases: Bool = false, bitmap: Data? = nil) {
      self.kind = kind
      self.points = points
      self.radius = radius
      self.erases = erases
      self.bitmap = bitmap
    }

    static let invert = Stroke(kind: .invert)

    func hash(into hasher: inout Hasher) {
      hasher.combine(kind)
      for point in points {
        hasher.combine(point.x)
        hasher.combine(point.y)
      }
      hasher.combine(radius)
      hasher.combine(erases)
      hasher.combine(bitmap)
    }

    static func rect(_ rect: CGRect, erases: Bool = false) -> Stroke {
      Stroke(kind: .rect, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], erases: erases)
    }

    static func ellipse(in rect: CGRect, erases: Bool = false) -> Stroke {
      Stroke(kind: .ellipse, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], erases: erases)
    }

    static func polygon(_ points: [CGPoint], erases: Bool = false) -> Stroke {
      Stroke(kind: .polygon, points: points, erases: erases)
    }

    /// A mask image the size of the canvas image (or placed at `origin`): painted where it's
    /// light (gray 128 or more) and opaque. Nil when it paints nothing.
    static func bitmap(_ image: CGImage, at origin: CGPoint = .zero, erases: Bool = false) -> Stroke? {
      let width = image.width, height = image.height
      var rgba = [UInt8](repeating: 0, count: width * height * 4)
      let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }
      guard drawn else { return nil }
      var coverage = [UInt8](repeating: 0, count: width * height)
      for index in coverage.indices {
        // Premultiplied, so a faint or transparent white reads dark. The engine's gray weights.
        let gray = (Int(rgba[index * 4]) * 6969 + Int(rgba[index * 4 + 1]) * 23434 + Int(rgba[index * 4 + 2]) * 2365) >> 15
        coverage[index] = rgba[index * 4 + 3] >= 128 && gray >= 128 ? 255 : 0
      }
      guard coverage.contains(255), let png = CanvasMask.grayPNG(coverage, width: width, height: height) else { return nil }
      return Stroke(kind: .bitmap, points: [origin], erases: erases, bitmap: png)
    }
  }

  var strokes: [Stroke] = []

  init(strokes: [Stroke] = []) {
    self.strokes = strokes
  }

  /// A mask of rectangles in image pixels (from the top left).
  init(rects: [CGRect]) {
    strokes = rects.map { Stroke.rect($0) }
  }

  /// A mask from an image the size of the canvas image (see `Stroke.bitmap`).
  init?(bitmap: CGImage) {
    guard let stroke = Stroke.bitmap(bitmap) else { return nil }
    strokes = [stroke]
  }

  /// Whether anything can have been painted (a mask of only erasing paints nothing).
  var mayHavePaint: Bool {
    strokes.contains { !$0.erases }
  }

  func translated(by delta: CGPoint) -> CanvasMask {
    var moved = self
    for index in moved.strokes.indices {
      moved.strokes[index].points = moved.strokes[index].points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }
    return moved
  }

  /// The mask over a `width` × `height` grid, one byte per pixel from the top-left row: 255
  /// painted, 0 not. An image point p lands on (p.x × scale.x + origin.x, p.y × scale.y +
  /// origin.y). Hard-edged (no antialiasing), as the engine reads a mask as codes, not coverage;
  /// Mask Blur softens it.
  func coverage(width: Int, height: Int, scale: (x: Double, y: Double) = (1, 1), origin: CGPoint = .zero) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: max(width, 0) * max(height, 0))
    guard width > 0, height > 0, !strokes.isEmpty else { return bytes }
    bytes.withUnsafeMutableBytes { raw in
      guard let context = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return }
      context.setShouldAntialias(false)
      context.setAllowsAntialiasing(false)
      context.interpolationQuality = .none
      // Image pixels counting down, onto the grid's rows top to bottom.
      context.translateBy(x: 0, y: CGFloat(height))
      context.scaleBy(x: 1, y: -1)
      context.translateBy(x: origin.x, y: origin.y)
      context.scaleBy(x: scale.x, y: scale.y)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      let pixels = raw.bindMemory(to: UInt8.self)
      for stroke in strokes {
        let gray: CGFloat = stroke.erases ? 0 : 1
        context.setStrokeColor(gray: gray, alpha: 1)
        context.setFillColor(gray: gray, alpha: 1)
        func spanned() -> CGRect? {
          guard stroke.points.count == 2 else { return nil }
          return CGRect(
            x: stroke.points[0].x, y: stroke.points[0].y,
            width: stroke.points[1].x - stroke.points[0].x, height: stroke.points[1].y - stroke.points[0].y
          ).standardized
        }
        switch stroke.kind {
        case .invert:
          for index in pixels.indices { pixels[index] = 255 - pixels[index] }
        case .rect:
          if let rect = spanned() { context.fill(rect) }
        case .ellipse:
          if let rect = spanned() { context.fillEllipse(in: rect) }
        case .polygon:
          guard stroke.points.count > 2 else { continue }
          context.addLines(between: stroke.points)
          context.closePath()
          context.fillPath()
        case .bitmap:
          guard let point = stroke.points.first, let data = stroke.bitmap,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
          else { continue }
          // Painted (white) pixels as a mask of the stroke color, so erasing leaves the rest.
          let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
          context.saveGState()
          // Upright: the flip above would turn it over.
          context.translateBy(x: point.x, y: point.y + CGFloat(image.height))
          context.scaleBy(x: 1, y: -1)
          if let mask = Self.grayAlpha(of: image) {
            context.clip(to: rect, mask: mask)
            context.fill(rect)
          }
          context.restoreGState()
        case .brush:
          context.setLineWidth(stroke.radius * 2)
          if stroke.points.count == 1, let point = stroke.points.first {
            // A dot: Core Graphics draws nothing for a zero-length line.
            context.fillEllipse(
              in: CGRect(x: point.x - stroke.radius, y: point.y - stroke.radius, width: stroke.radius * 2, height: stroke.radius * 2))
          } else if stroke.points.count > 1 {
            context.addLines(between: stroke.points)
            context.strokePath()
          }
        }
      }
    }
    // Hard edges: anything half covered or more counts as painted.
    for index in bytes.indices { bytes[index] = bytes[index] >= 128 ? 255 : 0 }
    return bytes
  }

  /// `image` as a device-gray image of 255 (painted) and 0, which `clip(to:mask:)` reads as alpha.
  private static func grayAlpha(of image: CGImage) -> CGImage? {
    var gray = [UInt8](repeating: 0, count: image.width * image.height)
    gray.withUnsafeMutableBytes { raw in
      let context = CGContext(
        data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    guard let provider = CGDataProvider(data: Data(gray.map { $0 >= 128 ? 255 : 0 }) as CFData) else { return nil }
    return CGImage(
      width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: image.width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// Draw Things' mask codes (`LocalImageGenerator.generateImageWithMask`, `byte & 7`).
  enum Code {
    /// Keep (retained while sampling; pasted back with Preserve Original After Inpaint).
    static let keep: UInt8 = 0
    /// Nothing there: filled from pure noise (outpainting).
    static let empty: UInt8 = 1
    /// Painted: regenerated at Strength.
    static let painted: UInt8 = 2
  }

  /// The frame's mask for the engine: 2 where painted, 1 where the frame lies outside the image
  /// (so it still outpaints there: an explicit mask replaces the one the engine derives from the
  /// canvas's transparency, `MediaGenerationExecutionUtilities.generate`), 0 elsewhere. As an
  /// opaque gray PNG at the frame size, the form MGK's `.mask()` input takes: it decodes it,
  /// redraws it at the run's size (`ImageConverter.resize`, the same size here, so no
  /// resampling) and reads gray value v as code v (`ImageConverter.grayscaleTensor`). Nil when
  /// nothing painted is inside the frame: the run is then the same as without a mask.
  func frameMask(_ placement: CanvasPlacement) -> Data? {
    let width = Int(placement.frameSize.width), height = Int(placement.frameSize.height)
    let rect = placement.imageRect
    let painted = coverage(
      width: width, height: height, scale: placement.zoom, origin: rect.origin)
    var codes = [UInt8](repeating: Code.keep, count: width * height)
    var anyPainted = false
    for y in 0..<height {
      let insideY = Double(y) + 0.5 >= rect.minY && Double(y) + 0.5 < rect.maxY
      for x in 0..<width {
        let index = y * width + x
        if !insideY || Double(x) + 0.5 < rect.minX || Double(x) + 0.5 >= rect.maxX {
          codes[index] = Code.empty
        } else if painted[index] != 0 {
          codes[index] = Code.painted
          anyPainted = true
        }
      }
    }
    guard anyPainted else { return nil }
    return Self.grayPNG(codes, width: width, height: height)
  }

  /// The codes Draw Things stores for a step's canvas mask (`binary_mask_<id>`): 2 painted, 0 not.
  static func storedCodes(_ coverage: [UInt8]) -> [UInt8] {
    coverage.map { $0 != 0 ? Code.painted : Code.keep }
  }

  /// An opaque RGB PNG whose every pixel has red = green = blue = its byte. RGB rather than gray:
  /// the engine draws the decoded PNG into device RGB, and an RGB image with no color profile
  /// goes through unchanged, so the codes arrive as they were written (see the unit test).
  static func grayPNG(_ bytes: [UInt8], width: Int, height: Int) -> Data? {
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for index in bytes.indices {
      rgba[index * 4] = bytes[index]
      rgba[index * 4 + 1] = bytes[index]
      rgba[index * 4 + 2] = bytes[index]
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
