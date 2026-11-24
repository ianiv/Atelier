import CoreGraphics
import Foundation
import Synchronization

/// Renders an Edit screen look (`EditOptions`) onto an image, on the CPU with Accelerate (no
/// Metal, no Core Image, as `ColorMatch` does, so the numbers follow grain.py's). The order is
/// fixed: 1 motion smear, 2 blur, 3 Reinhard Lab match, 4 histogram match, 5 grain.py's RGB
/// colour match, 6 grade, 7 LUT, 8 halation, 9 vignette, 10 random grain, 11 real noise, 12
/// truncate to 8 bits, alpha passing through. With only grain.py's controls set it's grain.py's
/// `process` (`Grain.process`), pixel for pixel.
///
/// The steps are pure functions here (`lens`, `color`, `finish`); `EditRenderer` runs them for
/// a fitted preview, a 100% window or the full image and keeps what it can between renders.
nonisolated enum EditPipeline {
  /// What a look is rendered with besides its options: the profile's grain data and a reference's
  /// measurements, taken once when they're loaded rather than on every render. A saved step's
  /// come from its record and the data it names in the project (`Project.editContext(for:)`), a
  /// queued job's from the job (`Edit.Job.context`).
  struct Context: Hashable, Sendable {
    /// The profile's reference width, which scales the grain (grain.py's `ref_w`).
    var refWidth: Int = 1440
    /// Grain gain at the four brightness band centres; nil for grain.py's built-in curve.
    var curve: [Double]?
    /// The profile's reference RGB mean and spread, for `Match.colour`.
    var refStats: GrainProfile.ChannelStats?
    /// The profile's real-noise patches, for `Grain.real`.
    var realNoise: GrainProfile.RealNoise? { didSet { digests.realNoise = realNoise?.digest } }
    /// The match target's Lab statistics, for the Reinhard match.
    var referenceLab: Edit.LabStats?
    /// The match target's cumulative histograms, for `Histogram`.
    var referenceHistogram: Edit.HistogramTable? { didSet { digests.referenceHistogram = referenceHistogram?.digest } }
    /// The LUT's table, for `EditOptions.lut`.
    var lut: Edit.LUTTable? { didSet { digests.lut = lut?.digest } }
    /// The large data's digests, taken when it's set rather than on every render (the renderer's
    /// cache keys name the data by them; a SHA-256 of the noise, LUT and histograms is about a
    /// millisecond). Derived from the data, so it never disagrees with it.
    private(set) var digests = Digests()

    /// `realNoise.digest`, `referenceHistogram.digest` and `lut.digest`; nil where there's none.
    struct Digests: Codable, Hashable, Sendable {
      var realNoise: String?
      var referenceHistogram: String?
      var lut: String?
    }

    init(
      refWidth: Int = 1440, curve: [Double]? = nil, refStats: GrainProfile.ChannelStats? = nil,
      realNoise: GrainProfile.RealNoise? = nil, referenceLab: Edit.LabStats? = nil,
      referenceHistogram: Edit.HistogramTable? = nil, lut: Edit.LUTTable? = nil
    ) {
      self.init(
        refWidth: refWidth, curve: curve, refStats: refStats, realNoise: realNoise, referenceLab: referenceLab,
        referenceHistogram: referenceHistogram, lut: lut,
        digests: Digests(realNoise: realNoise?.digest, referenceHistogram: referenceHistogram?.digest, lut: lut?.digest))
    }

    /// A context whose data's digests are already known (`Edit.Record.context(with:)`, which has
    /// just checked them against the record's), so they aren't taken again.
    init(
      refWidth: Int, curve: [Double]?, refStats: GrainProfile.ChannelStats?, realNoise: GrainProfile.RealNoise?,
      referenceLab: Edit.LabStats?, referenceHistogram: Edit.HistogramTable?, lut: Edit.LUTTable?, digests: Digests
    ) {
      self.refWidth = refWidth
      self.curve = curve
      self.refStats = refStats
      self.realNoise = realNoise
      self.referenceLab = referenceLab
      self.referenceHistogram = referenceHistogram
      self.lut = lut
      self.digests = digests
    }

    /// The context with nothing loaded: no profile, reference or LUT.
    static let empty = Context()

    /// The context with `profile`'s grain data (reference width, curve, RGB statistics, real
    /// noise) in place of what it had, the reference and LUT kept.
    func using(_ profile: GrainProfile) -> Context {
      var context = self
      context.refWidth = profile.refWidth
      context.curve = profile.curve
      context.refStats = profile.refStats
      context.realNoise = profile.real
      return context
    }
  }

  /// A render's cancellation, as the steps' inner loops read it. `Task.isCancelled` can't be read
  /// from a `concurrentPerform` worker (it isn't the task's thread), so `EditRenderer.render` sets
  /// this from a task cancellation handler, and every step checks it once per band or row and
  /// skips the rest of its work. The step's result is then garbage and the render throws
  /// `CancellationError` before anything is kept. Not cancelled, the checks change nothing: the
  /// output is bit for bit what it was without them.
  final class Cancel: Sendable {
    private let flag = Atomic<Bool>(false)
    private let cancellable: Bool

    init() { cancellable = true }
    private init(cancellable: Bool) { self.cancellable = cancellable }

    /// The default for a step called on its own: never cancelled (and `cancel()` does nothing).
    static let never = Cancel(cancellable: false)

    var isCancelled: Bool { cancellable && flag.load(ordering: .relaxed) }

    func cancel() {
      guard cancellable else { return }
      flag.store(true, ordering: .relaxed)
    }

    /// Throws `CancellationError` once cancelled.
    func check() throws {
      if isCancelled { throw CancellationError() }
    }
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

  /// A zoomed view's render: the part `region` of the image scaled by `scale`, in that scaled
  /// image's pixels (`scaledSize`). `scale` is the zoom snapped to a quarter octave
  /// (`EditViewport.renderScale`), so a pinch renders at a few scales rather than a new one every
  /// frame, and the view's tiles (`EditRenderer.zoomed`) line up on the scaled image's grid.
  struct Zoomed: Hashable, Sendable {
    var scale: Double
    var region: Resample.Region

    init(scale: Double, region: Resample.Region) {
      self.scale = scale
      self.region = region
    }
  }

  /// The whole image's size at `scale` (at most 1): what a render at that scale lays its parts,
  /// grain and vignette in (`EditRenderer.Geometry`).
  static func scaledSize(width: Int, height: Int, scale: Double) -> (width: Int, height: Int) {
    let scale = min(max(scale, 1e-4), 1)
    guard scale < 1 else { return (width, height) }
    return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
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
    var rgba: [UInt8] { rgba(cancel: .never) }

    /// `rgba`, rows skipped (left black) once `cancel` is set.
    func rgba(cancel: Cancel) -> [UInt8] {
      let count = width * height
      guard count > 0, r.count >= count, g.count >= count, b.count >= count, alpha.count >= count else {
        return [UInt8](repeating: 0, count: max(count, 0) * 4)
      }
      @inline(__always) func byte(_ value: Float) -> UInt8 { value.isNaN ? 0 : UInt8(min(max(value, 0), 255)) }
      let width = width
      let height = height
      // Every byte is written below, so the array isn't cleared first.
      return [UInt8](unsafeUninitializedCapacity: count * 4) { out, initialized in
        r.withUnsafeBufferPointer { r in
          g.withUnsafeBufferPointer { g in
            b.withUnsafeBufferPointer { b in
              alpha.withUnsafeBufferPointer { alpha in
                let out = out
                DispatchQueue.concurrentPerform(iterations: height) { row in
                  guard !cancel.isCancelled else {
                    out.baseAddress!.advanced(by: row * width * 4).update(repeating: 0, count: width * 4)
                    return
                  }
                  for index in row * width..<(row + 1) * width {
                    out[index * 4] = byte(r[index])
                    out[index * 4 + 1] = byte(g[index])
                    out[index * 4 + 2] = byte(b[index])
                    out[index * 4 + 3] = alpha[index]
                  }
                }
              }
            }
          }
        }
        initialized = count * 4
      }
    }

    /// The part `x, y, width, height` of tightly packed RGBA8 `pixels` (`pixelWidth` wide) as
    /// planes, clamped to the image.
    init(rgba pixels: [UInt8], pixelWidth: Int, x: Int, y: Int, width w: Int, height h: Int, cancel: Cancel = .never) {
      let pixelHeight = pixelWidth > 0 ? pixels.count / 4 / pixelWidth : 0
      let x0 = min(max(x, 0), pixelWidth)
      let y0 = min(max(y, 0), pixelHeight)
      let w = min(max(w, 0), pixelWidth - x0)
      let h = min(max(h, 0), pixelHeight - y0)
      // Every pixel is written below (rows a cancel skips as black), so the planes aren't
      // cleared first.
      var g = [Float](), b = [Float](), alpha = [UInt8]()
      let count = max(w, 0) * max(h, 0)
      let r = [Float](unsafeUninitializedCapacity: count) { r, rCount in
        g = [Float](unsafeUninitializedCapacity: count) { g, gCount in
          b = [Float](unsafeUninitializedCapacity: count) { b, bCount in
            alpha = [UInt8](unsafeUninitializedCapacity: count) { alpha, alphaCount in
              if count > 0 {
                pixels.withUnsafeBufferPointer { input in
                  let (r, g, b, alpha) = (r, g, b, alpha)
                  DispatchQueue.concurrentPerform(iterations: h) { row in
                    guard !cancel.isCancelled else {
                      for i in row * w..<(row + 1) * w {
                        (r[i], g[i], b[i], alpha[i]) = (0, 0, 0, 255)
                      }
                      return
                    }
                    let source = ((y0 + row) * pixelWidth + x0) * 4
                    for column in 0..<w {
                      let i = row * w + column
                      let p = source + column * 4
                      r[i] = Float(input[p])
                      g[i] = Float(input[p + 1])
                      b[i] = Float(input[p + 2])
                      alpha[i] = input[p + 3]
                    }
                  }
                }
              }
              alphaCount = count
            }
            bCount = count
          }
          gCount = count
        }
        rCount = count
      }
      self.init(width: w, height: h, r: r, g: g, b: b, alpha: alpha)
    }

    /// The part of tightly packed RGBA8 `pixels` (`pixelWidth` wide) at `x, y`, `width` ×
    /// `height`, which must lie inside it, as its own tightly packed RGBA8.
    static func part(of pixels: [UInt8], pixelWidth: Int, x: Int, y: Int, width w: Int, height h: Int) -> [UInt8] {
      [UInt8](unsafeUninitializedCapacity: w * h * 4) { out, initialized in
        pixels.withUnsafeBufferPointer { input in
          for row in 0..<h {
            (out.baseAddress! + row * w * 4).initialize(from: input.baseAddress! + ((y + row) * pixelWidth + x) * 4, count: w * 4)
          }
        }
        initialized = w * h * 4
      }
    }

    /// Copies tightly packed RGBA8 `part` (`width` × `height`) into `pixels` (`pixelWidth` wide)
    /// at `x, y`, the rows and columns outside it cut off.
    static func paste(_ part: [UInt8], width w: Int, height h: Int, into pixels: inout [UInt8], pixelWidth: Int, x: Int, y: Int) {
      let pixelHeight = pixelWidth > 0 ? pixels.count / 4 / pixelWidth : 0
      let x0 = max(x, 0), y0 = max(y, 0)
      let x1 = min(x + w, pixelWidth), y1 = min(y + h, pixelHeight)
      guard x1 > x0, y1 > y0 else { return }
      part.withUnsafeBufferPointer { input in
        pixels.withUnsafeMutableBufferPointer { output in
          for row in y0..<y1 {
            (output.baseAddress! + (row * pixelWidth + x0) * 4)
              .update(from: input.baseAddress! + ((row - y) * w + x0 - x) * 4, count: (x1 - x0) * 4)
          }
        }
      }
    }

    var cgImage: CGImage? { cgImage(cancel: .never) }

    /// `cgImage`; nil once `cancel` is set.
    func cgImage(cancel: Cancel) -> CGImage? {
      let pixels = rgba(cancel: cancel)
      guard !cancel.isCancelled else { return nil }
      return ColorMatch.cgImage(rgba: pixels, width: width, height: height)
    }

    /// The pixels inside `x, y, width, height`, clamped to the image: the planes themselves when
    /// that's all of them, with no copy.
    func cropped(x: Int, y: Int, width w: Int, height h: Int) -> Planes {
      let x0 = min(max(x, 0), width)
      let y0 = min(max(y, 0), height)
      let w = min(max(w, 0), width - x0)
      let h = min(max(h, 0), height - y0)
      if x0 == 0, y0 == 0, w == width, h == height { return self }
      let width = width
      func crop<T>(_ plane: [T]) -> [T] {
        guard plane.count >= width * height, w > 0, h > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: w * h) { out, initialized in
          plane.withUnsafeBufferPointer { plane in
            let (plane, out) = (plane.baseAddress!, out.baseAddress!)
            // Rows in bands across the cores.
            let bandRows = max(16, h / (ProcessInfo.processInfo.activeProcessorCount * 2))
            DispatchQueue.concurrentPerform(iterations: (h + bandRows - 1) / bandRows) { band in
              for row in band * bandRows..<min((band + 1) * bandRows, h) {
                (out + row * w).initialize(from: plane + (y0 + row) * width + x0, count: w)
              }
            }
          }
          initialized = w * h
        }
      }
      return Planes(width: w, height: h, r: crop(r), g: crop(g), b: crop(b), alpha: crop(alpha))
    }
  }

  enum RenderError: LocalizedError {
    /// The source image's pixels couldn't be read.
    case unreadableSource

    var errorDescription: String? { "The image couldn’t be read." }
  }

  /// `source` with `options` applied, rendered with `context`: the whole image at full size, or
  /// only `window` (a part, a fitted preview, or a part of one). Runs off the main actor; stops
  /// with `CancellationError` when its task is cancelled. Keeps nothing between calls: the
  /// screen renders through an `EditRenderer`, which does.
  @concurrent static func render(
    source: CGImage, options: EditOptions, context: Context = .empty, window: Window? = nil
  ) async throws -> CGImage {
    try await EditRenderer(memoryBudget: 0).render(source: source, options: options, context: context, window: window)
  }

  // MARK: - Whole-image statistics

  /// What the matches measure on the whole image rather than on the pixels being rendered, so a
  /// window, a preview and the full render move every pixel alike (and a baked LUT does too):
  ///
  /// - `labTarget`: the Lab statistics the Reinhard match (step 3) moves from, of the image as
  ///   it comes out of the smear and blur.
  /// - `histogramSource`: the cumulative histograms the histogram match (step 4) maps from, of
  ///   the image after the Reinhard match.
  /// - `channelStats`: grain.py's `channel_stats` of the unblurred source, which its colour
  ///   match (step 5) moves from, as grain.py measures it.
  ///
  /// The first two are taken on the source fitted to `statsSide` with the smear and blur scaled
  /// to it (ColorMatch measures at 512 anyway); `channelStats` on the full-size source, as
  /// grain.py does (it resizes to 512 wide itself). Each is nil when its step won't run.
  struct SourceStats: Hashable, Sendable {
    var labTarget: Edit.LabStats?
    var histogramSource: Edit.HistogramTable?
    var channelStats: GrainProfile.ChannelStats?

    init(labTarget: Edit.LabStats? = nil, histogramSource: Edit.HistogramTable? = nil, channelStats: GrainProfile.ChannelStats? = nil) {
      self.labTarget = labTarget
      self.histogramSource = histogramSource
      self.channelStats = channelStats
    }
  }

  /// The side the Lab and histogram statistics are measured at.
  static let statsSide = 1024

  /// Whether steps 3, 4 and 5 run with these options and this context.
  static func matchesLab(_ options: EditOptions, _ context: Context) -> Bool {
    options.match.matchesLab && context.referenceLab?.stats != nil
  }

  static func matchesHistogram(_ options: EditOptions, _ context: Context) -> Bool {
    !options.histogram.isIdentity && context.referenceHistogram != nil
  }

  static func matchesColour(_ options: EditOptions, _ context: Context) -> Bool {
    options.match.colour > 0 && context.refStats != nil
  }

  /// `SourceStats` of a source fitted to `statsSide` (`proxy`, `proxyScale` of the full size),
  /// with grain.py's `channelStats` measured beforehand (nil when step 5 doesn't run).
  static func sourceStats(
    proxy: Planes, proxyScale: Double, channelStats: GrainProfile.ChannelStats?, options: EditOptions, context: Context,
    cancel: Cancel = .never
  ) -> SourceStats {
    var stats = SourceStats(channelStats: matchesColour(options, context) ? channelStats : nil)
    let lab = matchesLab(options, context)
    let histogram = matchesHistogram(options, context)
    guard lab || histogram else { return stats }
    var planes = lens(proxy, options.lens, scale: proxyScale, cancel: cancel)
    guard !cancel.isCancelled else { return stats }
    if lab {
      let target = ReferenceMatch.labStats(of: planes)
      stats.labTarget = target
      if histogram, let target = target.stats, let reference = context.referenceLab?.stats {
        ReferenceMatch.apply(options.match.colorMatchOptions, to: &planes, target: target, reference: reference, cancel: cancel)
      }
    }
    if histogram { stats.histogramSource = HistogramMatch.table(of: planes, cancel: cancel) }
    return stats
  }

  // MARK: - The steps

  /// Steps 1 and 2: grain.py's motion smear (clamped, above 1 px) and blur, their lengths in
  /// full-size pixels times `scale` (a preview's ratio, as Grain Studio scales them).
  static func lens(_ planes: Planes, _ lens: EditOptions.Lens, scale: Double = 1, cancel: Cancel = .never) -> Planes {
    var out = planes
    if lens.smears { out = Grain.motionSmear(out, length: lens.motion * scale, angle: lens.angle, cancel: cancel) }
    if lens.blurs, !cancel.isCancelled { out = Grain.blur(out, sigma: lens.blur * scale, cancel: cancel) }
    return out
  }

  /// Steps 3 to 7, each pixel on its own: the Reinhard Lab match, the histogram match, grain.py's
  /// colour match, the grade (which owns exposure and tint, grain.py's included) and the LUT,
  /// then `sanitize`.
  /// `stats` is the whole image's (`SourceStats`); a step without its data is skipped.
  static func color(_ planes: inout Planes, options: EditOptions, context: Context, stats: SourceStats, cancel: Cancel = .never) {
    if matchesLab(options, context), let reference = context.referenceLab?.stats, let target = stats.labTarget?.stats {
      ReferenceMatch.apply(options.match.colorMatchOptions, to: &planes, target: target, reference: reference, cancel: cancel)
    }
    if matchesHistogram(options, context), let reference = context.referenceHistogram, let source = stats.histogramSource {
      HistogramMatch.apply(options.histogram, to: &planes, reference: reference, source: source, cancel: cancel)
    }
    if matchesColour(options, context), let reference = context.refStats, let source = stats.channelStats {
      planes = Grain.colourMatch(planes, source: source, reference: reference, amount: options.match.colour, cancel: cancel)
    }
    Grade.apply(options.grade, to: &planes, cancel: cancel)
    if !options.lut.isIdentity, let table = context.lut {
      CubeLUT.apply(table, to: &planes, strength: options.lut.strength, cancel: cancel)
    }
    sanitize(&planes, cancel: cancel)
  }

  /// The largest level kept between steps, either way: far past anything visible, small enough
  /// that a blur's sums stay finite.
  static let levelLimit: Float = 1e6

  /// Values that aren't numbers set to 0 and the rest kept to ±`levelLimit`, after the color
  /// steps: an unbounded grade (an agent's 200-stop exposure is infinity, times a black pixel
  /// NaN) would otherwise turn halation's and grain's sums, hence whole rows, into NaN.
  static func sanitize(_ planes: inout Planes, cancel: Cancel = .never) {
    let limit = levelLimit
    planes.withPixelBands(cancel: cancel) { range, r, g, b in
      for i in range {
        if !(abs(r[i]) <= limit) { r[i] = r[i].isNaN ? 0 : (r[i] > 0 ? limit : -limit) }
        if !(abs(g[i]) <= limit) { g[i] = g[i].isNaN ? 0 : (g[i] > 0 ? limit : -limit) }
        if !(abs(b[i]) <= limit) { b[i] = b[i].isNaN ? 0 : (b[i] > 0 ? limit : -limit) }
      }
    }
  }

  /// Steps 10 and 11 on the pre-grain planes (after the vignette): the random grain and the real
  /// noise, both weighted by the planes' own brightness, with fields made beforehand for the
  /// planes' place in the picture.
  static func grain(
    _ planes: inout Planes, options: EditOptions, context: Context, fields: Grain.GrainFields?, realNoise: [[Float]]?,
    cancel: Cancel = .never
  ) {
    let grain = options.grain
    guard grain.lum != 0 || grain.chroma != 0 || (grain.real > 0 && realNoise != nil) else { return }
    let luminance = Grain.luminance(planes, cancel: cancel)
    if let fields, !cancel.isCancelled {
      Grain.addGrain(&planes, luminance: luminance, lum: grain.lum, chroma: grain.chroma, curve: context.curve, fields: fields, cancel: cancel)
    }
    if grain.real > 0, let realNoise, let real = context.realNoise, !cancel.isCancelled {
      Grain.addRealNoise(&planes, luminance: luminance, curve: real.curve, amount: grain.real, field: realNoise, cancel: cancel)
    }
  }

  /// How far past its edges a render must read for the smear and blur (steps 1–2) at `scale`, in
  /// output pixels: the smear's longest shift plus the three box blurs' radii.
  static func lensReach(_ lens: EditOptions.Lens, scale: Double) -> Int {
    var reach = 0
    if lens.smears {
      let n = max(2, Grain.round(lens.motion * scale))
      reach += n / 2 + 1
    }
    if lens.blurs { reach += blurReach(sigma: lens.blur * scale) }
    return reach
  }

  /// How far halation's glow (step 8) reaches at `scale`, in output pixels.
  static func halationReach(_ halation: EditOptions.Halation, scale: Double) -> Int {
    halation.isIdentity ? 0 : blurReach(sigma: max(halation.radius * scale, 0))
  }

  /// The reach of `Blur.gauss`: its box radii added up, plus one.
  static func blurReach(sigma: Double) -> Int {
    guard sigma >= 0.3 else { return 0 }
    return Blur.boxSizes(sigma: sigma).reduce(1) { $0 + ($1 - 1) / 2 }
  }

  // MARK: - Export LUT

  /// Steps 3–7 baked into a `size`³ table (`CubeLUT.bake`), for Export LUT…. The matches use
  /// `stats`, this image's (`EditRenderer.sourceStats`), so the table reproduces this image's
  /// grade; on another image it's the same color transform, not a new match.
  static func bakeLUT(options: EditOptions, context: Context, stats: SourceStats, size: Int = 33, name: String) -> Edit.LUTTable {
    CubeLUT.bake(size: size, name: name) { planes in color(&planes, options: options, context: context, stats: stats) }
  }

  // MARK: - Measure Reference

  /// Everything a reference image gives a look, measured once: the Lab statistics and
  /// histograms the matches move toward, and the grain profile Match Reference makes of it.
  struct ReferenceMeasurement: Sendable {
    var lab: Edit.LabStats
    var histogram: Edit.HistogramTable
    /// grain.py's `--match --save-profile` profile of the reference; nil when it has no flat,
    /// mid-bright area to measure grain on, or when it wasn't asked for.
    var profile: GrainProfile?
    /// What Match Reference found, behind `profile` (its comparison of the reference's grain with
    /// Atelier's at the fitted sizes, for the screen's report); nil when `profile` is.
    var match: Grain.Match?

    /// `context` with the reference's Lab statistics and histograms, and its profile's grain data
    /// when there is one.
    func applied(to context: Context) -> Context {
      var context = profile.map { context.using($0) } ?? context
      context.referenceLab = lab
      context.referenceHistogram = histogram
      return context
    }
  }

  /// Measures `image` as a reference (Match Reference): Lab statistics, histograms and, with
  /// `profile`, a grain profile named `name` (a second or two at 1440 px). Nil when it can't be
  /// read.
  @concurrent static func measureReference(
    _ image: CGImage, name: String, source: String? = nil, profile: Bool = true
  ) async throws -> ReferenceMeasurement? {
    guard let planes = Planes(image) else { return nil }
    try Task.checkCancellation()
    let lab = ReferenceMatch.labStats(of: planes)
    let histogram = HistogramMatch.table(of: planes)
    try Task.checkCancellation()
    let match = profile ? Grain.matchReference(planes) : nil
    let measured = match.map { GrainProfile(match: $0, of: planes, name: name, source: source) }
    return ReferenceMeasurement(lab: lab, histogram: histogram, profile: measured, match: match)
  }
}

// MARK: - Renderer

/// Renders Edit screen looks and keeps what it can between renders, for the screen (Slice G)
/// and the save and export jobs (Slice H). One per screen; every call may run at once with the
/// others (the work runs off the actor, which only holds the caches), and each stops with
/// `CancellationError` when its task is cancelled, so a `.task(id:)` re-render just drops the
/// last. The steps stop within a band of rows of the cancel (`EditPipeline.Cancel`), and
/// nothing a cancelled render made is kept.
///
/// - `preview(source:options:context:fitting:)`: the whole image fitted to a size (the fitted
///   view). Smear, blur and halation lengths scale by the preview's ratio, and the grain is the
///   full render's grain at that size (its cells laid with the full image's aspect).
/// - `window(source:options:context:window:)`: a part of the image at 100% (`scale` 1), or of a
///   scaled render; reads past the part's edges for the smear, blur and halation, so it's that
///   part of the full render (within a level, from float rounding).
/// - `full(source:options:context:)`: the whole image at full size (Save to History, Export…).
/// - `sourceStats(source:options:context:)` and `bakeLUT(...)`: Export LUT….
///
/// Caches, all keyed by the source image (held while cached, so its identity can't be reused):
/// (a) per source, its pixels, grain.py's channel stats, a `statsSide` copy, scaled copies for
/// the fitted preview and zoomed views (three sizes) and the `SourceStats` for recent options; (b) three stages of the image before the
/// vignette: the lens stage (steps 1–2, per smear, blur and window), the colour stage (steps
/// 1–7: adds the matches, grade, LUT and the context data they use) and the halation stage
/// (steps 1–8), so a change runs only from its own step: the vignette or grain alone runs steps
/// 9–12, halation 8–12, the colour controls 3–12 (the vignette, a multiply per pixel, isn't
/// kept); (c) the grain fields and real-noise fields per size, seed, cells and layout. (b) and
/// (c) keep the newest entry per stage per lane (`Lane`: the whole image, as a fitted preview,
/// or a part, as a zoomed window), so the fitted preview's and the window's sit side by side,
/// within `memoryBudget` bytes (least recently used out first when they don't fit; an entry
/// bigger than a third of it isn't kept). A full-size render reads them but keeps nothing.
/// A window's lens and colour stages are read and kept with halation's margin, which grows with
/// its radius: a Radius change zoomed in misses them (the fitted preview's margins are the
/// whole image, so there it doesn't), and padding them to the largest radius instead would
/// cost every window render up to 600 px more each side and change its float rounding. Two
/// sources are kept; `forget(_:)` drops one when the screen closes it. The zoomed view's tiles
/// (`zoomed`) and the scaled copies are kept apart, in `tileBudget` and `scaledBudget`.
actor EditRenderer {
  typealias Planes = EditPipeline.Planes
  typealias Window = EditPipeline.Window
  typealias Context = EditPipeline.Context

  /// Bytes the stages and fields may take together. The zoomed view's tiles (`tileBudget`) and
  /// the sources' scaled copies (`scaledBudget`) each take up to a quarter of it more, so all
  /// that's kept stays within 1.5 times it (bar the newest scaled copy, always kept, as the one
  /// copy there was).
  let memoryBudget: Int
  /// Sources kept.
  let sourceLimit = 2

  /// The zoomed view's tiles' side, in output pixels (`zoomed`).
  let tileSide: Int

  init(memoryBudget: Int = EditRenderer.defaultMemoryBudget, tileSide: Int = 512) {
    self.memoryBudget = memoryBudget
    self.tileSide = max(tileSide, 1)
  }

  /// A sixteenth of the device's memory, from 512 MB to 2 GB. Each kept pixel is 13 bytes a
  /// stage (three Float32 planes and alpha) and 12 for the grain fields (24 with real noise). At
  /// a full-screen 5K window's sizes for a 3:2 photo, with the default look's halation margin
  /// (59 px each side): the fitted preview (4230 × 2820, 11.9 MP, every stage and field at that
  /// size, 51–63 bytes a pixel) takes about 610–750 MB; the 100% window (5248 × 2944, 15.5 MP)
  /// keeps its lens and colour stages at the margin's size (5366 × 3062, 16.4 MP) and its
  /// halation stage and fields at its own, about 810–995 MB. Both lanes fit in 2 GB together (a
  /// 32 GB or larger Mac) without either pushing the other out. A 16 GB Mac or iPad gets 1 GB
  /// (an iPad's previews are about half the pixels). An 8 GB one gets the 512 MB the single
  /// pre-grain cache had, whose third (the largest entry kept) is under that window's 200 MB
  /// halation stage: there, as before, a full 5K screen's 100% window keeps no stages.
  static let defaultMemoryBudget: Int = {
    let sixteenth = ProcessInfo.processInfo.physicalMemory / 16
    return Int(min(max(sixteenth, 512 << 20), 2 << 30))
  }()

  /// Cache hits and misses since the renderer was made, for tests and timing.
  struct Counters: Hashable, Sendable {
    /// Renders whose steps 1–8 all came from a kept stage (the halation stage, or the colour
    /// stage when there's no halation), and those that ran at least one of them.
    var preGrainHits = 0
    var preGrainMisses = 0
    /// Each stage's lookups: one is only looked up when every stage after it missed (and only
    /// when it does something: no lens lookup without a smear or blur, no halation lookup
    /// without halation).
    var lensHits = 0
    var lensMisses = 0
    var colourHits = 0
    var colourMisses = 0
    var halationHits = 0
    var halationMisses = 0
    var fieldHits = 0
    var fieldMisses = 0
    var statsHits = 0
    var statsMisses = 0
    /// The scaled copies of the source (`sourcePixels`), and the zoomed view's tiles.
    var scaledHits = 0
    var scaledMisses = 0
    var tileHits = 0
    var tileMisses = 0
  }

  private(set) var counters = Counters()

  // MARK: Calls

  /// The whole of `source` rendered to fit `width` × `height` (never larger than full size).
  @concurrent nonisolated func preview(
    source: CGImage, options: EditOptions, context: Context = .empty, fitting width: Int, height: Int
  ) async throws -> CGImage {
    let scale = min(1, Double(max(width, 1)) / Double(max(source.width, 1)), Double(max(height, 1)) / Double(max(source.height, 1)))
    return try await render(source: source, options: options, context: context, window: .whole(width: source.width, height: source.height, scale: scale))
  }

  /// `window` of the render (full-size pixels, at `window.scale`, 1 for 100%).
  @concurrent nonisolated func window(source: CGImage, options: EditOptions, context: Context = .empty, window: Window) async throws -> CGImage {
    try await render(source: source, options: options, context: context, window: window)
  }

  /// The whole render at full size.
  @concurrent nonisolated func full(source: CGImage, options: EditOptions, context: Context = .empty) async throws -> CGImage {
    try await render(source: source, options: options, context: context, window: nil)
  }

  /// The whole-image statistics the matches use for `options` (what `bakeLUT` takes).
  @concurrent nonisolated func sourceStats(source: CGImage, options: EditOptions, context: Context = .empty) async throws -> EditPipeline.SourceStats {
    let entry = try await sourceEntry(source)
    return try await stats(entry, options: options.rendered, context: context)
  }

  /// Export LUT…: steps 3–7 for this image baked into a `size`³ table.
  @concurrent nonisolated func bakeLUT(
    source: CGImage, options: EditOptions, context: Context = .empty, size: Int = 33, name: String
  ) async throws -> Edit.LUTTable {
    let options = options.rendered
    let stats = try await sourceStats(source: source, options: options, context: context)
    try Task.checkCancellation()
    return EditPipeline.bakeLUT(options: options, context: context, stats: stats, size: size, name: name)
  }

  /// Takes `rgba` as `image`'s pixels (tightly packed sRGB RGBA8, straight alpha: what it would
  /// read them as), so a picture just made from pixels at hand (the Edit screen's healed image,
  /// `HealCanvas`) isn't read back out of the image. Nothing when it's kept already.
  func prime(_ image: CGImage, rgba: [UInt8]) {
    guard rgba.count == image.width * image.height * 4, !rgba.isEmpty, sources[ObjectIdentifier(image)] == nil else { return }
    _ = keep(SourceEntry(image: image, rgba: rgba))
  }

  /// Drops everything kept for `source`.
  func forget(_ source: CGImage) {
    let id = ObjectIdentifier(source)
    sources[id] = nil
    for key in store.keys where key.source == id { remove(key) }
    for lane in laneTickets.keys where lane.source == id { laneTickets[lane] = nil }
    forgetTiles(of: id)
  }

  /// Drops everything.
  func removeAll() {
    sources = [:]
    store = [:]
    lanes = [:]
    laneTickets = [:]
    storedBytes = 0
    tileStore = [:]
    tileBytes = 0
  }

  // MARK: Rendering

  /// The render, as `window` (nil for the whole image at full size).
  ///
  /// This and the other calls (`zoomed`, `keptView`, `sourceStats`, `bakeLUT`) render
  /// `options.rendered`, the stages that are off as no change, so no caller (the screen, Save,
  /// Export…, an agent's job) can render a stage that's off, and every cache is keyed by what
  /// actually renders.
  @concurrent nonisolated func render(source: CGImage, options: EditOptions, context: Context, window: Window?) async throws -> CGImage {
    try Task.checkCancellation()
    let options = options.rendered
    // Nothing to do: the source as it is.
    if options.isIdentity, window == nil || window == .whole(width: source.width, height: source.height) { return source }
    let cancel = EditPipeline.Cancel()
    return try await withTaskCancellationHandler {
      try await render(source: source, options: options, context: context, window: window, cancel: cancel)
    } onCancel: {
      cancel.cancel()
    }
  }

  /// `render`, its steps stopping when `cancel` is set.
  @concurrent private nonisolated func render(
    source: CGImage, options: EditOptions, context: Context, window: Window?, cancel: EditPipeline.Cancel
  ) async throws -> CGImage {
    let entry = try await sourceEntry(source)
    let geometry = Geometry(width: entry.width, height: entry.height, window: window).withReach(options)
    // A full-size render (Save, Export…) is a one-off whose 16–24 MP stages would push the
    // screen's out of the budget: it reads what's kept but keeps nothing.
    let lane = window == nil ? nil : await ticket(Lane.Kind(geometry))
    let out = try await finished(entry, options: options, context: context, geometry: geometry, lane: lane, cancel: cancel)
    let image = out.cgImage(cancel: cancel)
    try cancel.check()
    guard let image else { throw EditPipeline.RenderError.unreadableSource }
    return image
  }

  /// Steps 1–11 for `geometry` (the planes of `geometry.region`, before they're truncated to
  /// bytes), keeping what it makes in `lane` (nothing for nil).
  @concurrent private nonisolated func finished(
    _ entry: SourceEntry, options: EditOptions, context: Context, geometry: Geometry, lane: Ticket?, cancel: EditPipeline.Cancel
  ) async throws -> Planes {
    let id = ObjectIdentifier(entry.image)

    // Steps 1–8 from the newest stage kept (`staged`), then 9.
    var out = try await staged(entry, options: options, context: context, geometry: geometry, lane: lane, cancel: cancel)
    try cancel.check()
    Self.vignetteStage(&out, geometry: geometry, options: options, cancel: cancel)
    try cancel.check()

    // Steps 10–12.
    let layout = Grain.Layout(
      width: geometry.scaledWidth, height: geometry.scaledHeight, aspect: Double(entry.height) / Double(max(entry.width, 1)),
      region: geometry.region)
    let grain = options.grain
    var fields: Grain.GrainFields?
    if grain.lum != 0 || grain.chroma != 0 {
      let key = FieldKey(
        source: id, lumaCells: grain.lum != 0 ? Grain.lumaCells(refWidth: context.refWidth, size: grain.size, aspect: layout.aspect) : nil,
        chromaCells: grain.chroma != 0 ? Grain.chromaCells(refWidth: context.refWidth, size: grain.csize, aspect: layout.aspect) : nil,
        seed: grain.seed, layout: layout)
      if case .grain(let cached)? = await lookup(.grain(key)) {
        fields = cached
      } else {
        let made = Grain.grainFields(
          lum: grain.lum, chroma: grain.chroma, size: grain.size, csize: grain.csize, seed: grain.seed, refWidth: context.refWidth,
          layout: layout, cancel: cancel)
        try cancel.check()
        fields = made
        await store(.grain(key), .grain(made), bytes: made.byteCount, lane: lane)
      }
    }
    var realField: [[Float]]?
    if grain.real > 0, let real = context.realNoise, real.count > 0 {
      let key = RealKey(source: id, digest: context.digests.realNoise ?? "", refWidth: context.refWidth, seed: grain.seed, layout: layout)
      if case .real(let cached)? = await lookup(.real(key)) {
        realField = cached
      } else {
        let made = Grain.realNoiseField(real, refWidth: context.refWidth, seed: grain.seed, layout: layout, cancel: cancel)
        try cancel.check()
        realField = made
        await store(.real(key), .real(made), bytes: made.reduce(0) { $0 + $1.count * 4 }, lane: lane)
      }
    }
    try cancel.check()
    EditPipeline.grain(&out, options: options, context: context, fields: fields, realNoise: realField, cancel: cancel)
    try cancel.check()
    return out
  }

  // MARK: The zoomed view's tiles

  /// The zoomed view `zoomed` of the render, made of tiles `tileSide` output pixels square on
  /// the scaled image's grid, which are kept between calls (`TileKey`: the source, the look, the
  /// scale and the tile), so a pan renders only the tiles it brings into view. With none of the
  /// view's tiles kept (a new look, scale or source) the view renders at once, as a window does,
  /// keeping its stages in the part lane, so the next look renders from its changed step; its
  /// tiles wholly inside it are kept. With some kept, the rest render in rectangles of whole
  /// tiles (kept, with no stages: the view's own stages are of another region), nearest the
  /// view's centre first, and `progress` is handed the view so far after each rectangle but the
  /// last (the parts still to come transparent; the screen draws it over the last complete
  /// view). Not before the first: what's up already shows the kept tiles' part, and a pan that
  /// asks again every 64 px would put up a whole view each time for nothing.
  ///
  /// Every tile is the same pixels the view rendered at once has there: each part is read with
  /// the margins its smear, blur and halation reach (`Geometry.withReach`), and the vignette and
  /// grain fields are laid in the whole scaled image's coordinates (`vignetteStage`,
  /// `Grain.Layout.region`). The blurs' Float64 running sums start at each part's read edge, so
  /// a value could in principle differ from the view's in its last bit, but rounded to Float32
  /// and truncated to bytes the tiles come out byte for byte (`tiledZoomedViewIsTheWholeRender`).
  /// `contextID` names `context` in the tiles' keys (the screen's context version), so they
  /// needn't hash its data.
  @concurrent nonisolated func zoomed(
    source: CGImage, options: EditOptions, context: Context = .empty, contextID: Int = 0, zoomed: EditPipeline.Zoomed,
    progress: (@Sendable (CGImage) async -> Void)? = nil
  ) async throws -> CGImage {
    try Task.checkCancellation()
    let options = options.rendered
    let cancel = EditPipeline.Cancel()
    return try await withTaskCancellationHandler {
      try await tiled(source: source, options: options, context: context, contextID: contextID, zoomed: zoomed, progress: progress, cancel: cancel)
    } onCancel: {
      cancel.cancel()
    }
  }

  /// How long the rest of a zoomed render must look to take for a partial view to go up.
  nonisolated static let partialAfter = Duration.milliseconds(100)

  /// The kept tiles of the zoomed view `zoomed` that aren't wholly inside `excluding` (the
  /// last render up, at the same scale) nor in `skipping` (already up), as one image of their bounding box with the tiles not
  /// kept transparent, and where it goes; nil when there are none. Renders nothing: what a pan
  /// shows while it moves, kept small (the strip a pan brings into view) since the main thread
  /// puts up each one.
  @concurrent nonisolated func keptView(
    source: CGImage, options: EditOptions, contextID: Int = 0, zoomed: EditPipeline.Zoomed, excluding: Resample.Region? = nil,
    skipping: Set<Tile> = []
  ) async -> (image: CGImage, zoomed: EditPipeline.Zoomed, tiles: Set<Tile>)? {
    let options = options.rendered
    let view = Geometry(width: source.width, height: source.height, scale: zoomed.scale, region: zoomed.region)
    let region = view.region, side = tileSide
    let id = ObjectIdentifier(source)
    func area(_ tile: Tile) -> Resample.Region {
      let x = tile.column * side, y = tile.row * side
      return Resample.Region(x: x, y: y, width: min(side, view.scaledWidth - x), height: min(side, view.scaledHeight - y))
    }
    let columns = region.x / side..<(region.x + region.width + side - 1) / side
    let rows = region.y / side..<(region.y + region.height + side - 1) / side
    let tiles = rows.flatMap { row in columns.map { Tile(column: $0, row: row) } }.filter { tile in
      guard !skipping.contains(tile) else { return false }
      guard let excluding else { return true }
      let part = area(tile)
      return !(part.x >= excluding.x && part.y >= excluding.y && part.x + part.width <= excluding.x + excluding.width
        && part.y + part.height <= excluding.y + excluding.height)
    }
    func key(_ tile: Tile) -> TileKey { TileKey(source: id, options: options, context: contextID, scale: view.scale, tile: tile) }
    let kept = await keptTiles(tiles.map(key), counting: false)
    let found = tiles.filter { kept[key($0)] != nil }
    guard !found.isEmpty, !Task.isCancelled else { return nil }
    let x0 = found.map { area($0).x }.min()!, y0 = found.map { area($0).y }.min()!
    let x1 = found.map { area($0).x + area($0).width }.max()!, y1 = found.map { area($0).y + area($0).height }.max()!
    var canvas = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0) * 4)
    for tile in found {
      let part = area(tile)
      Planes.paste(kept[key(tile)]!, width: part.width, height: part.height, into: &canvas, pixelWidth: x1 - x0, x: part.x - x0, y: part.y - y0)
    }
    guard let image = ColorMatch.cgImage(rgba: canvas, width: x1 - x0, height: y1 - y0) else { return nil }
    return (image, EditPipeline.Zoomed(scale: view.scale, region: .init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)), Set(found))
  }

  /// `rects` merged into at most `limit`: each render of a part reads its margins and keeps no
  /// stages, so a few larger ones cost less than many small ones. The pair whose bounding box
  /// adds the fewest tiles is merged first (re-rendering a kept tile there gives its bytes again),
  /// and rectangles a merge covers are dropped.
  nonisolated static func merged(_ rects: [TileRect], limit: Int) -> [TileRect] {
    var rects = rects
    func area(_ rect: TileRect) -> Int { rect.columns.count * rect.rows.count }
    func union(_ a: TileRect, _ b: TileRect) -> TileRect {
      TileRect(
        columns: min(a.columns.lowerBound, b.columns.lowerBound)..<max(a.columns.upperBound, b.columns.upperBound),
        rows: min(a.rows.lowerBound, b.rows.lowerBound)..<max(a.rows.upperBound, b.rows.upperBound))
    }
    while rects.count > max(limit, 1) {
      var best = (i: 0, j: 1, cost: Int.max)
      for i in rects.indices {
        for j in rects.indices where j > i {
          let cost = area(union(rects[i], rects[j])) - area(rects[i]) - area(rects[j])
          if cost < best.cost { best = (i, j, cost) }
        }
      }
      let joined = union(rects[best.i], rects[best.j])
      rects = rects.enumerated().filter { index, rect in
        index != best.i && index != best.j && !(joined.columns.contains(rect.columns.lowerBound) && joined.columns.upperBound >= rect.columns.upperBound
          && joined.rows.contains(rect.rows.lowerBound) && joined.rows.upperBound >= rect.rows.upperBound)
      }.map(\.element) + [joined]
    }
    return rects
  }

  /// A tile of the zoomed view: its column and row on the scaled image's grid.
  struct Tile: Hashable, Sendable {
    var column: Int
    var row: Int
  }

  /// What a kept tile is of.
  struct TileKey: Hashable, Sendable {
    var source: ObjectIdentifier
    var options: EditOptions
    var context: Int
    var scale: Double
    var tile: Tile
  }

  /// Tiles side by side: columns × rows.
  struct TileRect: Hashable, Sendable {
    var columns: Range<Int>
    var rows: Range<Int>
  }

  /// `tiles` grouped into rectangles: each row's runs of tiles, a run joined with the one below
  /// it when they're the same columns.
  nonisolated static func rectangles(_ tiles: Set<Tile>) -> [TileRect] {
    var done: [TileRect] = []
    var open: [Range<Int>: Range<Int>] = [:]
    for row in Set(tiles.map(\.row)).sorted() {
      let columns = tiles.filter { $0.row == row }.map(\.column).sorted()
      var runs: [Range<Int>] = []
      for column in columns {
        if let last = runs.last, last.upperBound == column { runs[runs.count - 1] = last.lowerBound..<column + 1 } else { runs.append(column..<column + 1) }
      }
      var next: [Range<Int>: Range<Int>] = [:]
      for run in runs {
        if let rows = open.removeValue(forKey: run), rows.upperBound == row { next[run] = rows.lowerBound..<row + 1 } else { next[run] = row..<row + 1 }
      }
      done += open.map { TileRect(columns: $0.key, rows: $0.value) }
      open = next
    }
    done += open.map { TileRect(columns: $0.key, rows: $0.value) }
    return done
  }

  @concurrent private nonisolated func tiled(
    source: CGImage, options: EditOptions, context: Context, contextID: Int, zoomed: EditPipeline.Zoomed,
    progress: (@Sendable (CGImage) async -> Void)?, cancel: EditPipeline.Cancel
  ) async throws -> CGImage {
    let entry = try await sourceEntry(source)
    let view = Geometry(width: entry.width, height: entry.height, scale: zoomed.scale, region: zoomed.region)
    let region = view.region
    let side = tileSide
    let (scaledWidth, scaledHeight) = (view.scaledWidth, view.scaledHeight)
    let id = ObjectIdentifier(source)
    func key(_ tile: Tile) -> TileKey { TileKey(source: id, options: options, context: contextID, scale: view.scale, tile: tile) }
    /// A tile's pixels in the scaled image.
    func area(_ tile: Tile) -> Resample.Region {
      let x = tile.column * side, y = tile.row * side
      return Resample.Region(x: x, y: y, width: min(side, scaledWidth - x), height: min(side, scaledHeight - y))
    }
    let columns = region.x / side..<(region.x + region.width + side - 1) / side
    let rows = region.y / side..<(region.y + region.height + side - 1) / side
    let tiles = rows.flatMap { row in columns.map { Tile(column: $0, row: row) } }
    let kept = await keptTiles(tiles.map(key))

    if kept.isEmpty {
      let geometry = view.withReach(options)
      let lane = await ticket(Lane.Kind(geometry))
      let out = try await finished(entry, options: options, context: context, geometry: geometry, lane: lane, cancel: cancel)
      let rgba = out.rgba(cancel: cancel)
      try cancel.check()
      var made: [(TileKey, [UInt8])] = []
      for tile in tiles {
        let part = area(tile)
        guard part.x >= region.x, part.y >= region.y, part.x + part.width <= region.x + region.width,
              part.y + part.height <= region.y + region.height
        else { continue }
        made.append((key(tile), Planes.part(
          of: rgba, pixelWidth: region.width, x: part.x - region.x, y: part.y - region.y, width: part.width, height: part.height)))
      }
      await keepTiles(made)
      guard let image = ColorMatch.cgImage(rgba: rgba, width: region.width, height: region.height) else {
        throw EditPipeline.RenderError.unreadableSource
      }
      return image
    }

    var canvas = [UInt8](repeating: 0, count: region.width * region.height * 4)
    func paste(_ pixels: [UInt8], _ tile: Tile) {
      let part = area(tile)
      Planes.paste(pixels, width: part.width, height: part.height, into: &canvas, pixelWidth: region.width, x: part.x - region.x, y: part.y - region.y)
    }
    func image() throws -> CGImage {
      guard let image = ColorMatch.cgImage(rgba: canvas, width: region.width, height: region.height) else {
        throw EditPipeline.RenderError.unreadableSource
      }
      return image
    }
    for tile in tiles { if let pixels = kept[key(tile)] { paste(pixels, tile) } }
    let missing = Set(tiles.filter { kept[key($0)] == nil })
    guard !missing.isEmpty else { return try image() }
    // Nearest the view's centre first.
    let centreX = Double(region.x) + Double(region.width) / 2, centreY = Double(region.y) + Double(region.height) / 2
    let rects = Self.merged(Self.rectangles(missing), limit: 3).sorted { a, b in
      func distance(_ rect: TileRect) -> Double {
        let x = (Double(rect.columns.lowerBound) + Double(rect.columns.count) / 2) * Double(side) - centreX
        let y = (Double(rect.rows.lowerBound) + Double(rect.rows.count) / 2) * Double(side) - centreY
        return x * x + y * y
      }
      return distance(a) < distance(b)
    }
    let clock = ContinuousClock(), started = clock.now
    func pixels(_ rect: TileRect) -> Int {
      (min(rect.columns.upperBound * side, scaledWidth) - rect.columns.lowerBound * side)
        * (min(rect.rows.upperBound * side, scaledHeight) - rect.rows.lowerBound * side)
    }
    var remaining = rects.reduce(0) { $0 + pixels($1) }, done = 0
    for (index, rect) in rects.enumerated() {
      let x = rect.columns.lowerBound * side, y = rect.rows.lowerBound * side
      let part = Resample.Region(
        x: x, y: y, width: min(rect.columns.upperBound * side, scaledWidth) - x, height: min(rect.rows.upperBound * side, scaledHeight) - y)
      let geometry = Geometry(width: entry.width, height: entry.height, scale: view.scale, region: part).withReach(options)
      let out = try await finished(entry, options: options, context: context, geometry: geometry, lane: nil, cancel: cancel)
      let rgba = out.rgba(cancel: cancel)
      try cancel.check()
      var made: [(TileKey, [UInt8])] = []
      for row in rect.rows {
        for column in rect.columns {
          let tile = Tile(column: column, row: row), tileArea = area(tile)
          let pixels = Planes.part(
            of: rgba, pixelWidth: part.width, x: tileArea.x - part.x, y: tileArea.y - part.y, width: tileArea.width, height: tileArea.height)
          paste(pixels, tile)
          made.append((key(tile), pixels))
        }
      }
      await keepTiles(made)
      done += pixels(rect)
      remaining -= pixels(rect)
      // A partial costs a copy of the view and a moment of the main thread to put up: only
      // when what's left looks like it'll take a while yet, at the pace so far.
      let elapsed = clock.now - started
      if index < rects.count - 1, let progress, elapsed * (Double(remaining) / Double(max(done, 1))) >= Self.partialAfter {
        await progress(try image())
      }
    }
    return try image()
  }

  private struct KeptTile {
    var rgba: [UInt8]
    var lastUse: UInt64
  }

  private var tileStore: [TileKey: KeptTile] = [:]
  private var tileBytes = 0

  /// Bytes the zoomed view's tiles may take, apart from the stages': a quarter of the budget
  /// (128–512 MB; a full-screen 5K view at 100% is about 60 MB of tiles).
  nonisolated var tileBudget: Int { memoryBudget / 4 }

  private func keptTiles(_ keys: [TileKey], counting: Bool = true) -> [TileKey: [UInt8]] {
    var found: [TileKey: [UInt8]] = [:]
    for key in keys {
      guard var kept = tileStore[key] else {
        if counting { counters.tileMisses += 1 }
        continue
      }
      if counting { counters.tileHits += 1 }
      clock += 1
      kept.lastUse = clock
      tileStore[key] = kept
      found[key] = kept.rgba
    }
    return found
  }

  /// Keeps `made`, the least recently used tiles dropped while they don't fit; nothing for a
  /// source that's been dropped since.
  private func keepTiles(_ made: [(TileKey, [UInt8])]) {
    for (key, rgba) in made where sources[key.source] != nil && rgba.count <= tileBudget {
      if let old = tileStore.removeValue(forKey: key) { tileBytes -= old.rgba.count }
      while tileBytes + rgba.count > tileBudget, let oldest = tileStore.min(by: { $0.value.lastUse < $1.value.lastUse }) {
        tileStore[oldest.key] = nil
        tileBytes -= oldest.value.rgba.count
      }
      clock += 1
      tileStore[key] = KeptTile(rgba: rgba, lastUse: clock)
      tileBytes += rgba.count
    }
  }

  private func forgetTiles(of source: ObjectIdentifier) {
    for (key, kept) in tileStore where key.source == source {
      tileStore[key] = nil
      tileBytes -= kept.rgba.count
    }
  }

  /// Bytes kept in the tile cache, for tests.
  var keptTileBytes: Int { tileBytes }

  /// Steps 1–8 for `geometry` (the planes of `geometry.region`, before the vignette), from the
  /// latest stage kept: the halation stage as it is, else the colour stage with halation run on
  /// it, else the lens stage with the colour steps and halation, else everything from the source
  /// pixels. Each stage it makes is kept in `lane` (none for nil) once it's checked not cancelled,
  /// so nothing a cancelled render half-made is kept. A stage that does nothing with these
  /// options (no smear or blur; no halation, whose output is then the colour stage's) isn't kept
  /// apart from the one before it.
  @concurrent private nonisolated func staged(
    _ entry: SourceEntry, options: EditOptions, context: Context, geometry: Geometry, lane: Ticket?, cancel: EditPipeline.Cancel
  ) async throws -> Planes {
    let lensKey = LensKey(source: ObjectIdentifier(entry.image), lens: options.lens, geometry: geometry)
    let colourKey = ColourKey(lens: lensKey, options: options, context: context)
    let halationKey = HalationKey(colour: colourKey, halation: options.halation)
    let halates = !options.halation.isIdentity

    if halates, case .planes(let kept)? = await lookup(.halation(halationKey)) {
      await count(preGrainHit: true)
      return kept
    }
    var coloured: Planes?
    if case .planes(let kept)? = await lookup(.colour(colourKey)) { coloured = kept }
    await count(preGrainHit: !halates && coloured != nil)
    if !halates, let coloured { return coloured }

    if coloured == nil {
      var lensed: Planes?
      let lenses = !options.lens.isIdentity
      if lenses, case .planes(let kept)? = await lookup(.lens(lensKey)) { lensed = kept }
      if lensed == nil {
        let base = try await sourcePixels(entry, geometry: geometry, cancel: cancel)
        try cancel.check()
        let made = try Self.lensStage(base: base, geometry: geometry, options: options, cancel: cancel)
        try cancel.check()
        if lenses { await store(.lens(lensKey), .planes(made), bytes: made.byteCount, lane: lane) }
        lensed = made
      }
      let stats = try await stats(entry, options: options, context: context, cancel: cancel)
      try cancel.check()
      let made = try Self.colourStage(lensed!, options: options, context: context, stats: stats, cancel: cancel)
      try cancel.check()
      await store(.colour(colourKey), .planes(made), bytes: made.byteCount, lane: lane)
      if !halates { return made }
      coloured = made
    }
    let made = try Self.halationStage(coloured!, geometry: geometry, options: options, cancel: cancel)
    try cancel.check()
    await store(.halation(halationKey), .planes(made), bytes: made.byteCount, lane: lane)
    return made
  }

  /// Steps 1–9 on `base`, the source pixels of `geometry.read` (the output region with the
  /// margins the smear, blur and halation reach into); the result is `geometry.region`. The
  /// stages one after another, kept nowhere: what `staged` and the vignette make, bit for bit.
  nonisolated static func preGrain(
    base: Planes, geometry: Geometry, options: EditOptions, context: Context, stats: EditPipeline.SourceStats,
    cancel: EditPipeline.Cancel = .never
  ) throws -> Planes {
    let lensed = try lensStage(base: base, geometry: geometry, options: options, cancel: cancel)
    let coloured = try colourStage(lensed, options: options, context: context, stats: stats, cancel: cancel)
    var planes = try halationStage(coloured, geometry: geometry, options: options, cancel: cancel)
    vignetteStage(&planes, geometry: geometry, options: options, cancel: cancel)
    try cancel.check()
    return planes
  }

  /// The lens stage: steps 1–2 on `base` (`geometry.read`), then cut to what halation needs
  /// (`geometry.glow`).
  nonisolated static func lensStage(base: Planes, geometry: Geometry, options: EditOptions, cancel: EditPipeline.Cancel = .never) throws -> Planes {
    var planes = EditPipeline.lens(base, options.lens, scale: geometry.scale, cancel: cancel)
    try cancel.check()
    let glow = geometry.glow
    planes = planes.cropped(x: glow.x - geometry.read.x, y: glow.y - geometry.read.y, width: glow.width, height: glow.height)
    try cancel.check()
    return planes
  }

  /// The colour stage: steps 3–7 on the lens stage (`geometry.glow`).
  nonisolated static func colourStage(
    _ lensed: Planes, options: EditOptions, context: Context, stats: EditPipeline.SourceStats, cancel: EditPipeline.Cancel = .never
  ) throws -> Planes {
    var planes = lensed
    EditPipeline.color(&planes, options: options, context: context, stats: stats, cancel: cancel)
    try cancel.check()
    return planes
  }

  /// The halation stage: step 8 on the colour stage (`geometry.glow`), then cut to the output
  /// (`geometry.region`; the same planes when there's no halation, whose glow is the region).
  nonisolated static func halationStage(
    _ coloured: Planes, geometry: Geometry, options: EditOptions, cancel: EditPipeline.Cancel = .never
  ) throws -> Planes {
    var planes = coloured
    Halation.apply(options.halation, to: &planes, scale: geometry.scale, cancel: cancel)
    try cancel.check()
    let glow = geometry.glow
    let region = geometry.region
    if glow != region {
      planes = planes.cropped(x: region.x - glow.x, y: region.y - glow.y, width: region.width, height: region.height)
    }
    return planes
  }

  /// Step 9, in the scaled image's coordinates (the vignette only depends on where a pixel is in
  /// the frame). Not kept: it's one multiply per pixel, about what copying a kept stage costs.
  nonisolated static func vignetteStage(_ planes: inout Planes, geometry: Geometry, options: EditOptions, cancel: EditPipeline.Cancel = .never) {
    let region = geometry.region
    Grade.vignette(
      options.vignette, to: &planes, fullWidth: geometry.scaledWidth, fullHeight: geometry.scaledHeight,
      window: Window(x: region.x, y: region.y, width: region.width, height: region.height), cancel: cancel)
  }

  /// Where a render sits: the scaled image it's a part of, the output region in it, and the
  /// regions read for the smear and blur (`read`) and halation (`glow`), all in scaled pixels.
  struct Geometry: Hashable, Sendable {
    var scaledWidth: Int
    var scaledHeight: Int
    var scale: Double
    var region: Resample.Region
    var glow: Resample.Region
    var read: Resample.Region

    init(width: Int, height: Int, window: Window?) {
      let window = window ?? .whole(width: width, height: height)
      let scale = min(max(window.scale, 1e-4), 1)
      (scaledWidth, scaledHeight) = EditPipeline.scaledSize(width: width, height: height, scale: scale)
      self.scale = scale
      let x = min(max(Int((Double(window.x) * scale).rounded()), 0), scaledWidth - 1)
      let y = min(max(Int((Double(window.y) * scale).rounded()), 0), scaledHeight - 1)
      let w = min(max(scale == 1 ? window.width : Int((Double(window.width) * scale).rounded()), 1), scaledWidth - x)
      let h = min(max(scale == 1 ? window.height : Int((Double(window.height) * scale).rounded()), 1), scaledHeight - y)
      region = Resample.Region(x: x, y: y, width: w, height: h)
      glow = region
      read = region
    }

    /// The part `region` (in scaled pixels, kept to the scaled image) of an image of `width` ×
    /// `height` at `scale`: a zoomed view, or one of its tiles.
    init(width: Int, height: Int, scale: Double, region: Resample.Region) {
      let scale = min(max(scale, 1e-4), 1)
      (scaledWidth, scaledHeight) = EditPipeline.scaledSize(width: width, height: height, scale: scale)
      self.scale = scale
      let x = min(max(region.x, 0), scaledWidth - 1)
      let y = min(max(region.y, 0), scaledHeight - 1)
      let w = min(max(region.width, 1), scaledWidth - x)
      let h = min(max(region.height, 1), scaledHeight - y)
      self.region = Resample.Region(x: x, y: y, width: w, height: h)
      glow = self.region
      read = self.region
    }

    /// `region` grown by `margin` each side, kept to the scaled image.
    func grown(_ region: Resample.Region, by margin: Int) -> Resample.Region {
      let x0 = max(region.x - margin, 0)
      let y0 = max(region.y - margin, 0)
      let x1 = min(region.x + region.width + margin, scaledWidth)
      let y1 = min(region.y + region.height + margin, scaledHeight)
      return Resample.Region(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// With the margins `options` need.
    func withReach(_ options: EditOptions) -> Geometry {
      var out = self
      out.glow = grown(region, by: EditPipeline.halationReach(options.halation, scale: scale))
      out.read = grown(out.glow, by: EditPipeline.lensReach(options.lens, scale: scale))
      return out
    }
  }

  // MARK: Sources

  /// What's kept per source image.
  final class SourceEntry: @unchecked Sendable {
    // Written once in `init`; the rest only on the renderer's actor.
    let image: CGImage
    let width: Int
    let height: Int
    let rgba: [UInt8]
    var channelStats: GrainProfile.ChannelStats?
    var proxy: Planes?
    var proxyScale = 1.0
    /// The source scaled for the fitted preview and zoomed views, the most recently used first:
    /// up to `EditRenderer.scaledLimit` sizes, so the fitted preview's survives a zoom.
    var scaled: [(width: Int, height: Int, rgba: [UInt8], lastUse: UInt64)] = []
    var stats: [StatsKey: EditPipeline.SourceStats] = [:]
    var lastUse: UInt64 = 0

    init(image: CGImage, rgba: [UInt8]) {
      self.image = image
      width = image.width
      height = image.height
      self.rgba = rgba
    }
  }

  private var sources: [ObjectIdentifier: SourceEntry] = [:]
  private var clock: UInt64 = 0

  private func cachedSource(_ id: ObjectIdentifier) -> SourceEntry? {
    guard let entry = sources[id] else { return nil }
    clock += 1
    entry.lastUse = clock
    return entry
  }

  private func keep(_ entry: SourceEntry) -> SourceEntry {
    let id = ObjectIdentifier(entry.image)
    if let existing = sources[id] { return existing }
    clock += 1
    entry.lastUse = clock
    sources[id] = entry
    while sources.count > max(sourceLimit, 1), let oldest = sources.min(by: { $0.value.lastUse < $1.value.lastUse }) {
      sources[oldest.key] = nil
      for key in store.keys where key.source == oldest.key { remove(key) }
      for lane in laneTickets.keys where lane.source == oldest.key { laneTickets[lane] = nil }
      forgetTiles(of: oldest.key)
    }
    return entry
  }

  @concurrent private nonisolated func sourceEntry(_ image: CGImage) async throws -> SourceEntry {
    if let entry = await cachedSource(ObjectIdentifier(image)) { return entry }
    guard let rgba = ColorMatch.rgba(image), rgba.count == image.width * image.height * 4, !rgba.isEmpty else {
      throw EditPipeline.RenderError.unreadableSource
    }
    return await keep(SourceEntry(image: image, rgba: rgba))
  }

  /// The source pixels a render reads (`geometry.read`), from the full-size pixels or the scaled copy.
  @concurrent private nonisolated func sourcePixels(
    _ entry: SourceEntry, geometry: Geometry, cancel: EditPipeline.Cancel = .never
  ) async throws -> Planes {
    let read = geometry.read
    if geometry.scaledWidth == entry.width, geometry.scaledHeight == entry.height {
      return Planes(rgba: entry.rgba, pixelWidth: entry.width, x: read.x, y: read.y, width: read.width, height: read.height, cancel: cancel)
    }
    let scaled: [UInt8]
    if let kept = await scaledCopy(entry, width: geometry.scaledWidth, height: geometry.scaledHeight) {
      scaled = kept
    } else {
      guard let made = ColorMatch.scaled(entry.rgba, width: entry.width, height: entry.height, toWidth: geometry.scaledWidth, height: geometry.scaledHeight)
      else { throw EditPipeline.RenderError.unreadableSource }
      await keepScaled(entry, width: geometry.scaledWidth, height: geometry.scaledHeight, rgba: made)
      scaled = made
    }
    try cancel.check()
    return Planes(rgba: scaled, pixelWidth: geometry.scaledWidth, x: read.x, y: read.y, width: read.width, height: read.height, cancel: cancel)
  }

  /// Scaled copies kept per source. With a single one (as there was), a zoomed view's scale
  /// pushed out the fitted preview's, and the next look scaled the whole source again for it.
  static let scaledLimit = 3

  private func scaledCopy(_ entry: SourceEntry, width: Int, height: Int) -> [UInt8]? {
    guard let index = entry.scaled.firstIndex(where: { $0.width == width && $0.height == height }) else {
      counters.scaledMisses += 1
      return nil
    }
    counters.scaledHits += 1
    var copy = entry.scaled.remove(at: index)
    clock += 1
    copy.lastUse = clock
    entry.scaled.insert(copy, at: 0)
    return copy.rgba
  }

  /// Bytes every source's scaled copies may take together: a quarter of the budget, apart from
  /// the stages' and the tiles' (`memoryBudget` documents the three).
  nonisolated var scaledBudget: Int { memoryBudget / 4 }

  /// Keeps a scaled copy first, dropping its source's least recently used past `scaledLimit`,
  /// then any source's least recently used while all of them take more than `scaledBudget`
  /// (the newest is always kept, as the single one was).
  private func keepScaled(_ entry: SourceEntry, width: Int, height: Int, rgba: [UInt8]) {
    entry.scaled.removeAll { $0.width == width && $0.height == height }
    clock += 1
    entry.scaled.insert((width, height, rgba, clock), at: 0)
    if entry.scaled.count > Self.scaledLimit { entry.scaled.removeLast(entry.scaled.count - Self.scaledLimit) }
    func total() -> Int { sources.values.reduce(0) { $0 + $1.scaled.reduce(0) { $0 + $1.rgba.count } } }
    while total() > scaledBudget {
      // The oldest copy other than the one just kept.
      var oldest: (entry: SourceEntry, index: Int, use: UInt64)?
      for source in sources.values {
        for (index, copy) in source.scaled.enumerated() where !(source === entry && index == 0) {
          if copy.lastUse < oldest?.use ?? .max { oldest = (source, index, copy.lastUse) }
        }
      }
      guard let oldest else { break }
      oldest.entry.scaled.remove(at: oldest.index)
    }
  }

  /// What `SourceStats` depends on besides the source.
  struct StatsKey: Hashable, Sendable {
    var lens: EditOptions.Lens?
    var match: EditOptions.Match?
    var referenceLab: Edit.LabStats?
    var histogram: Bool
    var colour: Bool

    init(_ options: EditOptions, _ context: Context) {
      let lab = EditPipeline.matchesLab(options, context)
      histogram = EditPipeline.matchesHistogram(options, context)
      colour = EditPipeline.matchesColour(options, context)
      lens = lab || histogram ? options.lens : nil
      var match = options.match
      match.colour = 0
      self.match = lab ? match : nil
      referenceLab = lab && histogram ? context.referenceLab : nil
    }
  }

  @concurrent private nonisolated func stats(
    _ entry: SourceEntry, options: EditOptions, context: Context, cancel: EditPipeline.Cancel = .never
  ) async throws -> EditPipeline.SourceStats {
    let key = StatsKey(options, context)
    if let kept = await keptStats(entry, key) { return kept }
    var channelStats: GrainProfile.ChannelStats?
    if key.colour {
      if let kept = await keptChannelStats(entry) {
        channelStats = kept
      } else {
        let measured = Grain.channelStats(rgba: entry.rgba, width: entry.width, height: entry.height, cancel: cancel)
        try cancel.check()
        await setChannelStats(entry, measured)
        channelStats = measured
      }
    }
    try Task.checkCancellation()
    try cancel.check()
    var proxy: Planes?
    var proxyScale = 1.0
    if key.lens != nil {
      if let kept = await keptProxy(entry) {
        (proxy, proxyScale) = kept
      } else {
        let size = ColorMatch.fitSize(width: entry.width, height: entry.height, side: EditPipeline.statsSide)
        let pixels = ColorMatch.downsampled(entry.rgba, width: entry.width, height: entry.height, fit: EditPipeline.statsSide)
        let made = Planes(rgba: pixels, width: size.width, height: size.height)
        let madeScale = Double(size.width) / Double(entry.width)
        await setProxy(entry, made, scale: madeScale)
        (proxy, proxyScale) = (made, madeScale)
      }
    }
    try Task.checkCancellation()
    let stats = proxy.map {
      EditPipeline.sourceStats(proxy: $0, proxyScale: proxyScale, channelStats: channelStats, options: options, context: context, cancel: cancel)
    } ?? EditPipeline.SourceStats(channelStats: channelStats)
    try cancel.check()
    await keepStats(entry, key, stats)
    return stats
  }

  private func keptStats(_ entry: SourceEntry, _ key: StatsKey) -> EditPipeline.SourceStats? {
    if let stats = entry.stats[key] {
      counters.statsHits += 1
      return stats
    }
    counters.statsMisses += 1
    return nil
  }

  private func keepStats(_ entry: SourceEntry, _ key: StatsKey, _ stats: EditPipeline.SourceStats) {
    if entry.stats.count >= 16 { entry.stats.removeAll() }
    entry.stats[key] = stats
  }

  private func keptChannelStats(_ entry: SourceEntry) -> GrainProfile.ChannelStats? { entry.channelStats }
  private func setChannelStats(_ entry: SourceEntry, _ stats: GrainProfile.ChannelStats) { entry.channelStats = stats }
  private func keptProxy(_ entry: SourceEntry) -> (Planes, Double)? { entry.proxy.map { ($0, entry.proxyScale) } }
  private func setProxy(_ entry: SourceEntry, _ proxy: Planes, scale: Double) {
    entry.proxy = proxy
    entry.proxyScale = scale
  }

  // MARK: The stage and field cache

  /// Everything the lens stage (steps 1–2) depends on: the smear and blur, and where the render
  /// sits (its regions are what it reads and keeps).
  struct LensKey: Hashable, Sendable {
    var source: ObjectIdentifier
    var lens: EditOptions.Lens
    var geometry: Geometry

    init(source: ObjectIdentifier, lens: EditOptions.Lens, geometry: Geometry) {
      self.source = source
      // Every lens that does nothing is the same lens.
      self.lens = lens.isIdentity ? .identity : lens
      self.geometry = geometry
    }
  }

  /// Everything the colour stage (steps 1–7) depends on: the lens stage's, the options for steps
  /// 3–7 (all of them but halation, the vignette and grain, so a setting added later is in it
  /// until it's taken out on purpose), and the parts of the context those steps use (by digest
  /// where there's one).
  struct ColourKey: Hashable, Sendable {
    var lens: LensKey
    var options: EditOptions
    var referenceLab: Edit.LabStats?
    var histogram: String?
    var refStats: GrainProfile.ChannelStats?
    var lut: String?

    init(lens: LensKey, options: EditOptions, context: Context) {
      self.lens = lens
      var options = options
      options.lens = lens.lens
      options.halation = .init()
      options.vignette = .init()
      options.grain = .identity
      self.options = options
      referenceLab = EditPipeline.matchesLab(options, context) ? context.referenceLab : nil
      histogram = EditPipeline.matchesHistogram(options, context) ? context.digests.referenceHistogram : nil
      refStats = EditPipeline.matchesColour(options, context) ? context.refStats : nil
      lut = options.lut.isIdentity ? nil : context.digests.lut ?? ""
    }
  }

  /// Everything the halation stage (steps 1–8) depends on.
  struct HalationKey: Hashable, Sendable {
    var colour: ColourKey
    var halation: EditOptions.Halation
  }

  struct FieldKey: Hashable, Sendable {
    var source: ObjectIdentifier
    var lumaCells: Cells?
    var chromaCells: Cells?
    var seed: Int
    var layout: Grain.Layout

    init(source: ObjectIdentifier, lumaCells: (width: Int, height: Int)?, chromaCells: (width: Int, height: Int)?, seed: Int, layout: Grain.Layout) {
      self.source = source
      self.lumaCells = lumaCells.map { Cells(width: $0.width, height: $0.height) }
      self.chromaCells = chromaCells.map { Cells(width: $0.width, height: $0.height) }
      self.seed = seed
      self.layout = layout
    }
  }

  struct Cells: Hashable, Sendable {
    var width: Int
    var height: Int
  }

  struct RealKey: Hashable, Sendable {
    var source: ObjectIdentifier
    var digest: String
    var refWidth: Int
    var seed: Int
    var layout: Grain.Layout
  }

  enum Key: Hashable, Sendable {
    case lens(LensKey)
    case colour(ColourKey)
    case halation(HalationKey)
    case grain(FieldKey)
    case real(RealKey)

    var source: ObjectIdentifier {
      switch self {
      case .lens(let key): key.source
      case .colour(let key): key.lens.source
      case .halation(let key): key.colour.lens.source
      case .grain(let key): key.source
      case .real(let key): key.source
      }
    }

    var stage: Lane.Stage {
      switch self {
      case .lens: .lens
      case .colour: .colour
      case .halation: .halation
      case .grain: .grain
      case .real: .real
      }
    }
  }

  /// Where an entry is kept: one entry per stage (and field kind) per source and kind of render,
  /// the newest. A slider drag makes a new key every tick; keeping only the newest of each lets
  /// the fitted preview's stages and the 100% window's sit side by side within the budget
  /// instead of the drag's stale ones pushing the other lane's out. A pane's fitted preview and
  /// the Slider comparison's share the whole-image lane (only one shows at a time), and the
  /// Side by Side original renders nothing.
  struct Lane: Hashable, Sendable {
    enum Stage: Hashable, Sendable { case lens, colour, halation, grain, real }
    /// The whole (scaled) image, as a fitted preview is, or a part of it, as a zoomed window is.
    enum Kind: Hashable, Sendable {
      case whole, part

      init(_ geometry: Geometry) {
        let region = geometry.region
        self = region.x == 0 && region.y == 0 && region.width == geometry.scaledWidth && region.height == geometry.scaledHeight ? .whole : .part
      }
    }

    var source: ObjectIdentifier
    var stage: Stage
    var kind: Kind
  }

  enum Value: Sendable {
    case planes(Planes)
    case grain(Grain.GrainFields)
    case real([[Float]])
  }

  private struct Stored {
    var value: Value
    var bytes: Int
    var lastUse: UInt64
  }

  private var store: [Key: Stored] = [:]
  /// Each lane's entry, and the ticket of the render that kept it.
  private var lanes: [Lane: Key] = [:]
  private var laneTickets: [Lane: UInt64] = [:]
  private var tickets: UInt64 = 0

  /// A render's place among those asked for, and the kind of lane it keeps its entries in.
  struct Ticket: Sendable {
    var kind: Lane.Kind
    var number: UInt64
  }

  /// The next render's ticket: a render that finishes after a later one in its lane (the render
  /// loop lets an in-flight one finish) mustn't replace that later render's entries.
  private func ticket(_ kind: Lane.Kind) -> Ticket {
    tickets += 1
    return Ticket(kind: kind, number: tickets)
  }
  private var storedBytes = 0

  private func lookup(_ key: Key) -> Value? {
    let hit = store[key] != nil
    switch key {
    case .lens: if hit { counters.lensHits += 1 } else { counters.lensMisses += 1 }
    case .colour: if hit { counters.colourHits += 1 } else { counters.colourMisses += 1 }
    case .halation: if hit { counters.halationHits += 1 } else { counters.halationMisses += 1 }
    case .grain, .real: if hit { counters.fieldHits += 1 } else { counters.fieldMisses += 1 }
    }
    guard var stored = store[key] else { return nil }
    clock += 1
    stored.lastUse = clock
    store[key] = stored
    return stored.value
  }

  private func count(preGrainHit hit: Bool) {
    if hit { counters.preGrainHits += 1 } else { counters.preGrainMisses += 1 }
  }

  /// Keeps `value` as `key`'s, in place of its lane's entry, with the least recently used of the
  /// other lanes' dropped while it doesn't fit; nothing for no lane (a full-size render), nor
  /// from a render asked for before the one that kept the lane's entry. Planes two stages share
  /// (a colour stage's alpha, say) count in each: the bytes are an upper bound.
  private func store(_ key: Key, _ value: Value, bytes: Int, lane ticket: Ticket?) {
    // Not for a source that's been dropped since, nor bigger than a third of the budget.
    guard let ticket, sources[key.source] != nil, bytes <= memoryBudget / 3 else { return }
    let lane = Lane(source: key.source, stage: key.stage, kind: ticket.kind)
    if let last = laneTickets[lane], last > ticket.number { return }
    laneTickets[lane] = ticket.number
    if let previous = lanes[lane] { remove(previous) }
    remove(key)
    while storedBytes + bytes > memoryBudget, let oldest = store.min(by: { $0.value.lastUse < $1.value.lastUse }) {
      remove(oldest.key)
    }
    clock += 1
    store[key] = Stored(value: value, bytes: bytes, lastUse: clock)
    lanes[lane] = key
    storedBytes += bytes
  }

  private func remove(_ key: Key) {
    guard let stored = store.removeValue(forKey: key) else { return }
    storedBytes -= stored.bytes
    for (lane, kept) in lanes where kept == key { lanes[lane] = nil }
  }

  /// Bytes kept in the stage and field cache, for tests.
  var keptBytes: Int { storedBytes }
}

extension EditPipeline.Planes {
  /// Bytes held.
  nonisolated var byteCount: Int { (r.count + g.count + b.count) * MemoryLayout<Float>.size + alpha.count }
}
