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
  /// The canvas's mask when the run was queued, painted inside the frame or not: it goes back on
  /// the canvas with the result.
  var canvasMask: CanvasMask?

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
    var canvasMask: CanvasMask?
  }

  var record: Record {
    Record(
      sourceTensorId: sourceTensorId, scale: scale, offsetX: offset.width, offsetY: offset.height,
      frameWidth: frameSize.width, frameHeight: frameSize.height, mask: mask, canvasMask: canvasMask)
  }

  init(
    source: CGImage, sourceTensorId: Int64?, scale: Double?, offset: CGSize, frameSize: CGSize, mask: CanvasMask?,
    canvasMask: CanvasMask? = nil
  ) {
    self.source = source
    self.sourceTensorId = sourceTensorId
    self.scale = scale
    self.offset = offset
    self.frameSize = frameSize
    self.mask = mask
    self.canvasMask = canvasMask ?? mask
  }

  init(record: Record, source: CGImage, sameProject: Bool) {
    self.init(
      source: source, sourceTensorId: sameProject ? record.sourceTensorId : nil, scale: record.scale,
      offset: CGSize(width: record.offsetX, height: record.offsetY),
      frameSize: CGSize(width: record.frameWidth, height: record.frameHeight), mask: record.mask,
      canvasMask: record.canvasMask)
  }
}

/// The canvas image's mask when an Edit job was queued, for that image to remember: the image's
/// step (nil for an image from outside), its size, and the mask in its pixels.
nonisolated struct CanvasSourceMask: Codable, Hashable, Sendable {
  var tensorId: Int64?
  var width: Double
  var height: Double
  var mask: CanvasMask
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
  /// drawn. Merge only applies when it changes anything (`RefineMerge.applies`). `detail` is the
  /// source step's finer layers (`Project.detailLayers`), drawn into the frame at their own
  /// resolution.
  @discardableResult
  mutating func setRefineInputs(
    source: CGImage, sourceTensorId: Int64?, isImported: Bool, scale: Double?, offset: CGSize,
    mask: CanvasMask?, merge: Bool, detail: [Project.DetailLayer] = []
  ) -> Bool {
    let frame = CGSize(width: configuration.width, height: configuration.height)
    // A merging run at a near-whole zoom takes that zoom, so its kept layer is its pixels.
    let snapped = merge
      ? RefineMerge.snapped(scale: scale, offset: offset, sourceSize: CGSize(width: source.width, height: source.height), frameSize: frame)
      : (scale: scale, offset: offset)
    let scale = snapped.scale, offset = snapped.offset
    let placement = CanvasPlacement(
      sourceSize: CGSize(width: source.width, height: source.height), frameSize: frame, scale: scale, offset: offset)
    guard let rendered = CanvasState.render(source, placement: placement, detail: detail) else { return false }
    canvas = rendered
    canvasIsImported = isImported
    let maskPNG = mask.flatMap { $0.mayHavePaint ? $0.frameMask(placement, canvas: rendered) : nil }
    self.mask = maskPNG
    canvasSourceMask = mask.map {
      CanvasSourceMask(
        tensorId: isImported ? nil : sourceTensorId, width: Double(source.width), height: Double(source.height), mask: $0)
    }
    if merge, RefineMerge.applies(placement: placement, scale: scale, offset: offset, hasMask: maskPNG != nil) {
      self.merge = RefineMerge(
        source: source, sourceTensorId: isImported ? nil : sourceTensorId, scale: scale, offset: offset,
        frameSize: frame, mask: maskPNG != nil ? mask : nil, canvasMask: mask)
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

nonisolated extension RefineMerge {
  /// The canvas zoom and offset a merging run takes: a zoom within 2% of a whole number is that
  /// number (`CanvasMerge.frameDensity`, the user's choice), about the same image point at the
  /// frame's center, and the image's edge moved onto a whole frame pixel (`CanvasPlacement` rounds
  /// its rectangle out to whole pixels, which would stretch it a pixel). The frame's pixels are then
  /// its kept layer's one for one. A fitted zoom (nil) is left alone.
  static func snapped(scale: Double?, offset: CGSize, sourceSize: CGSize, frameSize: CGSize) -> (scale: Double?, offset: CGSize) {
    guard let scale, scale > 0 else { return (scale, offset) }
    let whole = scale.rounded()
    guard whole >= 1, abs(scale - whole) <= whole * 0.02 else { return (scale, offset) }
    func axis(_ offset: Double, source: Double, frame: Double) -> Double {
      // The image's leading edge in frame pixels is base + offset (`CanvasPlacement.imageRect`).
      let base = frame / 2 - source * whole / 2
      return (base + offset * whole / scale).rounded() - base
    }
    return (
      whole,
      CGSize(
        width: axis(offset.width, source: sourceSize.width, frame: frameSize.width),
        height: axis(offset.height, source: sourceSize.height, frame: frameSize.height)))
  }

  /// Whether merging changes anything: with a mask, or with the frame moved or zoomed to show part
  /// of the image or reach past it. A fitted, centered image is left as Edit always took it (the
  /// result at the output size), even when its shape leaves bars in the frame.
  static func applies(placement: CanvasPlacement, scale: Double?, offset: CGSize, hasMask: Bool) -> Bool {
    hasMask || (!placement.showsWholeImage && !(scale == nil && offset == .zero))
  }
}

/// A merged result as the project stores it, Draw Things' way. Without a mask or zoom, inside the
/// source, it's one flattened image layer. With a mask, zoomed in, or when the frame reached past
/// the source, it's layers, as Draw Things keeps a canvas (a zoomed frame at its own density,
/// `CanvasMerge.denseFrame`, over the source step's earlier detail layers): the source at the origin (its own step's tensor when
/// that's a plain image, carrying the paint mask, `CanvasMask.Stored`), and over it the merged
/// result cropped to the frame, at the frame's place in the source's pixels (possibly negative).
/// What neither layer covers is empty (`Project.composite`).
nonisolated struct RefinedStep: @unchecked Sendable {
  var record: RefineRecord
  /// The merged image as it shows: the canvas of both layers, transparent where neither reaches.
  var composite: CGImage
  var layers: Layers?

  struct Layers {
    /// The canvas image, alpha and all.
    var source: CGImage
    /// Its project step's image, reused as the bottom layer when that's a plain image.
    var sourceTensorId: Int64?
    /// Painted pixels at the source's size, 255 painted (`CanvasMask.coverage`).
    var paint: [UInt8]?
    /// The merged result inside the frame, and where its top left is in the source's pixels.
    var frame: CGImage
    var frameX: Int32
    var frameY: Int32
    /// The frame's pixels per source pixel ×120 (`scale_factor_by_120`): above 120 for a zoomed
    /// refine, which keeps the detail the run added (`CanvasMerge.denseFrame`).
    var frameScaleFactorBy120: Int32 = 120
    /// The frame's alpha at its size, when `frame` is its straight color, opaque (a dense frame,
    /// see-through where the source below shows); nil takes `frame`'s own alpha.
    var frameAlpha: [UInt8]?
  }
}

/// Merges a refine run's result back into its source image (`RefineMerge`), in pure Core
/// Graphics plus byte math, so it's exact and testable. The result frame is scaled back into the
/// rectangle it showed (`CanvasPlacement.cropRect`) on a canvas grown to hold both the source and
/// that rectangle, as Draw Things' canvas grows when the frame reaches past the image. Pixels
/// neither covers stay transparent.
///
/// With a mask, the result shows through it, grown by Mask Blur Outset and feathered by Mask Blur
/// as the engine does in the frame (`LocalImageGenerator.imageWithMask`: dilate, then blur), the
/// amounts converted from frame pixels to the source's; source pixels the feathered mask doesn't
/// reach are left exactly as they were. The frame's edges that lie inside the source are feathered
/// over Mask Blur too, with or without a mask, so no seam shows; edges at or past the source's edge
/// aren't. Wherever the frame lies outside the source or over its transparent pixels
/// (outpainted), the result goes in whole.
nonisolated enum CanvasMerge {
  struct Merged: @unchecked Sendable {
    var image: CGImage
    /// `image` as one flattened tensor (RGB: what neither covers turns black), for the run's output.
    var tensor: Tensor<FloatType> = Tensor(.CPU, .NHWC(1, 1, 1, 3))
    /// Where the source's top left is in `image` (it moves when the canvas grows left or up).
    var sourceOrigin: CGPoint
    var step: RefinedStep
  }

  /// `input` is the frame as the run took it (`GenerationEngine.Request.canvas`), which a zoomed
  /// refine blends over at the frame's resolution (`denseFrame`).
  @concurrent static func merged(
    _ result: Tensor<FloatType>, into merge: RefineMerge, input: CGImage?, maskBlur: Double, maskBlurOutset: Int
  ) async throws -> Merged {
    guard let image = ImageTensor.cgImage(from: result),
          var merged = Self.merge(image, into: merge, input: input, maskBlur: maskBlur, maskBlurOutset: maskBlurOutset),
          let tensor = ImageTensor.tensor(from: merged.image)
    else { throw ProjectError.badImage }
    merged.tensor = tensor
    return merged
  }

  /// A refine frame's density (`scale_factor_by_120`) for a canvas zoom: zoom ×120, a zoom
  /// within 2% of a whole number taken as that number (so a 4× frame lands pixel for pixel), at
  /// most 8×, and never below the source's own 120.
  static func frameDensity(zoom: Double) -> Int {
    var zoom = zoom
    let whole = zoom.rounded()
    if whole >= 1, abs(zoom - whole) <= whole * 0.02 { zoom = whole }
    return min(max(Int((zoom * 120).rounded()), 120), 960)
  }

  /// `input` is the frame as the run took it (`GenerationEngine.Request.canvas`; nil renders it
  /// from the source). A zoomed refine inside the source keeps its frame at the frame's own
  /// density (`denseFrame`); any other is merged at the source's pixels.
  static func merge(
    _ result: CGImage, into merge: RefineMerge, input: CGImage? = nil, maskBlur: Double, maskBlurOutset: Int
  ) -> Merged? {
    let placement = merge.placement
    let source = merge.source
    let sourceWidth = source.width, sourceHeight = source.height
    let crop = placement.cropRect
    let sourceRect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
    let bounds = sourceRect.union(crop).integral
    let zoom = (placement.zoom.x + placement.zoom.y) / 2
    let density = frameDensity(zoom: zoom)
    // A canvas grown past the source stays at its pixels, as before.
    if density > 120, bounds == sourceRect {
      return denseFrame(
        result, into: merge, input: input, density: density, maskBlur: maskBlur, maskBlurOutset: maskBlurOutset)
    }
    let width = Int(bounds.width), height = Int(bounds.height)
    guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
    let originX = Int(-bounds.minX), originY = Int(-bounds.minY)
    // The frame in the merged image's pixels.
    let frameRect = crop.offsetBy(dx: Double(originX), dy: Double(originY))
    // Mask Blur and Outset are frame pixels (the engine applies them in the frame).
    let feather = maskBlur / zoom
    let outset = Int((Double(maskBlurOutset) / zoom).rounded())

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
    if let mask = merge.mask {
      let coverage = mask.coverage(
        width: regionWidth, height: regionHeight,
        origin: CGPoint(x: originX - x0, y: originY - y0))
      weight = coverage.map { $0 != 0 ? 1 : 0 }
      weight = MaskFilter.outset(weight, width: regionWidth, height: regionHeight, by: outset)
      weight = MaskFilter.blur(weight, width: regionWidth, height: regionHeight, sigma: feather)
    }
    if feather > 0 {
      // The frame's edges inside the source fade out, so a mask crossing one leaves no seam.
      let fade = Float(feather)
      let left = crop.minX > 0, right = crop.maxX < Double(sourceWidth)
      let top = crop.minY > 0, bottom = crop.maxY < Double(sourceHeight)
      for j in 0..<regionHeight {
        let py = Float(y0 + j) + 0.5
        for i in 0..<regionWidth {
          let px = Float(x0 + i) + 0.5
          var w: Float = 1
          if left { w = min(w, (px - Float(frameRect.minX)) / fade) }
          if right { w = min(w, (Float(frameRect.maxX) - px) / fade) }
          if top { w = min(w, (py - Float(frameRect.minY)) / fade) }
          if bottom { w = min(w, (Float(frameRect.maxY) - py) / fade) }
          weight[j * regionWidth + i] *= min(max(w, 0), 1)
        }
      }
    }
    // Outpainted pixels take the result whole: outside the source, or where it's transparent.
    for j in 0..<regionHeight {
      for i in 0..<regionWidth where output[((y0 + j) * width + x0 + i) * 4 + 3] < 128 {
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

    let record = RefineRecord(
      rect: [crop.minX, crop.minY, crop.width, crop.height], scale: merge.scale,
      offset: [merge.offset.width, merge.offset.height], mask: merge.mask)
    var step = RefinedStep(record: record, composite: image)
    let grown = bounds != sourceRect
    if grown || merge.mask != nil, let frame = image.cropping(to: region) {
      // The paint the stored mask keeps is what's under the frame layer: Draw Things renders a
      // painted pixel at alpha 0xF8, so paint outside the frame would leave the image faintly
      // see-through there. The whole mask stays in the record.
      let frameX = x0 - originX, frameY = y0 - originY
      let paint = merge.mask.map {
        paintUnder($0, width: sourceWidth, height: sourceHeight, frame: CGRect(x: frameX, y: frameY, width: regionWidth, height: regionHeight))
      }
      step.layers = RefinedStep.Layers(
        source: source, sourceTensorId: merge.sourceTensorId, paint: paint,
        frame: frame, frameX: Int32(frameX), frameY: Int32(frameY))
    }
    return Merged(image: image, sourceOrigin: CGPoint(x: originX, y: originY), step: step)
  }

  /// The mask's coverage at the source's size, kept only inside `frame` (source pixels).
  private static func paintUnder(_ mask: CanvasMask, width: Int, height: Int, frame: CGRect) -> [UInt8] {
    var coverage = mask.coverage(width: width, height: height)
    let frameX = Int(frame.minX), frameY = Int(frame.minY), frameWidth = Int(frame.width), frameHeight = Int(frame.height)
    for y in 0..<height {
      let insideY = y >= frameY && y < frameY + frameHeight
      for x in 0..<width where !insideY || x < frameX || x >= frameX + frameWidth {
        coverage[y * width + x] = 0
      }
    }
    return coverage
  }

  /// A zoomed refine inside its source, kept at the detail the run added, as Draw Things keeps a
  /// canvas layer at more pixels than the area it covers (`TensorData.scale_factor_by_120`). The
  /// weight the result has in each frame pixel is worked out in the frame's own pixels: the mask
  /// grown by Mask Blur Outset and feathered by Mask Blur exactly as the engine does
  /// (`LocalImageGenerator.imageWithMask`), the frame's edges inside the source feathered over
  /// Mask Blur, outpainted pixels (transparent in the input) taken whole. The top layer is the
  /// result with that weight as its alpha, so where the weight is 0 the source below shows as it
  /// is, its own pixels untouched; painted pixels are the result blended over the input as the run
  /// took it, opaque, since the source below them is stored see-through (0xF9, alpha 0xF8). The
  /// layer covers the crop rectangle grown to whole source pixels, at `density` (at a whole zoom,
  /// frame pixels one for one), transparent around the frame. Its alpha goes into its mask's codes
  /// (`CanvasMask.Stored`, so `& 0xF8`); the image the step shows (`Merged.image`) is the source with
  /// the layer drawn over it at those alphas, at the source's size, as `Project.composite` reads it.
  private static func denseFrame(
    _ result: CGImage, into merge: RefineMerge, input: CGImage?, density: Int, maskBlur: Double, maskBlurOutset: Int
  ) -> Merged? {
    let placement = merge.placement
    let source = merge.source
    let sourceWidth = source.width, sourceHeight = source.height
    let crop = placement.cropRect
    let frameWidth = Int(placement.frameSize.width), frameHeight = Int(placement.frameSize.height)
    let frameBounds = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
    guard frameWidth > 0, frameHeight > 0,
          let input = input ?? CanvasState.render(source, placement: placement),
          let inputBytes = draw(input, width: frameWidth, height: frameHeight, in: frameBounds),
          let drawnResult = draw(result, width: frameWidth, height: frameHeight, in: frameBounds)
    else { return nil }

    var weight = [Float](repeating: 1, count: frameWidth * frameHeight)
    var painted = [Bool](repeating: false, count: frameWidth * frameHeight)
    if let mask = merge.mask {
      let coverage = mask.coverage(
        width: frameWidth, height: frameHeight, scale: placement.zoom, origin: placement.imageRect.origin)
      painted = coverage.map { $0 != 0 }
      weight = coverage.map { $0 != 0 ? 1 : 0 }
      weight = MaskFilter.outset(weight, width: frameWidth, height: frameHeight, by: maskBlurOutset)
      weight = MaskFilter.blur(weight, width: frameWidth, height: frameHeight, sigma: maskBlur)
    }
    if maskBlur > 0 {
      // The frame's edges inside the source fade out, so a mask crossing one leaves no seam.
      let fade = Float(maskBlur)
      let left = crop.minX > 0, right = crop.maxX < Double(sourceWidth)
      let top = crop.minY > 0, bottom = crop.maxY < Double(sourceHeight)
      for j in 0..<frameHeight {
        let py = Float(j) + 0.5
        for i in 0..<frameWidth {
          let px = Float(i) + 0.5
          var w: Float = 1
          if left { w = min(w, px / fade) }
          if right { w = min(w, (Float(frameWidth) - px) / fade) }
          if top { w = min(w, py / fade) }
          if bottom { w = min(w, (Float(frameHeight) - py) / fade) }
          weight[j * frameWidth + i] *= min(max(w, 0), 1)
        }
      }
    }
    // The layer's straight (not premultiplied) color and its alpha, in frame pixels.
    var color = [UInt8](repeating: 0, count: frameWidth * frameHeight * 4)
    var alpha = [UInt8](repeating: 0, count: frameWidth * frameHeight)
    for index in weight.indices {
      let inputAlpha = inputBytes[index * 4 + 3]
      var w = weight[index]
      if inputAlpha < 128 { w = 1 }
      let resultAlpha = Float(drawnResult[index * 4 + 3]) / 255
      if painted[index], inputAlpha >= 128 {
        // Premultiplied blend over the input, as `merge` does, kept opaque.
        let keep = 1 - w * resultAlpha
        var out = [Float](repeating: 0, count: 4)
        for c in 0..<4 {
          out[c] = Float(inputBytes[index * 4 + c]) * keep + Float(drawnResult[index * 4 + c]) * w
        }
        let a = max(out[3], 1)
        for c in 0..<3 { color[index * 4 + c] = UInt8(clamping: Int((out[c] * 255 / a).rounded())) }
        alpha[index] = 255
      } else {
        let a = Float(drawnResult[index * 4 + 3])
        for c in 0..<3 {
          color[index * 4 + c] = a > 0 ? UInt8(clamping: Int((Float(drawnResult[index * 4 + c]) * 255 / a).rounded())) : 0
        }
        alpha[index] = UInt8(clamping: Int((w * resultAlpha * 255).rounded()))
      }
      color[index * 4 + 3] = 255
    }
    guard let straight = makeImage(color, width: frameWidth, height: frameHeight),
          let alphaImage = grayImage(alpha, width: frameWidth, height: frameHeight)
    else { return nil }

    // The layer: whole source pixels around the crop, `density` pixels per 120 of them.
    let units = crop.integral.intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
    let scale = Double(density) / 120
    let layerWidth = Int((units.width * scale).rounded()), layerHeight = Int((units.height * scale).rounded())
    guard !units.isNull, layerWidth > 0, layerHeight > 0, layerWidth <= 16384, layerHeight <= 16384 else { return nil }
    // Within a hundredth of a pixel is that pixel, so a whole zoom isn't resampled.
    func snapped(_ value: Double) -> Double { abs(value - value.rounded()) < 0.01 ? value.rounded() : value }
    let frameInLayer = CGRect(
      x: snapped((crop.minX - units.minX) * scale), y: snapped((crop.minY - units.minY) * scale),
      width: snapped(crop.width * scale), height: snapped(crop.height * scale))
    guard let covered = composed([(straight, frameInLayer)], width: layerWidth, height: layerHeight),
          let layerAlpha = grayDrawn(alphaImage, width: layerWidth, height: layerHeight, in: frameInLayer),
          var frameBytes = draw(covered, width: layerWidth, height: layerHeight, in: CGRect(x: 0, y: 0, width: layerWidth, height: layerHeight))
    else { return nil }
    // Pixels the frame only partly covers (its edges, at a fractional zoom) come premultiplied by
    // that coverage, which the alpha already carries: back to the straight color, opaque, so the
    // stored tensor isn't darkened there and then faded again.
    for index in 0..<(layerWidth * layerHeight) {
      let coverage = Int(frameBytes[index * 4 + 3])
      guard coverage < 255 else { continue }
      for c in 0..<3 {
        frameBytes[index * 4 + c] = coverage > 0 ? UInt8(min(Int(frameBytes[index * 4 + c]) * 255 / coverage, 255)) : 0
      }
      frameBytes[index * 4 + 3] = 255
    }
    guard let frame = makeImage(frameBytes, width: layerWidth, height: layerHeight) else { return nil }
    // What the layer shows once stored: its color at its mask codes' alpha (`Project.masked`).
    var shown = [UInt8](repeating: 0, count: layerWidth * layerHeight * 4)
    for index in 0..<(layerWidth * layerHeight) {
      let a = Int(CanvasMask.Stored.alpha(CanvasMask.Stored.code(alpha: layerAlpha[index])))
      for c in 0..<3 { shown[index * 4 + c] = UInt8((Int(frameBytes[index * 4 + c]) * a) / 255) }
      shown[index * 4 + 3] = UInt8(a)
    }
    guard let shownImage = makeImage(shown, width: layerWidth, height: layerHeight),
          let image = composed([
            (source, CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)), (shownImage, units),
          ], width: sourceWidth, height: sourceHeight)
    else { return nil }

    let record = RefineRecord(
      rect: [crop.minX, crop.minY, crop.width, crop.height], scale: merge.scale,
      offset: [merge.offset.width, merge.offset.height], mask: merge.mask)
    var step = RefinedStep(record: record, composite: image)
    step.layers = RefinedStep.Layers(
      source: source, sourceTensorId: merge.sourceTensorId,
      paint: merge.mask.map {
        paintCovered(
          paintUnder($0, width: sourceWidth, height: sourceHeight, frame: units), width: sourceWidth, units: units,
          scale: scale, layerAlpha: layerAlpha, layerWidth: layerWidth, layerHeight: layerHeight)
      },
      frame: frame, frameX: Int32(units.minX), frameY: Int32(units.minY), frameScaleFactorBy120: Int32(density),
      frameAlpha: layerAlpha)
    return Merged(image: image, sourceOrigin: .zero, step: step)
  }

  /// `paint` (source pixels) kept only where the dense layer over it is wholly opaque: every
  /// layer pixel over the source pixel and its neighbours stored at alpha 255. The source keeps a painted pixel as
  /// 0xF9, which Draw Things and `Project.composite` show at alpha 0xF8, so anywhere the layer is
  /// see-through (around the frame, a stroke's edge) paint would leave the image faintly
  /// see-through; there the source keeps its opaque code instead.
  private static func paintCovered(
    _ paint: [UInt8], width: Int, units: CGRect, scale: Double, layerAlpha: [UInt8], layerWidth: Int, layerHeight: Int
  ) -> [UInt8] {
    var paint = paint
    for index in paint.indices where paint[index] != 0 {
      let x = index % width, y = index / width
      // With the source pixels on either side: drawn at the source's size the layer is resampled,
      // and its neighbours' alpha reaches into this pixel.
      let x0 = Int(((Double(x - 1) - units.minX) * scale).rounded(.down)), x1 = Int(((Double(x + 2) - units.minX) * scale).rounded(.up))
      let y0 = Int(((Double(y - 1) - units.minY) * scale).rounded(.down)), y1 = Int(((Double(y + 2) - units.minY) * scale).rounded(.up))
      var opaque = x0 >= 0 && y0 >= 0 && x1 <= layerWidth && y1 <= layerHeight && x0 < x1 && y0 < y1
      if opaque {
        check: for ly in y0..<y1 {
          for lx in x0..<x1 where CanvasMask.Stored.alpha(CanvasMask.Stored.code(alpha: layerAlpha[ly * layerWidth + lx])) != 255 {
            opaque = false
            break check
          }
        }
      }
      if !opaque { paint[index] = 0 }
    }
    return paint
  }

  /// One byte per pixel as a gray image, top row first.
  private static func grayImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  /// A gray image drawn in `rect` (y down) on a black canvas, as bytes top row first.
  private static func grayDrawn(_ image: CGImage, width: Int, height: Int, in rect: CGRect) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: width * height)
    let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
      guard let context = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height))
      return true
    }
    return drawn ? bytes : nil
  }

  /// Images drawn in order, each in its rectangle (y down), on a transparent canvas.
  private static func composed(_ images: [(CGImage, CGRect)], width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    for (image, rect) in images {
      context.draw(image, in: CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height))
    }
    return context.makeImage()
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
