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
  /// How strongly to match. The Match Colors… sheet (`ColorMatchSheet`) and agents set these; the
  /// one-click menu item uses the defaults.
  struct Options: Sendable, Hashable {
    /// 0 leaves the image as it is, 1 matches fully.
    var strength: Double = 1
    /// How much of the lightness (L) to match as well, 0 to 1: L moves by `strength × luminance`.
    /// 0 by default: an edit often means to change brightness.
    var luminance: Double = 0

    /// Both in whole percents from 0 to 100%, as the sheet's sliders step, so two matches with
    /// the same settings compare equal (`Job.isSameMatch`) however their numbers were arrived at.
    var snapped: Options {
      Options(strength: ColorMatch.snapped(strength), luminance: ColorMatch.snapped(luminance))
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
    var strength: Double
    /// How much of the lightness was matched, 0 to 1 (`Options.luminance`). Written as it was
    /// when this was on or off, true or false, when it's all or nothing (`Amount`).
    var luminance: Double
    /// The original's image tensor; nil when the original was the step's first moodboard image
    /// (carried over with it).
    var originalTensorId: Int64?
    /// The shift taken out, so the Queue and agents can say what changed without measuring again.
    /// Optional: steps saved before it was recorded don't have it.
    var shift: Shift?

    private enum CodingKeys: String, CodingKey { case strength, luminance, originalTensorId, shift }

    init(strength: Double, luminance: Double, originalTensorId: Int64? = nil, shift: Shift? = nil) {
      self.strength = strength
      self.luminance = luminance
      self.originalTensorId = originalTensorId
      self.shift = shift
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      strength = try container.decode(Double.self, forKey: .strength)
      luminance = try container.decode(Amount.self, forKey: .luminance).value
      originalTensorId = try container.decodeIfPresent(Int64.self, forKey: .originalTensorId)
      shift = try container.decodeIfPresent(Shift.self, forKey: .shift)
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(strength, forKey: .strength)
      try container.encode(Amount(value: luminance), forKey: .luminance)
      try container.encodeIfPresent(originalTensorId, forKey: .originalTensorId)
      try container.encodeIfPresent(shift, forKey: .shift)
    }
  }

  /// `luminance` as saved queues and steps' `profile_data` hold it. It was a Bool before it became
  /// an amount, so true reads as 1 and false as 0; and 1 and 0 are still written as true and
  /// false, so a default match's step stays readable by a copy of Atelier from before the change
  /// (which would otherwise fail to read the step's whole profile).
  private struct Amount: Codable {
    var value: Double

    init(value: Double) { self.value = value }

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let flag = try? container.decode(Bool.self) {
        value = flag ? 1 : 0
      } else {
        value = try container.decode(Double.self)
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      if value == 0 || value == 1 {
        try container.encode(value == 1)
      } else {
        try container.encode(value)
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
    var strength: Double
    /// As `Record.luminance`, and read and written the same way.
    var luminance: Double
    /// What the saved step records, once the job has run.
    var record: Record?

    var options: Options { Options(strength: strength, luminance: luminance) }

    /// The same match: the same step with the same settings, whose result would be the same
    /// image, so it's never queued twice. Other settings make another image, and may queue.
    func isSameMatch(as other: Job) -> Bool {
      project == other.project && sourceTensorId == other.sourceTensorId && options.snapped == other.options.snapped
    }

    private enum CodingKeys: String, CodingKey { case project, sourceTensorId, strength, luminance, record }

    init(project: String, sourceTensorId: Int64, strength: Double, luminance: Double, record: Record? = nil) {
      self.project = project
      self.sourceTensorId = sourceTensorId
      self.strength = strength
      self.luminance = luminance
      self.record = record
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      project = try container.decode(String.self, forKey: .project)
      sourceTensorId = try container.decode(Int64.self, forKey: .sourceTensorId)
      strength = try container.decode(Double.self, forKey: .strength)
      luminance = try container.decode(Amount.self, forKey: .luminance).value
      record = try container.decodeIfPresent(Record.self, forKey: .record)
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(project, forKey: .project)
      try container.encode(sourceTensorId, forKey: .sourceTensorId)
      try container.encode(strength, forKey: .strength)
      try container.encode(Amount(value: luminance), forKey: .luminance)
      try container.encodeIfPresent(record, forKey: .record)
    }
  }

  /// What the Match Colors… sheet previews with: the statistics exactly as the job takes them
  /// (from the full images, each downsampled to fit 512), and the edited image at a size small
  /// enough to transfer again on every slider move. Rendering the small image with the full
  /// images' statistics shows what the job will make, rather than a match of the small image.
  struct Preview: Sendable {
    /// The edited image's statistics, and the original's.
    var target: Stats
    var reference: Stats
    /// The edited image fit to `side`, as RGBA8.
    var pixels: [UInt8]
    var width: Int
    var height: Int
    /// The original at the same fit, to show beside it.
    var original: CGImage

    /// The longer side of the previewed image, in pixels.
    static let side = 768

    /// The shift a full match takes out.
    var shift: Shift { ColorMatch.shift(target: target, reference: reference) }

    /// The small edited image matched with `options`, as the job would the full one. `progress`
    /// is `transferred`'s, and can throw to stop.
    func render(_ options: Options, progress: (Double) throws -> Void) rethrows -> CGImage? {
      let out = try ColorMatch.transferred(rgba: pixels, target: target, reference: reference, options: options, progress: progress)
      return ColorMatch.cgImage(rgba: out, width: width, height: height)
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
      let target = stats(rgba: downsampled(pixels, width: edited.width, height: edited.height))
      let reference = stats(rgba: downsampled(referencePixels, width: original.width, height: original.height))
      let size = fitSize(width: edited.width, height: edited.height, side: side)
      let originalSize = fitSize(width: original.width, height: original.height, side: side)
      guard let small = cgImage(
        rgba: downsampled(referencePixels, width: original.width, height: original.height, fit: side),
        width: originalSize.width, height: originalSize.height)
      else { return nil }
      return Preview(
        target: target, reference: reference, pixels: downsampled(pixels, width: edited.width, height: edited.height, fit: side),
        width: size.width, height: size.height, original: small)
    }
  }

  /// Per-channel mean and population standard deviation (plus 1e-6, as the script adds), L, a, b.
  struct Stats: Sendable, Hashable {
    var mean: SIMD3<Double>
    var std: SIMD3<Double>
  }

  /// Lab channels, one array each.
  struct Planes: Sendable {
    var l: [Double]
    var a: [Double]
    var b: [Double]
  }

  // MARK: Images

  /// `image` with its colors matched to `reference`'s, and the shift taken out; nil when either
  /// can't be read. `progress` hears how far it is, 0 to 1, mostly through the transfer, which
  /// takes the time; it can throw to stop.
  static func matched(
    _ image: CGImage, to reference: CGImage, options: Options = Options(), progress: (Double) throws -> Void
  ) rethrows -> (image: CGImage, shift: Shift)? {
    guard let pixels = rgba(image), let referencePixels = rgba(reference) else { return nil }
    let target = stats(rgba: downsampled(pixels, width: image.width, height: image.height))
    let source = stats(rgba: downsampled(referencePixels, width: reference.width, height: reference.height))
    try progress(0.05)
    let out = try transferred(rgba: pixels, target: target, reference: source, options: options) { try progress(0.05 + 0.9 * $0) }
    guard let result = cgImage(rgba: out, width: image.width, height: image.height) else { return nil }
    try progress(1)
    return (result, shift(target: target, reference: source))
  }

  /// `matched` with no progress. (A defaulted closure would make every `rethrows` call throwing.)
  static func matched(_ image: CGImage, to reference: CGImage, options: Options = Options()) -> (image: CGImage, shift: Shift)? {
    matched(image, to: reference, options: options) { _ in }
  }

  /// Runs `matched` away from the main actor: a large image takes a moment. Stops with
  /// `CancellationError` when the task is cancelled, between slices of the transfer.
  @concurrent static func matching(
    _ image: CGImage, to reference: CGImage, options: Options, progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> (image: CGImage, shift: Shift)? {
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
  static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    guard rgba.count == width * height * 4, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    var opaque = true
    for index in stride(from: 3, to: rgba.count, by: 4) where rgba[index] != 255 {
      opaque = false
      break
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipLast : .last).rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  /// The pixels scaled down to fit 512×512, where the statistics are taken (unchanged when they
  /// already fit).
  static func downsampled(_ rgba: [UInt8], width: Int, height: Int, fit side: Int = 512) -> [UInt8] {
    guard width > side || height > side else { return rgba }
    let (newWidth, newHeight) = fitSize(width: width, height: height, side: side)
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
    return error == kvImageNoError ? out : rgba
  }

  /// The size `downsampled` makes: scaled down to fit `side`×`side`, or as it is when it fits.
  static func fitSize(width: Int, height: Int, side: Int) -> (width: Int, height: Int) {
    guard width > side || height > side else { return (width, height) }
    let scale = Double(side) / Double(max(width, height))
    return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
  }

  // MARK: Statistics and transfer

  /// Lab statistics of the pixels that aren't fully transparent.
  static func stats(rgba: [UInt8]) -> Stats {
    var visible: [UInt8] = []
    visible.reserveCapacity(rgba.count)
    for index in stride(from: 0, to: rgba.count, by: 4) where rgba[index + 3] > 0 {
      visible.append(contentsOf: rgba[index..<(index + 4)])
    }
    let planes = lab(rgba: visible)
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

  /// The shift `transferred` removes: the target's mean minus the reference's.
  static func shift(target: Stats, reference: Stats) -> Shift {
    let delta = target.mean - reference.mean
    return Shift(l: delta.x, a: delta.y, b: delta.z)
  }

  /// The pixels with a and b (and L, by `luminance`) moved from `target`'s statistics to
  /// `reference`'s: matched = (x − target mean) · (reference std / target std) + reference mean,
  /// then x + amount · (matched − x), where amount is `strength` for a and b and
  /// `strength × luminance` for L. At `luminance` 0 L isn't touched at all, rather than moved by
  /// nothing, so the default's pixels stay what they were before lightness was an amount. Done a
  /// slice at a time, so a large image's Lab planes
  /// never all exist at once. `progress` hears the fraction done after each slice (at least 1%
  /// apart, and 1 at the end); it can throw to stop.
  static func transferred(
    rgba: [UInt8], target: Stats, reference: Stats, options: Options, progress: (Double) throws -> Void
  ) rethrows -> [UInt8] {
    // matched − x is linear in x, so the whole step is x · scale + offset per channel.
    func coefficients(_ channel: Int, amount s: Double) -> (scale: Double, offset: Double) {
      let k = reference.std[channel] / target.std[channel]
      return (1 + s * (k - 1), s * (reference.mean[channel] - k * target.mean[channel]))
    }
    let matchesLightness = options.luminance > 0
    let l: (scale: Double, offset: Double) = matchesLightness ? coefficients(0, amount: options.strength * options.luminance) : (1, 0)
    let a = coefficients(1, amount: options.strength)
    let b = coefficients(2, amount: options.strength)
    var out = [UInt8](repeating: 0, count: rgba.count)
    let slice = 65536 * 4
    var reported = 0.0
    for start in stride(from: 0, to: rgba.count, by: slice) {
      let end = min(start + slice, rgba.count)
      let pixels = Array(rgba[start..<end])
      var planes = lab(rgba: pixels)
      if matchesLightness { planes.l = vDSP.add(l.offset, vDSP.multiply(l.scale, planes.l)) }
      planes.a = vDSP.add(a.offset, vDSP.multiply(a.scale, planes.a))
      planes.b = vDSP.add(b.offset, vDSP.multiply(b.scale, planes.b))
      var alpha = [UInt8](repeating: 0, count: pixels.count / 4)
      for index in alpha.indices { alpha[index] = pixels[index * 4 + 3] }
      let converted = encoded(lab: planes, alpha: alpha)
      out.replaceSubrange(start..<end, with: converted)
      let fraction = Double(end) / Double(rgba.count)
      if fraction - reported >= 0.01 || end == rgba.count {
        reported = fraction
        try progress(fraction)
      }
    }
    if rgba.isEmpty { try progress(1) }
    return out
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
