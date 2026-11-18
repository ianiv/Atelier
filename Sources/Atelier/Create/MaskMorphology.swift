import CoreGraphics
import Foundation

/// Growing and shrinking a mask by a number of pixels, with a round element: what "expand the
/// selection" does in an image editor. A `CanvasMask` is hard-edged (`CanvasMask.coverage`), so
/// this moves its edge; softness is Mask Blur's.
nonisolated enum MaskMorphology {
  /// `coverage` (one byte per pixel, top row first, painted where not 0) with its painted area
  /// grown by `pixels` (dilated) or, when negative, shrunk (eroded); 0 gives it back as 255 / 0.
  /// The element is a disc: a pixel is painted when a painted one lies within `pixels` of it,
  /// centre to centre, and stays painted when no unpainted one does. The distances are exact (a
  /// Euclidean distance transform, thresholded), worked out only over the painted bounds padded by
  /// the radius, which is all that can change. Shrinking counts what's outside the image as
  /// painted, so a mask touching an edge doesn't draw back from it.
  static func grown(_ coverage: [UInt8], width: Int, height: Int, by pixels: Int) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: max(width, 0) * max(height, 0))
    guard width > 0, height > 0, coverage.count >= width * height else { return result }
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
      let row = y * width
      for x in 0..<width where coverage[row + x] != 0 {
        result[row + x] = 255
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        maxY = y
      }
    }
    let radius = abs(pixels)
    guard maxX >= 0, radius > 0 else { return result }
    // The window: nothing farther than the radius from the painted pixels changes.
    let x0 = max(minX - radius, 0), y0 = max(minY - radius, 0)
    let x1 = min(maxX + radius, width - 1), y1 = min(maxY + radius, height - 1)
    let w = x1 - x0 + 1, h = y1 - y0 + 1
    let grows = pixels > 0
    // Growing measures from the painted pixels, shrinking from the unpainted ones.
    var seeds = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
      let row = (y + y0) * width + x0
      for x in 0..<w { seeds[y * w + x] = (result[row + x] != 0) == grows }
    }
    let near = within(radius, of: seeds, width: w, height: h)
    for y in 0..<h {
      let row = (y + y0) * width + x0
      for x in 0..<w where near[y * w + x] { result[row + x] = grows ? 255 : 0 }
    }
    return result
  }

  /// Which pixels have a seed within `radius` of them (centre to centre), by the two-pass exact
  /// squared distance transform (Felzenszwalb and Huttenlocher, "Distance Transforms of Sampled
  /// Functions"): the distance to the nearest seed up and down each column, then along each row the
  /// lower envelope of the parabolas those distances make.
  private static func within(_ radius: Int, of seeds: [Bool], width: Int, height: Int) -> [Bool] {
    // Farther than the radius is all that matters about a column distance beyond it.
    let far = Int32(radius + 1)
    var column = [Int32](repeating: far, count: width * height)
    for x in 0..<width {
      var distance = far
      for y in 0..<height {
        distance = seeds[y * width + x] ? 0 : min(distance + 1, far)
        column[y * width + x] = distance
      }
      distance = far
      for y in (0..<height).reversed() {
        distance = seeds[y * width + x] ? 0 : min(distance + 1, far)
        if distance < column[y * width + x] { column[y * width + x] = distance }
      }
    }
    var result = [Bool](repeating: false, count: width * height)
    // The envelope: parabola `vertex[k]` is the lowest from `start[k]` to `start[k + 1]`.
    var vertex = [Int](repeating: 0, count: width)
    var start = [Double](repeating: 0, count: width + 1)
    let limit = radius * radius
    for y in 0..<height {
      let row = y * width
      var last = -1
      // A column with no seed within the radius can't bring any pixel within it.
      for x in 0..<width where column[row + x] < far {
        let fx = Int(column[row + x]) * Int(column[row + x])
        var crossing = -Double.infinity
        while last >= 0 {
          let p = vertex[last]
          let fp = Int(column[row + p]) * Int(column[row + p])
          crossing = Double(fx + x * x - fp - p * p) / Double(2 * (x - p))
          if crossing > start[last] { break }
          last -= 1
          crossing = -Double.infinity
        }
        last += 1
        vertex[last] = x
        start[last] = crossing
        start[last + 1] = .infinity
      }
      guard last >= 0 else { continue }
      var k = 0
      for x in 0..<width {
        while start[k + 1] < Double(x) { k += 1 }
        let p = vertex[k]
        let d = Int(column[row + p])
        result[row + x] = (x - p) * (x - p) + d * d <= limit
      }
    }
    return result
  }
}

nonisolated extension CanvasMask {
  /// What the mask paints over a `width` × `height` image, grown by `pixels` (shrunk when
  /// negative; `MaskMorphology.grown`), as a mask of one bitmap stroke. Nil when nothing is left.
  func grown(by pixels: Int, width: Int, height: Int) -> CanvasMask? {
    let grown = MaskMorphology.grown(coverage(width: width, height: height), width: width, height: height, by: pixels)
    guard grown.contains(255), let png = Self.grayPNG(grown, width: width, height: height) else { return nil }
    return CanvasMask(strokes: [Stroke(kind: .bitmap, points: [.zero], bitmap: png)])
  }
}
