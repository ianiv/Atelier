import Foundation
import simd

/// Pipeline step 8: film halation, the warm glow that light scattered back through film's base
/// spreads around bright highlights.
///
/// It works in linear light, since it models light being scattered and added: summed in the
/// planes' gamma-encoded values the glow comes out too bright, and a threshold on them means
/// something different in shadows and highlights.
///
/// 1. Emitters: only the light above `threshold`. A pixel's linear Rec. 709 luminance `Y` past the
///    threshold (itself linearized, so the slider keeps the brightness it looks like), as a
///    fraction `s` of what's left up to white, goes through a soft knee (quadratic over the first
///    `knee` of `s`, then straight, scaled so white gives 1). The pixel emits its own color scaled
///    to that luminance. So a pixel just over the threshold barely glows and brighter ones glow
///    more, with no step anywhere; masking a pixel's whole color instead made every sky or white
///    wall a full-strength emitter.
/// 2. Spread: that blurred by `Blur.gauss` with sigma `radius` (full-size pixels, times the
///    render's scale).
/// 3. Tint: the glow's color moved toward film's red-orange by `warmth`, geometrically per
///    channel in linear light: Y · (c / Y)^(1 − warmth) · warmL^warmth, where c is the glow's color,
///    Y its luminance and warmL `warm` linearized. Mixing linearly would leave a neutral glow
///    beige at 60% (the gamma-space gains are much redder once decoded, and a straight mix only
///    gets there at the very end). Then it's scaled back toward the glow's own luminance, so
///    warmth changes its color more than its strength, but no further than red at twice the
///    glow's luminance (`maxRed`), which would clip red around strong highlights.
/// 4. Added back in linear light, times `amount` and times (1 − Y)² of the receiving pixel: on
///    film the glow shows against what's darker around a highlight and vanishes into the highlight
///    itself, so bright areas take almost none and dark surroundings take it all. What's added to
///    a value is the change in its encoding (each channel clamped to 0–1 to work out), so values
///    outside 0–255 that a grade leaves keep their offset and nothing jumps where the glow ends;
///    pixels the glow doesn't reach, and white ones, keep their exact values.
nonisolated enum Halation {
  /// Film's halation color, red-orange, as sRGB-encoded RGB gains with red at 1.
  static let warm = SIMD3<Float>(1, 0.4, 0.15)
  /// `warm` in linear light, about (1, 0.133, 0.019).
  static let warmLinear = SIMD3(srgbToLinear(warm.x), srgbToLinear(warm.y), srgbToLinear(warm.z))
  /// The most the tint's luminance correction may raise red, in multiples of the glow's
  /// luminance.
  static let maxRed: Float = 2
  /// The soft knee's width, as a fraction of the range from the threshold to white.
  static let knee: Float = 0.25

  /// `planes` with `halation` added. `scale` is output pixels per full-size pixel (the render
  /// window's), which `radius` is multiplied by. Nothing happens when `halation.isIdentity`.
  static func apply(_ halation: EditOptions.Halation, to planes: inout EditPipeline.Planes, scale: Double = 1) {
    guard !halation.isIdentity, planes.width > 0, planes.height > 0 else { return }
    let width = planes.width
    let height = planes.height
    let encodedThreshold = Float(min(max(halation.threshold, 0), 1))
    let threshold = srgbToLinear(encodedThreshold)
    // A pixel's luminance is at most its brightest channel's, so one whose brightest encoded
    // channel is at or below the threshold can't emit, without decoding it.
    let skipBelow = 255 * encodedThreshold
    let range = max(1 - threshold, 1e-4)
    let kneeTop = 1 - knee / 2
    // The emitters, in linear light, as a copy of the planes.
    var source = planes
    var bright = [Bool](repeating: false, count: (height + 7) / 8 + 1)
    bright.withUnsafeMutableBufferPointer { bright in
      let bright = bright.baseAddress!
      source.withRowBands { rows, r, g, b in
        var found = false
        for i in rows.lowerBound * width..<rows.upperBound * width {
          let light = max(r[i], g[i], b[i]) > skipBelow ? linear(r[i], g[i], b[i]) : .zero
          let y = luma(light)
          guard y > threshold else {
            r[i] = 0
            g[i] = 0
            b[i] = 0
            continue
          }
          let s = min((y - threshold) / range, 1)
          let e = (s < knee ? s * s / (2 * knee) : s - knee / 2) / kneeTop
          let emitted = light * (e / max(y, 1e-6))
          r[i] = emitted.x
          g[i] = emitted.y
          b[i] = emitted.z
          found = true
        }
        // Bands are at least 8 rows tall, so no two start in the same eight and share a flag.
        if found { bright[rows.lowerBound / 8] = true }
      }
    }
    let any = bright.contains(true)
    guard any else { return }
    let sigma = max(halation.radius * scale, 0)
    let glow = Blur.gauss([source.r, source.g, source.b], width: width, height: height, sigma: sigma)
    let warmth = Float(min(max(halation.warmth, 0), 1))
    let amount = Float(min(max(halation.amount, 0), 1))
    let warmPower = SIMD3(Foundation.pow(warmLinear.x, warmth), Foundation.pow(warmLinear.y, warmth), Foundation.pow(warmLinear.z, warmth))
    glow[0].withUnsafeBufferPointer { gr in
      glow[1].withUnsafeBufferPointer { gg in
        glow[2].withUnsafeBufferPointer { gb in
          let gr = gr.baseAddress!
          let gg = gg.baseAddress!
          let gb = gb.baseAddress!
          planes.withPixelBands { range, r, g, b in
            for i in range {
              let own = SIMD3(gr[i], gg[i], gb[i])
              // Where no glow reaches (or the blur's rounding leaves a trace far below a level),
              // the pixel keeps its exact value rather than going through the round trip.
              guard max(own.x, own.y, own.z) > 1e-6 else { continue }
              let light = linear(r[i], g[i], b[i])
              // (1 − Y)²: midtones (Y 0.2, about sRGB 0.48) take 64% of the glow, a highlight at
              // sRGB 0.9 (Y 0.79) under 5%.
              let dark = max(1 - luma(light), 0)
              let receive = dark * dark
              // White (or past it, from an overflowing grade) takes no glow and keeps its values.
              guard receive > 0 else { continue }
              let out = light + amount * receive * tint(own, warmth: warmth, warmPower: warmPower)
              r[i] += 255 * (linearToSrgb(out.x) - linearToSrgb(light.x))
              g[i] += 255 * (linearToSrgb(out.y) - linearToSrgb(light.y))
              b[i] += 255 * (linearToSrgb(out.z) - linearToSrgb(light.z))
            }
          }
        }
      }
    }
  }

  /// Linear glow `color` moved toward `warmLinear` by `warmth` (`warmPower` is warmLinear to that
  /// power), as the type's step 3 describes.
  @inline(__always) static func tint(_ color: SIMD3<Float>, warmth: Float, warmPower: SIMD3<Float>) -> SIMD3<Float> {
    // The blur's rounding can leave a trace below zero, which a power would turn into NaN.
    let c = simd_max(color, .zero)
    let y = luma(c)
    guard warmth > 0, y > 1e-9 else { return c }
    let keep = 1 - warmth
    let t = y * SIMD3(Foundation.pow(c.x / y, keep), Foundation.pow(c.y / y, keep), Foundation.pow(c.z / y, keep)) * warmPower
    let ty = luma(t)
    guard ty > 1e-12 else { return t }
    let restore = y / ty
    let cap = t.x > 0 ? maxRed * y / t.x : restore
    return t * min(restore, cap)
  }

  /// Rec. 709 luminance of linear light (the weights for linear values; `Grade.luma`'s Rec. 601
  /// ones are grain.py's, for gamma-encoded values).
  @inline(__always) static func luma(_ c: SIMD3<Float>) -> Float {
    0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
  }

  /// A pixel's 0–255 sRGB values as linear light, clamped to 0–1 first: values past white from an
  /// overflowing grade would otherwise emit without bound.
  @inline(__always) static func linear(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
    SIMD3(srgbToLinear(r / 255), srgbToLinear(g / 255), srgbToLinear(b / 255))
  }

  /// The sRGB transfer function's inverse, on 0–1 (clamped).
  @inline(__always) static func srgbToLinear(_ v: Float) -> Float {
    let c = min(max(v, 0), 1)
    return c <= 0.04045 ? c / 12.92 : Foundation.pow((c + 0.055) / 1.055, 2.4)
  }

  /// The sRGB transfer function, linear 0–1 (clamped) to encoded 0–1.
  @inline(__always) static func linearToSrgb(_ v: Float) -> Float {
    // White is exactly 1: the formula gives a hair under it, which would truncate to 254.
    guard v < 1 else { return 1 }
    let c = max(v, 0)
    return c <= 0.0031308 ? 12.92 * c : 1.055 * Foundation.pow(c, 1 / 2.4) - 0.055
  }
}
