import Foundation

/// grain.py's Gaussian blur, ported line for line so the Edit screen's blur, halation and
/// Match Reference measure and soften as the script does: `gauss` is three box blurs per axis
/// (`box_sizes`, the widths whose passes best approximate the Gaussian), each `box_blur_axis` an
/// edge-clamped running mean taken as differences of a Float64 cumulative sum, as numpy's
/// `cumsum(..., dtype=float64)` computes it, then rounded to Float32. The same sum order makes
/// the same numbers, and the cost doesn't depend on the radius.
///
/// Planes are row-major Float32, `width` × `height`; rows (and columns) run across the cores.
nonisolated enum Blur {
  /// grain.py's `box_sizes(sigma, n)`: odd box widths whose `n` passes approximate a Gaussian of
  /// `sigma`. Python's `round` on a numpy float rounds halves to even, as here.
  static func boxSizes(sigma: Double, n: Int = 3) -> [Int] {
    let ideal = (12 * sigma * sigma / Double(n) + 1).squareRoot()
    var lower = Int(ideal.rounded(.down))
    if lower % 2 == 0 { lower -= 1 }
    let upper = lower + 2
    let dn = Double(n)
    let dl = Double(lower)
    let m = ((12 * sigma * sigma - dn * dl * dl - 4 * dn * dl - 3 * dn) / (-4 * dl - 4)).rounded(.toNearestOrEven)
    return (0..<n).map { Double($0) < m ? lower : upper }
  }

  /// grain.py's `box_blur_axis` along x (`horizontal`, numpy axis 1) or y (axis 0): the mean of
  /// the `2r + 1` pixels around each, edges clamped. Radius below 1 returns the plane as it is.
  ///
  /// Each line's sums are the scalar ones, added in the same order; only the lines are taken
  /// side by side so the additions of different lines overlap: eight rows at a time, a row per
  /// SIMD lane, along x, and down the rows `columnsPerTask` columns at a time along y (reading
  /// rows, not columns with a stride). Lines a cancel skips are zeros.
  static func boxBlur(
    _ plane: [Float], width: Int, height: Int, radius r: Int, horizontal: Bool, cancel: EditPipeline.Cancel = .never
  ) -> [Float] {
    guard r >= 1, width > 0, height > 0, plane.count == width * height else { return plane }
    let count = plane.count
    return [Float](unsafeUninitializedCapacity: count) { output, initialized in
      plane.withUnsafeBufferPointer { input in
        let input = input.baseAddress!
        let output = output.baseAddress!
        if horizontal {
          rowsAlong(input, output, width: width, height: height, radius: r, cancel: cancel)
        } else {
          rowsDown(input, output, width: width, height: height, radius: r, cancel: cancel)
        }
      }
      initialized = count
    }
  }

  /// The columns each task of the vertical pass sums side by side.
  static let columnsPerTask = 32

  /// `boxBlur` along x, `input` to `output`.
  private static func rowsAlong(
    _ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, width: Int, height: Int, radius r: Int, cancel: EditPipeline.Cancel
  ) {
    typealias Lanes = SIMD8<Double>
    let window = Double(2 * r + 1)
    // The padded line's cumulative sum: r + 1 copies of the first pixel, the line, r of the last.
    let padded = width + 2 * r + 1
    let groups = (height + 7) / 8
    let groupsPerTask = max(1, groups / (ProcessInfo.processInfo.activeProcessorCount * 4))
    let tasks = (groups + groupsPerTask - 1) / groupsPerTask
    DispatchQueue.concurrentPerform(iterations: tasks) { task in
      let groups = task * groupsPerTask..<min((task + 1) * groupsPerTask, groups)
      guard !cancel.isCancelled else {
        let rows = groups.lowerBound * 8..<min(groups.upperBound * 8, height)
        (output + rows.lowerBound * width).update(repeating: 0, count: rows.count * width)
        return
      }
      withUnsafeTemporaryAllocation(of: Lanes.self, capacity: padded) { sums in
        let sums = sums.baseAddress!
        for group in groups {
          let top = group * 8
          let lanes = min(8, height - top)
          var total = Lanes()
          var k = 0
          let first = column(input, x: 0, top: top, lanes: lanes, width: width)
          while k < r + 1 {
            total += first
            sums[k] = total
            k += 1
          }
          for x in 0..<width {
            total += column(input, x: x, top: top, lanes: lanes, width: width)
            sums[k] = total
            k += 1
          }
          let last = column(input, x: width - 1, top: top, lanes: lanes, width: width)
          while k < padded {
            total += last
            sums[k] = total
            k += 1
          }
          let divisor = Lanes(repeating: window)
          for i in 0..<width {
            let mean = SIMD8<Float>((sums[i + 2 * r + 1] - sums[i]) / divisor)
            for lane in 0..<lanes { output[(top + lane) * width + i] = mean[lane] }
          }
        }
      }
    }
  }

  /// Column `x` of the eight rows from `top`, a row per lane. A short last group (`lanes` rows)
  /// repeats its last row in the lanes past it, which aren't written.
  @inline(__always) private static func column(_ input: UnsafePointer<Float>, x: Int, top: Int, lanes: Int, width: Int) -> SIMD8<Double> {
    var v = SIMD8<Double>()
    for lane in 0..<8 { v[lane] = Double(input[(top + min(lane, lanes - 1)) * width + x]) }
    return v
  }

  /// `boxBlur` along y, `input` to `output`: each task runs down the rows, keeping the last
  /// `2r + 2` rows of its columns' cumulative sums (all a mean needs).
  private static func rowsDown(
    _ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, width: Int, height: Int, radius r: Int, cancel: EditPipeline.Cancel
  ) {
    let window = Double(2 * r + 1)
    let padded = height + 2 * r + 1
    let kept = 2 * r + 2
    let columns = columnsPerTask
    let tasks = (width + columns - 1) / columns
    DispatchQueue.concurrentPerform(iterations: tasks) { task in
      let x0 = task * columns
      let n = min(columns, width - x0)
      guard !cancel.isCancelled else {
        for y in 0..<height { (output + y * width + x0).update(repeating: 0, count: n) }
        return
      }
      withUnsafeTemporaryAllocation(of: Double.self, capacity: (kept + 1) * columns) { buffer in
        let ring = buffer.baseAddress!
        let total = ring + kept * columns
        total.update(repeating: 0, count: columns)
        for k in 0..<padded {
          let source = input + min(max(k - (r + 1), 0), height - 1) * width + x0
          let sums = ring + (k % kept) * columns
          for c in 0..<n {
            total[c] += Double(source[c])
            sums[c] = total[c]
          }
          guard k >= 2 * r + 1 else { continue }
          let i = k - (2 * r + 1)
          let before = ring + (i % kept) * columns
          let out = output + i * width + x0
          for c in 0..<n { out[c] = Float((sums[c] - before[c]) / window) }
        }
      }
    }
  }

  /// grain.py's `gauss(a, sigma)` for one plane: for each of `boxSizes(sigma)`, a box blur of
  /// radius `(size − 1) / 2` along x, then y. Below sigma 0.3 the plane is returned as it is.
  static func gauss(_ plane: [Float], width: Int, height: Int, sigma: Double, cancel: EditPipeline.Cancel = .never) -> [Float] {
    guard sigma >= 0.3 else { return plane }
    var out = plane
    for size in boxSizes(sigma: sigma) {
      // Each pass makes a whole new plane: none once cancelled.
      guard !cancel.isCancelled else { return out }
      let r = (size - 1) / 2
      out = boxBlur(out, width: width, height: height, radius: r, horizontal: true, cancel: cancel)
      out = boxBlur(out, width: width, height: height, radius: r, horizontal: false, cancel: cancel)
    }
    return out
  }

  /// `gauss` for each plane of an image (grain.py's HxWxC case, which blurs channels apart).
  static func gauss(_ planes: [[Float]], width: Int, height: Int, sigma: Double, cancel: EditPipeline.Cancel = .never) -> [[Float]] {
    planes.map { gauss($0, width: width, height: height, sigma: sigma, cancel: cancel) }
  }
}
