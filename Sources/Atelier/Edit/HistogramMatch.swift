import CoreGraphics
import Foundation

/// Pipeline step 4: histogram (CDF) matching to the match target's cumulative histograms
/// (`Edit.HistogramTable`), by `EditOptions.Histogram`'s amount and space.
///
/// Each level v goes to the level of the target whose share of pixels below it is the share
/// below v in the image (`curve`, scikit-image's interpolated CDF match): an image matched to
/// its own histogram keeps every value, and the result is a smooth curve rather than steps.
/// Float values between levels interpolate the curve.
///
/// - `.luma`: the curve is built and applied on Rec. 601 luma (grain.py's `luma`), and each
///   pixel's red, green and blue are scaled together by new luma / old luma, so their ratios,
///   hence hue and HSV saturation, stay the image's own (until the end clips them). Pixels darker
///   than one level get the luma difference added instead, which can't divide by nothing.
/// - `.rgb`: red, green and blue each matched to the target's own channel; this moves hues.
///
/// The amount blends: value + amount × (matched − value).
nonisolated enum HistogramMatch {
  /// Levels.
  static let levels = 256

  // MARK: Measuring

  /// The cumulative histograms of `image`'s visible pixels; nil when it can't be read.
  static func table(of image: CGImage) -> Edit.HistogramTable? {
    guard let planes = EditPipeline.Planes(image) else { return nil }
    return table(of: planes)
  }

  /// The cumulative histograms of the planes' pixels that aren't fully transparent, each value
  /// rounded to its nearest level (luma from the unrounded values). An image with no visible
  /// pixels gives the CDFs of an even spread, which matching to leaves an even image as it is.
  static func table(of planes: EditPipeline.Planes) -> Edit.HistogramTable {
    let count = min(planes.width * planes.height, planes.r.count, planes.g.count, planes.b.count)
    // Each band counts into its own four histograms, added up after.
    let bandSize = 65536
    let bands = max(1, (count + bandSize - 1) / bandSize)
    var counts = [Int](repeating: 0, count: bands * 4 * levels)
    @inline(__always) func level(_ value: Float) -> Int { value.isNaN ? 0 : Int(min(max(value, 0), 255) + 0.5) }
    planes.r.withUnsafeBufferPointer { r in
      planes.g.withUnsafeBufferPointer { g in
        planes.b.withUnsafeBufferPointer { b in
          planes.alpha.withUnsafeBufferPointer { alpha in
            counts.withUnsafeMutableBufferPointer { counts in
              let counts = counts.baseAddress!
              DispatchQueue.concurrentPerform(iterations: bands) { band in
                let histogram = counts + band * 4 * levels
                for index in band * bandSize..<min((band + 1) * bandSize, count) where index >= alpha.count || alpha[index] > 0 {
                  histogram[level(Grade.luma(r[index], g[index], b[index]))] += 1
                  histogram[levels + level(r[index])] += 1
                  histogram[2 * levels + level(g[index])] += 1
                  histogram[3 * levels + level(b[index])] += 1
                }
              }
            }
          }
        }
      }
    }
    var totals = [[Double]](repeating: [Double](repeating: 0, count: levels), count: 4)
    for band in 0..<bands {
      for channel in 0..<4 {
        for value in 0..<levels { totals[channel][value] += Double(counts[(band * 4 + channel) * levels + value]) }
      }
    }
    return Edit.HistogramTable(luma: cumulative(totals[0]), red: cumulative(totals[1]), green: cumulative(totals[2]), blue: cumulative(totals[3]))
  }

  /// Counts as a CDF from the share at level 0 up to 1; an even ramp when there are none.
  static func cumulative(_ counts: [Double]) -> [Double] {
    let total = counts.reduce(0, +)
    guard total > 0 else { return (0..<counts.count).map { Double($0 + 1) / Double(counts.count) } }
    var running = 0.0
    return counts.map {
      running += $0
      return running / total
    }
  }

  // MARK: Matching

  /// The curve taking each level of an image with CDF `source` to the level of `reference`
  /// with the same share below it, as scikit-image's `match_histograms` interpolates: only the
  /// levels each image has are used (each at its bin's middle share, so an image matched to its
  /// own histogram keeps every value), the target's inverted by linear interpolation between
  /// them, and the levels the image doesn't have filled in between their neighbours' (shifted
  /// alike beyond the first and last), so values between levels follow a smooth curve.
  static func curve(source: [Double], reference: [Double]) -> [Float] {
    let identity = (0..<levels).map(Float.init)
    guard source.count == levels, reference.count == levels else { return identity }
    /// The levels holding pixels, and the share below each one's middle.
    func occupied(_ cdf: [Double]) -> [(level: Int, share: Double)] {
      (0..<levels).compactMap { level in
        let below = level > 0 ? cdf[level - 1] : 0
        return cdf[level] > below ? (level, (below + cdf[level]) / 2) : nil
      }
    }
    let target = occupied(reference)
    let present = occupied(source)
    guard !target.isEmpty, !present.isEmpty else { return identity }
    var out = [Float](repeating: 0, count: levels)
    var k = 0
    for (level, share) in present {
      if share <= target[0].share {
        out[level] = Float(target[0].level)
      } else if share >= target[target.count - 1].share {
        out[level] = Float(target[target.count - 1].level)
      } else {
        // Shares rise with level, so the search goes on from the last one.
        while target[k + 1].share < share { k += 1 }
        let t = (share - target[k].share) / (target[k + 1].share - target[k].share)
        out[level] = Float(Double(target[k].level) + t * Double(target[k + 1].level - target[k].level))
      }
    }
    // Levels without pixels: between their neighbours, or shifted as the nearest one is.
    let first = present[0].level
    let last = present[present.count - 1].level
    for level in 0..<first { out[level] = Float(level) + out[first] - Float(first) }
    for level in last + 1..<levels { out[level] = Float(level) + out[last] - Float(last) }
    for (a, b) in zip(present, present.dropFirst()) where b.level > a.level + 1 {
      for level in a.level + 1..<b.level {
        let t = Float(level - a.level) / Float(b.level - a.level)
        out[level] = out[a.level] + t * (out[b.level] - out[a.level])
      }
    }
    return out
  }

  /// `planes` matched to `reference` by `histogram`'s amount and space. `source` is the planes'
  /// own table, measured here when it's nil (pass the whole image's when `planes` is a window of
  /// it). Nothing happens when `histogram.isIdentity`.
  static func apply(
    _ histogram: EditOptions.Histogram, to planes: inout EditPipeline.Planes, reference: Edit.HistogramTable,
    source: Edit.HistogramTable? = nil
  ) {
    guard !histogram.isIdentity else { return }
    let source = source ?? table(of: planes)
    let amount = Float(min(histogram.amount, 1))
    switch histogram.space {
    case .luma:
      let map = curve(source: source.luma, reference: reference.luma)
      planes.withPixelBands { range, r, g, b in
        for i in range {
          let y = Grade.luma(r[i], g[i], b[i])
          let target = y + amount * (mapped(y, map) - y)
          if y >= 1 {
            let k = target / y
            r[i] *= k
            g[i] *= k
            b[i] *= k
          } else {
            let d = target - y
            r[i] += d
            g[i] += d
            b[i] += d
          }
        }
      }
    case .rgb:
      let red = curve(source: source.red, reference: reference.red)
      let green = curve(source: source.green, reference: reference.green)
      let blue = curve(source: source.blue, reference: reference.blue)
      planes.withPixelBands { range, r, g, b in
        for i in range {
          r[i] += amount * (mapped(r[i], red) - r[i])
          g[i] += amount * (mapped(g[i], green) - g[i])
          b[i] += amount * (mapped(b[i], blue) - b[i])
        }
      }
    }
  }

  /// `value` through `curve`, interpolated between levels; beyond 0–255 (headroom from a
  /// brighter exposure, say) it carries on from the end level at slope 1, so values past white
  /// keep their distance from it. Not a number is 0.
  @inline(__always) static func mapped(_ value: Float, _ curve: [Float]) -> Float {
    guard value.isFinite else { return 0 }
    if value > 255 { return curve[levels - 1] + (value - 255) }
    if value < 0 { return curve[0] + value }
    let v = value
    let low = min(Int(v), levels - 2)
    let t = v - Float(low)
    return curve[low] + t * (curve[low + 1] - curve[low])
  }
}
