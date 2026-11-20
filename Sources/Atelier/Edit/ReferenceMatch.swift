import CoreGraphics
import Foundation
import simd

/// Pipeline step 3: Match Colors…'s Reinhard Lab transfer (`ColorMatch`) on the Edit screen's
/// float planes, toward the reference's or the original's Lab statistics (`Edit.LabStats`), with
/// `EditOptions.Match`'s four amounts as `ColorMatch.Options`.
///
/// It's ColorMatch's match, not a look-alike: the statistics are measured by ColorMatch's own
/// code (`ColorMatch.downsampled` to fit 512 then `ColorMatch.stats`), and each channel moves by
/// `ColorMatch.coefficients`, L only when brightness or contrast is set, as
/// `ColorMatch.transfer` does. Only the per-pixel conversion is redone here, because ColorMatch's
/// reads and writes 8-bit RGBA and the planes are floats in 0–255: the same sRGB EOTF, D65
/// matrix, white and CIE constants (copied from ColorMatch's private ones), in Double, without
/// rounding the result to a level (the pipeline truncates at the end, as grain.py does). On an
/// 8-bit image it gives ColorMatch's pixels within one level (ColorMatch rounds, this doesn't).
nonisolated enum ReferenceMatch {
  // MARK: Measuring

  /// The Lab statistics a match to `image` is made with, as Match Colors… measures its original
  /// (fit to 512, transparent pixels left out); nil when it can't be read.
  static func labStats(of image: CGImage) -> Edit.LabStats? {
    guard let pixels = ColorMatch.rgba(image) else { return nil }
    return labStats(rgba: pixels, width: image.width, height: image.height)
  }

  /// `labStats(of:)` of tightly packed sRGB RGBA8.
  static func labStats(rgba: [UInt8], width: Int, height: Int) -> Edit.LabStats {
    Edit.LabStats(ColorMatch.stats(rgba: ColorMatch.downsampled(rgba, width: width, height: height)))
  }

  /// `labStats(of:)` of planes, each value rounded to its nearest level first (an 8-bit image's
  /// planes measure exactly as the image does).
  static func labStats(of planes: EditPipeline.Planes) -> Edit.LabStats {
    labStats(rgba: roundedRGBA(planes), width: planes.width, height: planes.height)
  }

  // MARK: Matching

  /// `planes` matched by `match`'s Reinhard amounts toward `reference`, the planes' own
  /// statistics measured first (`labStats(of:)`). Nothing happens unless `match.matchesLab`, or
  /// when `reference` isn't three means and spreads.
  static func apply(_ match: EditOptions.Match, to planes: inout EditPipeline.Planes, reference: Edit.LabStats) {
    guard match.matchesLab, let reference = reference.stats, let target = labStats(of: planes).stats else { return }
    apply(match.colorMatchOptions, to: &planes, target: target, reference: reference)
  }

  /// `planes` moved from `target`'s statistics (theirs, measured beforehand, e.g. on the whole
  /// image when `planes` is a window of it) toward `reference`'s, by `options` as
  /// `ColorMatch.transferred` moves them.
  static func apply(
    _ options: ColorMatch.Options, to planes: inout EditPipeline.Planes, target: ColorMatch.Stats, reference: ColorMatch.Stats,
    cancel: EditPipeline.Cancel = .never
  ) {
    let matchesLightness = options.matchesLightness
    let l: (scale: Double, offset: Double) = matchesLightness
      ? ColorMatch.coefficients(target: target, reference: reference, channel: 0, mean: options.brightness, spread: options.contrast) : (1, 0)
    let a = ColorMatch.coefficients(target: target, reference: reference, channel: 1, mean: options.tint, spread: options.saturation)
    let b = ColorMatch.coefficients(target: target, reference: reference, channel: 2, mean: options.tint, spread: options.saturation)
    planes.withPixelBands(cancel: cancel) { range, red, green, blue in
      for i in range {
        var lab = Self.lab(red[i], green[i], blue[i])
        if matchesLightness { lab.x = lab.x * l.scale + l.offset }
        lab.y = lab.y * a.scale + a.offset
        lab.z = lab.z * b.scale + b.offset
        let rgb = Self.rgb(lab)
        red[i] = Float(rgb.x)
        green[i] = Float(rgb.y)
        blue[i] = Float(rgb.z)
      }
    }
  }

  // MARK: Lab (ColorMatch's constants)

  private static let white = SIMD3<Double>(0.95047, 1, 1.08883)
  private static let epsilon = 216.0 / 24389
  private static let kappa = 24389.0 / 27
  private static let rgbToXYZ = simd_double3x3(rows: [
    SIMD3(0.4124564, 0.3575761, 0.1804375),
    SIMD3(0.2126729, 0.7151522, 0.0721750),
    SIMD3(0.0193339, 0.1191920, 0.9503041),
  ])
  private static let xyzToRGB = rgbToXYZ.inverse

  /// Lab of one pixel in 0–255 (clipped to it first).
  static func lab(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Double> {
    func linear(_ value: Float) -> Double {
      let c = Double(min(max(value, 0), 255)) / 255
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    func f(_ t: Double) -> Double { t <= epsilon ? (kappa * t + 16) / 116 : cbrt(t) }
    let xyz = (rgbToXYZ * SIMD3(linear(r), linear(g), linear(b))) / white
    let fx = f(xyz.x)
    let fy = f(xyz.y)
    let fz = f(xyz.z)
    return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
  }

  /// sRGB in 0–255 of a Lab color, out-of-gamut colors clipped as `ColorMatch.encoded` clips
  /// them, but not rounded.
  static func rgb(_ lab: SIMD3<Double>) -> SIMD3<Double> {
    let fy = (lab.x + 16) / 116
    let fx = fy + lab.y / 500
    let fz = fy - lab.z / 200
    func inverse(_ f: Double) -> Double {
      let cubed = f * f * f
      return cubed <= epsilon ? (116 * f - 16) / kappa : cubed
    }
    let xyz = SIMD3(inverse(fx), inverse(fy), inverse(fz)) * white
    let linear = simd_clamp(xyzToRGB * xyz, SIMD3(repeating: 0), SIMD3(repeating: 1))
    func encode(_ c: Double) -> Double {
      let e = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
      return min(max(e, 0), 1) * 255
    }
    return SIMD3(encode(linear.x), encode(linear.y), encode(linear.z))
  }

  /// The planes as RGBA8, each value rounded to the nearest level.
  static func roundedRGBA(_ planes: EditPipeline.Planes) -> [UInt8] {
    let count = planes.width * planes.height
    var out = [UInt8](repeating: 0, count: count * 4)
    func byte(_ value: Float) -> UInt8 { value.isNaN ? 0 : UInt8(min(max(value, 0), 255).rounded()) }
    for index in 0..<count {
      out[index * 4] = byte(planes.r[index])
      out[index * 4 + 1] = byte(planes.g[index])
      out[index * 4 + 2] = byte(planes.b[index])
      out[index * 4 + 3] = index < planes.alpha.count ? planes.alpha[index] : 255
    }
    return out
  }
}
