import Foundation

/// The Edit screen's built-in LUTs: ten looks that are Atelier's own, written from scratch as
/// formulas (no third-party LUT, film emulation or preset went into them), and baked into 33³
/// tables, sRGB in and out, the first time each is chosen. Shipping the formulas rather than
/// `.cube` text keeps about 10 MB of tables out of the app. A saved step embeds the table it was
/// made with, so changing a formula here never changes a step already saved.
///
/// Each look is a chain of the small operations below on an RGB colour in 0–1, worked in Double
/// and clipped to 0–1 at the end. Values may leave 0–1 between steps, as the formulas were
/// written to allow.
enum BuiltInLUTs {
  /// The looks, in the order the LUT menu lists them.
  static let names = [
    "Warm Film", "Teal and Orange", "Faded Matte", "Punchy Slide", "Bleach Bypass",
    "Sodium Night", "Cool Phone Night", "Golden Hour", "Tri-X Mono", "Cross Process",
  ]

  /// Each table's grid, as the `.cube` files the formulas were first written out as.
  static let size = 33

  @MainActor private static var cache: [String: Edit.LUTTable] = [:]

  /// The baked table for `name`, nil for a name that isn't a built-in. Baked once per run.
  @MainActor static func table(_ name: String) -> Edit.LUTTable? {
    if let cached = cache[name] { return cached }
    guard let look = look(name) else { return nil }
    let table = CubeLUT.bake(size: size, name: name) { color in
      let out = look(RGB(Double(color[0]), Double(color[1]), Double(color[2])))
      return [Float(clip(out.r)), Float(clip(out.g)), Float(clip(out.b))]
    }
    cache[name] = table
    return table
  }

  /// The built-in a table is, by its digest, so a step saved with one shows it chosen.
  @MainActor static func name(of table: Edit.LUTTable?) -> String? {
    guard let table, names.contains(table.name) else { return nil }
    return self.table(table.name)?.digest == table.digest ? table.name : nil
  }

  /// One colour through the look, unclipped; nil for an unknown name. For tests and baking.
  static func look(_ name: String) -> ((RGB) -> RGB)? {
    switch name {
    case "Warm Film": warmFilm
    case "Teal and Orange": tealOrange
    case "Faded Matte": fadedMatte
    case "Punchy Slide": punchySlide
    case "Bleach Bypass": bleachBypass
    case "Sodium Night": sodiumNight
    case "Cool Phone Night": coolPhoneNight
    case "Golden Hour": goldenHour
    case "Tri-X Mono": triXMono
    case "Cross Process": crossProcess
    default: nil
    }
  }

  /// A colour, or a per-channel amount.
  struct RGB: Equatable {
    var r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) {
      self.r = r
      self.g = g
      self.b = b
    }

    init(all value: Double) { self.init(value, value, value) }

    static func + (a: RGB, b: RGB) -> RGB { RGB(a.r + b.r, a.g + b.g, a.b + b.b) }
    static func - (a: RGB, b: RGB) -> RGB { RGB(a.r - b.r, a.g - b.g, a.b - b.b) }
    static func * (a: RGB, b: RGB) -> RGB { RGB(a.r * b.r, a.g * b.g, a.b * b.b) }
    static func * (a: RGB, s: Double) -> RGB { RGB(a.r * s, a.g * s, a.b * s) }
    static func + (a: RGB, s: Double) -> RGB { RGB(a.r + s, a.g + s, a.b + s) }
    func map(_ f: (Double) -> Double) -> RGB { RGB(f(r), f(g), f(b)) }
  }

  // MARK: Operations

  private static func clip(_ x: Double) -> Double { min(max(x, 0), 1) }

  /// Rec. 601 luma.
  private static func luma(_ x: RGB) -> Double { x.r * 0.299 + x.g * 0.587 + x.b * 0.114 }

  private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clip((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)
  }

  /// Contrast around mid grey that keeps 0 and 1 where they are.
  private static func scurve(_ x: Double, _ amount: Double) -> Double {
    let s = x * x * (3 - 2 * x)
    return x + (s - x) * amount
  }

  private static func scurve(_ x: RGB, _ amount: Double) -> RGB { x.map { scurve($0, amount) } }

  private static func sat(_ x: RGB, _ s: Double) -> RGB {
    let y = luma(x)
    return x.map { y + ($0 - y) * s }
  }

  private static func liftGain(_ x: Double, _ lift: Double, _ gain: Double) -> Double { lift + x * (gain - lift) }

  private static func liftGain(_ x: RGB, _ lift: Double, _ gain: Double) -> RGB { x.map { liftGain($0, lift, gain) } }

  /// Adds `shadow` to the darks and `highlight` to the lights, fading across the mids.
  private static func splitTone(_ x: RGB, _ shadow: RGB, _ highlight: RGB) -> RGB {
    let y = luma(x)
    return x + shadow * (1 - smooth(0, 0.55, y)) + highlight * smooth(0.45, 1, y)
  }

  /// How much a colour is of the hue `centre` (degrees, HSV), falling to 0 at `width` away,
  /// times how coloured it is (no weight for greys).
  private static func hueMask(_ x: RGB, _ centre: Double, _ width: Double) -> Double {
    let mx = max(x.r, x.g, x.b), mn = min(x.r, x.g, x.b)
    let d = mx - mn + 1e-9
    let sector = if mx == x.r { floorMod((x.g - x.b) / d, 6) } else if mx == x.g { (x.b - x.r) / d + 2 } else { (x.r - x.g) / d + 4 }
    let distance = abs(floorMod(sector * 60 - centre + 180, 360) - 180)
    return clip(1 - distance / width) * clip(d * 3)
  }

  /// The remainder with the divisor's sign, as Python's `%`.
  private static func floorMod(_ a: Double, _ b: Double) -> Double { a - b * (a / b).rounded(.down) }

  // MARK: Looks

  private static func warmFilm(_ x: RGB) -> RGB {
    var x = liftGain(x, 0.035, 0.98)
    x = scurve(x, 0.35)
    x = splitTone(x, RGB(-0.010, 0.006, 0.018), RGB(0.030, 0.012, -0.025))
    let greens = hueMask(x, 110, 50)
    x = x - (x - RGB(all: luma(x))) * (greens * 0.35) // tame greens
    return sat(x, 0.92)
  }

  private static func tealOrange(_ x: RGB) -> RGB {
    var x = scurve(x, 0.45)
    x = splitTone(x, RGB(-0.035, 0.010, 0.040), RGB(0.040, 0.010, -0.040))
    let skin = hueMask(x, 25, 30)
    x = x + RGB(0.02, 0.005, -0.015) * skin
    return sat(x, 1.08)
  }

  private static func fadedMatte(_ x: RGB) -> RGB {
    var x = liftGain(x, 0.09, 0.93)
    x = scurve(x, 0.15)
    x = splitTone(x, RGB(0, 0.006, 0.012), RGB(0.012, 0.008, 0))
    return sat(x, 0.78)
  }

  private static func punchySlide(_ x: RGB) -> RGB {
    var x = scurve(x, 0.7)
    let reds = hueMask(x, 5, 40)
    let yellows = hueMask(x, 50, 30)
    x = x + RGB(0.03, -0.01, -0.01) * reds + RGB(0.02, 0.015, -0.03) * yellows
    let blues = hueMask(x, 220, 40)
    x = x + RGB(-0.01, 0, 0.025) * blues
    return sat(x, 1.22)
  }

  private static func bleachBypass(_ x: RGB) -> RGB {
    let y = luma(x)
    var x = x * 0.55 + y * 0.45
    x = scurve(x, 0.9)
    return liftGain(x, 0.01, 1)
  }

  /// An orange street-light cast in the mids and highlights, cyan-green shadows, crushed blacks.
  private static func sodiumNight(_ x: RGB) -> RGB {
    var x = x.map { clip($0 - 0.015) / 0.985 }
    x = scurve(x, 0.4)
    x = splitTone(x, RGB(-0.02, 0.018, 0.02), RGB(0.06, 0.02, -0.06))
    return sat(x, 0.9)
  }

  /// Slightly lifted shadows, a cool white balance and a little more saturation.
  private static func coolPhoneNight(_ x: RGB) -> RGB {
    var x = liftGain(x, 0.02, 1)
    x = x * RGB(0.95, 1, 1.07)
    x = scurve(x, 0.2)
    return sat(x, 1.1)
  }

  private static func goldenHour(_ x: RGB) -> RGB {
    var x = x * RGB(1.06, 1, 0.88)
    x = splitTone(x, RGB(0.015, 0, -0.01), RGB(0.02, 0.01, -0.02))
    x = scurve(x, 0.25)
    return sat(x, 1.05)
  }

  /// Black and white through a red filter's weights, a strong S-curve, slightly lifted.
  private static func triXMono(_ x: RGB) -> RGB {
    var y = x.r * 0.45 + x.g * 0.45 + x.b * 0.10
    y = scurve(y, 0.6)
    y = liftGain(y, 0.02, 0.99)
    return RGB(all: y)
  }

  private static func crossProcess(_ x: RGB) -> RGB {
    let r = scurve(x.r, 0.6)
    let g = scurve(x.g, 0.3) * 1.02 + 0.01
    let b = liftGain(x.b, 0.10, 0.82)
    return sat(RGB(r, g, b), 1.05)
  }
}
