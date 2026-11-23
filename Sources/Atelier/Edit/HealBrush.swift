import Foundation

/// The Heal tool's pixel work: each `Edit.HealStroke` copies the pixels at its offset over its
/// area and blends them in with a membrane (harmonic) correction, the reduced form of Pérez et
/// al.'s Poisson image editing (2003) known as mean-value or membrane cloning. The correction c
/// solves Δc = 0 inside the stroke with c = destination − source on its edge, so the result,
/// source + c, takes the source's texture and the destination's tone and shading at the edge,
/// with no seam: a feathered clone alone leaves a visible tone ring.
///
/// There's no model and no search for a source (the user picks it; each stroke stores its
/// offset), so a stroke renders the same forever. The work is the stroke's bounding box only,
/// never the image's: c is smooth, so it's solved coarse to fine (a few dozen relaxation sweeps
/// per level, starting from the coarser level's answer) and the cost grows with the stroke's
/// area. Pixels outside every stroke's box are left alone bit for bit.
nonisolated enum HealBrush {
  /// A rectangle of image pixels.
  struct Region: Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var count: Int { width * height }

    /// The smallest region holding both.
    func union(_ other: Region) -> Region {
      let x0 = min(x, other.x), y0 = min(y, other.y)
      let x1 = max(x + width, other.x + other.width), y1 = max(y + height, other.y + other.height)
      return Region(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
  }

  /// A region's pixels as Float RGB, 0–255 (the fourth lane unused, so a pixel is one SIMD
  /// value). What a stroke heals, rather than RGBA bytes, so frequency separation can later fill
  /// it with a band (the high band goes negative) and add the bands back.
  struct HealSurface: Sendable {
    var region: Region
    var pixels: [SIMD4<Float>]

    init(region: Region, pixels: [SIMD4<Float>]) {
      self.region = region
      self.pixels = pixels
    }

    /// `region` of tightly packed RGBA8 `rgba` (`width` × `height`), moved by `shift`, with
    /// pixels past the image's edges taken from the nearest edge pixel.
    init(rgba: UnsafeBufferPointer<UInt8>, width: Int, height: Int, region: Region, shift: SIMD2<Int> = .zero) {
      self.region = region
      var pixels = [SIMD4<Float>](repeating: .zero, count: region.count)
      pixels.withUnsafeMutableBufferPointer { out in
        for row in 0..<region.height {
          let y = min(max(region.y + row + shift.y, 0), height - 1)
          for column in 0..<region.width {
            let x = min(max(region.x + column + shift.x, 0), width - 1)
            let index = (y * width + x) * 4
            out[row * region.width + column] = SIMD4(Float(rgba[index]), Float(rgba[index + 1]), Float(rgba[index + 2]), 0)
          }
        }
      }
      self.pixels = pixels
    }

    /// Tightly packed RGBA8 `rgba` holding exactly `region`.
    init(packed rgba: UnsafeBufferPointer<UInt8>, region: Region) {
      self.region = region
      pixels = (0..<region.count).map { SIMD4(Float(rgba[$0 * 4]), Float(rgba[$0 * 4 + 1]), Float(rgba[$0 * 4 + 2]), 0) }
    }
  }

  /// A stroke's footprint in its region: `coverage` 0–1 for the soft edge, and `inside` (the
  /// pixels the correction is solved for: any coverage at all).
  struct Mask: Sendable {
    var region: Region
    var coverage: [Float]
    var inside: [Bool]
  }

  // MARK: Strokes

  /// `points` along their polyline every `spacing` pixels, first and last kept, so a quick drag
  /// whose events are far apart still brushes a continuous band.
  static func resample(_ points: [SIMD2<Float>], spacing: Float) -> [SIMD2<Float>] {
    guard var previous = points.first else { return [] }
    let spacing = max(spacing, 0.25)
    var out = [previous]
    var carried: Float = 0
    for point in points.dropFirst() {
      let segment = point - previous
      let length = (segment * segment).sum().squareRoot()
      guard length > 0 else { continue }
      var along = spacing - carried
      while along <= length {
        out.append(previous + segment * (along / length))
        along += spacing
      }
      carried = length - (along - spacing)
      previous = point
    }
    if let last = points.last, out.last != last { out.append(last) }
    return out
  }

  /// The discs a stroke is brushed with: its points resampled at a quarter of its radius.
  static func centres(of stroke: Edit.HealStroke) -> [SIMD2<Float>] {
    resample(stroke.points, spacing: stroke.radius / 4)
  }

  /// The stroke's whole box grown by 2 px for the correction's edge, inside a `width` × `height`
  /// image; nil when it misses the image or has no area. A long stroke is healed in pieces
  /// (`Brush.pieces`), each in its own part of this box.
  static func region(of stroke: Edit.HealStroke, width: Int, height: Int) -> Region? {
    guard let brush = Brush(stroke, width: width, height: height) else { return nil }
    return region(centres: brush.centres, radius: brush.radius, width: width, height: height)
  }

  private static func region(centres: [SIMD2<Float>], radius: Float, width: Int, height: Int) -> Region? {
    guard radius > 0, !centres.isEmpty, width > 0, height > 0 else { return nil }
    var low = centres[0], high = centres[0]
    for centre in centres {
      low = pointwiseMin(low, centre)
      high = pointwiseMax(high, centre)
    }
    let reach = radius + 2
    let x0 = max(Int((low.x - reach).rounded(.down)), 0), y0 = max(Int((low.y - reach).rounded(.down)), 0)
    let x1 = min(Int((high.x + reach).rounded(.up)), width), y1 = min(Int((high.y + reach).rounded(.up)), height)
    guard x1 > x0, y1 > y0 else { return nil }
    return Region(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }

  /// The union of the stroke's discs over `region`, full strength up to `radius − feather` and
  /// fading to nothing at `radius` (smoothstep). Each disc touches only its own square, so the
  /// cost is the stroke's area, not its box's times its length.
  static func mask(of stroke: Edit.HealStroke, in region: Region) -> Mask {
    mask(centres: centres(of: stroke), radius: stroke.radius, feather: stroke.feather, in: region)
  }

  private static func mask(centres: [SIMD2<Float>], radius: Float, feather: Float, in region: Region) -> Mask {
    var nearest = [Float](repeating: .infinity, count: region.count)
    nearest.withUnsafeMutableBufferPointer { nearest in
      for centre in centres {
        let x0 = max(Int((centre.x - radius).rounded(.down)), region.x), x1 = min(Int((centre.x + radius).rounded(.up)), region.x + region.width)
        let y0 = max(Int((centre.y - radius).rounded(.down)), region.y), y1 = min(Int((centre.y + radius).rounded(.up)), region.y + region.height)
        guard x1 > x0, y1 > y0 else { continue }
        for y in y0..<y1 {
          let dy = Float(y) + 0.5 - centre.y
          let row = (y - region.y) * region.width - region.x
          for x in x0..<x1 {
            let dx = Float(x) + 0.5 - centre.x
            let d2 = dx * dx + dy * dy
            if d2 < nearest[row + x] { nearest[row + x] = d2 }
          }
        }
      }
    }
    let soft = max(min(feather, 1), 0) * radius
    let hard = radius - soft
    var coverage = [Float](repeating: 0, count: region.count)
    var inside = [Bool](repeating: false, count: region.count)
    for index in 0..<region.count where nearest[index] < radius * radius {
      let distance = nearest[index].squareRoot()
      let value: Float
      if distance <= hard || soft <= 0 {
        value = 1
      } else {
        let t = (radius - distance) / soft
        value = t * t * (3 - 2 * t)
      }
      coverage[index] = value
      inside[index] = true
    }
    return Mask(region: region, coverage: coverage, inside: inside)
  }

  // MARK: Applying

  /// The largest radius applied, in image pixels. A piece's box is what a solve allocates (about
  /// 150 bytes a pixel across its buffers), so this keeps the largest solve near 300 MB (a
  /// 1,500 px square piece) whatever a record or an agent asks for; spots are a few dozen pixels.
  static let maxRadius: Float = 256
  /// The most disc centres one stroke is brushed with; past it they're spaced further apart. Only
  /// a nonsensical stroke (thousands of image-wide segments) gets near it.
  static let maxCentres = 1 << 20

  /// A stroke made safe for an image: finite, its offset within the image's size, its radius
  /// within `maxRadius` and the diagonal, its feather 0…1, and its path clipped to where its discs
  /// can reach the image, so no value from a corrupt record or an agent can overflow an Int or a
  /// byte or make work for pixels that aren't there. Nil when nothing usable is left (a
  /// non-finite radius or offset, no radius, no finite points, or a path that misses the image).
  struct Brush: Sendable {
    /// The resampled path's parts that reach the image, in order.
    var runs: [[SIMD2<Float>]]
    var radius: Float
    var feather: Float
    var shift: SIMD2<Int>
    /// Between centres: a quarter of the radius, unless `maxCentres` spreads them.
    var spacing: Float

    var centres: [SIMD2<Float>] { runs.flatMap(\.self) }

    init?(_ stroke: Edit.HealStroke, width: Int, height: Int) {
      guard width > 0, height > 0, stroke.radius.isFinite, stroke.radius > 0,
            stroke.offset.x.isFinite, stroke.offset.y.isFinite
      else { return nil }
      let size = SIMD2(Float(width), Float(height))
      let diagonal = (size * size).sum().squareRoot()
      radius = min(stroke.radius, diagonal, HealBrush.maxRadius)
      feather = stroke.feather.isFinite ? min(max(stroke.feather, 0), 1) : Edit.HealStroke.defaultFeather
      let offset = pointwiseMin(pointwiseMax(stroke.offset, -size), size)
      shift = SIMD2(Int(offset.x.rounded()), Int(offset.y.rounded()))
      // Points far beyond any image are pulled in (which barely turns their segments) so the
      // clipping below works in ordinary Float ranges.
      let far = SIMD2<Float>(repeating: 1e7)
      let points = stroke.points.compactMap { point -> SIMD2<Float>? in
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return pointwiseMin(pointwiseMax(point, -far), far)
      }
      guard !points.isEmpty else { return nil }
      let paths = HealBrush.clip(points, low: SIMD2(repeating: -radius - 1), high: size + radius + 1)
      let length = paths.reduce(Float(0)) { total, path in
        zip(path, path.dropFirst()).reduce(total) { $0 + (($1.1 - $1.0) * ($1.1 - $1.0)).sum().squareRoot() }
      }
      let spacing = max(radius / 4, length / Float(HealBrush.maxCentres), 0.25)
      guard !paths.isEmpty else { return nil }
      self.spacing = spacing
      runs = paths.map { HealBrush.resample($0, spacing: spacing) }
    }

    /// The centres in consecutive pieces of about `max(4 × radius, 64)` px of path (measured
    /// faster than 2× or 3×, whose extra solves cost more than their smaller boxes save), each sharing
    /// its first centre with the last of the piece before, and none with a disc off the image. A
    /// piece is solved on its own box, so a long drag costs about its own area (a corner-to-corner
    /// stroke's one box would be the whole image); pieces applied in order compose as overlapping
    /// dabs do, and where one meets the last the correction carries on, as the healed pixels it
    /// meets are its own source plus nearly the same correction.
    func pieces(width: Int, height: Int) -> [[SIMD2<Float>]] {
      let step = max(Int(max(4 * radius, 64) / spacing), 1)
      let low = SIMD2(repeating: -radius), high = SIMD2(Float(width), Float(height)) + radius
      var pieces: [[SIMD2<Float>]] = []
      var run: [SIMD2<Float>] = []
      func finish() {
        guard !run.isEmpty else { return }
        var start = 0
        while true {
          let end = min(start + step, run.count - 1)
          pieces.append(Array(run[start...end]))
          if end == run.count - 1 { break }
          start = end
        }
        run.removeAll(keepingCapacity: true)
      }
      for path in runs {
        for centre in path {
          if centre.x > low.x, centre.y > low.y, centre.x < high.x, centre.y < high.y {
            run.append(centre)
          } else {
            finish()
          }
        }
        finish()
      }
      return pieces
    }
  }

  /// The polyline's parts inside the box `low`–`high` (Liang–Barsky per segment), as separate
  /// paths where it leaves and comes back. Clipping keeps every segment's direction, so the
  /// part of the stroke on the image is brushed exactly as given.
  static func clip(_ points: [SIMD2<Float>], low: SIMD2<Float>, high: SIMD2<Float>) -> [[SIMD2<Float>]] {
    func inside(_ p: SIMD2<Float>) -> Bool { p.x >= low.x && p.y >= low.y && p.x <= high.x && p.y <= high.y }
    guard points.count > 1 else { return points.filter(inside).map { [$0] } }
    var paths: [[SIMD2<Float>]] = []
    var path: [SIMD2<Float>] = []
    for (p, q) in zip(points, points.dropFirst()) {
      let d = q - p
      var t0: Float = 0, t1: Float = 1
      var visible = true
      for (delta, start, lower, upper) in [(d.x, p.x, low.x, high.x), (d.y, p.y, low.y, high.y)] {
        if delta == 0 {
          if start < lower || start > upper { visible = false }
          continue
        }
        var a = (lower - start) / delta, b = (upper - start) / delta
        if a > b { swap(&a, &b) }
        t0 = max(t0, a)
        t1 = min(t1, b)
      }
      guard visible, t0 <= t1 else {
        if !path.isEmpty { paths.append(path) }
        path = []
        continue
      }
      let entry = t0 == 0 ? p : p + d * t0
      let exit = t1 == 1 ? q : p + d * t1
      if path.last != entry {
        if !path.isEmpty { paths.append(path) }
        path = [entry]
      }
      path.append(exit)
      if t1 < 1 {
        paths.append(path)
        path = []
      }
    }
    if !path.isEmpty { paths.append(path) }
    return paths
  }

  /// Heals `stroke` into tightly packed RGBA8 `pixels` (`width` × `height`, straight alpha, which
  /// is kept), returning the region it changed (nil for none). Every piece's source is read
  /// before anything is written, so where it overlaps the stroke's own area it's the pre-stroke
  /// pixels: a stroke never feeds on itself.
  @discardableResult
  static func apply(_ stroke: Edit.HealStroke, to pixels: inout [UInt8], width: Int, height: Int) -> Region? {
    guard width > 0, height > 0, pixels.count >= width * height * 4, let brush = Brush(stroke, width: width, height: height) else { return nil }
    let pieces = brush.pieces(width: width, height: height).compactMap { centres -> (Region, [SIMD2<Float>])? in
      region(centres: centres, radius: brush.radius, width: width, height: height).map { ($0, centres) }
    }
    // The sources as bytes (a quarter of a surface's size), all taken before the first write.
    let sources = pixels.withUnsafeBufferPointer { rgba in
      pieces.map { region, _ in snapshot(rgba, width: width, height: height, region: region, shift: brush.shift) }
    }
    var changed: Region?
    for ((region, centres), sourceBytes) in zip(pieces, sources) {
      let mask = mask(centres: centres, radius: brush.radius, feather: brush.feather, in: region)
      let destination = pixels.withUnsafeBufferPointer { HealSurface(rgba: $0, width: width, height: height, region: region) }
      let source = sourceBytes.withUnsafeBufferPointer { HealSurface(packed: $0, region: region) }
      let healed = heal(destination: destination, source: source, mask: mask)
      pixels.withUnsafeMutableBufferPointer { out in
        for row in 0..<region.height {
          for column in 0..<region.width {
            let index = row * region.width + column
            guard mask.coverage[index] > 0 else { continue }
            let value = healed.pixels[index]
            let at = ((region.y + row) * width + region.x + column) * 4
            out[at] = byte(value.x)
            out[at + 1] = byte(value.y)
            out[at + 2] = byte(value.z)
          }
        }
      }
      changed = changed.map { $0.union(region) } ?? region
    }
    return changed
  }

  /// `region` of `rgba` moved by `shift`, edge-clamped, as its own tightly packed RGBA8.
  private static func snapshot(_ rgba: UnsafeBufferPointer<UInt8>, width: Int, height: Int, region: Region, shift: SIMD2<Int>) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: region.count * 4)
    out.withUnsafeMutableBufferPointer { out in
      for row in 0..<region.height {
        let y = min(max(region.y + row + shift.y, 0), height - 1)
        for column in 0..<region.width {
          let x = min(max(region.x + column + shift.x, 0), width - 1)
          let from = (y * width + x) * 4, to = (row * region.width + column) * 4
          out[to] = rgba[from]
          out[to + 1] = rgba[from + 1]
          out[to + 2] = rgba[from + 2]
          out[to + 3] = rgba[from + 3]
        }
      }
    }
    return out
  }

  /// Heals the strokes in order (each on the result of the ones before it), returning the region
  /// they changed together. Checks `cancel` between strokes, for re-applying a long list.
  @discardableResult
  static func apply(_ strokes: Edit.HealStrokes, to pixels: inout [UInt8], width: Int, height: Int,
                    cancel: EditPipeline.Cancel = .never) throws -> Region?
  {
    var changed: Region?
    for stroke in strokes.strokes {
      try cancel.check()
      if let region = apply(stroke, to: &pixels, width: width, height: height) {
        changed = changed.map { $0.union(region) } ?? region
      }
    }
    return changed
  }

  /// The healed surface: `source` plus the membrane correction, laid over `destination` with the
  /// mask's soft edge. All three share one region.
  static func heal(destination: HealSurface, source: HealSurface, mask: Mask) -> HealSurface {
    let region = mask.region
    let count = region.count
    var states = [State](repeating: .outside, count: count)
    var values = [SIMD4<Float>](repeating: .zero, count: count)
    for index in 0..<count {
      if mask.inside[index] {
        states[index] = .unknown
        continue
      }
      // An edge pixel: outside the stroke with a neighbour inside it.
      let x = index % region.width, y = index / region.width
      let touches = (x > 0 && mask.inside[index - 1]) || (x + 1 < region.width && mask.inside[index + 1])
        || (y > 0 && mask.inside[index - region.width]) || (y + 1 < region.height && mask.inside[index + region.width])
      if touches {
        states[index] = .fixed
        values[index] = destination.pixels[index] - source.pixels[index]
      }
    }
    let correction = membrane(Grid(width: region.width, height: region.height, states: states, values: values))
    var out = destination
    for index in 0..<count {
      let a = mask.coverage[index]
      guard a > 0 else { continue }
      out.pixels[index] = destination.pixels[index] * (1 - a) + (source.pixels[index] + correction[index]) * a
    }
    return out
  }

  /// Rounded and clipped; NaN (which no sanitised stroke makes) goes to 0 rather than trapping.
  private static func byte(_ value: Float) -> UInt8 {
    value.isNaN ? 0 : UInt8(min(max(value.rounded(), 0), 255))
  }

  // MARK: Membrane

  enum State: UInt8, Sendable {
    /// Not part of the problem: past the image's edge, or away from the stroke.
    case outside
    /// Solved for.
    case unknown
    /// Given (the stroke's edge).
    case fixed
  }

  /// A Laplace problem on a grid: `fixed` cells hold their `values`, `unknown` ones are solved
  /// for; `outside` cells are left out of their neighbours' averages (a free edge).
  struct Grid: Sendable {
    var width: Int
    var height: Int
    var states: [State]
    var values: [SIMD4<Float>]
  }

  // The solver's constants (`sweeps`, `omega`, the coarsest level's size and sweep count,
  // `tolerance`) decide the pixels a saved step renders to: a stroke is stored as data and healed
  // again whenever the step is opened or saved. Changing any of them changes saved steps, so it
  // must bump `Edit.HealStrokes.version` (and keep the old solver for the old version).

  /// Relaxation sweeps on the full-size level, after the coarser level's answer; each coarser
  /// level gets twice as many (up to 8×), as it has a quarter of the cells, and the coarsest is
  /// small enough to sweep until it settles. With `omega` this lands within half a level of the
  /// converged answer on a 60 px disc whose edge jumps by 60 levels (measured against 4000
  /// sweeps); finer than that is invisible after rounding to bytes.
  static let sweeps = 24
  /// The over-relaxation factor, tuned on that disc (1.5 and 1.92 both did worse in 24 sweeps).
  static let omega: Float = 1.85
  /// Halving stops once a side is this small or smaller.
  static let coarsestSize = 12
  /// The coarsest level's sweeps stop once no cell moves more than this.
  static let coarsestTolerance: Float = 1e-3

  /// The harmonic fill of `grid`: unknown cells end at the average of their neighbours, fixed
  /// ones keep their values. Solved coarse to fine: the grid is halved until it's small (a coarse
  /// cell is fixed if any of its four is, at their mean; unknown if any is), the coarsest is
  /// relaxed to convergence from the edge's mean, and each finer level starts from the coarser
  /// answer, bilinearly interpolated, and relaxes a fixed number of sweeps. A grid with no fixed
  /// cells has nothing to carry across, so it gets no correction.
  static func membrane(_ grid: Grid) -> [SIMD4<Float>] {
    guard grid.states.contains(.fixed) else { return [SIMD4<Float>](repeating: .zero, count: grid.states.count) }
    var levels = [grid]
    while let last = levels.last, min(last.width, last.height) > coarsestSize, levels.count < 10 {
      levels.append(restrict(last))
    }
    let coarsest = levels[levels.count - 1]
    var mean = SIMD4<Float>.zero
    var fixedCount: Float = 0
    for index in coarsest.states.indices where coarsest.states[index] == .fixed {
      mean += coarsest.values[index]
      fixedCount += 1
    }
    mean /= max(fixedCount, 1)
    var solution = coarsest.values
    for index in solution.indices where coarsest.states[index] == .unknown { solution[index] = mean }
    relax(coarsest, &solution, sweeps: 4 * (coarsest.width + coarsest.height) + 50, tolerance: coarsestTolerance)
    for level in stride(from: levels.count - 2, through: 0, by: -1) {
      solution = prolong(solution, from: levels[level + 1], to: levels[level])
      relax(levels[level], &solution, sweeps: sweeps << min(level, 3), tolerance: 0)
    }
    return solution
  }

  /// The grid at half size.
  private static func restrict(_ fine: Grid) -> Grid {
    let width = (fine.width + 1) / 2, height = (fine.height + 1) / 2
    var states = [State](repeating: .outside, count: width * height)
    var values = [SIMD4<Float>](repeating: .zero, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        var sum = SIMD4<Float>.zero
        var fixed: Float = 0
        var unknown = false
        for fy in (2 * y)..<min(2 * y + 2, fine.height) {
          for fx in (2 * x)..<min(2 * x + 2, fine.width) {
            let index = fy * fine.width + fx
            switch fine.states[index] {
            case .fixed:
              sum += fine.values[index]
              fixed += 1
            case .unknown: unknown = true
            case .outside: break
            }
          }
        }
        if fixed > 0 {
          states[y * width + x] = .fixed
          values[y * width + x] = sum / fixed
        } else if unknown {
          states[y * width + x] = .unknown
        }
      }
    }
    return Grid(width: width, height: height, states: states, values: values)
  }

  /// `coarse`'s answer laid onto `fine`'s unknown cells, bilinearly from the coarse cells that are
  /// part of the problem; fixed cells keep their own values.
  private static func prolong(_ coarseValues: [SIMD4<Float>], from coarse: Grid, to fine: Grid) -> [SIMD4<Float>] {
    var out = fine.values
    for y in 0..<fine.height {
      let cy = (Float(y) + 0.5) / 2 - 0.5
      let y0 = min(max(Int(cy.rounded(.down)), 0), coarse.height - 1), y1 = min(y0 + 1, coarse.height - 1)
      let wy = min(max(cy - Float(y0), 0), 1)
      for x in 0..<fine.width where fine.states[y * fine.width + x] == .unknown {
        let cx = (Float(x) + 0.5) / 2 - 0.5
        let x0 = min(max(Int(cx.rounded(.down)), 0), coarse.width - 1), x1 = min(x0 + 1, coarse.width - 1)
        let wx = min(max(cx - Float(x0), 0), 1)
        var sum = SIMD4<Float>.zero
        var weight: Float = 0
        func take(_ index: Int, _ w: Float) {
          guard w > 0, coarse.states[index] != .outside else { return }
          sum += coarseValues[index] * w
          weight += w
        }
        take(y0 * coarse.width + x0, (1 - wx) * (1 - wy))
        take(y0 * coarse.width + x1, wx * (1 - wy))
        take(y1 * coarse.width + x0, (1 - wx) * wy)
        take(y1 * coarse.width + x1, wx * wy)
        out[y * fine.width + x] = weight > 0 ? sum / weight : coarseValues[(y / 2) * coarse.width + x / 2]
      }
    }
    return out
  }

  /// Successive over-relaxation (Gauss–Seidel, row by row, so the result is the same every run)
  /// of the unknown cells, up to `sweeps` times or until no cell moves more than `tolerance`.
  private static func relax(_ grid: Grid, _ solution: inout [SIMD4<Float>], sweeps: Int, tolerance: Float) {
    // Each unknown cell's index and its neighbours that take part, worked out once.
    var cells: [Int32] = []
    var neighbours: [Int32] = []
    var inverse: [Float] = []
    let width = grid.width
    for index in grid.states.indices where grid.states[index] == .unknown {
      let x = index % width, y = index / width
      var found = 0
      func take(_ other: Int) {
        guard grid.states[other] != .outside else { return }
        neighbours.append(Int32(other))
        found += 1
      }
      if x > 0 { take(index - 1) }
      if x + 1 < width { take(index + 1) }
      if y > 0 { take(index - width) }
      if y + 1 < grid.height { take(index + width) }
      // A lone cell with no neighbours in the problem keeps its starting value.
      guard found > 0 else { continue }
      for _ in found..<4 { neighbours.append(Int32(index)) }
      cells.append(Int32(index))
      // Four slots a cell; the padding repeats the cell itself, which the sweep skips.
      inverse.append(1 / Float(found))
    }
    guard !cells.isEmpty else { return }
    let omega = omega
    solution.withUnsafeMutableBufferPointer { values in
      cells.withUnsafeBufferPointer { cells in
        neighbours.withUnsafeBufferPointer { neighbours in
          inverse.withUnsafeBufferPointer { inverse in
            for _ in 0..<sweeps {
              var largest: Float = 0
              for (slot, cell) in cells.enumerated() {
                let base = slot * 4
                let current = values[Int(cell)]
                var sum = SIMD4<Float>.zero
                for k in 0..<4 {
                  let other = Int(neighbours[base + k])
                  if other != Int(cell) { sum += values[other] }
                }
                let change = (sum * inverse[slot] - current) * omega
                values[Int(cell)] = current + change
                if tolerance > 0 { largest = Swift.max(largest, pointwiseMax(change, -change).max()) }
              }
              if tolerance > 0, largest < tolerance { break }
            }
          }
        }
      }
    }
  }
}
