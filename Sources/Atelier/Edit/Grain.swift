import Foundation

/// grain.py's stages after its blur, and Match Reference's measuring (`--match`), ported line for
/// line from Lira's `grain.py` so a look and a profile come out as the script makes them. Pure
/// functions on `EditPipeline.Planes` and row-major Float32 planes; `EditPipeline` calls them in
/// its order and caches what it can. `process` runs grain.py's own `process` from end to end.
///
/// The numbers follow numpy's: Float32 arithmetic where grain.py's arrays are float32 (a Python
/// float meeting a float32 array becomes a float32, NEP 50), Float64 where numpy promotes
/// (`np.interp`, sums divided by a count), numpy's pairwise summation for whole-array sums and
/// its row-by-row sums along axis 0, round-half-even for Python's `round`. So Match Reference
/// measures a reference exactly as grain.py does (the same patches, the same statistics).
///
/// Two differences, both by the user's choice: the random fields use Atelier's own generator
/// (`Random`, PCG with Box–Muller), not numpy's, so the grain is grain.py's statistically rather
/// than pixel for pixel (and the fitted size can land a step from grain.py's, whose fit compares
/// against its own random fields); and the motion smear clamps at the edges instead of wrapping.
nonisolated enum Grain {
  /// grain.py's `BAND_CENTRES`: the brightness band centres (0–1) of the grain curve.
  static let bandCentres: [Double] = [24, 65, 125, 197].map { $0 / 255 }

  /// grain.py's `SIZES`.
  static var sizes: [Double] { EditOptions.Grain.sizes }

  // MARK: - numpy's arithmetic

  /// numpy's `pairwise_sum` for float32, how `a.sum()` adds a whole array: runs under 8 add in
  /// order, up to 128 in eight interleaved partial sums, longer ones split in halves (a multiple
  /// of 8 first). Float32 throughout.
  static func pairwiseSum(_ a: UnsafeBufferPointer<Float>, _ start: Int, _ n: Int) -> Float {
    if n < 8 {
      var res: Float = 0
      for i in 0..<n { res += a[start + i] }
      return res
    }
    if n <= 128 {
      var r0 = a[start], r1 = a[start + 1], r2 = a[start + 2], r3 = a[start + 3]
      var r4 = a[start + 4], r5 = a[start + 5], r6 = a[start + 6], r7 = a[start + 7]
      var i = 8
      while i < n - n % 8 {
        r0 += a[start + i]
        r1 += a[start + i + 1]
        r2 += a[start + i + 2]
        r3 += a[start + i + 3]
        r4 += a[start + i + 4]
        r5 += a[start + i + 5]
        r6 += a[start + i + 6]
        r7 += a[start + i + 7]
        i += 8
      }
      var res = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7))
      while i < n {
        res += a[start + i]
        i += 1
      }
      return res
    }
    var n2 = n / 2
    n2 -= n2 % 8
    return pairwiseSum(a, start, n2) + pairwiseSum(a, start + n2, n - n2)
  }

  /// `a.sum()` of a float32 array (or of a strided view, which numpy copies out in order first).
  static func sum(_ a: [Float]) -> Float {
    a.withUnsafeBufferPointer { pairwiseSum($0, 0, $0.count) }
  }

  /// `a.mean()`: the float32 sum divided by the count in Float64 (numpy divides by an intp), then
  /// rounded to Float32.
  static func mean(_ a: [Float]) -> Float {
    guard !a.isEmpty else { return .nan }
    return Float(Double(sum(a)) / Double(a.count))
  }

  /// `a.std()`: numpy's `_var` (mean, deviations squared, their sum over the count) and a Float32
  /// square root.
  static func std(_ a: [Float]) -> Float {
    guard !a.isEmpty else { return .nan }
    let m = mean(a)
    let squares = a.map { ($0 - m) * ($0 - m) }
    return Float(Double(sum(squares)) / Double(a.count)).squareRoot()
  }

  /// `np.mean(rows, 0)` of float32 rows: numpy adds rows one after another along axis 0.
  static func meanOfRows(_ rows: [[Float]]) -> [Float] {
    guard let first = rows.first else { return [] }
    var total = [Float](repeating: 0, count: first.count)
    for row in rows {
      for k in 0..<total.count { total[k] += row[k] }
    }
    return total.map { Float(Double($0) / Double(rows.count)) }
  }

  /// `np.median` of Python floats.
  static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
  }

  /// Python's `round(x)` (halves to even).
  static func round(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

  /// Python's `round(x, 1)`: the exact binary value rounded to one decimal, as `%.1f` prints it.
  static func round1(_ x: Double) -> Double {
    guard x.isFinite else { return x }
    return Double(String(format: "%.1f", x)) ?? x
  }

  /// grain.py's `interp_curve`: `np.interp(L, BAND_CENTRES, curve)`, flat outside the centres.
  static func interp(_ x: Double, curve: [Double]) -> Double {
    let xp = bandCentres
    guard curve.count == xp.count else { return 1 }
    if x <= xp[0] { return curve[0] }
    if x >= xp[xp.count - 1] { return curve[curve.count - 1] }
    var j = 0
    while x >= xp[j + 1] { j += 1 }
    let slope = (curve[j + 1] - curve[j]) / (xp[j + 1] - xp[j])
    return slope * (x - xp[j]) + curve[j]
  }

  /// grain.py's `luma`: `0.299 R + 0.587 G + 0.114 B` in Float32, left to right.
  static func luma(_ r: [Float], _ g: [Float], _ b: [Float]) -> [Float] {
    let kr = Float(0.299), kg = Float(0.587), kb = Float(0.114)
    var out = [Float](repeating: 0, count: r.count)
    for i in 0..<r.count {
      let red = kr * r[i]
      let green = kg * g[i]
      out[i] = red + green + kb * b[i]
    }
    return out
  }

  static func luma(_ planes: EditPipeline.Planes) -> [Float] { luma(planes.r, planes.g, planes.b) }

  /// `np.gradient(f)` of a plane: (d/dy, d/dx), central differences inside, one-sided at the edges.
  static func gradient(_ f: [Float], width: Int, height: Int) -> (dy: [Float], dx: [Float]) {
    var dy = [Float](repeating: 0, count: f.count)
    var dx = dy
    guard width >= 2, height >= 2 else { return (dy, dx) }
    let two = Float(2)
    for y in 0..<height {
      let row = y * width
      for x in 0..<width {
        let i = row + x
        if y == 0 {
          dy[i] = f[i + width] - f[i]
        } else if y == height - 1 {
          dy[i] = f[i] - f[i - width]
        } else {
          dy[i] = (f[i + width] - f[i - width]) / two
        }
        if x == 0 {
          dx[i] = f[i + 1] - f[i]
        } else if x == width - 1 {
          dx[i] = f[i] - f[i - 1]
        } else {
          dx[i] = (f[i + 1] - f[i - 1]) / two
        }
      }
    }
    return (dy, dx)
  }

  /// The values of `plane[y0 ..< y1 : step, x0 ..< x1 : step]`, row by row (a strided numpy view).
  static func strided(_ plane: [Float], width: Int, rows: StrideTo<Int>, columns: StrideTo<Int>) -> [Float] {
    var out: [Float] = []
    for y in rows {
      for x in columns { out.append(plane[y * width + x]) }
    }
    return out
  }

  /// The `size` × `size` block of a plane at `(x, y)`.
  static func block(_ plane: [Float], width: Int, x: Int, y: Int, size: Int) -> [Float] {
    var out = [Float](repeating: 0, count: size * size)
    for row in 0..<size {
      for column in 0..<size { out[row * size + column] = plane[(y + row) * width + x + column] }
    }
    return out
  }

  // MARK: - Random fields

  /// Atelier's random numbers (grain.py uses numpy's `default_rng`): PCG32 (XSH RR 64/32),
  /// uniform doubles from 53 bits, Gaussians by Box–Muller.
  struct Random {
    private var state: UInt64 = 0
    private let increment: UInt64

    init(seed: UInt64, stream: UInt64 = 54) {
      increment = (stream << 1) | 1
      _ = next()
      state &+= seed
      _ = next()
    }

    init(seed: Int, stream: UInt64 = 54) { self.init(seed: UInt64(bitPattern: Int64(seed)), stream: stream) }

    mutating func next() -> UInt32 {
      let old = state
      state = old &* 6_364_136_223_846_793_005 &+ increment
      let shifted = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27)
      let rotation = UInt32(truncatingIfNeeded: old >> 59)
      return (shifted >> rotation) | (shifted << ((~rotation &+ 1) & 31))
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double {
      let high = UInt64(next() >> 5)
      let low = UInt64(next() >> 6)
      return Double(high * 67_108_864 + low) / 9_007_199_254_740_992
    }

    /// Uniform in 0 ..< n.
    mutating func integer(below n: Int) -> Int {
      guard n > 1 else { return 0 }
      let value = UInt64(next()) << 32 | UInt64(next())
      return Int(value % UInt64(n))
    }

    /// Two independent unit Gaussians.
    mutating func gaussians() -> (Double, Double) {
      let u1 = 1 - uniform()
      let u2 = uniform()
      let radius = (-2 * Foundation.log(u1)).squareRoot()
      let angle = 2 * Double.pi * u2
      return (radius * Foundation.cos(angle), radius * Foundation.sin(angle))
    }

    /// SplitMix64, to give each row of a field its own seed.
    static func mix(_ value: UInt64) -> UInt64 {
      var z = value &+ 0x9E37_79B9_7F4A_7C15
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  /// grain.py's `noise_field(cells_w, cells_h, seed)`: unit Gaussian cells clipped at ±4σ, row-major.
  /// Each row has its own generator (seeded from the seed and the row), so rows fill in parallel.
  static func noiseField(width: Int, height: Int, seed: Int) -> [Float] {
    guard width > 0, height > 0 else { return [] }
    var out = [Float](repeating: 0, count: width * height)
    let base = Random.mix(UInt64(bitPattern: Int64(seed)))
    out.withUnsafeMutableBufferPointer { buffer in
      let buffer = buffer
      DispatchQueue.concurrentPerform(iterations: height) { row in
        var random = Random(seed: Random.mix(base ^ UInt64(row)))
        var x = 0
        while x < width {
          let (a, b) = random.gaussians()
          buffer[row * width + x] = Float(min(max(a, -4), 4))
          if x + 1 < width { buffer[row * width + x + 1] = Float(min(max(b, -4), 4)) }
          x += 2
        }
      }
    }
    return out
  }

  /// Where a render's planes sit in the picture the grain is laid over.
  struct Layout: Hashable, Sendable {
    /// The whole output's size: the full image, or the whole of a fitted preview.
    var width: Int
    var height: Int
    /// grain.py's `aspect`, the source's height over its width, which sets the fields' rows. A
    /// preview passes the full image's, so its fields have the same cells as the full render's.
    var aspect: Double
    /// The part of the output the planes hold.
    var region: Resample.Region

    init(width: Int, height: Int, aspect: Double? = nil, region: Resample.Region? = nil) {
      self.width = width
      self.height = height
      self.aspect = aspect ?? Double(height) / Double(max(width, 1))
      self.region = region ?? .whole(width: width, height: height)
    }

    static func whole(width: Int, height: Int) -> Layout { Layout(width: width, height: height) }
  }

  /// The luma field's cells across and down: `max(64, round(ref_w × 1.3 / size))`.
  static func lumaCells(refWidth: Int, size: Double, aspect: Double) -> (width: Int, height: Int) {
    let w = max(64, round(Double(refWidth) * 1.3 / size))
    return (w, max(64, round(Double(w) * aspect)))
  }

  /// The colour fields' cells: `max(32, round(ref_w × 1.3 / csize))`.
  static func chromaCells(refWidth: Int, size: Double, aspect: Double) -> (width: Int, height: Int) {
    let w = max(32, round(Double(refWidth) * 1.3 / size))
    return (w, max(32, round(Double(w) * aspect)))
  }

  /// A noise field of `cells`, enlarged with Pillow's bicubic to the layout's output and cut to its
  /// region (grain.py's `resize_float(noise_field(...), W, H)`).
  static func field(cells: (width: Int, height: Int), seed: Int, layout: Layout) -> [Float] {
    let raw = noiseField(width: cells.width, height: cells.height, seed: seed)
    return Resample.resize(raw, width: cells.width, height: cells.height, toWidth: layout.width, height: layout.height, region: layout.region)
  }

  // MARK: - The pipeline's stages

  /// grain.py's `motion_smear`: the mean of `max(2, round(length))` copies shifted along `angle`
  /// (degrees, 0 = horizontal), each shift rounded half to even. Edges clamp (the user's choice)
  /// where `np.roll` wraps. grain.py smears only when `length > 1`; callers check.
  static func motionSmear(_ planes: EditPipeline.Planes, length: Double, angle: Double) -> EditPipeline.Planes {
    let n = max(2, round(length))
    let t = angle * Double.pi / 180
    let shifts = (0..<n).map { i -> (dy: Int, dx: Int) in
      let d = Double(i) - Double(n - 1) / 2
      return (round(d * Foundation.sin(t)), round(d * Foundation.cos(t)))
    }
    let width = planes.width, height = planes.height
    func smear(_ plane: [Float]) -> [Float] {
      var out = [Float](repeating: 0, count: plane.count)
      plane.withUnsafeBufferPointer { input in
        out.withUnsafeMutableBufferPointer { output in
          let input = input
          let output = output
          DispatchQueue.concurrentPerform(iterations: height) { y in
            let row = y * width
            for shift in shifts {
              let source = min(max(y - shift.dy, 0), height - 1) * width
              for x in 0..<width { output[row + x] += input[source + min(max(x - shift.dx, 0), width - 1)] }
            }
            let count = Float(n)
            for x in 0..<width { output[row + x] /= count }
          }
        }
      }
      return out
    }
    var out = planes
    out.r = smear(planes.r)
    out.g = smear(planes.g)
    out.b = smear(planes.b)
    return out
  }

  /// grain.py's `gauss(a, blur)` on the three colour planes.
  static func blur(_ planes: EditPipeline.Planes, sigma: Double) -> EditPipeline.Planes {
    guard sigma >= 0.3 else { return planes }
    var out = planes
    let blurred = Blur.gauss([planes.r, planes.g, planes.b], width: planes.width, height: planes.height, sigma: sigma)
    out.r = blurred[0]
    out.g = blurred[1]
    out.b = blurred[2]
    return out
  }

  /// grain.py's `channel_stats`: the per-channel mean and std (+ 0.001) of the image clipped and
  /// truncated to bytes, resized with Pillow's 8-bit bicubic to 512 wide, in float32.
  static func channelStats(_ planes: EditPipeline.Planes) -> GrainProfile.ChannelStats {
    let w = planes.width, h = planes.height
    guard w > 0, h > 0 else { return GrainProfile.ChannelStats(m: [0, 0, 0], s: [1, 1, 1]) }
    var bytes = [UInt8](repeating: 0, count: w * h * 3)
    func byte(_ v: Float) -> UInt8 { v.isNaN ? 0 : UInt8(min(max(v, 0), 255)) }
    for i in 0..<w * h {
      bytes[i * 3] = byte(planes.r[i])
      bytes[i * 3 + 1] = byte(planes.g[i])
      bytes[i * 3 + 2] = byte(planes.b[i])
    }
    return channelStats(rgb: bytes, width: w, height: h)
  }

  /// `channelStats` of an 8-bit image's RGBA (the same numbers as its planes give), without
  /// making the planes.
  static func channelStats(rgba: [UInt8], width w: Int, height h: Int) -> GrainProfile.ChannelStats {
    guard w > 0, h > 0, rgba.count >= w * h * 4 else { return GrainProfile.ChannelStats(m: [0, 0, 0], s: [1, 1, 1]) }
    var bytes = [UInt8](repeating: 0, count: w * h * 3)
    for i in 0..<w * h {
      bytes[i * 3] = rgba[i * 4]
      bytes[i * 3 + 1] = rgba[i * 4 + 1]
      bytes[i * 3 + 2] = rgba[i * 4 + 2]
    }
    return channelStats(rgb: bytes, width: w, height: h)
  }

  /// `channelStats` of interleaved 8-bit RGB.
  static func channelStats(rgb bytes: [UInt8], width w: Int, height h: Int) -> GrainProfile.ChannelStats {
    let smallHeight = max(1, round(512 * Double(h) / Double(w)))
    let small = Resample.resizeRGB8(bytes, width: w, height: h, toWidth: 512, height: smallHeight)
    let count = small.count / 3
    var means: [Double] = []
    var spreads: [Double] = []
    for c in 0..<3 {
      // Along axis 0 numpy adds the pixels one after another, in float32.
      var total: Float = 0
      for i in 0..<count { total += Float(small[i * 3 + c]) }
      let m = Float(Double(total) / Double(count))
      var squares: Float = 0
      for i in 0..<count {
        let d = Float(small[i * 3 + c]) - m
        squares += d * d
      }
      let s = Float(Double(squares) / Double(count)).squareRoot() + Float(1e-3)
      means.append(Double(m))
      spreads.append(Double(s))
    }
    return GrainProfile.ChannelStats(m: means, s: spreads)
  }

  /// grain.py's colour match (`--colour`): each channel moved to the reference's mean and spread,
  /// `(a − sm) × (rs / ss) + rm`, mixed in by `amount` (0–1). `source` is the *unblurred* source's
  /// `channelStats`, as grain.py measures it, applied to the (smeared, blurred) planes.
  static func colourMatch(
    _ planes: EditPipeline.Planes, source: GrainProfile.ChannelStats, reference: GrainProfile.ChannelStats, amount: Double
  ) -> EditPipeline.Planes {
    guard amount > 0, source.m.count == 3, source.s.count == 3, reference.m.count == 3, reference.s.count == 3 else { return planes }
    let keep = Float(1 - amount), take = Float(amount)
    func moved(_ plane: [Float], _ c: Int) -> [Float] {
      let sm = Float(source.m[c]), ratio = Float(reference.s[c]) / Float(source.s[c]), rm = Float(reference.m[c])
      return plane.map { a in a * keep + ((a - sm) * ratio + rm) * take }
    }
    var out = planes
    out.r = moved(planes.r, 0)
    out.g = moved(planes.g, 1)
    out.b = moved(planes.b, 2)
    return out
  }

  /// grain.py's exposure, `a *= 2 ** expo` (stops), in float32. Slice B's Grade section owns the
  /// control; this is the script's formula for it.
  static func exposure(_ planes: inout EditPipeline.Planes, stops: Double) {
    guard stops != 0 else { return }
    let factor = Float(Foundation.pow(2, stops))
    for i in 0..<planes.r.count {
      planes.r[i] *= factor
      planes.g[i] *= factor
      planes.b[i] *= factor
    }
  }

  /// grain.py's tint (`--tint`, green − to magenta +, −30…30), in 0–255 levels:
  ///
  ///     a[..., 1] -= tint * 0.5
  ///     a[..., 0] += tint * 0.25
  ///     a[..., 2] += tint * 0.25
  ///
  /// Slice B's Grade section owns the control; this is the script's formula for it.
  static func tint(_ planes: inout EditPipeline.Planes, _ tint: Double) {
    guard tint != 0 else { return }
    let green = Float(tint * 0.5), other = Float(tint * 0.25)
    for i in 0..<planes.r.count {
      planes.g[i] -= green
      planes.r[i] += other
      planes.b[i] += other
    }
  }

  /// grain.py's `L = np.clip(a.sum(-1) / 765, 0, 1)`: brightness 0–1 before grain, which sets
  /// the grain's strength (`gain`) and the real noise's.
  static func luminance(_ planes: EditPipeline.Planes) -> [Float] {
    var out = [Float](repeating: 0, count: planes.r.count)
    let scale = Float(765)
    for i in 0..<out.count {
      let total = planes.r[i] + planes.g[i] + planes.b[i]
      out[i] = min(max(total / scale, 0), 1)
    }
    return out
  }

  /// grain.py's grain strength by brightness: `0.55 + 0.9 √L (1 − 0.5 L)` (float32), or the
  /// profile's curve through the band centres (`interp_curve`, float64).
  static func gain(_ luminance: Float, curve: [Double]?) -> Double {
    if let curve { return interp(Double(luminance), curve: curve) }
    let l = luminance
    return Double(Float(0.55) + Float(0.9) * l.squareRoot() * (1 - Float(0.5) * l))
  }

  /// The random grain's three fields, enlarged to the layout's region: the luma field (`seed`)
  /// and the two colour fields (`seed + 99`, `seed + 199`), each nil when its strength is 0.
  /// They depend only on the sizes, seed, reference width and layout, not on the picture, so
  /// `EditRenderer` keeps them between renders.
  struct GrainFields: Sendable {
    var luma: [Float]?
    var c1: [Float]?
    var c2: [Float]?

    var byteCount: Int { ((luma?.count ?? 0) + (c1?.count ?? 0) + (c2?.count ?? 0)) * MemoryLayout<Float>.size }
  }

  /// The fields `addGrain` adds for these settings.
  static func grainFields(lum: Double, chroma: Double, size: Double, csize: Double, seed: Int, refWidth: Int, layout: Layout) -> GrainFields {
    let n0 = lum != 0 ? field(cells: lumaCells(refWidth: refWidth, size: size, aspect: layout.aspect), seed: seed, layout: layout) : nil
    var c1: [Float]?
    var c2: [Float]?
    if chroma != 0 {
      let cells = chromaCells(refWidth: refWidth, size: csize, aspect: layout.aspect)
      c1 = field(cells: cells, seed: seed + 99, layout: layout)
      c2 = field(cells: cells, seed: seed + 199, layout: layout)
    }
    return GrainFields(luma: n0, c1: c1, c2: c2)
  }

  /// grain.py's random grain: a luma field (`seed`) at `lum × gain(L)`, and two colour fields
  /// (`seed + 99`, `seed + 199`) at `chroma`, added as `R += n0 + c1`, `G += n0 − (c1 + c2)/2`,
  /// `B += n0 + c2`. `luminance` is `luminance(planes)` from before; the planes are the layout's
  /// region. A strength of 0 skips its fields, which adds the same as grain.py's zeros.
  static func addGrain(
    _ planes: inout EditPipeline.Planes, luminance: [Float], lum: Double, chroma: Double, size: Double, csize: Double,
    seed: Int, refWidth: Int, curve: [Double]?, layout: Layout
  ) {
    guard planes.r.count == luminance.count, planes.r.count == layout.region.width * layout.region.height else { return }
    let fields = grainFields(lum: lum, chroma: chroma, size: size, csize: csize, seed: seed, refWidth: refWidth, layout: layout)
    addGrain(&planes, luminance: luminance, lum: lum, chroma: chroma, curve: curve, fields: fields)
  }

  /// `addGrain` with its fields made beforehand (`grainFields`, the planes' size).
  static func addGrain(
    _ planes: inout EditPipeline.Planes, luminance: [Float], lum: Double, chroma: Double, curve: [Double]?, fields: GrainFields
  ) {
    let count = planes.r.count
    guard count == luminance.count, planes.width * planes.height == count else { return }
    let n0 = fields.luma.flatMap { $0.count == count ? $0 : nil }
    var c1 = fields.c1.flatMap { $0.count == count ? $0 : nil }
    var c2 = fields.c2.flatMap { $0.count == count ? $0 : nil }
    if c1 == nil || c2 == nil {
      c1 = nil
      c2 = nil
    }
    guard n0 != nil || c1 != nil else { return }
    let lumFloat = Float(lum), chromaFloat = Float(chroma), half = Float(0.5)
    let width = planes.width
    let rows = planes.height
    planes.r.withUnsafeMutableBufferPointer { r in
      planes.g.withUnsafeMutableBufferPointer { g in
        planes.b.withUnsafeMutableBufferPointer { b in
          let r = r, g = g, b = b
          DispatchQueue.concurrentPerform(iterations: rows) { row in
            for i in row * width..<(row + 1) * width {
              var luma: Float = 0
              if let n0 {
                if let curve {
                  // grain.py multiplies the float32 field by a float64 gain.
                  luma = Float(Double(n0[i]) * (lum * interp(Double(luminance[i]), curve: curve)))
                } else {
                  let l = luminance[i]
                  let gain = Float(0.55) + Float(0.9) * l.squareRoot() * (1 - half * l)
                  luma = n0[i] * (lumFloat * gain)
                }
              }
              if let c1, let c2 {
                let a = c1[i] * chromaFloat, bb = c2[i] * chromaFloat
                r[i] += luma + a
                g[i] += luma - half * (a + bb)
                b[i] += luma + bb
              } else {
                r[i] += luma
                g[i] += luma
                b[i] += luma
              }
            }
          }
        }
      }
    }
  }

  /// grain.py's `real_noise_texture`: random reference patches, each flipped across and/or down
  /// at random, tiled over `refWidth` × `round(refWidth × aspect)`; seeded with `seed + 1`. Three
  /// planes (R, G, B).
  static func realNoiseTexture(_ real: GrainProfile.RealNoise, refWidth: Int, aspect: Double, seed: Int) -> (width: Int, height: Int, planes: [[Float]]) {
    let p = real.patch
    let tw = refWidth, th = round(Double(refWidth) * aspect)
    var planes = [[Float]](repeating: [Float](repeating: 0, count: max(tw * th, 0)), count: 3)
    guard p > 0, real.count > 0, tw > 0, th > 0 else { return (tw, th, planes) }
    let patches = (0..<real.count).map { real.values(ofPatch: $0) }
    var random = Random(seed: seed + 1)
    for ty in stride(from: 0, to: th, by: p) {
      for tx in stride(from: 0, to: tw, by: p) {
        let values = patches[random.integer(below: patches.count)]
        let across = random.uniform() < 0.5
        let down = random.uniform() < 0.5
        guard values.count == p * p * 3 else { continue }
        for y in 0..<min(p, th - ty) {
          let sy = down ? p - 1 - y : y
          for x in 0..<min(p, tw - tx) {
            let sx = across ? p - 1 - x : x
            let source = (sy * p + sx) * 3
            let target = (ty + y) * tw + tx + x
            planes[0][target] = values[source]
            planes[1][target] = values[source + 1]
            planes[2][target] = values[source + 2]
          }
        }
      }
    }
    return (tw, th, planes)
  }

  /// The real-noise texture (`realNoiseTexture`) enlarged to the layout's region, three planes:
  /// what `addRealNoise` adds before its weight. Picture-independent, so `EditRenderer` keeps it.
  static func realNoiseField(_ real: GrainProfile.RealNoise, refWidth: Int, seed: Int, layout: Layout) -> [[Float]] {
    let texture = realNoiseTexture(real, refWidth: refWidth, aspect: layout.aspect, seed: seed)
    return texture.planes.map {
      Resample.resize($0, width: texture.width, height: texture.height, toWidth: layout.width, height: layout.height, region: layout.region)
    }
  }

  /// grain.py's real reference noise: the texture enlarged to the output (the layout's region)
  /// and added at `amount × interp(real.curve, L)`, in float64 as numpy does.
  static func addRealNoise(
    _ planes: inout EditPipeline.Planes, luminance: [Float], real: GrainProfile.RealNoise, amount: Double, refWidth: Int, seed: Int,
    layout: Layout
  ) {
    guard amount > 0, real.count > 0, planes.r.count == luminance.count, planes.r.count == layout.region.width * layout.region.height else { return }
    addRealNoise(&planes, luminance: luminance, curve: real.curve, amount: amount, field: realNoiseField(real, refWidth: refWidth, seed: seed, layout: layout))
  }

  /// `addRealNoise` with its field made beforehand (`realNoiseField`, the planes' size).
  static func addRealNoise(_ planes: inout EditPipeline.Planes, luminance: [Float], curve: [Double], amount: Double, field enlarged: [[Float]]) {
    let count = planes.r.count
    guard amount > 0, count == luminance.count, enlarged.count == 3, enlarged.allSatisfy({ $0.count == count }) else { return }
    let width = planes.width
    planes.withRowBands { rows, r, g, b in
      for i in rows.lowerBound * width..<rows.upperBound * width {
        let weight = amount * interp(Double(luminance[i]), curve: curve)
        r[i] = Float(Double(r[i]) + Double(enlarged[0][i]) * weight)
        g[i] = Float(Double(g[i]) + Double(enlarged[1][i]) * weight)
        b[i] = Float(Double(b[i]) + Double(enlarged[2][i]) * weight)
      }
    }
  }

  /// grain.py's `process` from end to end, at full size: motion smear (clamped), blur, colour
  /// match against `context.refStats`, exposure, tint, random grain, real noise. The Edit
  /// screen's pipeline runs these stages with its own in between; this is the script's look on
  /// its own (and the parity tests' reference).
  static func process(_ source: EditPipeline.Planes, settings s: GrainProfile.Settings, context: EditPipeline.Context = .empty) -> EditPipeline.Planes {
    var a = source
    if s.motion > 1 { a = motionSmear(a, length: s.motion, angle: s.angle) }
    a = blur(a, sigma: s.blur)
    if let reference = context.refStats, s.colour > 0 {
      a = colourMatch(a, source: channelStats(source), reference: reference, amount: s.colour)
    }
    exposure(&a, stops: s.expo)
    tint(&a, s.tint)
    let layout = Layout.whole(width: a.width, height: a.height)
    let l = luminance(a)
    let seed = s.seed ?? 7
    addGrain(
      &a, luminance: l, lum: s.lum, chroma: s.chroma, size: s.size, csize: s.csize, seed: seed, refWidth: context.refWidth,
      curve: context.curve, layout: layout)
    if let real = context.realNoise, s.real > 0 {
      addRealNoise(&a, luminance: l, real: real, amount: s.real, refWidth: context.refWidth, seed: seed, layout: layout)
    }
    return a
  }

  // MARK: - Match Reference

  /// One of the reference's flat patches (`extract_real_noise`): its noise (picture minus a 3 px
  /// blur) over its luminance spread `sd`, and its colour residuals (R−G and B−G, picture minus an
  /// 8 px blur). `patch` × `patch` planes.
  struct Patch: Sendable {
    var r: [Float]
    var g: [Float]
    var b: [Float]
    var sd: Double
    var cr: [Float]
    var cb: [Float]
  }

  /// `extract_real_noise`'s result: the flat patches, smoothest first, and the noise strength per
  /// brightness band.
  struct RealExtraction: Sendable {
    var patches: [Patch]
    var curve: [Double]
    var patch: Int
  }

  /// grain.py's `extract_real_noise(ref, patch)`: blocks of `patch` px every `patch / 2`, those of
  /// brightness 8–235 sorted by flatness (the 6 px blur's gradient), the flattest fifth (at least
  /// 12) kept. Nil when the reference has no such block.
  static func extractRealNoise(_ ref: EditPipeline.Planes, patch: Int = 48) -> RealExtraction? {
    let w = ref.width, h = ref.height
    guard w >= patch, h >= patch, patch >= 4 else { return nil }
    let d0 = [ref.r, ref.g, ref.b]
    let d3 = Blur.gauss(d0, width: w, height: h, sigma: 3)
    let d6 = Blur.gauss(d0, width: w, height: h, sigma: 6)
    let d8 = Blur.gauss(d0, width: w, height: h, sigma: 8)
    let y6 = luma(d6[0], d6[1], d6[2])
    let (gy, gx) = gradient(y6, width: w, height: h)
    var flatness = [Float](repeating: 0, count: w * h)
    for i in 0..<flatness.count { flatness[i] = abs(gx[i]) + abs(gy[i]) }
    let y3 = luma(d3[0], d3[1], d3[2])

    struct Block { var flatness: Float, bx: Int, by: Int, l: Float }
    let step = patch / 2
    let origins = Array(stride(from: 0, through: h - patch, by: step))
    var rows = [[Block]](repeating: [], count: origins.count)
    rows.withUnsafeMutableBufferPointer { rows in
      let rows = rows
      DispatchQueue.concurrentPerform(iterations: origins.count) { index in
        let by = origins[index]
        var found: [Block] = []
        for bx in stride(from: 0, through: w - patch, by: step) {
          let l = mean(strided(y3, width: w, rows: stride(from: by, to: by + patch, by: 3), columns: stride(from: bx, to: bx + patch, by: 3)))
          if l > 8, l < 235 {
            let f = mean(
              strided(
                flatness, width: w, rows: stride(from: by + 1, to: by + patch - 1, by: 3),
                columns: stride(from: bx + 1, to: bx + patch - 1, by: 3)))
            found.append(Block(flatness: f, bx: bx, by: by, l: l))
          }
        }
        rows[index] = found
      }
    }
    // Python sorts the tuples (flatness, bx, by, L).
    let blocks = rows.flatMap(\.self).sorted {
      if $0.flatness != $1.flatness { return $0.flatness < $1.flatness }
      if $0.bx != $1.bx { return $0.bx < $1.bx }
      if $0.by != $1.by { return $0.by < $1.by }
      return $0.l < $1.l
    }
    let flat = Array(blocks.prefix(max(12, blocks.count / 5)))
    guard !flat.isEmpty else { return nil }
    let mids = (0..<bandCentres.count - 1).map { (bandCentres[$0] + bandCentres[$0 + 1]) / 2 }

    var patches = [Patch?](repeating: nil, count: flat.count)
    patches.withUnsafeMutableBufferPointer { patches in
      // Each task writes only its own index.
      nonisolated(unsafe) let patches = patches
      DispatchQueue.concurrentPerform(iterations: flat.count) { index in
        let block = flat[index]
        func cut(_ plane: [Float]) -> [Float] { Grain.block(plane, width: w, x: block.bx, y: block.by, size: patch) }
        let c0 = d0.map(cut), c3 = d3.map(cut), c8 = d8.map(cut)
        let res = (0..<3).map { c in zip(c0[c], c3[c]).map { $0 - $1 } }
        let y = luma(res[0], res[1], res[2])
        let sd = Double(mean(y.map { $0 * $0 }).squareRoot()) + 1e-3
        let divisor = Float(sd)
        let n = patch * patch
        var cr = [Float](repeating: 0, count: n)
        var cb = cr
        for i in 0..<n {
          cr[i] = (c0[0][i] - c0[1][i]) - (c8[0][i] - c8[1][i])
          cb[i] = (c0[2][i] - c0[1][i]) - (c8[2][i] - c8[1][i])
        }
        patches[index] = Patch(
          r: res[0].map { $0 / divisor }, g: res[1].map { $0 / divisor }, b: res[2].map { $0 / divisor }, sd: sd, cr: cr, cb: cb)
      }
    }
    var bands = [[Double]](repeating: [], count: bandCentres.count)
    for (block, patch) in zip(flat, patches) {
      let ln = Double(block.l / 255)
      bands[mids.filter { $0 < ln }.count].append(patch!.sd)
    }
    let medians = bands.map { $0.isEmpty ? Double.nan : median($0) }
    let known = medians.enumerated().filter { !$0.element.isNaN }
    let curve = medians.enumerated().map { i, v -> Double in
      guard v.isNaN else { return v }
      // The nearest band with a value, the lower on a tie (Python's `min` keeps the first).
      var best = known[0]
      for k in known.dropFirst() where abs(k.offset - i) < abs(best.offset - i) { best = k }
      return best.element
    }
    return RealExtraction(patches: patches.map { $0! }, curve: curve, patch: patch)
  }

  /// grain.py's `autocorr(a, lag)` of a `width` × `height` plane: the correlation of the plane
  /// with itself shifted by `lag` across and down, averaged. NaN for a flat plane.
  static func autocorr(_ plane: [Float], width: Int, height: Int, lag: Int) -> Float {
    let m = mean(plane)
    let a = plane.map { $0 - m }
    let den = sum(a.map { $0 * $0 })
    if Double(den) < 1e-9 { return .nan }
    var across = [Float]()
    across.reserveCapacity(height * max(width - lag, 0))
    for y in 0..<height {
      for x in 0..<max(width - lag, 0) { across.append(a[y * width + x] * a[y * width + x + lag]) }
    }
    var down = [Float]()
    down.reserveCapacity(max(height - lag, 0) * width)
    for y in 0..<max(height - lag, 0) {
      for x in 0..<width { down.append(a[y * width + x] * a[(y + lag) * width + x]) }
    }
    let num = sum(across) + sum(down)
    return num / (2 * den)
  }

  /// grain.py's `lum_shape`: luminance autocorrelation at 1, 2 and 4 px, and its std.
  static func lumShape(_ r: [Float], _ g: [Float], _ b: [Float], width: Int, height: Int) -> (ac: [Float], sd: Double) {
    let y = luma(r, g, b)
    return ([1, 2, 4].map { autocorr(y, width: width, height: height, lag: $0) }, Double(std(y)))
  }

  /// grain.py's `colour_stats`: R−G and B−G autocorrelation at 1, 2, 4 and 8 px, and their mean std.
  static func colourStats(_ cr: [Float], _ cb: [Float], width: Int, height: Int) -> (ac: [Float], sd: Double) {
    let ac = [1, 2, 4, 8].map { lag in
      (autocorr(cr, width: width, height: height, lag: lag) + autocorr(cb, width: width, height: height, lag: lag)) / 2
    }
    return (ac, Double((std(cr) + std(cb)) / 2))
  }

  /// grain.py's `reference_stats`: what Match Reference fits to.
  struct ReferenceStats: Hashable, Sendable {
    /// Grain shape: luminance autocorrelation at 1, 2, 4 px.
    var yAC: [Double]
    /// Colour blotches: R−G/B−G autocorrelation at 1, 2, 4, 8 px.
    var cAC: [Double]
    /// Colour blotch strength.
    var cSD: Double
    /// Noise strength per brightness band.
    var curve: [Double]
  }

  /// grain.py's `reference_stats(real)`: grain shape and colour blotches averaged over up to ~120
  /// of the flat patches.
  static func referenceStats(_ real: RealExtraction) -> ReferenceStats {
    let points = real.patches
    let step = max(1, points.count / 120)
    let p = real.patch
    var yACs: [[Float]] = []
    var cACs: [[Float]] = []
    var cSDs: [Double] = []
    for patch in stride(from: 0, to: points.count, by: step).map({ points[$0] }) {
      let shape = lumShape(patch.r, patch.g, patch.b, width: p, height: p)
      if !shape.ac.contains(where: \.isNaN) { yACs.append(shape.ac) }
      let colour = colourStats(patch.cr, patch.cb, width: p, height: p)
      if !colour.ac.contains(where: \.isNaN) { cACs.append(colour.ac) }
      cSDs.append(colour.sd)
    }
    let yAC = yACs.isEmpty ? [Double](repeating: .nan, count: 3) : meanOfRows(yACs).map(Double.init)
    let cAC = cACs.isEmpty ? [0, 0, 0, 0] : meanOfRows(cACs).map(Double.init)
    return ReferenceStats(yAC: yAC, cAC: cAC, cSD: median(cSDs), curve: real.curve)
  }

  /// grain.py's `synth_stats(size)`: the same measurements of Atelier's random grain at `size`.
  struct SynthStats: Hashable, Sendable {
    var yAC: [Double]
    var cAC: [Double]
    var ySD: Double
    var cSD: Double
  }

  /// grain.py's `synth_stats(size, S, n)`: `n` trials of three fields (seeds `1000 + 3t + k`) of
  /// `S` px, measured as the reference is (high-passed by a 3 px blur for luma, 8 px for colour).
  static func synthStats(size: Double, side s: Int = 192, trials n: Int = 3) -> SynthStats {
    var yAC = [Double](repeating: 0, count: 3), cAC = [Double](repeating: 0, count: 4)
    var ySD = 0.0, cSD = 0.0
    let trials = Float(n)
    for t in 0..<n {
      let cells = max(4, round(Double(s) * 1.3 / size))
      let f = (0..<3).map { k in
        Resample.resize(noiseField(width: cells, height: cells, seed: 1000 + t * 3 + k), width: cells, height: cells, toWidth: s, height: s)
      }
      let lumBlur = Blur.gauss(f[0], width: s, height: s, sigma: 3)
      let hp = zip(f[0], lumBlur).map { $0 - $1 }
      let shape = lumShape(hp, hp, hp, width: s, height: s)
      for k in 0..<3 { yAC[k] += Double(shape.ac[k] / trials) }
      ySD += shape.sd / Double(n)
      let half = Float(-0.5)
      let col = [f[1], zip(f[1], f[2]).map { half * ($0 + $1) }, f[2]]
      let blurred = Blur.gauss(col, width: s, height: s, sigma: 8)
      let chp = (0..<3).map { c in zip(col[c], blurred[c]).map { $0 - $1 } }
      let cr = zip(chp[0], chp[1]).map { $0 - $1 }
      let cb = zip(chp[2], chp[1]).map { $0 - $1 }
      let colour = colourStats(cr, cb, width: s, height: s)
      for k in 0..<4 { cAC[k] += Double(colour.ac[k] / trials) }
      cSD += colour.sd / Double(n)
    }
    return SynthStats(yAC: yAC, cAC: cAC, ySD: ySD, cSD: cSD)
  }

  /// `synthStats` for each of `sizes`, made once (the seeds are fixed, so they never change).
  static let synthTable: [SynthStats] = {
    let sizes = EditOptions.Grain.sizes
    var table = [SynthStats?](repeating: nil, count: sizes.count)
    table.withUnsafeMutableBufferPointer { table in
      // Each task writes only its own index.
      nonisolated(unsafe) let table = table
      DispatchQueue.concurrentPerform(iterations: sizes.count) { table[$0] = synthStats(size: sizes[$0]) }
    }
    return table.map { $0! }
  }()

  /// What Match Reference finds (grain.py's `match_reference`): the grain settings that rebuild
  /// the reference's noise, the brightness curve, the real noise as a profile stores it, and the
  /// measurements behind them (the reference's, and Atelier's grain at the fitted sizes).
  struct Match: Sendable {
    var size: Double
    var csize: Double
    var lum: Double
    var chroma: Double
    var curve: [Double]
    var real: GrainProfile.RealNoise
    var reference: ReferenceStats
    var ours: (luma: SynthStats, colour: SynthStats)
  }

  /// grain.py's `match_reference(ref)`: extract, measure, then the `SIZES` whose grain shape and
  /// colour blotches are closest (the first on a tie), the strength from the brightness curve's
  /// peak over that size's spread (one decimal), the curve over that peak.
  static func matchReference(_ ref: EditPipeline.Planes) -> Match? {
    guard let real = extractRealNoise(ref) else { return nil }
    let t = referenceStats(real)
    let table = synthTable
    let sizes = EditOptions.Grain.sizes
    func closest(_ distance: (SynthStats) -> Double) -> Int {
      var best = 0
      var bestDistance = Double.infinity
      for (i, stats) in table.enumerated() {
        let d = distance(stats)
        if d < bestDistance {
          best = i
          bestDistance = d
        }
      }
      return best
    }
    let sizeIndex = closest { s in zip(s.yAC, t.yAC).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } }
    let csizeIndex = closest { s in zip(s.cAC, t.cAC).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } }
    let amps = t.curve.map { $0 / table[sizeIndex].ySD }
    let lum = amps.max() ?? 0
    return Match(
      size: sizes[sizeIndex], csize: sizes[csizeIndex], lum: round1(lum), chroma: round1(t.cSD / table[csizeIndex].cSD),
      curve: amps.map { $0 / lum }, real: encodedRealNoise(real), reference: t, ours: (table[sizeIndex], table[csizeIndex]))
  }

  /// The real noise as grain.py's `save_profile` stores it: every `count / 120`th patch, at most
  /// 120, each value a byte `clip(round(128 + value × 24))`, HWC interleaved.
  static func encodedRealNoise(_ real: RealExtraction, maxPatches: Int = 120, enc: Int = 24) -> GrainProfile.RealNoise {
    let step = max(1, real.patches.count / maxPatches)
    let chosen = Array(stride(from: 0, to: real.patches.count, by: step).map { real.patches[$0] }.prefix(maxPatches))
    let n = real.patch * real.patch
    var bytes = [UInt8](repeating: 0, count: chosen.count * n * 3)
    let scale = Float(enc)
    func byte(_ v: Float) -> UInt8 { UInt8(min(max((128 + v * scale).rounded(.toNearestOrEven), 0), 255)) }
    for (index, patch) in chosen.enumerated() {
      let base = index * n * 3
      for i in 0..<n {
        bytes[base + i * 3] = byte(patch.r[i])
        bytes[base + i * 3 + 1] = byte(patch.g[i])
        bytes[base + i * 3 + 2] = byte(patch.b[i])
      }
    }
    return GrainProfile.RealNoise(patch: real.patch, count: chosen.count, enc: Double(enc), curve: real.curve, data: Data(bytes))
  }
}
