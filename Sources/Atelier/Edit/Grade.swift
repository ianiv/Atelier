import Foundation

/// The Edit screen's grade (pipeline step 6) and vignette (step 9), on `EditPipeline.Planes` in
/// grain.py's 0–255 float units, nothing clipped until the pipeline truncates at the end (as
/// grain.py's float array is only clipped when it's written out).
///
/// The grade runs in `EditOptions.Grade`'s order: exposure, temperature, tint, contrast,
/// saturation, vibrance. A control at 0 is skipped, not applied as nothing, so the defaults give
/// back the very same floats.
///
/// - Exposure: every channel times 2^exposure, grain.py's `a *= 2 ** s["expo"]`.
/// - Temperature: a white-balance gain on red and blue, green left alone: red times
///   2^(0.25·t), blue times 2^(−0.25·t), t = temperature/100. So 100 is red ×1.19 and blue
///   ×0.84, −100 the reverse.
/// - Tint: grain.py's formula exactly (`process`): green less tint/2, red and blue more tint/4
///   each, in 0–255 units, after the exposure as there.
/// - Contrast: each channel pushed from or pulled to mid grey (127.5) by 1 + contrast, so −1 is
///   flat grey and 1 doubles every distance from it.
/// - Saturation: each channel moved from or toward the pixel's Rec. 601 luma (grain.py's
///   `luma`) by 1 + saturation, so −1 is greyscale and the luma stays put.
/// - Vibrance: the same move, by vibrance times a weight that's 1 for a grey pixel and falls to
///   0 at full saturation ((max − min)/255), and is cut by up to 60% for skin (red ≥ green ≥ blue
///   with an HSV hue near 25°), so muted colors move most and faces don't go orange.
///
/// grain.py's exposure and tint are these two controls (`EditOptions.Grade.exposure`/`tint`);
/// the grain step doesn't apply them again.
///
/// The vignette is computed in full-size coordinates, so a window of the image (the 100% view)
/// gets the same darkening as that part of the full render.
nonisolated enum Grade {
  /// The temperature gain's stops at ±100: red and blue move ±0.25 stop.
  static let temperatureStops: Float = 0.25
  /// Contrast's pivot.
  static let midGrey: Float = 127.5
  /// How much of vibrance's push skin keeps out of (1 = all of it).
  static let skinProtection: Float = 0.6

  /// `planes` graded by `grade`. Nothing happens when it's `isIdentity`.
  static func apply(_ grade: EditOptions.Grade, to planes: inout EditPipeline.Planes) {
    guard !grade.isIdentity else { return }
    let exposure: Float = grade.exposure != 0 ? Float(pow(2, grade.exposure)) : 1
    let t = Float(grade.temperature / 100)
    let redGain = exposure * (t != 0 ? exp2(temperatureStops * t) : 1)
    let blueGain = exposure * (t != 0 ? exp2(-temperatureStops * t) : 1)
    let tint = Float(grade.tint)
    let contrast = Float(1 + grade.contrast)
    let saturation = Float(1 + grade.saturation)
    let vibrance = Float(grade.vibrance)
    let scales = exposure != 1 || t != 0
    let tints = tint != 0
    let contrasts = grade.contrast != 0
    let saturates = grade.saturation != 0
    let vibrant = vibrance != 0
    let midGrey = midGrey
    planes.withPixelBands { range, r, g, b in
      for i in range {
        var red = r[i]
        var green = g[i]
        var blue = b[i]
        if scales {
          red *= redGain
          green *= exposure
          blue *= blueGain
        }
        if tints {
          green -= tint * 0.5
          red += tint * 0.25
          blue += tint * 0.25
        }
        if contrasts {
          red = midGrey + (red - midGrey) * contrast
          green = midGrey + (green - midGrey) * contrast
          blue = midGrey + (blue - midGrey) * contrast
        }
        if saturates {
          let y = luma(red, green, blue)
          red = y + (red - y) * saturation
          green = y + (green - y) * saturation
          blue = y + (blue - y) * saturation
        }
        if vibrant {
          let factor = 1 + vibrance * vibranceWeight(red, green, blue)
          let y = luma(red, green, blue)
          red = y + (red - y) * factor
          green = y + (green - y) * factor
          blue = y + (blue - y) * factor
        }
        r[i] = red
        g[i] = green
        b[i] = blue
      }
    }
  }

  /// grain.py's `luma`: Rec. 601 weights.
  @inline(__always) static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
    0.299 * r + 0.587 * g + 0.114 * b
  }

  /// How strongly vibrance moves a pixel: 1 − its saturation, less `skinProtection` of that for
  /// skin tones.
  @inline(__always) static func vibranceWeight(_ r: Float, _ g: Float, _ b: Float) -> Float {
    let high = max(r, g, b)
    let low = min(r, g, b)
    let chroma = high - low
    var weight = 1 - min(max(chroma / 255, 0), 1)
    if r >= g, g >= b, chroma > 0 {
      // HSV hue for red ≥ green ≥ blue: 0° (red) to 60° (yellow).
      let hue = 60 * (g - b) / chroma
      let skin = max(0, 1 - abs(hue - 25) / 20)
      weight *= 1 - skinProtection * skin
    }
    return weight
  }

  // MARK: - Vignette

  /// `planes` vignetted by `vignette`. `fullWidth` × `fullHeight` is the whole image's size and
  /// `window` the part of it `planes` holds (nil when it's the whole image), so a window darkens
  /// exactly as that part of the full render does; the planes may be at the window's scale.
  ///
  /// The distance from the centre is elliptical, following the frame: 0 at the centre, 1 at
  /// the corners (`d = √((((x − cx)/cx)² + ((y − cy)/cy)²) / 2)`). The falloff is a smoothstep
  /// from `size` to `size + (1 − size) · softness` (softness 0 is a hard edge at `size`, 1 ramps
  /// all the way to the corners). A positive amount multiplies by 1 − amount · falloff (1 makes
  /// the corners black); a negative one blends toward white by −amount · falloff.
  static func vignette(
    _ vignette: EditOptions.Vignette, to planes: inout EditPipeline.Planes, fullWidth: Int, fullHeight: Int,
    window: EditPipeline.Window? = nil
  ) {
    guard !vignette.isIdentity, planes.width > 0, planes.height > 0, fullWidth > 0, fullHeight > 0 else { return }
    let window = window ?? .whole(width: fullWidth, height: fullHeight)
    let amount = Float(min(max(vignette.amount, -1), 1))
    let start = Float(min(max(vignette.size, 0), 1))
    let end = max(start + (1 - start) * Float(min(max(vignette.softness, 0), 1)), start + 1e-4)
    let cx = Float(fullWidth) / 2
    let cy = Float(fullHeight) / 2
    let width = planes.width
    // Output pixel centres in full-size pixels.
    let stepX = Float(window.width) / Float(planes.width)
    let stepY = Float(window.height) / Float(planes.height)
    let originX = Float(window.x)
    let originY = Float(window.y)
    planes.withRowBands { rows, r, g, b in
      for row in rows {
        let y = originY + (Float(row) + 0.5) * stepY
        let dy = (y - cy) / cy
        for column in 0..<width {
          let x = originX + (Float(column) + 0.5) * stepX
          let dx = (x - cx) / cx
          let d = ((dx * dx + dy * dy) / 2).squareRoot()
          let s = min(max((d - start) / (end - start), 0), 1)
          let falloff = s * s * (3 - 2 * s)
          guard falloff > 0 else { continue }
          let i = row * width + column
          if amount > 0 {
            let k = 1 - amount * falloff
            r[i] *= k
            g[i] *= k
            b[i] *= k
          } else {
            let k = -amount * falloff
            r[i] += (255 - r[i]) * k
            g[i] += (255 - g[i]) * k
            b[i] += (255 - b[i]) * k
          }
        }
      }
    }
  }
}

extension EditPipeline.Planes {
  /// Runs `body` on bands of rows across the cores, with the three planes' storage: `body` gets
  /// a band's rows and must touch only their pixels (`row * width + column`).
  nonisolated mutating func withRowBands(
    _ body: (_ rows: Range<Int>, _ r: UnsafeMutablePointer<Float>, _ g: UnsafeMutablePointer<Float>, _ b: UnsafeMutablePointer<Float>) -> Void
  ) {
    let height = height
    guard height > 0, width > 0, r.count >= width * height, g.count >= width * height, b.count >= width * height else { return }
    // A few bands per core, at least 8 rows each.
    let bandRows = max(8, height / (ProcessInfo.processInfo.activeProcessorCount * 4))
    let bands = (height + bandRows - 1) / bandRows
    r.withUnsafeMutableBufferPointer { r in
      g.withUnsafeMutableBufferPointer { g in
        b.withUnsafeMutableBufferPointer { b in
          let r = r.baseAddress!
          let g = g.baseAddress!
          let b = b.baseAddress!
          DispatchQueue.concurrentPerform(iterations: bands) { band in
            body(band * bandRows..<min((band + 1) * bandRows, height), r, g, b)
          }
        }
      }
    }
  }

  /// `withRowBands`, with `body` given each band's pixel indices instead of its rows.
  nonisolated mutating func withPixelBands(
    _ body: (_ pixels: Range<Int>, _ r: UnsafeMutablePointer<Float>, _ g: UnsafeMutablePointer<Float>, _ b: UnsafeMutablePointer<Float>) -> Void
  ) {
    let width = width
    withRowBands { rows, r, g, b in body(rows.lowerBound * width..<rows.upperBound * width, r, g, b) }
  }
}
