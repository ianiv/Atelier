import Accelerate
import CoreGraphics
import Foundation
import simd

/// Match Colors to Original: moves an edited image's colors back to its original's, by Reinhard
/// color transfer in CIELAB (Reinhard, Ashikhmin, Gooch and Shirley, "Color Transfer between
/// Images", IEEE CG&A 2001). Edit models (Fibo Edit, Kontext, Qwen Edit, MOSS Edit, image to
/// image, refines) often shift the whole image warmer or cooler; matching each Lab channel's mean
/// and spread to the original's takes that shift out while keeping what the edit changed.
///
/// A port of the Python script this feature started from, step for step: 8-bit sRGB through
/// linear RGB and D65 XYZ to Lab and back, with statistics taken on each image downsampled to fit
/// 512×512. It's done here with Accelerate rather than Core Image, whose Lab conversion uses
/// another white point and color management, so its numbers wouldn't match the script's.
///
/// Pixels are RGBA, 8 bits per channel, not premultiplied. Alpha passes through; fully transparent
/// pixels count toward no statistics.
nonisolated enum ColorMatch {
  /// How to match. The Match Colors… sheet (`ColorMatchSheet`) and agents set these; the
  /// one-click menu item uses the defaults. Each amount runs from 0 (leave it) to 1 (match fully).
  /// Mean and spread are separate because they go wrong separately: an edit model's cast is a
  /// moved mean, while a matched spread is what over- or under-saturates when the edit added or
  /// removed something colorful.
  struct Options: Sendable, Hashable {
    /// How far the color balance (the means of a and b) moves to the original's.
    var tint: Double = 1
    /// How far the saturation (the spreads of a and b) moves to the original's.
    var saturation: Double = 1
    /// How far the brightness (the mean of L) moves. 0 by default, as `contrast` is: an edit
    /// often means to change the light.
    var brightness: Double = 0
    /// How far the contrast (the spread of L) moves.
    var contrast: Double = 0
    /// Measure both images only where the edit left the picture alone (`measurements`), so what
    /// it added or removed doesn't count as a color shift. Off for the one-click item and agents,
    /// whose results stay what they were; the sheet turns it on.
    var unchangedOnly = false

    init(tint: Double = 1, saturation: Double = 1, brightness: Double = 0, contrast: Double = 0, unchangedOnly: Bool = false) {
      self.tint = tint
      self.saturation = saturation
      self.brightness = brightness
      self.contrast = contrast
      self.unchangedOnly = unchangedOnly
    }

    /// The settings from when there were two: `strength` for the colors, and `luminance` for how
    /// much of that the lightness moved by. Saved steps and queues, and agents, still give them.
    init(strength: Double, luminance: Double = 0) {
      self.init(tint: strength, saturation: strength, brightness: strength * luminance, contrast: strength * luminance)
    }

    /// Whether L is touched at all.
    var matchesLightness: Bool { brightness > 0 || contrast > 0 }

    /// The amounts in whole percents from 0 to 100%, as the sheet's sliders step, so two matches
    /// with the same settings compare equal (`Job.isSameMatch`) however their numbers were
    /// arrived at.
    var snapped: Options {
      Options(
        tint: ColorMatch.snapped(tint), saturation: ColorMatch.snapped(saturation), brightness: ColorMatch.snapped(brightness),
        contrast: ColorMatch.snapped(contrast), unchangedOnly: unchangedOnly)
    }

    /// The keys a saved step or queue holds the settings under, beside the record's or job's own.
    /// `strength` and `luminance` are the two settings there were before these.
    private enum CodingKeys: String, CodingKey { case tint, saturation, brightness, contrast, unchangedOnly, strength, luminance }

    /// Reads the settings from among a record's or job's keys. One saved before there were four
    /// has only `strength` and `luminance` (true, false, or for a while an amount), which give
    /// them as `init(strength:luminance:)` does.
    init(savedIn decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? 1
      let luminance = try container.decodeIfPresent(Amount.self, forKey: .luminance)?.value ?? 0
      let legacy = Options(strength: strength, luminance: luminance)
      tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? legacy.tint
      saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? legacy.saturation
      brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? legacy.brightness
      contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? legacy.contrast
      unchangedOnly = try container.decodeIfPresent(Bool.self, forKey: .unchangedOnly) ?? false
    }

    /// Writes the settings among a record's or job's keys, and always `strength` as a number and
    /// `luminance` as true or false as well: a copy of Atelier from before these settings needs
    /// both in those types, or it fails to read the step's whole profile. It ignores the rest.
    func save(in encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(tint, forKey: .tint)
      try container.encode(saturation, forKey: .saturation)
      try container.encode(brightness, forKey: .brightness)
      try container.encode(contrast, forKey: .contrast)
      try container.encode(unchangedOnly, forKey: .unchangedOnly)
      try container.encode(tint, forKey: .strength)
      try container.encode(matchesLightness, forKey: .luminance)
    }
  }

  /// `amount` kept to 0...1 and rounded to a whole percent.
  static func snapped(_ amount: Double) -> Double {
    (min(max(amount, 0), 1) * 100).rounded() / 100
  }

  /// The shift taken out: the edited image's mean minus the original's, in Lab units. Positive b
  /// is warmer (yellower), positive a more magenta.
  struct Shift: Codable, Sendable, Hashable {
    var l: Double
    var a: Double
    var b: Double

    /// For the status bar, in plain words.
    var summary: String {
      func signed(_ value: Double) -> String { String(format: "%+.1f", value) }
      let numbers = "Δa \(signed(a)), Δb \(signed(b))"
      guard max(abs(a), abs(b)) >= 0.5 else {
        return "Matched colors to the original. They were already close (\(numbers))."
      }
      var casts: [String] = []
      if abs(b) >= 0.5 { casts.append(b > 0 ? "warmer" : "cooler") }
      if abs(a) >= 0.5 { casts.append(a > 0 ? "more magenta" : "greener") }
      return "Matched colors to the original. The edit had come out \(casts.joined(separator: " and ")) (\(numbers))."
    }
  }

  /// What a step made by Match Colors records (`profile_data` `color_match`), so matching it again
  /// goes back to the same original rather than to the image it was matched from.
  struct Record: Codable, Hashable, Sendable {
    /// How it was matched. Saved among the record's own keys (`Options.save(in:)`).
    var options: Options
    /// The fraction of the image that was measured, when only its unchanged areas were
    /// (`Options.unchangedOnly`); nil when the whole image was, asked for or not.
    var counted: Double?
    /// The original's image tensor; nil when the original was the step's first moodboard image
    /// (carried over with it).
    var originalTensorId: Int64?
    /// The shift taken out, so the Queue and agents can say what changed without measuring again.
    /// Optional: steps saved before it was recorded don't have it.
    var shift: Shift?

    private enum CodingKeys: String, CodingKey { case counted, originalTensorId, shift }

    init(options: Options, counted: Double? = nil, originalTensorId: Int64? = nil, shift: Shift? = nil) {
      self.options = options
      self.counted = counted
      self.originalTensorId = originalTensorId
      self.shift = shift
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      options = try Options(savedIn: decoder)
      counted = try container.decodeIfPresent(Double.self, forKey: .counted)
      originalTensorId = try container.decodeIfPresent(Int64.self, forKey: .originalTensorId)
      shift = try container.decodeIfPresent(Shift.self, forKey: .shift)
    }

    func encode(to encoder: Encoder) throws {
      try options.save(in: encoder)
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encodeIfPresent(counted, forKey: .counted)
      try container.encodeIfPresent(originalTensorId, forKey: .originalTensorId)
      try container.encodeIfPresent(shift, forKey: .shift)
    }
  }

  /// `luminance` as saved queues and steps' `profile_data` held it before there were four
  /// settings: true or false at first, then an amount. True reads as 1 and false as 0.
  private struct Amount: Decodable {
    var value: Double

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let flag = try? container.decode(Bool.self) {
        value = flag ? 1 : 0
      } else {
        value = try container.decode(Double.self)
      }
    }
  }

  /// A queued Match Colors to Original (`GenerationEngine.Request.colorMatch`): which step, in
  /// which project, and how. It names its project because it saves there whichever project is
  /// open when it runs (`CreateModel.run(_:request:job:)`), and it's worked out from the project
  /// when it runs rather than when queued, so it's kept across a quit with no images of its own.
  struct Job: Codable, Hashable, Sendable {
    var project: String
    /// The edited step's image tensor, which stays the same when steps are renumbered.
    var sourceTensorId: Int64
    /// As `Record.options`, and read and written the same way.
    var options: Options
    /// What the saved step records, once the job has run.
    var record: Record?

    /// The same match: the same step with the same settings, whose result would be the same
    /// image, so it's never queued twice. Other settings make another image, and may queue.
    func isSameMatch(as other: Job) -> Bool {
      project == other.project && sourceTensorId == other.sourceTensorId && options.snapped == other.options.snapped
    }

    private enum CodingKeys: String, CodingKey { case project, sourceTensorId, record }

    init(project: String, sourceTensorId: Int64, options: Options = Options(), record: Record? = nil) {
      self.project = project
      self.sourceTensorId = sourceTensorId
      self.options = options
      self.record = record
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      project = try container.decode(String.self, forKey: .project)
      sourceTensorId = try container.decode(Int64.self, forKey: .sourceTensorId)
      options = try Options(savedIn: decoder)
      record = try container.decodeIfPresent(Record.self, forKey: .record)
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(project, forKey: .project)
      try container.encode(sourceTensorId, forKey: .sourceTensorId)
      try options.save(in: encoder)
      try container.encodeIfPresent(record, forKey: .record)
    }
  }

  /// What the Match Colors… sheet previews with: the statistics exactly as the job takes them
  /// (`measurements`, from the full images), and the edited image at a size small enough to
  /// transfer again on every slider move. Rendering the small image with the full images'
  /// statistics shows what the job will make, rather than a match of the small image.
  struct Preview: Sendable {
    /// Both ways of measuring, taken once, so switching between them only draws again.
    var measurements: Measurements
    /// The edited image fit to `side`, as RGBA8.
    var pixels: [UInt8]
    var width: Int
    var height: Int
    /// `pixels` in Lab, their alpha, and whether all of it is opaque, kept so that a slider move
    /// only moves the planes and encodes them: going to Lab again each time was half of a
    /// render. The planes are made a slice at a time as `transferred` makes them
    /// (`ColorMatch.slicedLab`), so a render has the very bytes the transfer of `pixels` has.
    var planes: Planes
    var alpha: [UInt8]
    var opaque: Bool
    /// The original at the same fit, to show beside it.
    var original: CGImage

    /// The longer side of the previewed image, in pixels: twice the sheet's picture box (190
    /// points high) covers it on a Retina display, and each render takes time with its pixel
    /// count. Only what's shown is this size; the statistics come from the full images.
    static let side = 512

    /// The whole edited image's statistics, and the whole original's.
    var target: Stats { measurements.whole.target }
    var reference: Stats { measurements.whole.reference }

    /// The shift a full match of the whole images takes out.
    var shift: Shift { measurements.whole.shift }

    /// The small edited image matched with `options`, as the job would the full one. `progress`
    /// is `transferred`'s, and can throw to stop.
    func render(_ options: Options, progress: (Double) throws -> Void) rethrows -> CGImage? {
      let measured = measurements.measurement(unchangedOnly: options.unchangedOnly)
      let out = try ColorMatch.transfer(
        count: alpha.count, target: measured.target, reference: measured.reference, options: options, progress: progress
      ) { range in
        (Planes(l: Array(planes.l[range]), a: Array(planes.a[range]), b: Array(planes.b[range])), Array(alpha[range]))
      }
      return ColorMatch.cgImage(rgba: out, width: width, height: height, opaque: opaque)
    }

    /// `render` with no progress.
    func render(_ options: Options) -> CGImage? {
      render(options) { _ in }
    }

    /// Runs `render` away from the main actor, stopping with `CancellationError` when the task is
    /// cancelled: a slider being dragged asks for many, and only the last matters.
    @concurrent func rendering(_ options: Options) async throws -> CGImage? {
      try render(options) { _ in try Task.checkCancellation() }
    }

    /// Reads both images and measures them, away from the main actor; nil when either can't be read.
    @concurrent static func make(edited: CGImage, original: CGImage) async -> Preview? {
      guard let pixels = rgba(edited), let referencePixels = rgba(original) else { return nil }
      let measurements = ColorMatch.measurements(
        edited: pixels, width: edited.width, height: edited.height,
        original: referencePixels, width: original.width, height: original.height)
      let size = fitSize(width: edited.width, height: edited.height, side: side)
      let originalSize = fitSize(width: original.width, height: original.height, side: side)
      guard let small = cgImage(
        rgba: downsampled(referencePixels, width: original.width, height: original.height, fit: side),
        width: originalSize.width, height: originalSize.height)
      else { return nil }
      let shown = downsampled(pixels, width: edited.width, height: edited.height, fit: side)
      let alpha = stride(from: 3, to: shown.count, by: 4).map { shown[$0] }
      return Preview(
        measurements: measurements, pixels: shown, width: size.width, height: size.height,
        planes: slicedLab(rgba: shown), alpha: alpha, opaque: !alpha.contains { $0 != 255 }, original: small)
    }
  }

  /// Per-channel mean and population standard deviation (plus 1e-6, as the script adds), L, a, b.
  struct Stats: Sendable, Hashable {
    var mean: SIMD3<Double>
    var std: SIMD3<Double>
  }

  /// The statistics a match is made with, and what they were taken from.
  struct Measurement: Sendable, Hashable {
    /// The edited image's statistics, and the original's.
    var target: Stats
    var reference: Stats
    /// The fraction of the visible image they were taken from, when that's only its unchanged
    /// areas; nil when it's the whole image.
    var counted: Double?

    /// The shift a full match takes out.
    var shift: Shift { ColorMatch.shift(target: target, reference: reference) }
  }

  /// Why only the whole image could be measured, when the unchanged areas were asked for.
  enum WholeImageReason: Sendable, Hashable {
    /// The original has another shape, so no pixel of it lies under one of the edit's.
    case shape
    /// Too little of the image is unchanged (this fraction of it) to speak for its colors: under
    /// a quarter when the rest moved together, under just over half when it didn't
    /// (`minimumRegionFraction`, `minimumUnchangedFraction`).
    case mostlyChanged(Double)
    /// The image changed everywhere: even the part that moved least moved too far for that to
    /// be a cast (`maximumCastDeltaE`), so there's no telling unchanged areas from the edit.
    case changedTogether
  }

  /// Both ways of measuring a pair of images (`measurements`).
  struct Measurements: Sendable, Hashable {
    /// Each whole image.
    var whole: Measurement
    /// Only where the edit left the picture alone; nil when that can't be used, or wasn't taken.
    var unchanged: Measurement?
    /// Why `unchanged` can't be used, when it can't.
    var reason: WholeImageReason?

    /// What a match with `Options.unchangedOnly` set so is made with: the whole image when the
    /// unchanged areas can't be used.
    func measurement(unchangedOnly: Bool) -> Measurement {
      unchangedOnly ? unchanged ?? whole : whole
    }
  }

  /// Lab channels, one array each.
  struct Planes: Sendable {
    var l: [Double]
    var a: [Double]
    var b: [Double]
  }

  // MARK: Images

  /// `image` with its colors matched to `reference`'s, the shift taken out, and the fraction of
  /// the image measured when that was only its unchanged areas; nil when either can't be read. `progress` hears how far it is, 0 to 1, mostly through the transfer, which
  /// takes the time; it can throw to stop.
  static func matched(
    _ image: CGImage, to reference: CGImage, options: Options = Options(), progress: (Double) throws -> Void
  ) rethrows -> (image: CGImage, shift: Shift, counted: Double?)? {
    guard let pixels = rgba(image), let referencePixels = rgba(reference) else { return nil }
    let measured = measure(
      edited: pixels, width: image.width, height: image.height,
      original: referencePixels, width: reference.width, height: reference.height, unchangedOnly: options.unchangedOnly)
    try progress(0.05)
    let out = try transferred(rgba: pixels, target: measured.target, reference: measured.reference, options: options) {
      try progress(0.05 + 0.9 * $0)
    }
    guard let result = cgImage(rgba: out, width: image.width, height: image.height) else { return nil }
    try progress(1)
    return (result, measured.shift, measured.counted)
  }

  /// `matched` with no progress. (A defaulted closure would make every `rethrows` call throwing.)
  static func matched(
    _ image: CGImage, to reference: CGImage, options: Options = Options()
  ) -> (image: CGImage, shift: Shift, counted: Double?)? {
    matched(image, to: reference, options: options) { _ in }
  }

  /// Runs `matched` away from the main actor: a large image takes a moment. Stops with
  /// `CancellationError` when the task is cancelled, between slices of the transfer.
  @concurrent static func matching(
    _ image: CGImage, to reference: CGImage, options: Options, progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> (image: CGImage, shift: Shift, counted: Double?)? {
    try matched(image, to: reference, options: options) { fraction in
      try Task.checkCancellation()
      progress(fraction)
    }
  }

  /// The image's pixels as tightly packed sRGB RGBA8, not premultiplied.
  static func rgba(_ image: CGImage) -> [UInt8]? {
    guard var format = vImage_CGImageFormat(
      bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
    else { return nil }
    var buffer = vImage_Buffer()
    guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    else { return nil }
    defer { free(buffer.data) }
    let width = Int(buffer.width)
    let height = Int(buffer.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { out in
      for row in 0..<height {
        memcpy(out.baseAddress! + row * width * 4, buffer.data + row * buffer.rowBytes, width * 4)
      }
    }
    return pixels
  }

  /// An sRGB image of tightly packed RGBA8 pixels, not premultiplied; opaque ones drop alpha.
  /// `opaque` says whether they are when the caller already knows (the sheet's preview, drawn
  /// again and again from the same alpha); otherwise it's looked for.
  static func cgImage(rgba: [UInt8], width: Int, height: Int, opaque known: Bool? = nil) -> CGImage? {
    guard rgba.count == width * height * 4, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    var opaque = known ?? true
    if known == nil {
      for index in stride(from: 3, to: rgba.count, by: 4) where rgba[index] != 255 {
        opaque = false
        break
      }
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipLast : .last).rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  /// The pixels scaled down to fit 512×512, where the statistics are taken (unchanged when they
  /// already fit).
  static func downsampled(_ rgba: [UInt8], width: Int, height: Int, fit side: Int = statsSide) -> [UInt8] {
    guard width > side || height > side else { return rgba }
    let (newWidth, newHeight) = fitSize(width: width, height: height, side: side)
    return scaled(rgba, width: width, height: height, toWidth: newWidth, height: newHeight) ?? rgba
  }

  /// The pixels resampled to another size; nil when that fails.
  static func scaled(_ rgba: [UInt8], width: Int, height: Int, toWidth newWidth: Int, height newHeight: Int) -> [UInt8]? {
    var out = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
    var input = rgba
    let error = input.withUnsafeMutableBytes { inBytes in
      out.withUnsafeMutableBytes { outBytes in
        var source = vImage_Buffer(data: inBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var destination = vImage_Buffer(
          data: outBytes.baseAddress, height: vImagePixelCount(newHeight), width: vImagePixelCount(newWidth), rowBytes: newWidth * 4)
        return vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
      }
    }
    return error == kvImageNoError ? out : nil
  }

  /// The size `downsampled` makes: scaled down to fit `side`×`side`, or as it is when it fits.
  static func fitSize(width: Int, height: Int, side: Int) -> (width: Int, height: Int) {
    guard width > side || height > side else { return (width, height) }
    let scale = Double(side) / Double(max(width, height))
    return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
  }

  // MARK: Statistics

  /// Lab statistics of the pixels that aren't fully transparent; with `counted` (one per pixel),
  /// only of those it holds true for.
  static func stats(rgba: [UInt8], where counted: [Bool]? = nil) -> Stats {
    var visible: [UInt8] = []
    visible.reserveCapacity(rgba.count)
    for index in stride(from: 0, to: rgba.count, by: 4) where rgba[index + 3] > 0 && counted?[index / 4] != false {
      visible.append(contentsOf: rgba[index..<(index + 4)])
    }
    return stats(lab: lab(rgba: visible))
  }

  /// `stats(rgba:where:)` of pixels whose Lab planes are already made (`planes` is `rgba`'s), so
  /// an image measured more than one way goes to Lab once. The same numbers to the bit: each
  /// pixel's Lab doesn't depend on its neighbors, and the same values are averaged in the same
  /// order.
  static func stats(lab planes: Planes, rgba: [UInt8], where counted: [Bool]? = nil) -> Stats {
    let count = rgba.count / 4
    var included = planes
    if counted != nil || stride(from: 3, to: rgba.count, by: 4).contains(where: { rgba[$0] == 0 }) {
      var l: [Double] = []
      var a: [Double] = []
      var b: [Double] = []
      l.reserveCapacity(count)
      a.reserveCapacity(count)
      b.reserveCapacity(count)
      for index in 0..<count where rgba[index * 4 + 3] > 0 && counted?[index] != false {
        l.append(planes.l[index])
        a.append(planes.a[index])
        b.append(planes.b[index])
      }
      included = Planes(l: l, a: a, b: b)
    }
    return stats(lab: included)
  }

  /// Each plane's mean and spread.
  private static func stats(lab planes: Planes) -> Stats {
    func meanAndStd(_ values: [Double]) -> (Double, Double) {
      guard !values.isEmpty else { return (0, 1e-6) }
      let mean = vDSP.mean(values)
      let centered = vDSP.add(-mean, values)
      return (mean, vDSP.meanSquare(centered).squareRoot() + 1e-6)
    }
    let l = meanAndStd(planes.l)
    let a = meanAndStd(planes.a)
    let b = meanAndStd(planes.b)
    return Stats(mean: SIMD3(l.0, a.0, b.0), std: SIMD3(l.1, a.1, b.1))
  }

  // MARK: Measuring

  /// The side the statistics are taken at: each image scaled down to fit it (`downsampled`).
  static let statsSide = 512
  /// How far around each pixel the Lab planes are averaged before the two images are compared,
  /// in pixels each way (a 5×5 box): an edit model's VAE gives even untouched areas new fine
  /// texture, which pixel by pixel would read as change.
  static let unchangedBlurRadius = 2
  /// The most a pixel may differ from the original's (ΔE76, once the image-wide shift is taken
  /// off) and still count as unchanged. Around 2 is just visible; 10 is well past what a cast's
  /// unevenness and the blurred texture add, and well short of new content.
  static let unchangedDeltaE = 10.0
  /// The least of the visible image that must be unchanged for it to be measured alone, when
  /// the rest didn't move together: just over half. The shift taken off before comparing is the
  /// median difference, and a median speaks for the unchanged pixels only while they're the
  /// majority. Under half, it's whatever the changed ones did, and "unchanged" is then the part
  /// that changed. (When the rest did move together there are two regions to tell apart
  /// instead, and `minimumRegionFraction` is the floor.)
  static let minimumUnchangedFraction = 0.51
  /// How much of the pixels the median left out must lie within `unchangedDeltaE` of their own
  /// median difference for them to be a second region that moved together, rather than a
  /// scatter of changes. An edit that recolors a backdrop evenly moves over half the image by
  /// one amount: the image-wide median is then the edit and the pixels near it are the edited
  /// ones, while what it left out is the subject the edit kept, all of it carrying the same
  /// cast. Most of it, not all: the blur mixes the two regions along their border, and those
  /// pixels belong to neither.
  static let coherentRegionFraction = 0.8
  /// The least of the visible image the unchanged region must be when the image is two regions
  /// that each moved together, and the one that moved less is taken as unchanged. It needn't be
  /// the majority then (the other region's own median vouches for it), but under a quarter it's
  /// too little of the picture to speak for the colors of all of it.
  static let minimumRegionFraction = 0.25
  /// The largest shift of the areas taken as unchanged (their median difference, as ΔE76)
  /// that's taken for a cast. An edit model's cast is a few units (a b of 6 is a plainly warmer
  /// image) and a strong one around 10; 20 is another color. A median past it isn't a cast but
  /// new content, all changed the same way, and with nothing that moved less there's no part of
  /// the image the edit can be said to have kept.
  static let maximumCastDeltaE = 20.0

  /// The statistics a match of `edited` to `original` is made with (tightly packed RGBA8 of the
  /// full images). The job and the sheet's preview both take them here, so the preview can't
  /// show another match than the job makes.
  static func measure(
    edited: [UInt8], width: Int, height: Int, original: [UInt8], width originalWidth: Int, height originalHeight: Int,
    unchangedOnly: Bool
  ) -> Measurement {
    measurements(
      edited: edited, width: width, height: height, original: original, width: originalWidth, height: originalHeight,
      unchanged: unchangedOnly
    ).measurement(unchangedOnly: unchangedOnly)
  }

  /// `measure` both ways at once (the unchanged areas only with `unchanged`, which takes longer).
  ///
  /// The whole images are measured as they always were, each scaled down to fit 512. The
  /// unchanged areas are found at that size: both images go to Lab (once each, for this and for
  /// the statistics) and are blurred a little, the median difference between them is taken off
  /// (that's the cast being matched, which would otherwise mark every pixel changed), and a
  /// pixel whose remaining difference is small is unchanged. The statistics are then those of the
  /// same pixels of both images, unblurred. An edit that adds a red coat then no longer reads as
  /// the image having turned red. When the pixels that leaves out moved together too (an evenly
  /// recolored backdrop, which as the larger part is what the median follows), the unchanged
  /// areas are whichever of the two regions moved less (`unchangedPixels`). It falls back to the
  /// whole images when the original has another shape (nothing lines up), when even those areas
  /// moved too far for a cast, or when they're too little of the image
  /// (`maximumCastDeltaE`, `minimumUnchangedFraction`, `minimumRegionFraction`).
  static func measurements(
    edited: [UInt8], width: Int, height: Int, original: [UInt8], width originalWidth: Int, height originalHeight: Int,
    unchanged: Bool = true
  ) -> Measurements {
    let target = downsampled(edited, width: width, height: height, fit: statsSide)
    let reference = downsampled(original, width: originalWidth, height: originalHeight, fit: statsSide)
    let targetLab = lab(rgba: target)
    let referenceLab = lab(rgba: reference)
    var result = Measurements(
      whole: Measurement(target: stats(lab: targetLab, rgba: target), reference: stats(lab: referenceLab, rgba: reference)))
    guard unchanged else { return result }
    let size = fitSize(width: width, height: height, side: statsSide)
    let originalSize = fitSize(width: originalWidth, height: originalHeight, side: statsSide)
    // The same shape when the original, scaled so its longer side is the edit's, comes to the
    // edit's size, give or take the rounding of both (what two images a pixel apart, each fit to
    // 512, can differ by). Comparing the two fitted sizes instead would call a small edit of a
    // large original another shape: 400×400 stays 400, while its 800×800 original fits to 512.
    let scale = Double(max(size.width, size.height)) / Double(max(originalWidth, originalHeight))
    guard abs(Double(originalWidth) * scale - Double(size.width)) <= 1.5,
          abs(Double(originalHeight) * scale - Double(size.height)) <= 1.5,
          target.count == size.width * size.height * 4, reference.count == originalSize.width * originalSize.height * 4
    else {
      result.reason = .shape
      return result
    }
    // The original at the edit's size, so each pixel lies under one of the edit's.
    var aligned = reference
    var alignedLab = referenceLab
    if originalSize != size {
      guard let scaled = scaled(reference, width: originalSize.width, height: originalSize.height, toWidth: size.width, height: size.height)
      else {
        result.reason = .shape
        return result
      }
      aligned = scaled
      alignedLab = lab(rgba: scaled)
    }
    let found = unchangedPixels(
      edited: target, lab: targetLab, original: aligned, lab: alignedLab, width: size.width, height: size.height)
    guard found.cast <= maximumCastDeltaE else {
      result.reason = .changedTogether
      return result
    }
    guard found.fraction >= found.floor else {
      result.reason = .mostlyChanged(found.fraction)
      return result
    }
    result.unchanged = Measurement(
      target: stats(lab: targetLab, rgba: target, where: found.mask),
      reference: stats(lab: alignedLab, rgba: aligned, where: found.mask), counted: found.fraction)
    return result
  }

  /// Which pixels of two images of the same size the edit left alone (see `measurements`), the
  /// fraction they are of the edited image's visible pixels, how large the shift taken off them
  /// was (their median difference, as ΔE76), and the least that fraction may be for them to be
  /// used. `lab` and `originalLab` are the two images' Lab planes.
  ///
  /// First they're the pixels near the image-wide median difference. That's right while the
  /// unchanged pixels are the majority, but an edit that moves more than half the image evenly
  /// (a backdrop made cooler) makes the median its own, and the pixels near it the edited ones.
  /// So the pixels left out are tested too: when most of them lie near their own median
  /// (`coherentRegionFraction`) the image is two regions that each moved together, and the one
  /// that moved less from the original is the unchanged one, since an edit moves pixels further
  /// than the cast the model leaves on what it kept. That region need only be a quarter of the
  /// image (`minimumRegionFraction`). Otherwise the median is trusted only as a majority
  /// (`minimumUnchangedFraction`).
  static func unchangedPixels(
    edited: [UInt8], lab: Planes, original: [UInt8], lab originalLab: Planes, width: Int, height: Int
  ) -> (mask: [Bool], fraction: Double, cast: Double, floor: Double) {
    let count = width * height
    /// Blurred over the pixels that show only. A fully transparent pixel's color is whatever was
    /// left under it, and would otherwise bleed into the visible ones beside it and mark them
    /// changed. An image with none is blurred as it is.
    func blurred(_ planes: Planes, _ rgba: [UInt8]) -> Planes {
      func plain(_ values: [Double]) -> [Double] {
        boxBlurred(values, width: width, height: height, radius: unchangedBlurRadius)
      }
      guard stride(from: 3, to: rgba.count, by: 4).contains(where: { rgba[$0] == 0 }) else {
        return Planes(l: plain(planes.l), a: plain(planes.a), b: plain(planes.b))
      }
      var shows = [Double](repeating: 0, count: count)
      for index in 0..<count where rgba[index * 4 + 3] > 0 { shows[index] = 1 }
      // How much of each pixel's box shows; the sums of 0s and 1s are exact, so none is exactly 0.
      let share = plain(shows)
      func weighted(_ values: [Double]) -> [Double] {
        var out = plain(vDSP.multiply(values, shows))
        for index in 0..<count { out[index] = share[index] > 0 ? out[index] / share[index] : 0 }
        return out
      }
      return Planes(l: weighted(planes.l), a: weighted(planes.a), b: weighted(planes.b))
    }
    let target = blurred(lab, edited)
    let reference = blurred(originalLab, original)
    // Seen in both images: a pixel either doesn't show has nothing to compare.
    var both = [Bool](repeating: false, count: count)
    var visible = 0
    for index in 0..<count {
      let shows = edited[index * 4 + 3] > 0
      if shows { visible += 1 }
      both[index] = shows && original[index * 4 + 3] > 0
    }
    guard visible > 0 else { return ([Bool](repeating: false, count: count), 0, 0, minimumUnchangedFraction) }
    let dl = vDSP.subtract(target.l, reference.l)
    let da = vDSP.subtract(target.a, reference.a)
    let db = vDSP.subtract(target.b, reference.b)
    /// The median difference, each channel's own, over the pixels of `among` `included` holds
    /// `holds` for (all of them with none).
    func median(among: [Bool], where included: [Bool]? = nil, is holds: Bool = true) -> SIMD3<Double> {
      func median(_ d: [Double]) -> Double {
        var seen = [Double]()
        seen.reserveCapacity(count)
        for index in 0..<count where among[index] && (included == nil || included?[index] == holds) { seen.append(d[index]) }
        guard !seen.isEmpty else { return 0 }
        seen.sort()
        return seen.count % 2 == 1 ? seen[seen.count / 2] : (seen[seen.count / 2 - 1] + seen[seen.count / 2]) / 2
      }
      return SIMD3(median(dl), median(da), median(db))
    }
    let limit = unchangedDeltaE * unchangedDeltaE
    /// Whether a pixel's difference is within `unchangedDeltaE` of `shift`.
    func near(_ index: Int, _ shift: SIMD3<Double>) -> Bool {
      let l = dl[index] - shift.x
      let a = da[index] - shift.y
      let b = db[index] - shift.z
      return l * l + a * a + b * b <= limit
    }
    func length(_ shift: SIMD3<Double>) -> Double { (shift.x * shift.x + shift.y * shift.y + shift.z * shift.z).squareRoot() }
    let shift = median(among: both)
    var mask = [Bool](repeating: false, count: count)
    var unchanged = 0
    for index in 0..<count where both[index] && near(index, shift) {
      mask[index] = true
      unchanged += 1
    }
    // The pixels that left out: a second region that moved together, when most are near their
    // own median.
    let otherShift = median(among: both, where: mask, is: false)
    var other = [Bool](repeating: false, count: count)
    var left = 0
    var together = 0
    for index in 0..<count where both[index] && !mask[index] {
      left += 1
      if near(index, otherShift) {
        other[index] = true
        together += 1
      }
    }
    guard left > 0, Double(together) >= coherentRegionFraction * Double(left) else {
      return (mask, Double(unchanged) / Double(visible), length(shift), minimumUnchangedFraction)
    }
    // Two regions: the one that moved less is the one the edit kept. Of the second, the pixels
    // near its median (the rest, along the border, are neither's).
    if length(otherShift) < length(shift) {
      return (other, Double(together) / Double(visible), length(otherShift), minimumRegionFraction)
    }
    return (mask, Double(unchanged) / Double(visible), length(shift), minimumRegionFraction)
  }

  /// A plane averaged over the (2·`radius` + 1)-wide box around each value, the box cut off at
  /// the plane's edges.
  static func boxBlurred(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
    guard radius > 0, values.count == width * height else { return values }
    // Rows, then columns, each from running sums.
    var rows = values
    var sums = [Double](repeating: 0, count: max(width, height) + 1)
    for y in 0..<height {
      let base = y * width
      for x in 0..<width { sums[x + 1] = sums[x] + values[base + x] }
      for x in 0..<width {
        let low = max(0, x - radius)
        let high = min(width - 1, x + radius)
        rows[base + x] = (sums[high + 1] - sums[low]) / Double(high - low + 1)
      }
    }
    var out = rows
    for x in 0..<width {
      for y in 0..<height { sums[y + 1] = sums[y] + rows[y * width + x] }
      for y in 0..<height {
        let low = max(0, y - radius)
        let high = min(height - 1, y + radius)
        out[y * width + x] = (sums[high + 1] - sums[low]) / Double(high - low + 1)
      }
    }
    return out
  }

  // MARK: Transfer

  /// How far a channel's spread may be stretched or squeezed, as the ratio of the original's
  /// spread to the edit's, for a and b and for L. Always on, with no setting. Doubling chroma
  /// doubles chroma noise with it, and 1.5× the L contrast already clips 8-bit highlights; past
  /// these a ratio says the two images hold different things, not that the colors drifted. It
  /// also keeps a flat image, whose spread is near 0, from making the ratio explode.
  static let chromaSpreadLimits = 0.5...2.0
  static let lightnessSpreadLimits = 0.67...1.5

  /// One channel's transfer (0 is L, 1 a, 2 b) as x · scale + offset, with its mean moved by
  /// `mean` of the way to the reference's and its spread by `spread` of the way:
  ///
  ///   k = reference std / target std, kept within the channel's limits
  ///   scale = 1 + spread · (k − 1)
  ///   offset = mean · (reference mean − k · target mean) + (mean − spread) · (k − 1) · target mean
  ///
  /// With the two amounts equal the last term is nothing and is left out, so this is to the bit
  /// the one-amount transfer there was before (x + amount · (matched − x)) whenever k is within
  /// its limits: the default match, and steps matched then, come out with the same pixels.
  static func coefficients(
    target: Stats, reference: Stats, channel: Int, mean: Double, spread: Double
  ) -> (scale: Double, offset: Double) {
    let limits = channel == 0 ? lightnessSpreadLimits : chromaSpreadLimits
    let k = min(max(reference.std[channel] / target.std[channel], limits.lowerBound), limits.upperBound)
    let scale = 1 + spread * (k - 1)
    let offset = mean * (reference.mean[channel] - k * target.mean[channel])
    guard mean != spread else { return (scale, offset) }
    return (scale, offset + (mean - spread) * (k - 1) * target.mean[channel])
  }

  /// The shift `transferred` removes: the target's mean minus the reference's.
  static func shift(target: Stats, reference: Stats) -> Shift {
    let delta = target.mean - reference.mean
    return Shift(l: delta.x, a: delta.y, b: delta.z)
  }

  /// The pixels moved from `target`'s statistics toward `reference`'s, each channel by
  /// `coefficients`: a and b by `tint` (mean) and `saturation` (spread), L by `brightness` and
  /// `contrast`. With both of those 0, L isn't touched at all, rather than moved by nothing, so
  /// the default's pixels stay what they always were. Done a slice at a time, so a large image's
  /// Lab planes never all exist at once. `progress` hears the fraction done after each slice (at
  /// least 1% apart, and 1 at the end); it can throw to stop.
  static func transferred(
    rgba: [UInt8], target: Stats, reference: Stats, options: Options, progress: (Double) throws -> Void
  ) rethrows -> [UInt8] {
    try transfer(count: rgba.count / 4, target: target, reference: reference, options: options, progress: progress) { range in
      let pixels = Array(rgba[range.lowerBound * 4..<range.upperBound * 4])
      var alpha = [UInt8](repeating: 0, count: pixels.count / 4)
      for index in alpha.indices { alpha[index] = pixels[index * 4 + 3] }
      return (lab(rgba: pixels), alpha)
    }
  }

  /// How many pixels `transferred` moves at a time.
  private static let transferSlice = 65536

  /// `transferred`'s work on `count` pixels, whose Lab planes and alpha `slice` gives a range at
  /// a time: from RGBA for the job, and for the sheet's preview from planes it keeps
  /// (`Preview.planes`). One loop for both, so they can't come apart.
  private static func transfer(
    count: Int, target: Stats, reference: Stats, options: Options, progress: (Double) throws -> Void,
    slice: (Range<Int>) -> (planes: Planes, alpha: [UInt8])
  ) rethrows -> [UInt8] {
    let matchesLightness = options.matchesLightness
    let l: (scale: Double, offset: Double) = matchesLightness
      ? coefficients(target: target, reference: reference, channel: 0, mean: options.brightness, spread: options.contrast) : (1, 0)
    let a = coefficients(target: target, reference: reference, channel: 1, mean: options.tint, spread: options.saturation)
    let b = coefficients(target: target, reference: reference, channel: 2, mean: options.tint, spread: options.saturation)
    var out = [UInt8](repeating: 0, count: count * 4)
    var reported = 0.0
    for start in stride(from: 0, to: count, by: transferSlice) {
      let end = min(start + transferSlice, count)
      var (planes, alpha) = slice(start..<end)
      if matchesLightness { planes.l = vDSP.add(l.offset, vDSP.multiply(l.scale, planes.l)) }
      planes.a = vDSP.add(a.offset, vDSP.multiply(a.scale, planes.a))
      planes.b = vDSP.add(b.offset, vDSP.multiply(b.scale, planes.b))
      out.replaceSubrange(start * 4..<end * 4, with: encoded(lab: planes, alpha: alpha))
      let fraction = Double(end) / Double(count)
      if fraction - reported >= 0.01 || end == count {
        reported = fraction
        try progress(fraction)
      }
    }
    if count == 0 { try progress(1) }
    return out
  }

  /// The Lab planes of `rgba`, made a slice at a time as `transferred` makes them, so planes
  /// kept from here hold the very numbers it works with.
  static func slicedLab(rgba: [UInt8]) -> Planes {
    let count = rgba.count / 4
    var planes = Planes(l: [], a: [], b: [])
    planes.l.reserveCapacity(count)
    planes.a.reserveCapacity(count)
    planes.b.reserveCapacity(count)
    for start in stride(from: 0, to: count, by: transferSlice) {
      let part = lab(rgba: Array(rgba[start * 4..<min(start + transferSlice, count) * 4]))
      planes.l += part.l
      planes.a += part.a
      planes.b += part.b
    }
    return planes
  }

  /// `transferred` with no progress.
  static func transferred(rgba: [UInt8], target: Stats, reference: Stats, options: Options) -> [UInt8] {
    transferred(rgba: rgba, target: target, reference: reference, options: options) { _ in }
  }

  // MARK: Lab

  /// The D65 white XYZ is divided by, and the CIE constants.
  private static let white = SIMD3<Double>(0.95047, 1, 1.08883)
  private static let epsilon = 216.0 / 24389
  private static let kappa = 24389.0 / 27
  /// Linear sRGB to XYZ (rows), and its inverse.
  private static let rgbToXYZ = simd_double3x3(rows: [
    SIMD3(0.4124564, 0.3575761, 0.1804375),
    SIMD3(0.2126729, 0.7151522, 0.0721750),
    SIMD3(0.0193339, 0.1191920, 0.9503041),
  ])
  private static let xyzToRGB = rgbToXYZ.inverse

  /// 8-bit sRGB to linear, one entry per level (the sRGB EOTF).
  private static let linear: [Double] = (0..<256).map { level in
    let c = Double(level) / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  /// Lab of RGBA8 pixels (alpha ignored).
  static func lab(rgba: [UInt8]) -> Planes {
    let count = rgba.count / 4
    guard count > 0 else { return Planes(l: [], a: [], b: []) }
    var r = [Double](repeating: 0, count: count)
    var g = r
    var bl = r
    for index in 0..<count {
      r[index] = linear[Int(rgba[index * 4])]
      g[index] = linear[Int(rgba[index * 4 + 1])]
      bl[index] = linear[Int(rgba[index * 4 + 2])]
    }
    // XYZ over the white, each row of the matrix at a time.
    func row(_ index: Int) -> [Double] {
      let m = rgbToXYZ.transpose[index] / white[index]
      return vDSP.add(vDSP.add(vDSP.multiply(m.x, r), vDSP.multiply(m.y, g)), vDSP.multiply(m.z, bl))
    }
    func f(_ t: [Double]) -> [Double] {
      var out = [Double](repeating: 0, count: t.count)
      var length = Int32(t.count)
      vvcbrt(&out, t, &length)
      for index in out.indices where t[index] <= epsilon {
        out[index] = (kappa * t[index] + 16) / 116
      }
      return out
    }
    let fx = f(row(0))
    let fy = f(row(1))
    let fz = f(row(2))
    return Planes(
      l: vDSP.add(-16, vDSP.multiply(116, fy)),
      a: vDSP.multiply(500, vDSP.subtract(fx, fy)),
      b: vDSP.multiply(200, vDSP.subtract(fy, fz)))
  }

  /// RGBA8 pixels of Lab planes, with `alpha` as their alpha. Out-of-gamut colors clip.
  static func encoded(lab planes: Planes, alpha: [UInt8]) -> [UInt8] {
    let count = planes.l.count
    guard count > 0 else { return [] }
    let fy = vDSP.divide(vDSP.add(16, planes.l), 116)
    let fx = vDSP.add(fy, vDSP.divide(planes.a, 500))
    let fz = vDSP.subtract(fy, vDSP.divide(planes.b, 200))
    func xyz(_ f: [Double], _ channel: Int) -> [Double] {
      var cubed = vDSP.multiply(vDSP.multiply(f, f), f)
      for index in cubed.indices where cubed[index] <= epsilon {
        cubed[index] = (116 * f[index] - 16) / kappa
      }
      return vDSP.multiply(white[channel], cubed)
    }
    let x = xyz(fx, 0)
    let y = xyz(fy, 1)
    let z = xyz(fz, 2)
    let inverse = xyzToRGB.transpose
    let exponents = [Double](repeating: 1 / 2.4, count: count)
    func channel(_ index: Int) -> [Double] {
      let m = inverse[index]
      let c = vDSP.clip(vDSP.add(vDSP.add(vDSP.multiply(m.x, x), vDSP.multiply(m.y, y)), vDSP.multiply(m.z, z)), to: 0...1)
      var encoded = vDSP.add(-0.055, vDSP.multiply(1.055, vForce.pow(bases: c, exponents: exponents)))
      for index in encoded.indices where c[index] <= 0.0031308 {
        encoded[index] = 12.92 * c[index]
      }
      return vDSP.add(0.5, vDSP.multiply(255, vDSP.clip(encoded, to: 0...1)))
    }
    let red = channel(0)
    let green = channel(1)
    let blue = channel(2)
    var out = [UInt8](repeating: 0, count: count * 4)
    for index in 0..<count {
      out[index * 4] = UInt8(red[index])
      out[index * 4 + 1] = UInt8(green[index])
      out[index * 4 + 2] = UInt8(blue[index])
      out[index * 4 + 3] = index < alpha.count ? alpha[index] : 255
    }
    return out
  }
}
