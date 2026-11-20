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
  static func boxBlur(
    _ plane: [Float], width: Int, height: Int, radius r: Int, horizontal: Bool, cancel: EditPipeline.Cancel = .never
  ) -> [Float] {
    guard r >= 1, width > 0, height > 0, plane.count == width * height else { return plane }
    var out = [Float](repeating: 0, count: plane.count)
    let lines = horizontal ? height : width
    let length = horizontal ? width : height
    // Between pixels on a line, and between lines.
    let stride = horizontal ? 1 : width
    let lineStride = horizontal ? width : 1
    let window = Double(2 * r + 1)
    // Columns are read with a stride; a few at a time per task keeps the cost of a task low.
    let chunk = horizontal ? 1 : 16
    let tasks = (lines + chunk - 1) / chunk
    plane.withUnsafeBufferPointer { input in
      out.withUnsafeMutableBufferPointer { output in
        let input = input
        let output = output
        DispatchQueue.concurrentPerform(iterations: tasks) { task in
          guard !cancel.isCancelled else { return }
          // The padded line's cumulative sum: r + 1 copies of the first pixel, the line, r of the last.
          var sums = [Double](repeating: 0, count: length + 2 * r + 1)
          for line in task * chunk..<min((task + 1) * chunk, lines) {
            let base = line * lineStride
            var total = 0.0
            for k in 0..<sums.count {
              let index = min(max(k - (r + 1), 0), length - 1)
              total += Double(input[base + index * stride])
              sums[k] = total
            }
            for i in 0..<length {
              output[base + i * stride] = Float((sums[i + 2 * r + 1] - sums[i]) / window)
            }
          }
        }
      }
    }
    return out
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
