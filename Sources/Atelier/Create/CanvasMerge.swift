import CoreGraphics
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// How a refine run's result goes back into the image it was made from: the frame showed part of
/// `source` (zoomed and moved on the canvas), maybe past its edges, maybe with a painted mask.
/// Draw Things composites the result onto its canvas app-side; Atelier does the same here, on
/// this device (the one whose project holds the source), even when a server made the result.
nonisolated struct RefineMerge: Sendable {
  /// The canvas image, at its own resolution.
  var source: CGImage
  /// The project step `source` is exactly, if any: the result follows it.
  var sourceTensorId: Int64?
  /// The canvas zoom (nil fitted) and offset the run had (`CanvasState`).
  var scale: Double?
  var offset: CGSize
  var frameSize: CGSize
  /// The painted mask, in `source`'s pixels; nil merges the whole frame.
  var mask: CanvasMask?

  var placement: CanvasPlacement {
    CanvasPlacement(
      sourceSize: CGSize(width: source.width, height: source.height), frameSize: frameSize, scale: scale, offset: offset)
  }

  /// Everything but the image, for saving with a queued or remote job (the image goes beside it
  /// as a PNG).
  struct Record: Codable, Hashable, Sendable {
    var sourceTensorId: Int64?
    var scale: Double?
    var offsetX: Double
    var offsetY: Double
    var frameWidth: Double
    var frameHeight: Double
    var mask: CanvasMask?
  }

  var record: Record {
    Record(
      sourceTensorId: sourceTensorId, scale: scale, offsetX: offset.width, offsetY: offset.height,
      frameWidth: frameSize.width, frameHeight: frameSize.height, mask: mask)
  }

  init(source: CGImage, sourceTensorId: Int64?, scale: Double?, offset: CGSize, frameSize: CGSize, mask: CanvasMask?) {
    self.source = source
    self.sourceTensorId = sourceTensorId
    self.scale = scale
    self.offset = offset
    self.frameSize = frameSize
    self.mask = mask
  }

  init(record: Record, source: CGImage, sameProject: Bool) {
    self.init(
      source: source, sourceTensorId: sameProject ? record.sourceTensorId : nil, scale: record.scale,
      offset: CGSize(width: record.offsetX, height: record.offsetY),
      frameSize: CGSize(width: record.frameWidth, height: record.frameHeight), mask: record.mask)
  }
}

/// Where a merged step came from, kept in its `profile_data` (`ProjectMapping.Profile`'s
/// `refine_*` keys) so Use Settings can put its input back as it was: zoomed, moved and masked.
nonisolated struct RefineRecord: Codable, Hashable, Sendable {
  /// The frame in the input image's pixels: x, y, width, height from its top left.
  var rect: [Double]
  /// The canvas zoom; nil was fitted.
  var scale: Double?
  /// The canvas offset, frame pixels: x, y (down).
  var offset: [Double]
  var mask: CanvasMask?
}

extension GenerationEngine.Request {
  /// Sets the Edit inputs for refining part of `source`, the way Generate does from the canvas,
  /// for any caller (the Create screen, agents, scripted checks): the frame at the output size
  /// with `source` placed by `scale` (frame pixels per image pixel, nil fits) and `offset` (the
  /// image's center from the frame's, frame pixels, y down; see `CanvasPlacement.zoomAndOffset`
  /// to show a region instead), the mask's codes when anything painted is in the frame, and with
  /// `merge`, how to merge the result back into `source`. Returns false when `source` couldn't be
  /// drawn. Merge only applies when it changes anything: the frame shows less or more than the
  /// whole image, or there's a mask.
  @discardableResult
  mutating func setRefineInputs(
    source: CGImage, sourceTensorId: Int64?, isImported: Bool, scale: Double?, offset: CGSize,
    mask: CanvasMask?, merge: Bool
  ) -> Bool {
    let frame = CGSize(width: configuration.width, height: configuration.height)
    let placement = CanvasPlacement(
      sourceSize: CGSize(width: source.width, height: source.height), frameSize: frame, scale: scale, offset: offset)
    guard let rendered = CanvasState.render(source, placement: placement) else { return false }
    canvas = rendered
    canvasIsImported = isImported
    let maskPNG = mask.flatMap { $0.mayHavePaint ? $0.frameMask(placement) : nil }
    self.mask = maskPNG
    if merge, maskPNG != nil || !placement.showsWholeImage {
      self.merge = RefineMerge(
        source: source, sourceTensorId: isImported ? nil : sourceTensorId, scale: scale, offset: offset,
        frameSize: frame, mask: maskPNG != nil ? mask : nil)
      // The input step is the source itself, saved once for every job from it.
      canvasTensorId = self.merge?.sourceTensorId
      canvasKey = "merge \(ObjectIdentifier(source))"
    } else {
      self.merge = nil
      canvasKey = "\(ObjectIdentifier(source)) \(scale ?? 0) \(offset) \(frame.width)x\(frame.height)"
      if !isImported, placement.showsWholeImage, source.width == Int(frame.width), source.height == Int(frame.height) {
        canvasTensorId = sourceTensorId
      }
    }
    return true
  }
}

/// Merges a refine run's result back into its source image (`RefineMerge`), in pure Core
/// Graphics plus byte math, so it's exact and testable. The result frame is scaled back into the
/// rectangle it showed (`CanvasPlacement.cropRect`) on a canvas grown to hold both the source and
/// that rectangle, as Draw Things' canvas grows when the frame reaches past the image. Pixels
/// neither covers stay transparent.
///
/// With a mask, the result shows through it, grown by Mask Blur Outset and feathered by Mask Blur
/// as the engine does in the frame (`LocalImageGenerator.imageWithMask`: dilate, then blur), but
/// at the source's resolution; source pixels the feathered mask doesn't reach are left exactly as
/// they were. Without a mask, the whole frame goes in, its edges that lie inside the source
/// feathered over Mask Blur pixels so no seam shows; edges at or past the source's edge aren't.
/// Wherever the frame lies outside the source (outpainted), the result goes in whole.
nonisolated enum CanvasMerge {
  struct Merged: @unchecked Sendable {
    var image: CGImage
    /// `image` as the project stores it (RGB: what neither covers turns black).
    var tensor: Tensor<FloatType> = Tensor(.CPU, .NHWC(1, 1, 1, 3))
    /// `storedMask` as the `binary_mask` tensor, `[height, width]`.
    var maskTensor: Tensor<UInt8>?
    /// Where the source's top left is in `image` (it moves when the canvas grows left or up).
    var sourceOrigin: CGPoint
    /// The mask as Draw Things stores a step's canvas mask, at `image`'s size: 2 painted, 0 not.
    var storedMask: [UInt8]?
    var record: RefineRecord
  }

  @concurrent static func merged(
    _ result: Tensor<FloatType>, into merge: RefineMerge, maskBlur: Double, maskBlurOutset: Int
  ) async throws -> Merged {
    guard let image = ImageTensor.cgImage(from: result),
          var merged = Self.merge(image, into: merge, maskBlur: maskBlur, maskBlurOutset: maskBlurOutset),
          let tensor = ImageTensor.tensor(from: merged.image)
    else { throw ProjectError.badImage }
    merged.tensor = tensor
    if let codes = merged.storedMask {
      let width = merged.image.width, height = merged.image.height
      var mask = Tensor<UInt8>(.CPU, .NC(height, width))
      mask.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for index in 0..<min(codes.count, bytes.count) { bytes[index] = codes[index] }
      }
      merged.maskTensor = mask
    }
    return merged
  }

  static func merge(_ result: CGImage, into merge: RefineMerge, maskBlur: Double, maskBlurOutset: Int) -> Merged? {
    let placement = merge.placement
    let source = merge.source
    let sourceWidth = source.width, sourceHeight = source.height
    let crop = placement.cropRect
    let bounds = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight).union(crop).integral
    let width = Int(bounds.width), height = Int(bounds.height)
    guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
    let originX = Int(-bounds.minX), originY = Int(-bounds.minY)
    // The frame in the merged image's pixels.
    let frameRect = crop.offsetBy(dx: Double(originX), dy: Double(originY))

    guard var output = draw(source, width: width, height: height, in: CGRect(
            x: originX, y: originY, width: sourceWidth, height: sourceHeight)),
      let drawnResult = draw(result, width: width, height: height, in: frameRect)
    else { return nil }

    // The pixels the result can reach, and its weight in each.
    let region = frameRect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
    let x0 = Int(region.minX), y0 = Int(region.minY)
    let regionWidth = Int(region.width), regionHeight = Int(region.height)
    var weight = [Float](repeating: 1, count: regionWidth * regionHeight)
    func insideSource(_ x: Int, _ y: Int) -> Bool {
      x >= originX && x < originX + sourceWidth && y >= originY && y < originY + sourceHeight
    }
    if let mask = merge.mask {
      let coverage = mask.coverage(
        width: regionWidth, height: regionHeight,
        origin: CGPoint(x: originX - x0, y: originY - y0))
      weight = coverage.map { $0 != 0 ? 1 : 0 }
      weight = MaskFilter.outset(weight, width: regionWidth, height: regionHeight, by: maskBlurOutset)
      weight = MaskFilter.blur(weight, width: regionWidth, height: regionHeight, sigma: maskBlur)
    } else if maskBlur > 0 {
      // Feather only the edges inside the source.
      let feather = Float(maskBlur)
      let left = crop.minX > 0, right = crop.maxX < Double(sourceWidth)
      let top = crop.minY > 0, bottom = crop.maxY < Double(sourceHeight)
      for j in 0..<regionHeight {
        let py = Float(y0 + j) + 0.5
        for i in 0..<regionWidth {
          let px = Float(x0 + i) + 0.5
          var w: Float = 1
          if left { w = min(w, (px - Float(frameRect.minX)) / feather) }
          if right { w = min(w, (Float(frameRect.maxX) - px) / feather) }
          if top { w = min(w, (py - Float(frameRect.minY)) / feather) }
          if bottom { w = min(w, (Float(frameRect.maxY) - py) / feather) }
          weight[j * regionWidth + i] = min(max(w, 0), 1)
        }
      }
    }
    // Outpainted pixels take the result whole.
    for j in 0..<regionHeight {
      for i in 0..<regionWidth where !insideSource(x0 + i, y0 + j) {
        weight[j * regionWidth + i] = 1
      }
    }

    // Premultiplied blend: out = source × (1 − w·αresult) + result × w. Weight 0 copies the
    // source's bytes as they are.
    for j in 0..<regionHeight {
      for i in 0..<regionWidth {
        let w = weight[j * regionWidth + i]
        guard w > 0 else { continue }
        let index = ((y0 + j) * width + x0 + i) * 4
        let resultAlpha = Float(drawnResult[index + 3]) / 255
        let keep = 1 - w * resultAlpha
        guard keep < 1 else { continue }
        for c in 0..<4 {
          let value = Float(output[index + c]) * keep + Float(drawnResult[index + c]) * w
          output[index + c] = UInt8(clamping: Int(value.rounded()))
        }
      }
    }
    guard let image = makeImage(output, width: width, height: height) else { return nil }

    let storedMask = merge.mask.map {
      CanvasMask.storedCodes($0.coverage(width: width, height: height, origin: CGPoint(x: originX, y: originY)))
    }
    let record = RefineRecord(
      rect: [crop.minX, crop.minY, crop.width, crop.height], scale: merge.scale,
      offset: [merge.offset.width, merge.offset.height], mask: merge.mask)
    return Merged(image: image, sourceOrigin: CGPoint(x: originX, y: originY), storedMask: storedMask, record: record)
  }

  /// RGBA premultiplied sRGB bytes, `width` × `height` from the top-left row, with `image` drawn
  /// in `rect` (y down) and transparent elsewhere.
  private static func draw(_ image: CGImage, width: Int, height: Int, in rect: CGRect) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
      guard let context = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.draw(
        image, in: CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height))
      return true
    }
    return drawn ? bytes : nil
  }

  private static func makeImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}

/// The engine's mask softening, on a weight map: grow or shrink by whole pixels (`ccv_dilate`
/// with a 3×3 square, once per pixel), then a Gaussian blur of the given sigma (`ccv_blur`),
/// approximated by three box blurs so it costs the same at any sigma.
nonisolated enum MaskFilter {
  static func outset(_ values: [Float], width: Int, height: Int, by pixels: Int) -> [Float] {
    guard pixels != 0 else { return values }
    let radius = abs(pixels)
    let pick: (Float, Float) -> Float = pixels > 0 ? { max($0, $1) } : { min($0, $1) }
    // A square of side 2r + 1 is a row pass then a column pass.
    var rows = values
    for y in 0..<height {
      for x in 0..<width {
        var value = values[y * width + x]
        for dx in max(x - radius, 0)...min(x + radius, width - 1) { value = pick(value, values[y * width + dx]) }
        rows[y * width + x] = value
      }
    }
    var result = rows
    for y in 0..<height {
      for x in 0..<width {
        var value = rows[y * width + x]
        for dy in max(y - radius, 0)...min(y + radius, height - 1) { value = pick(value, rows[dy * width + x]) }
        result[y * width + x] = value
      }
    }
    return result
  }

  static func blur(_ values: [Float], width: Int, height: Int, sigma: Double) -> [Float] {
    guard sigma > 0, width > 0, height > 0 else { return values }
    // Box widths for three passes approximating a Gaussian (Kovesi, "Fast almost-Gaussian
    // filtering").
    let n = 3.0
    let ideal = (12 * sigma * sigma / n + 1).squareRoot()
    var lower = Int(ideal.rounded(.down))
    if lower % 2 == 0 { lower -= 1 }
    let upper = lower + 2
    let m = ((12 * sigma * sigma - n * Double(lower * lower) - 4 * n * Double(lower) - 3 * n) / (-4 * Double(lower) - 4)).rounded()
    var result = values
    for pass in 0..<3 {
      let radius = ((Double(pass) < m ? lower : upper) - 1) / 2
      guard radius > 0 else { continue }
      result = box(result, width: width, height: height, radius: radius, horizontal: true)
      result = box(result, width: width, height: height, radius: radius, horizontal: false)
    }
    // Box sums leave tiny remainders where they should be exactly 0 or 1.
    return result.map { $0 < 1e-4 ? 0 : $0 > 1 - 1e-4 ? 1 : $0 }
  }

  /// A running-sum box blur along rows or columns, the edge pixel repeated past the edges.
  private static func box(_ values: [Float], width: Int, height: Int, radius: Int, horizontal: Bool) -> [Float] {
    var result = values
    let lines = horizontal ? height : width
    let length = horizontal ? width : height
    let scale = 1 / Float(2 * radius + 1)
    for line in 0..<lines {
      func at(_ i: Int) -> Float {
        let clamped = min(max(i, 0), length - 1)
        return values[horizontal ? line * width + clamped : clamped * width + line]
      }
      var sum: Float = 0
      for i in -radius...radius { sum += at(i) }
      for i in 0..<length {
        result[horizontal ? line * width + i : i * width + line] = sum * scale
        sum += at(i + radius + 1) - at(i - radius)
      }
    }
    return result
  }
}
