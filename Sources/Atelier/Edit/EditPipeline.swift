import CoreGraphics
import Foundation

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
      guard count > 0, r.count >= count, g.count >= count, b.count >= count, alpha.count >= count else { return out }
      @inline(__always) func byte(_ value: Float) -> UInt8 { value.isNaN ? 0 : UInt8(min(max(value, 0), 255)) }
      let width = width
      let height = height
      r.withUnsafeBufferPointer { r in
        g.withUnsafeBufferPointer { g in
          b.withUnsafeBufferPointer { b in
            alpha.withUnsafeBufferPointer { alpha in
              out.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: height) { row in
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
      }
      return out
    }

    /// The part `x, y, width, height` of tightly packed RGBA8 `pixels` (`pixelWidth` wide) as
    /// planes, clamped to the image.
    init(rgba pixels: [UInt8], pixelWidth: Int, x: Int, y: Int, width w: Int, height h: Int) {
      let pixelHeight = pixelWidth > 0 ? pixels.count / 4 / pixelWidth : 0
      let x0 = min(max(x, 0), pixelWidth)
      let y0 = min(max(y, 0), pixelHeight)
      let w = min(max(w, 0), pixelWidth - x0)
      let h = min(max(h, 0), pixelHeight - y0)
      var r = [Float](repeating: 0, count: w * h)
      var g = r
      var b = r
      var alpha = [UInt8](repeating: 255, count: w * h)
      if w > 0, h > 0 {
        pixels.withUnsafeBufferPointer { input in
          r.withUnsafeMutableBufferPointer { r in
            g.withUnsafeMutableBufferPointer { g in
              b.withUnsafeMutableBufferPointer { b in
                alpha.withUnsafeMutableBufferPointer { alpha in
                  let (r, g, b, alpha) = (r, g, b, alpha)
                  DispatchQueue.concurrentPerform(iterations: h) { row in
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
            }
          }
        }
      }
      self.init(width: w, height: h, r: r, g: g, b: b, alpha: alpha)
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
    proxy: Planes, proxyScale: Double, channelStats: GrainProfile.ChannelStats?, options: EditOptions, context: Context
  ) -> SourceStats {
    var stats = SourceStats(channelStats: matchesColour(options, context) ? channelStats : nil)
    let lab = matchesLab(options, context)
    let histogram = matchesHistogram(options, context)
    guard lab || histogram else { return stats }
    var planes = lens(proxy, options.lens, scale: proxyScale)
    if lab {
      let target = ReferenceMatch.labStats(of: planes)
      stats.labTarget = target
      if histogram, let target = target.stats, let reference = context.referenceLab?.stats {
        ReferenceMatch.apply(options.match.colorMatchOptions, to: &planes, target: target, reference: reference)
      }
    }
    if histogram { stats.histogramSource = HistogramMatch.table(of: planes) }
    return stats
  }

  // MARK: - The steps

  /// Steps 1 and 2: grain.py's motion smear (clamped, above 1 px) and blur, their lengths in
  /// full-size pixels times `scale` (a preview's ratio, as Grain Studio scales them).
  static func lens(_ planes: Planes, _ lens: EditOptions.Lens, scale: Double = 1) -> Planes {
    var out = planes
    if lens.smears { out = Grain.motionSmear(out, length: lens.motion * scale, angle: lens.angle) }
    if lens.blurs { out = Grain.blur(out, sigma: lens.blur * scale) }
    return out
  }

  /// Steps 3 to 7, each pixel on its own: the Reinhard Lab match, the histogram match, grain.py's
  /// colour match, the grade (which owns exposure and tint, grain.py's included) and the LUT,
  /// then `sanitize`.
  /// `stats` is the whole image's (`SourceStats`); a step without its data is skipped.
  static func color(_ planes: inout Planes, options: EditOptions, context: Context, stats: SourceStats) {
    if matchesLab(options, context), let reference = context.referenceLab?.stats, let target = stats.labTarget?.stats {
      ReferenceMatch.apply(options.match.colorMatchOptions, to: &planes, target: target, reference: reference)
    }
    if matchesHistogram(options, context), let reference = context.referenceHistogram, let source = stats.histogramSource {
      HistogramMatch.apply(options.histogram, to: &planes, reference: reference, source: source)
    }
    if matchesColour(options, context), let reference = context.refStats, let source = stats.channelStats {
      planes = Grain.colourMatch(planes, source: source, reference: reference, amount: options.match.colour)
    }
    Grade.apply(options.grade, to: &planes)
    if !options.lut.isIdentity, let table = context.lut {
      CubeLUT.apply(table, to: &planes, strength: options.lut.strength)
    }
    sanitize(&planes)
  }

  /// The largest level kept between steps, either way: far past anything visible, small enough
  /// that a blur's sums stay finite.
  static let levelLimit: Float = 1e6

  /// Values that aren't numbers set to 0 and the rest kept to ±`levelLimit`, after the color
  /// steps: an unbounded grade (an agent's 200-stop exposure is infinity, times a black pixel
  /// NaN) would otherwise turn halation's and grain's sums, hence whole rows, into NaN.
  static func sanitize(_ planes: inout Planes) {
    let limit = levelLimit
    planes.withPixelBands { range, r, g, b in
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
    _ planes: inout Planes, options: EditOptions, context: Context, fields: Grain.GrainFields?, realNoise: [[Float]]?
  ) {
    let grain = options.grain
    guard grain.lum != 0 || grain.chroma != 0 || (grain.real > 0 && realNoise != nil) else { return }
    let luminance = Grain.luminance(planes)
    if let fields {
      Grain.addGrain(&planes, luminance: luminance, lum: grain.lum, chroma: grain.chroma, curve: context.curve, fields: fields)
    }
    if grain.real > 0, let realNoise, let real = context.realNoise {
      Grain.addRealNoise(&planes, luminance: luminance, curve: real.curve, amount: grain.real, field: realNoise)
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
    let measured = profile ? GrainProfile(measuring: planes, name: name, source: source) : nil
    return ReferenceMeasurement(lab: lab, histogram: histogram, profile: measured)
  }
}

// MARK: - Renderer

/// Renders Edit screen looks and keeps what it can between renders, for the screen (Slice G)
/// and the save and export jobs (Slice H). One per screen; every call may run at once with the
/// others (the work runs off the actor, which only holds the caches), and each stops with
/// `CancellationError` when its task is cancelled, so a `.task(id:)` re-render just drops the
/// last.
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
/// (a) per source, its pixels, grain.py's channel stats, a `statsSide` copy, a scaled copy for
/// previews and the `SourceStats` for recent options; (b) the pre-grain image (steps 1–9) per
/// options-before-grain, context and window, so a change to only the grain settings runs only
/// steps 10–12; (c) the grain fields and real-noise fields per size, seed, cells and layout.
/// (b) and (c) share `memoryBudget` bytes, least recently used out first, and an entry bigger
/// than a third of it (a 16 MP full render's) isn't kept. Two sources are kept; `forget(_:)`
/// drops one when the screen closes it.
actor EditRenderer {
  typealias Planes = EditPipeline.Planes
  typealias Window = EditPipeline.Window
  typealias Context = EditPipeline.Context

  /// Bytes the pre-grain images and fields may take together.
  let memoryBudget: Int
  /// Sources kept.
  let sourceLimit = 2

  init(memoryBudget: Int = 512 << 20) {
    self.memoryBudget = memoryBudget
  }

  /// Cache hits and misses since the renderer was made, for tests and timing.
  struct Counters: Hashable, Sendable {
    var preGrainHits = 0
    var preGrainMisses = 0
    var fieldHits = 0
    var fieldMisses = 0
    var statsHits = 0
    var statsMisses = 0
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
    return try await stats(entry, options: options, context: context)
  }

  /// Export LUT…: steps 3–7 for this image baked into a `size`³ table.
  @concurrent nonisolated func bakeLUT(
    source: CGImage, options: EditOptions, context: Context = .empty, size: Int = 33, name: String
  ) async throws -> Edit.LUTTable {
    let stats = try await sourceStats(source: source, options: options, context: context)
    try Task.checkCancellation()
    return EditPipeline.bakeLUT(options: options, context: context, stats: stats, size: size, name: name)
  }

  /// Drops everything kept for `source`.
  func forget(_ source: CGImage) {
    let id = ObjectIdentifier(source)
    sources[id] = nil
    for key in store.keys where key.source == id { remove(key) }
  }

  /// Drops everything.
  func removeAll() {
    sources = [:]
    store = [:]
    storedBytes = 0
  }

  // MARK: Rendering

  /// The render, as `window` (nil for the whole image at full size).
  @concurrent nonisolated func render(source: CGImage, options: EditOptions, context: Context, window: Window?) async throws -> CGImage {
    try Task.checkCancellation()
    // Nothing to do: the source as it is.
    if options.isIdentity, window == nil || window == .whole(width: source.width, height: source.height) { return source }
    let entry = try await sourceEntry(source)
    let geometry = Geometry(width: entry.width, height: entry.height, window: window).withReach(options)
    let id = ObjectIdentifier(source)

    // Steps 1–9, or the cached result.
    let preKey = PreGrainKey(source: id, options: options, context: context, geometry: geometry)
    let planes: Planes
    if case .planes(let cached)? = await lookup(.preGrain(preKey)) {
      planes = cached
    } else {
      let stats = try await stats(entry, options: options, context: context)
      try Task.checkCancellation()
      let base = try await sourcePixels(entry, geometry: geometry)
      try Task.checkCancellation()
      planes = try Self.preGrain(base: base, geometry: geometry, options: options, context: context, stats: stats)
      await store(.preGrain(preKey), .planes(planes), bytes: planes.byteCount)
    }
    try Task.checkCancellation()

    // Steps 10–12.
    var out = planes
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
          layout: layout)
        fields = made
        await store(.grain(key), .grain(made), bytes: made.byteCount)
      }
    }
    var realField: [[Float]]?
    if grain.real > 0, let real = context.realNoise, real.count > 0 {
      let key = RealKey(source: id, digest: real.digest, refWidth: context.refWidth, seed: grain.seed, layout: layout)
      if case .real(let cached)? = await lookup(.real(key)) {
        realField = cached
      } else {
        let made = Grain.realNoiseField(real, refWidth: context.refWidth, seed: grain.seed, layout: layout)
        realField = made
        await store(.real(key), .real(made), bytes: made.reduce(0) { $0 + $1.count * 4 })
      }
    }
    try Task.checkCancellation()
    EditPipeline.grain(&out, options: options, context: context, fields: fields, realNoise: realField)
    try Task.checkCancellation()
    guard let image = out.cgImage else { throw EditPipeline.RenderError.unreadableSource }
    return image
  }

  /// Steps 1–9 on `base`, the source pixels of `geometry.read` (the output region with the
  /// margins the smear, blur and halation reach into); the result is `geometry.region`.
  nonisolated static func preGrain(
    base: Planes, geometry: Geometry, options: EditOptions, context: Context, stats: EditPipeline.SourceStats
  ) throws -> Planes {
    let scale = geometry.scale
    // 1–2, then cut to what halation needs.
    var planes = EditPipeline.lens(base, options.lens, scale: scale)
    let glow = geometry.glow
    planes = planes.cropped(x: glow.x - geometry.read.x, y: glow.y - geometry.read.y, width: glow.width, height: glow.height)
    try Task.checkCancellation()
    // 3–7.
    EditPipeline.color(&planes, options: options, context: context, stats: stats)
    try Task.checkCancellation()
    // 8, then cut to the output.
    Halation.apply(options.halation, to: &planes, scale: scale)
    let region = geometry.region
    if glow != region {
      planes = planes.cropped(x: region.x - glow.x, y: region.y - glow.y, width: region.width, height: region.height)
    }
    // 9, in the scaled image's coordinates (the vignette only depends on where a pixel is in
    // the frame).
    Grade.vignette(
      options.vignette, to: &planes, fullWidth: geometry.scaledWidth, fullHeight: geometry.scaledHeight,
      window: Window(x: region.x, y: region.y, width: region.width, height: region.height))
    return planes
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
      if scale == 1 {
        scaledWidth = width
        scaledHeight = height
      } else {
        scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        scaledHeight = max(1, Int((Double(height) * scale).rounded()))
      }
      self.scale = scale
      let x = min(max(Int((Double(window.x) * scale).rounded()), 0), scaledWidth - 1)
      let y = min(max(Int((Double(window.y) * scale).rounded()), 0), scaledHeight - 1)
      let w = min(max(scale == 1 ? window.width : Int((Double(window.width) * scale).rounded()), 1), scaledWidth - x)
      let h = min(max(scale == 1 ? window.height : Int((Double(window.height) * scale).rounded()), 1), scaledHeight - y)
      region = Resample.Region(x: x, y: y, width: w, height: h)
      glow = region
      read = region
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
    /// The source scaled for previews: one size at a time.
    var scaled: (width: Int, height: Int, rgba: [UInt8])?
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
  @concurrent private nonisolated func sourcePixels(_ entry: SourceEntry, geometry: Geometry) async throws -> Planes {
    let read = geometry.read
    if geometry.scaledWidth == entry.width, geometry.scaledHeight == entry.height {
      return Planes(rgba: entry.rgba, pixelWidth: entry.width, x: read.x, y: read.y, width: read.width, height: read.height)
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
    return Planes(rgba: scaled, pixelWidth: geometry.scaledWidth, x: read.x, y: read.y, width: read.width, height: read.height)
  }

  private func scaledCopy(_ entry: SourceEntry, width: Int, height: Int) -> [UInt8]? {
    guard let scaled = entry.scaled, scaled.width == width, scaled.height == height else { return nil }
    return scaled.rgba
  }

  private func keepScaled(_ entry: SourceEntry, width: Int, height: Int, rgba: [UInt8]) {
    entry.scaled = (width, height, rgba)
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

  @concurrent private nonisolated func stats(_ entry: SourceEntry, options: EditOptions, context: Context) async throws -> EditPipeline.SourceStats {
    let key = StatsKey(options, context)
    if let kept = await keptStats(entry, key) { return kept }
    var channelStats: GrainProfile.ChannelStats?
    if key.colour {
      if let kept = await keptChannelStats(entry) {
        channelStats = kept
      } else {
        let measured = Grain.channelStats(rgba: entry.rgba, width: entry.width, height: entry.height)
        await setChannelStats(entry, measured)
        channelStats = measured
      }
    }
    try Task.checkCancellation()
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
      EditPipeline.sourceStats(proxy: $0, proxyScale: proxyScale, channelStats: channelStats, options: options, context: context)
    } ?? EditPipeline.SourceStats(channelStats: channelStats)
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

  // MARK: The pre-grain and field cache

  /// Everything steps 1–9 depend on: the options with the grain left out, the parts of the
  /// context those steps use (by digest where there's one), and where the render sits.
  struct PreGrainKey: Hashable, Sendable {
    var source: ObjectIdentifier
    var options: EditOptions
    var referenceLab: Edit.LabStats?
    var histogram: String?
    var refStats: GrainProfile.ChannelStats?
    var lut: String?
    var geometry: Geometry

    init(source: ObjectIdentifier, options: EditOptions, context: Context, geometry: Geometry) {
      self.source = source
      var options = options
      options.grain = .identity
      self.options = options
      referenceLab = EditPipeline.matchesLab(options, context) ? context.referenceLab : nil
      histogram = EditPipeline.matchesHistogram(options, context) ? context.referenceHistogram?.digest : nil
      refStats = EditPipeline.matchesColour(options, context) ? context.refStats : nil
      lut = options.lut.isIdentity ? nil : context.lut?.digest ?? ""
      self.geometry = geometry
    }
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
    case preGrain(PreGrainKey)
    case grain(FieldKey)
    case real(RealKey)

    var source: ObjectIdentifier {
      switch self {
      case .preGrain(let key): key.source
      case .grain(let key): key.source
      case .real(let key): key.source
      }
    }
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
  private var storedBytes = 0

  private func lookup(_ key: Key) -> Value? {
    let hit = store[key] != nil
    switch key {
    case .preGrain:
      if hit { counters.preGrainHits += 1 } else { counters.preGrainMisses += 1 }
    case .grain, .real:
      if hit { counters.fieldHits += 1 } else { counters.fieldMisses += 1 }
    }
    guard var stored = store[key] else { return nil }
    clock += 1
    stored.lastUse = clock
    store[key] = stored
    return stored.value
  }

  private func store(_ key: Key, _ value: Value, bytes: Int) {
    // Not for a source that's been dropped since, nor bigger than a third of the budget.
    guard sources[key.source] != nil, bytes <= memoryBudget / 3 else { return }
    remove(key)
    while storedBytes + bytes > memoryBudget, let oldest = store.min(by: { $0.value.lastUse < $1.value.lastUse }) {
      remove(oldest.key)
    }
    clock += 1
    store[key] = Stored(value: value, bytes: bytes, lastUse: clock)
    storedBytes += bytes
  }

  private func remove(_ key: Key) {
    guard let stored = store.removeValue(forKey: key) else { return }
    storedBytes -= stored.bytes
  }
}

extension EditPipeline.Planes {
  /// Bytes held.
  nonisolated var byteCount: Int { (r.count + g.count + b.count) * MemoryLayout<Float>.size + alpha.count }
}
