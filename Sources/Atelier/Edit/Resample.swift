import Foundation

/// Pillow's bicubic resize, ported from its `Resample.c` (`ImagingResample`) so grain fields and
/// grain.py's 512-wide statistics come out as the script's `Image.resize(..., BICUBIC)` makes
/// them: a separable two-pass filter, horizontal then vertical, with the cubic convolution kernel
/// at a = −0.5 (`bicubic_filter`), its support widened by the scale when shrinking, each output
/// pixel centred on the input at `(x + 0.5) × scale`, and each output's weights normalised to sum
/// to 1 (`precompute_coeffs`). A pass is skipped when that side keeps its size, as Pillow does.
///
/// Mode "F" planes (Float32) accumulate in Float64 and store Float32 between and after the passes
/// (`ImagingResampleHorizontal_32bpc`); 8-bit RGB uses Pillow's fixed-point weights
/// (`normalize_coeffs_8bpc`, 22 fraction bits) and clips to a byte after each pass, so the
/// numbers match bit for bit. Not vImage, whose kernel and edges differ.
///
/// Every output pixel depends only on its own index, so an output window (`Region`, in the full
/// output's pixels) computes exactly that part of the full resize: the 100% view's grain is the
/// full render's, cut out.
nonisolated enum Resample {
  /// A part of a resize's output, in output pixels.
  struct Region: Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }

    static func whole(width: Int, height: Int) -> Region { Region(x: 0, y: 0, width: width, height: height) }
  }

  /// Pillow's `bicubic_filter` (a = −0.5), support 2.
  static func bicubic(_ x: Double) -> Double {
    let a = -0.5
    let x = abs(x)
    if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
    if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
    return 0
  }

  /// One pass's weights for some of its outputs (`precompute_coeffs`): output `i` of `outputs`
  /// reads `count[i]` inputs from `first[i]`, with weights `weights[i * size ..< i * size + count[i]]`.
  struct Coefficients {
    var size: Int
    var first: [Int]
    var count: [Int]
    var weights: [Double]

    /// Pillow's coefficients for resizing `inSize` to `outSize`, at the outputs `outputs`.
    init(inSize: Int, outSize: Int, outputs: Range<Int>) {
      // `(double)(in1 - in0) / outSize` with the box (0, inSize).
      let scale = Double(inSize) / Double(outSize)
      let filterScale = max(scale, 1)
      let support = 2 * filterScale
      size = Int(support.rounded(.up)) * 2 + 1
      first = []
      count = []
      weights = [Double](repeating: 0, count: outputs.count * size)
      first.reserveCapacity(outputs.count)
      count.reserveCapacity(outputs.count)
      let ss = 1 / filterScale
      for (i, xx) in outputs.enumerated() {
        let center = (Double(xx) + 0.5) * scale
        // C's (int) casts truncate toward zero.
        let xmin = max(Int(center - support + 0.5), 0)
        let n = max(min(Int(center + support + 0.5), inSize) - xmin, 0)
        var total = 0.0
        for x in 0..<n {
          let w = Resample.bicubic((Double(x + xmin) - center + 0.5) * ss)
          weights[i * size + x] = w
          total += w
        }
        if total != 0 {
          for x in 0..<n { weights[i * size + x] /= total }
        }
        first.append(xmin)
        count.append(n)
      }
    }

    /// The weights as Pillow's 8-bit passes use them (`normalize_coeffs_8bpc`).
    var fixedPoint: [Int32] {
      let one = Double(1 << Resample.precisionBits)
      return weights.map { $0 < 0 ? Int32(-0.5 + $0 * one) : Int32(0.5 + $0 * one) }
    }
  }

  /// Pillow's `PRECISION_BITS`, 32 − 8 − 2.
  static let precisionBits = 22

  /// A Float32 plane (`width` × `height`, row-major) resized to `newWidth` × `newHeight`, as
  /// `Image.fromarray(a, mode="F").resize((newWidth, newHeight), Image.BICUBIC)` (grain.py's
  /// `resize_float`), or only the `region` of that output. The result is `region`'s size; a
  /// region not inside the output gives zeros.
  static func resize(
    _ plane: [Float], width: Int, height: Int, toWidth newWidth: Int, height newHeight: Int, region: Region? = nil
  ) -> [Float] {
    let region = region ?? .whole(width: newWidth, height: newHeight)
    guard plane.count == width * height else { return [Float](repeating: 0, count: max(region.width, 0) * max(region.height, 0)) }
    return plane.withUnsafeBufferPointer { input in
      let input = input
      return resize(width: width, height: height, toWidth: newWidth, height: newHeight, region: region) { y, columns, out in
        for x in columns { out[x - columns.lowerBound] = input[y * width + x] }
      }
    }
  }

  /// `resize` of a plane made a row at a time: `row(y, columns, out)` writes the input's row
  /// `y`, columns `columns`, to `out[0 ..< columns.count]`. Only the rows and columns the region
  /// reads are asked for (each once, from any thread), so a big plane that's cheap to make row by
  /// row, a noise field, is never held whole. The same numbers as `resize` of the whole plane.
  static func resize(
    width: Int, height: Int, toWidth newWidth: Int, height newHeight: Int, region: Region? = nil,
    row: (_ y: Int, _ columns: Range<Int>, _ out: UnsafeMutablePointer<Float>) -> Void
  ) -> [Float] {
    let region = region ?? .whole(width: newWidth, height: newHeight)
    let zeros = [Float](repeating: 0, count: max(region.width, 0) * max(region.height, 0))
    guard width > 0, height > 0, newWidth > 0, newHeight > 0, region.width > 0, region.height > 0, region.x >= 0, region.y >= 0,
          region.x + region.width <= newWidth, region.y + region.height <= newHeight
    else { return zeros }
    let columns = region.x..<region.x + region.width
    let rows = region.y..<region.y + region.height
    let horizontal = newWidth != width ? Coefficients(inSize: width, outSize: newWidth, outputs: columns) : nil
    let vertical = newHeight != height ? Coefficients(inSize: height, outSize: newHeight, outputs: rows) : nil
    // The input rows the vertical pass reads (Pillow's ybox_first ... ybox_last).
    let firstRow = vertical.map { $0.first[0] } ?? rows.lowerBound
    let lastRow = vertical.map { $0.first[rows.count - 1] + $0.count[rows.count - 1] } ?? rows.upperBound
    let tempRows = lastRow - firstRow
    let outWidth = region.width
    // The input columns the horizontal pass reads.
    let inColumns: Range<Int> = horizontal.map { h in
      let low = h.first.min() ?? 0
      let high = zip(h.first, h.count).map { $0 + $1 }.max() ?? low
      return low..<max(high, low)
    } ?? columns
    guard tempRows > 0 else { return zeros }

    // Horizontal pass: input rows firstRow..<lastRow, output columns `columns`.
    var temp = [Float](repeating: 0, count: tempRows * outWidth)
    temp.withUnsafeMutableBufferPointer { output in
      let output = output
      DispatchQueue.concurrentPerform(iterations: tempRows) { index in
        withUnsafeTemporaryAllocation(of: Float.self, capacity: max(inColumns.count, 1)) { line in
          let line = line.baseAddress!
          row(index + firstRow, inColumns, line)
          let target = index * outWidth
          if let h = horizontal {
            h.weights.withUnsafeBufferPointer { k in
              for i in 0..<outWidth {
                let start = h.first[i] - inColumns.lowerBound
                let base = i * h.size
                var ss = 0.0
                for x in 0..<h.count[i] { ss += Double(line[start + x]) * k[base + x] }
                output[target + i] = Float(ss)
              }
            }
          } else {
            for i in 0..<outWidth { output[target + i] = line[i] }
          }
        }
      }
    }
    guard let v = vertical else { return temp }

    // Vertical pass.
    var out = [Float](repeating: 0, count: region.height * outWidth)
    temp.withUnsafeBufferPointer { input in
      out.withUnsafeMutableBufferPointer { output in
        v.weights.withUnsafeBufferPointer { k in
          let input = input
          let output = output
          let k = k
          DispatchQueue.concurrentPerform(iterations: region.height) { j in
            let start = v.first[j] - firstRow
            let base = j * v.size
            let n = v.count[j]
            let target = j * outWidth
            for i in 0..<outWidth {
              var ss = 0.0
              for y in 0..<n { ss += Double(input[(start + y) * outWidth + i]) * k[base + y] }
              output[target + i] = Float(ss)
            }
          }
        }
      }
    }
    return out
  }

  /// Interleaved 8-bit RGB (`width` × `height` × 3) resized as Pillow resizes an "RGB" image with
  /// BICUBIC: fixed-point weights, rounding by adding half before the shift, a clip to 0–255
  /// after each pass (`ImagingResampleHorizontal_8bpc`, `ImagingResampleVertical_8bpc`).
  static func resizeRGB8(_ pixels: [UInt8], width: Int, height: Int, toWidth newWidth: Int, height newHeight: Int) -> [UInt8] {
    guard width > 0, height > 0, newWidth > 0, newHeight > 0, pixels.count == width * height * 3 else { return [] }
    if newWidth == width, newHeight == height { return pixels }
    let horizontal = newWidth != width ? Coefficients(inSize: width, outSize: newWidth, outputs: 0..<newWidth) : nil
    let vertical = newHeight != height ? Coefficients(inSize: height, outSize: newHeight, outputs: 0..<newHeight) : nil
    let half = Int32(1 << (precisionBits - 1))
    let bits = Int32(precisionBits)
    @Sendable func clip8(_ value: Int32) -> UInt8 {
      if value >= Int32(1 << 30) { return 255 }
      if value <= 0 { return 0 }
      return UInt8(value >> bits)
    }
    let firstRow = vertical.map { $0.first[0] } ?? 0
    let lastRow = vertical.map { $0.first[newHeight - 1] + $0.count[newHeight - 1] } ?? height
    let tempRows = lastRow - firstRow

    var temp: [UInt8]
    if let h = horizontal {
      let k = h.fixedPoint
      temp = [UInt8](repeating: 0, count: tempRows * newWidth * 3)
      pixels.withUnsafeBufferPointer { input in
        temp.withUnsafeMutableBufferPointer { output in
          let input = input
          let output = output
          DispatchQueue.concurrentPerform(iterations: tempRows) { row in
            let source = (row + firstRow) * width * 3
            let target = row * newWidth * 3
            for i in 0..<newWidth {
              var s0 = half, s1 = half, s2 = half
              let start = h.first[i]
              for x in 0..<h.count[i] {
                let w = k[i * h.size + x]
                let p = source + (start + x) * 3
                s0 &+= Int32(input[p]) &* w
                s1 &+= Int32(input[p + 1]) &* w
                s2 &+= Int32(input[p + 2]) &* w
              }
              output[target + i * 3] = clip8(s0)
              output[target + i * 3 + 1] = clip8(s1)
              output[target + i * 3 + 2] = clip8(s2)
            }
          }
        }
      }
    } else {
      temp = Array(pixels[firstRow * width * 3..<lastRow * width * 3])
    }
    guard let v = vertical else { return temp }

    let k = v.fixedPoint
    var out = [UInt8](repeating: 0, count: newHeight * newWidth * 3)
    let rowLength = newWidth * 3
    temp.withUnsafeBufferPointer { input in
      out.withUnsafeMutableBufferPointer { output in
        let input = input
        let output = output
        DispatchQueue.concurrentPerform(iterations: newHeight) { j in
          let start = v.first[j] - firstRow
          let target = j * rowLength
          for i in 0..<rowLength {
            var ss = half
            for y in 0..<v.count[j] { ss &+= Int32(input[(start + y) * rowLength + i]) &* k[j * v.size + y] }
            output[target + i] = clip8(ss)
          }
        }
      }
    }
    return out
  }
}
