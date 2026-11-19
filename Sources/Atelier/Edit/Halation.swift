import Foundation

/// Pipeline step 8: film halation, the warm glow that light scattered back through film's base
/// spreads around bright highlights.
///
/// 1. Highlights: each pixel's color times a smooth knee of its Rec. 601 luma (0–1): 0 at or
///    below `threshold`, rising as a smoothstep to 1 at `threshold + knee` (`knee` is 0.15, or
///    what's left above the threshold if that's less). Nothing at or below the threshold glows.
/// 2. Spread: that blurred by `Blur.gauss` with sigma `radius` (full-size pixels, times the
///    render's scale).
/// 3. Tint: the glow's color moved toward film's red-orange (`warm`, scaled to the glow's own
///    luma, so warmth changes its color, not its strength) by `warmth`.
/// 4. Added back by screen: 255 − (255 − v)(255 − amount · glow)/255, which brightens toward
///    white without passing it (values already above white are left as they are).
nonisolated enum Halation {
  /// Film's halation color, red-orange, as RGB gains (Rec. 601 luma 0.551).
  static let warm = SIMD3<Float>(1, 0.4, 0.15)
  /// The knee's width, in luma.
  static let knee: Float = 0.15

  /// `planes` with `halation` added. `scale` is output pixels per full-size pixel (the render
  /// window's), which `radius` is multiplied by. Nothing happens when `halation.isIdentity`.
  static func apply(_ halation: EditOptions.Halation, to planes: inout EditPipeline.Planes, scale: Double = 1) {
    guard !halation.isIdentity, planes.width > 0, planes.height > 0 else { return }
    let width = planes.width
    let height = planes.height
    let threshold = Float(min(max(halation.threshold, 0), 1))
    let kneeTop = min(threshold + knee, 1)
    let span = max(kneeTop - threshold, 1e-4)
    // The highlights, as a copy of the planes keeping only what's above the knee.
    var source = planes
    var bright = [Bool](repeating: false, count: (height + 7) / 8 + 1)
    bright.withUnsafeMutableBufferPointer { bright in
      let bright = bright.baseAddress!
      source.withRowBands { rows, r, g, b in
        var found = false
        for i in rows.lowerBound * width..<rows.upperBound * width {
          let y = Grade.luma(r[i], g[i], b[i]) / 255
          guard y > threshold else {
            r[i] = 0
            g[i] = 0
            b[i] = 0
            continue
          }
          let s = min((y - threshold) / span, 1)
          let k = s * s * (3 - 2 * s)
          r[i] *= k
          g[i] *= k
          b[i] *= k
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
    let warm = warm / Grade.luma(warm.x, warm.y, warm.z)
    let amount = Float(min(max(halation.amount, 0), 1))
    glow[0].withUnsafeBufferPointer { gr in
      glow[1].withUnsafeBufferPointer { gg in
        glow[2].withUnsafeBufferPointer { gb in
          let gr = gr.baseAddress!
          let gg = gg.baseAddress!
          let gb = gb.baseAddress!
          planes.withPixelBands { range, r, g, b in
            for i in range {
              let own = SIMD3(gr[i], gg[i], gb[i])
              let tinted = warm * Grade.luma(own.x, own.y, own.z)
              let light = (own + warmth * (tinted - own)) * amount
              r[i] = screen(r[i], light.x)
              g[i] = screen(g[i], light.y)
              b[i] = screen(b[i], light.z)
            }
          }
        }
      }
    }
  }

  @inline(__always) static func screen(_ base: Float, _ light: Float) -> Float {
    guard light > 0, base < 255 else { return base }
    return 255 - (255 - base) * (255 - min(light, 255)) / 255
  }
}
