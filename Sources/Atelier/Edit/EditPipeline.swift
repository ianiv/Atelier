import CoreGraphics
import Foundation

/// Renders an Edit screen look (`EditOptions`) onto an image, on the CPU with Accelerate (no
/// Metal, no Core Image, as `ColorMatch` does, so the numbers follow grain.py's). The order is
/// fixed: 1 motion smear, 2 blur, 3 Reinhard Lab match, 4 histogram match, 5 grain.py's RGB
/// colour match, 6 grade, 7 LUT, 8 halation, 9 vignette, 10 random grain, 11 real noise, 12
/// truncate to 8 bits, alpha passing through. Slice F assembles the steps and the caches; for
/// now the body is the identity.
nonisolated enum EditPipeline {
  /// What a look is rendered with besides its options: the profile's grain data and a reference's
  /// measurements, taken once when they're loaded rather than on every render. A saved step's
  /// come from its record (`Edit.Record.context`).
  struct Context: Hashable, Sendable {
    /// The profile's reference width, which scales the grain (grain.py's `ref_w`).
    var refWidth: Int = 1440
    /// Grain gain at the four brightness band centres; nil for grain.py's built-in curve.
    var curve: [Double]?
    /// The profile's reference RGB mean and spread, for `Match.colour`.
    var refStats: GrainProfile.ChannelStats?
    /// The profile's real-noise patches, for `Grain.real`.
    var realNoise: GrainProfile.RealNoise?
    /// The match target's Lab statistics, for the Reinhard match.
    var referenceLab: Edit.LabStats?
    /// The match target's cumulative histograms, for `Histogram`.
    var referenceHistogram: Edit.HistogramTable?
    /// The LUT's table, for `EditOptions.lut`.
    var lut: Edit.LUTTable?

    init(
      refWidth: Int = 1440, curve: [Double]? = nil, refStats: GrainProfile.ChannelStats? = nil,
      realNoise: GrainProfile.RealNoise? = nil, referenceLab: Edit.LabStats? = nil,
      referenceHistogram: Edit.HistogramTable? = nil, lut: Edit.LUTTable? = nil
    ) {
      self.refWidth = refWidth
      self.curve = curve
      self.refStats = refStats
      self.realNoise = realNoise
      self.referenceLab = referenceLab
      self.referenceHistogram = referenceHistogram
      self.lut = lut
    }

    /// The context with nothing loaded: no profile, reference or LUT.
    static let empty = Context()
  }

  /// The part of the full-size render to make, and at what scale: the 100% view renders only
  /// what's visible, and the resampler takes this window in full-size pixels, so its grain is
  /// exactly that part of the full render's. Blur and smear lengths are in full-size pixels and
  /// scale by `scale` (as Grain Studio's preview does).
  struct Window: Hashable, Sendable {
    /// Full-size pixels.
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    /// Output pixels per full-size pixel: 1 at 100%, below 1 for a fitted preview.
    var scale: Double = 1

    init(x: Int, y: Int, width: Int, height: Int, scale: Double = 1) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
      self.scale = scale
    }

    /// All of an image of this size, at `scale`.
    static func whole(width: Int, height: Int, scale: Double = 1) -> Window {
      Window(x: 0, y: 0, width: width, height: height, scale: scale)
    }

    /// The output's size in pixels.
    var outputWidth: Int { max(1, Int((Double(width) * scale).rounded())) }
    var outputHeight: Int { max(1, Int((Double(height) * scale).rounded())) }
  }

  /// An image as the steps work on it: grain.py's float32 HxWx3 array in 0–255, as three planes,
  /// with alpha kept apart to pass through.
  struct Planes: Sendable {
    var width: Int
    var height: Int
    var r: [Float]
    var g: [Float]
    var b: [Float]
    /// Straight (not premultiplied) alpha, 0–255.
    var alpha: [UInt8]

    init(width: Int, height: Int, r: [Float], g: [Float], b: [Float], alpha: [UInt8]) {
      self.width = width
      self.height = height
      self.r = r
      self.g = g
      self.b = b
      self.alpha = alpha
    }

    /// An image's sRGB pixels (`ColorMatch.rgba`); nil when it can't be read.
    init?(_ image: CGImage) {
      guard let pixels = ColorMatch.rgba(image) else { return nil }
      self.init(rgba: pixels, width: image.width, height: image.height)
    }

    init(rgba pixels: [UInt8], width: Int, height: Int) {
      let count = width * height
      var r = [Float](repeating: 0, count: count)
      var g = r
      var b = r
      var alpha = [UInt8](repeating: 255, count: count)
      for index in 0..<min(count, pixels.count / 4) {
        r[index] = Float(pixels[index * 4])
        g[index] = Float(pixels[index * 4 + 1])
        b[index] = Float(pixels[index * 4 + 2])
        alpha[index] = pixels[index * 4 + 3]
      }
      self.init(width: width, height: height, r: r, g: g, b: b, alpha: alpha)
    }

    /// RGBA8, each value clipped to 0–255 and truncated, as grain.py's
    /// `np.clip(a, 0, 255).astype(np.uint8)` (step 12).
    var rgba: [UInt8] {
      let count = width * height
      var out = [UInt8](repeating: 0, count: count * 4)
      func byte(_ value: Float) -> UInt8 { value.isNaN ? 0 : UInt8(min(max(value, 0), 255)) }
      for index in 0..<count {
        out[index * 4] = byte(r[index])
        out[index * 4 + 1] = byte(g[index])
        out[index * 4 + 2] = byte(b[index])
        out[index * 4 + 3] = alpha[index]
      }
      return out
    }

    var cgImage: CGImage? { ColorMatch.cgImage(rgba: rgba, width: width, height: height) }

    /// The pixels inside `x, y, width, height`, clamped to the image.
    func cropped(x: Int, y: Int, width w: Int, height h: Int) -> Planes {
      let x0 = min(max(x, 0), width)
      let y0 = min(max(y, 0), height)
      let w = min(max(w, 0), width - x0)
      let h = min(max(h, 0), height - y0)
      func crop<T>(_ plane: [T]) -> [T] {
        var out: [T] = []
        out.reserveCapacity(w * h)
        for row in y0..<y0 + h { out.append(contentsOf: plane[row * width + x0..<row * width + x0 + w]) }
        return out
      }
      return Planes(width: w, height: h, r: crop(r), g: crop(g), b: crop(b), alpha: crop(alpha))
    }
  }

  /// `source` with `options` applied, rendered with `context`: the whole image at full size, or
  /// only `window`. Runs off the main actor; stops with `CancellationError` when its task is
  /// cancelled (the screen re-renders on every change, `.task(id:)`).
  ///
  /// The identity for now: the source, cut to `window`. Later slices fill in the steps.
  @concurrent static func render(
    source: CGImage, options _: EditOptions, context _: Context = .empty, window: Window? = nil
  ) async throws -> CGImage {
    try Task.checkCancellation()
    guard let window else { return source }
    let whole = window.x == 0 && window.y == 0 && window.width == source.width && window.height == source.height
    if whole, window.scale == 1 { return source }
    guard var planes = Planes(source) else { return source }
    planes = planes.cropped(x: window.x, y: window.y, width: window.width, height: window.height)
    guard let cropped = planes.cgImage else { return source }
    guard window.scale != 1 else { return cropped }
    // A plain scale until Resample (Pillow's bicubic, Slice A) takes the window.
    let size = (width: window.outputWidth, height: window.outputHeight)
    guard
      let graphics = CGContext(
        data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return cropped }
    graphics.interpolationQuality = .high
    graphics.draw(cropped, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    return graphics.makeImage() ?? cropped
  }
}
