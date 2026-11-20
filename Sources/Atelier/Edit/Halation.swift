import Accelerate
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
///
/// The sRGB transfer function both ways is read from `Transfer`'s interpolated tables, and the
/// tint's powers are taken a row at a time with vForce: a dozen `pow` calls a pixel were most of
/// the step's time. The result is within a level (of 255) of the exact formulas.
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
  static func apply(
    _ halation: EditOptions.Halation, to planes: inout EditPipeline.Planes, scale: Double = 1, cancel: EditPipeline.Cancel = .never
  ) {
    let pixels = planes.width * planes.height
    guard !halation.isIdentity, planes.width > 0, planes.height > 0,
          planes.r.count >= pixels, planes.g.count >= pixels, planes.b.count >= pixels
    else { return }
    let width = planes.width
    let height = planes.height
    let encodedThreshold = Float(min(max(halation.threshold, 0), 1))
    let threshold = srgbToLinear(encodedThreshold)
    // A pixel's luminance is at most its brightest channel's, so one whose brightest encoded
    // channel is at or below the threshold can't emit, without decoding it.
    let skipBelow = 255 * encodedThreshold
    let range = max(1 - threshold, 1e-4)
    let kneeTop = 1 - knee / 2
    let decoding = Transfer.decoding, encoding = Transfer.encoding
    // The emitters, in linear light: new planes, every pixel written.
    let count = width * height
    let bandRows = max(8, height / (ProcessInfo.processInfo.activeProcessorCount * 4))
    let bands = (height + bandRows - 1) / bandRows
    var bright = [Bool](repeating: false, count: bands)
    var source = planes.r.withUnsafeBufferPointer { pr in
      planes.g.withUnsafeBufferPointer { pg in
        planes.b.withUnsafeBufferPointer { pb in
          bright.withUnsafeMutableBufferPointer { bright in
            let (pr, pg, pb, bright) = (pr.baseAddress!, pg.baseAddress!, pb.baseAddress!, bright.baseAddress!)
            return newPlanes(count: count) { r, g, b in
              DispatchQueue.concurrentPerform(iterations: bands) { band in
                let pixels = band * bandRows * width..<min((band + 1) * bandRows, height) * width
                var found = false
                // A band a cancel skips is left black; nothing reads it then.
                let skipped = cancel.isCancelled
                for i in pixels {
                  let light = !skipped && max(pr[i], pg[i], pb[i]) > skipBelow ? linear(pr[i], pg[i], pb[i], decoding) : .zero
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
                if found { bright[band] = true }
              }
            }
          }
        }
      }
    }
    let any = bright.contains(true)
    guard any, !cancel.isCancelled else { return }
    let sigma = max(halation.radius * scale, 0)
    let glow = Blur.gauss(source, width: width, height: height, sigma: sigma, cancel: cancel)
    source = []
    guard !cancel.isCancelled else { return }
    let warmth = Float(min(max(halation.warmth, 0), 1))
    let amount = Float(min(max(halation.amount, 0), 1))
    let warmPower = SIMD3(Foundation.pow(warmLinear.x, warmth), Foundation.pow(warmLinear.y, warmth), Foundation.pow(warmLinear.z, warmth))
    glow[0].withUnsafeBufferPointer { gr in
      glow[1].withUnsafeBufferPointer { gg in
        glow[2].withUnsafeBufferPointer { gb in
          let gr = gr.baseAddress!
          let gg = gg.baseAddress!
          let gb = gb.baseAddress!
          planes.withRowBands(cancel: cancel) { rows, r, g, b in
            // A row at a time: first the pixels that take glow, then their tint powers,
            // (c / Y)^(1 − warmth) per channel, all together, then the glow added to them.
            withUnsafeTemporaryAllocation(of: Int.self, capacity: width) { taking in
              withUnsafeTemporaryAllocation(of: Float.self, capacity: 9 * width) { scratch in
                let taking = taking.baseAddress!
                let lights = scratch.baseAddress!
                let ratio = lights + 3 * width
                let power = ratio + 3 * width
                let tints = warmth > 0
                for row in rows {
                  let start = row * width
                  var taken = 0
                  for i in start..<start + width {
                    // Where no glow reaches (or the blur's rounding leaves a trace far below a
                    // level), the pixel keeps its exact value rather than going through the round trip.
                    guard max(gr[i], gg[i], gb[i]) > 1e-6 else { continue }
                    let light = linear(r[i], g[i], b[i], decoding)
                    // (1 − Y)²: midtones (Y 0.2, about sRGB 0.48) take 64% of the glow, a highlight
                    // at sRGB 0.9 (Y 0.79) under 5%. White (or past it, from an overflowing grade)
                    // takes none and keeps its values.
                    guard luma(light) < 1 else { continue }
                    taking[taken] = i
                    (lights[3 * taken], lights[3 * taken + 1], lights[3 * taken + 2]) = (light.x, light.y, light.z)
                    if tints {
                      let c = simd_max(SIMD3(gr[i], gg[i], gb[i]), .zero)
                      // `tint` doesn't use the powers where Y is this small.
                      let luminance = luma(c)
                      let y = luminance > 1e-9 ? luminance : 1
                      (ratio[3 * taken], ratio[3 * taken + 1], ratio[3 * taken + 2]) = (c.x / y, c.y / y, c.z / y)
                    }
                    taken += 1
                  }
                  guard taken > 0 else { continue }
                  if tints {
                    var n = Int32(3 * taken)
                    var exponent = 1 - warmth
                    vvpowsf(power, &exponent, ratio, &n)
                  }
                  for k in 0..<taken {
                    let i = taking[k]
                    let light = SIMD3(lights[3 * k], lights[3 * k + 1], lights[3 * k + 2])
                    let dark = max(1 - luma(light), 0)
                    let receive = dark * dark
                    let powers = tints ? SIMD3(power[3 * k], power[3 * k + 1], power[3 * k + 2]) : .one
                    let out = light + amount * receive * tint(SIMD3(gr[i], gg[i], gb[i]), warmth: warmth, warmPower: warmPower, powers: powers)
                    r[i] += 255 * (Transfer.encode(out.x, encoding) - Transfer.encode(light.x, encoding))
                    g[i] += 255 * (Transfer.encode(out.y, encoding) - Transfer.encode(light.y, encoding))
                    b[i] += 255 * (Transfer.encode(out.z, encoding) - Transfer.encode(light.z, encoding))
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  /// Linear glow `color` moved toward `warmLinear` by `warmth` (`warmPower` is warmLinear to that
  /// power), as the type's step 3 describes.
  static func tint(_ color: SIMD3<Float>, warmth: Float, warmPower: SIMD3<Float>) -> SIMD3<Float> {
    let c = simd_max(color, .zero)
    let y = luma(c)
    guard y > 1e-9 else { return c }
    let keep = 1 - warmth
    let powers = SIMD3(Foundation.pow(c.x / y, keep), Foundation.pow(c.y / y, keep), Foundation.pow(c.z / y, keep))
    return tint(color, warmth: warmth, warmPower: warmPower, powers: powers)
  }

  /// `tint` with `powers`, (c / Y)^(1 − warmth) per channel of the clamped color, taken
  /// beforehand (`apply` takes a row's together).
  @inline(__always) static func tint(_ color: SIMD3<Float>, warmth: Float, warmPower: SIMD3<Float>, powers: SIMD3<Float>) -> SIMD3<Float> {
    // The blur's rounding can leave a trace below zero, which a power would turn into NaN.
    let c = simd_max(color, .zero)
    let y = luma(c)
    guard warmth > 0, y > 1e-9 else { return c }
    let t = y * powers * warmPower
    let ty = luma(t)
    guard ty > 1e-12 else { return t }
    let restore = y / ty
    let cap = t.x > 0 ? maxRed * y / t.x : restore
    return t * min(restore, cap)
  }

  /// Three new planes of `count` pixels, which `fill` must write every one of.
  static func newPlanes(
    count: Int, _ fill: (_ r: UnsafeMutablePointer<Float>, _ g: UnsafeMutablePointer<Float>, _ b: UnsafeMutablePointer<Float>) -> Void
  ) -> [[Float]] {
    var g = [Float](), b = [Float]()
    let r = [Float](unsafeUninitializedCapacity: count) { r, rCount in
      g = [Float](unsafeUninitializedCapacity: count) { g, gCount in
        b = [Float](unsafeUninitializedCapacity: count) { b, bCount in
          fill(r.baseAddress!, g.baseAddress!, b.baseAddress!)
          bCount = count
        }
        gCount = count
      }
      rCount = count
    }
    return [r, g, b]
  }

  /// Rec. 709 luminance of linear light (the weights for linear values; `Grade.luma`'s Rec. 601
  /// ones are grain.py's, for gamma-encoded values).
  @inline(__always) static func luma(_ c: SIMD3<Float>) -> Float {
    0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
  }

  /// A pixel's 0–255 sRGB values as linear light, clamped to 0–1 first: values past white from an
  /// overflowing grade would otherwise emit without bound. From `Transfer`'s table, `decoding`.
  @inline(__always) static func linear(_ r: Float, _ g: Float, _ b: Float, _ decoding: UnsafePointer<Float>) -> SIMD3<Float> {
    SIMD3(Transfer.decode(r, decoding), Transfer.decode(g, decoding), Transfer.decode(b, decoding))
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

  /// The sRGB transfer function both ways as tables of `size + 1` entries, read with linear
  /// interpolation: within a hundredth of a level of the formulas (`linearToSrgb` steepest just
  /// past its linear toe), against a `pow` call each.
  enum Transfer {
    static let size = 4096
    /// `srgbToLinear` at levels 0, 255 / size, … 255. Made once and kept for the app's life, so
    /// the loops read it with no checks.
    nonisolated(unsafe) static let decoding = table { srgbToLinear($0) }
    /// `linearToSrgb` at 0, 1 / size, … 1.
    nonisolated(unsafe) static let encoding = table { $0 == 1 ? 1 : linearToSrgb($0) }

    private static func table(_ f: (Double) -> Double) -> UnsafePointer<Float> {
      let table = UnsafeMutablePointer<Float>.allocate(capacity: size + 1)
      for i in 0...size { table[i] = Float(f(Double(i) / Double(size))) }
      return UnsafePointer(table)
    }

    /// `srgbToLinear(level / 255)` from `decoding`: a 0–255 level (clamped; NaN as 0) to linear
    /// light.
    @inline(__always) static func decode(_ level: Float, _ decoding: UnsafePointer<Float>) -> Float {
      read(decoding, level * (Float(size) / 255))
    }

    /// `linearToSrgb(value)` from `encoding`: linear light (clamped to 0–1) to encoded 0–1, white
    /// exactly 1. NaN gives 1, as `linearToSrgb` does (the sanitized planes have none).
    @inline(__always) static func encode(_ value: Float, _ encoding: UnsafePointer<Float>) -> Float {
      guard value < 1 else { return 1 }
      return read(encoding, value * Float(size))
    }

    /// `table` at `position` (in entries), interpolated.
    @inline(__always) private static func read(_ table: UnsafePointer<Float>, _ position: Float) -> Float {
      let t = position > 0 ? (position < Float(size) ? position : Float(size)) : 0
      let i = min(Int(t), size - 1)
      let low = table[i]
      return low + (t - Float(i)) * (table[i + 1] - low)
    }

    /// The formulas in Double, for the tables.
    private static func srgbToLinear(_ c: Double) -> Double {
      c <= 0.04045 ? c / 12.92 : Foundation.pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ c: Double) -> Double {
      c <= 0.0031308 ? 12.92 * c : 1.055 * Foundation.pow(c, 1 / 2.4) - 0.055
    }
  }
}
