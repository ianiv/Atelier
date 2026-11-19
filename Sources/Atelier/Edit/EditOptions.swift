import Foundation

/// Every setting of the Edit screen's look, in pipeline order (`EditPipeline`): what the
/// inspector shows, what a saved step records (`Edit.Record.options`), and what the screen's
/// caches are keyed by, so it's `Hashable` and holds settings only. What a look is rendered
/// *with* (a profile's brightness curve and real noise, a reference's measurements, a LUT's
/// table) is `EditPipeline.Context`'s.
///
/// The grain and lens settings take grain.py's names and defaults (Lira's `grain.py`, the script
/// and Grain Studio this screen ports), so its `.grain.json` profiles map onto them one for one
/// (`GrainProfile.Settings`). That makes `EditOptions()` grain.py's default look (blur 3, grain 9,
/// colour noise 3, seed 7), not a no-op; `identity` is the look that leaves an image alone. Every
/// other section defaults to doing nothing.
///
/// Each section decodes missing keys as its defaults, so records and remembered settings saved
/// before a setting existed still read.
nonisolated struct EditOptions: Codable, Hashable, Sendable {
  var match = Match()
  var histogram = Histogram()
  var grade = Grade()
  var lut = LUTRef()
  var halation = Halation()
  var lens = Lens()
  var vignette = Vignette()
  var grain = Grain()

  init(
    match: Match = Match(), histogram: Histogram = Histogram(), grade: Grade = Grade(), lut: LUTRef = LUTRef(),
    halation: Halation = Halation(), lens: Lens = Lens(), vignette: Vignette = Vignette(), grain: Grain = Grain()
  ) {
    self.match = match
    self.histogram = histogram
    self.grade = grade
    self.lut = lut
    self.halation = halation
    self.lens = lens
    self.vignette = vignette
    self.grain = grain
  }

  /// The look that leaves an image as it is: grain.py's defaults with the blur and grain off.
  static let identity = EditOptions(lens: Lens(blur: 0), grain: Grain(lum: 0, chroma: 0))

  /// Whether rendering with these options gives back the source unchanged (`EditPipeline.render`
  /// skips every step then).
  var isIdentity: Bool {
    match.isIdentity && histogram.isIdentity && grade.isIdentity && lut.isIdentity && halation.isIdentity
      && lens.isIdentity && vignette.isIdentity && grain.isIdentity
  }

  /// Every amount kept to its range and rounded to the inspector's steps, so two looks with the
  /// same settings compare equal (`Edit.Job.isSameEdit`) and key the same cache entry however
  /// their numbers were arrived at (a slider drag, an agent's JSON, a profile).
  var snapped: EditOptions {
    EditOptions(
      match: match.snapped, histogram: histogram.snapped, grade: grade.snapped, lut: lut.snapped,
      halation: halation.snapped, lens: lens.snapped, vignette: vignette.snapped, grain: grain.snapped)
  }

  private enum CodingKeys: String, CodingKey { case match, histogram, grade, lut, halation, lens, vignette, grain }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    match = try c.decodeIfPresent(Match.self, forKey: .match) ?? Match()
    histogram = try c.decodeIfPresent(Histogram.self, forKey: .histogram) ?? Histogram()
    grade = try c.decodeIfPresent(Grade.self, forKey: .grade) ?? Grade()
    lut = try c.decodeIfPresent(LUTRef.self, forKey: .lut) ?? LUTRef()
    halation = try c.decodeIfPresent(Halation.self, forKey: .halation) ?? Halation()
    lens = try c.decodeIfPresent(Lens.self, forKey: .lens) ?? Lens()
    vignette = try c.decodeIfPresent(Vignette.self, forKey: .vignette) ?? Vignette()
    grain = try c.decodeIfPresent(Grain.self, forKey: .grain) ?? Grain()
  }

  /// `value` kept to `range` and rounded to a multiple of `step`.
  static func snap(_ value: Double, _ range: ClosedRange<Double>, step: Double = 0.01) -> Double {
    guard value.isFinite else { return range.lowerBound }
    return ((min(max(value, range.lowerBound), range.upperBound) / step).rounded() * step * 1e6).rounded() / 1e6
  }

  // MARK: - Match (pipeline steps 3 to 5)

  /// Matching the image's colors to another's: Reinhard Lab transfer (`ColorMatch`, step 3) to
  /// the reference or the step's original, and grain.py's per-RGB mean and spread match to the
  /// profile's `refStats` (`colour`, step 5). The amounts run 0 (leave it) to 1 (match fully),
  /// as `ColorMatch.Options`'s do, but default to 0 here: the Edit screen matches only when asked.
  struct Match: Codable, Hashable, Sendable {
    /// What the Reinhard and histogram matches move toward.
    enum Target: String, Codable, Hashable, Sendable, CaseIterable {
      /// The reference image picked in Look (a file, a History step, a moodboard image).
      case reference
      /// The image the step was made from (`CreateModel.originalImage`), as Match Colors… uses.
      case original
    }

    var target: Target = .reference
    /// As `ColorMatch.Options`: the means of a and b, their spreads, the mean of L, its spread.
    var tint: Double = 0
    var saturation: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    /// grain.py's `colour`: how far each RGB channel's mean and spread move to the profile's
    /// reference (`EditPipeline.Context.refStats`), the source measured before blurring as
    /// grain.py measures it. Does nothing without `refStats`.
    var colour: Double = 0

    init(target: Target = .reference, tint: Double = 0, saturation: Double = 0, brightness: Double = 0, contrast: Double = 0, colour: Double = 0) {
      self.target = target
      self.tint = tint
      self.saturation = saturation
      self.brightness = brightness
      self.contrast = contrast
      self.colour = colour
    }

    /// Whether the Reinhard step does anything.
    var matchesLab: Bool { tint > 0 || saturation > 0 || brightness > 0 || contrast > 0 }
    var isIdentity: Bool { !matchesLab && colour <= 0 }

    /// The Reinhard amounts as Match Colors… takes them, measured over the whole image.
    var colorMatchOptions: ColorMatch.Options {
      ColorMatch.Options(tint: tint, saturation: saturation, brightness: brightness, contrast: contrast)
    }

    var snapped: Match {
      Match(
        target: target, tint: EditOptions.snap(tint, 0...1), saturation: EditOptions.snap(saturation, 0...1),
        brightness: EditOptions.snap(brightness, 0...1), contrast: EditOptions.snap(contrast, 0...1),
        colour: EditOptions.snap(colour, 0...1))
    }

    private enum CodingKeys: String, CodingKey { case target, tint, saturation, brightness, contrast, colour }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      target = try c.decodeIfPresent(Target.self, forKey: .target) ?? .reference
      tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
      saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
      brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
      contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
      colour = try c.decodeIfPresent(Double.self, forKey: .colour) ?? 0
    }
  }

  // MARK: - Histogram (step 4)

  /// Histogram (CDF) matching to the match target (`Match.target`): each level moved to where the
  /// target's cumulative histogram has the same share of pixels below it.
  struct Histogram: Codable, Hashable, Sendable {
    enum Space: String, Codable, Hashable, Sendable, CaseIterable {
      /// Luma only (Rec. 601, as grain.py's `luma`), each pixel's RGB scaled together, so the
      /// colors stay the image's own. The default: matching RGB separately moves hues.
      case luma
      /// Red, green and blue each matched on its own.
      case rgb
    }

    /// 0 (leave it) to 1 (match fully).
    var amount: Double = 0
    var space: Space = .luma

    init(amount: Double = 0, space: Space = .luma) {
      self.amount = amount
      self.space = space
    }

    var isIdentity: Bool { amount <= 0 }
    var snapped: Histogram { Histogram(amount: EditOptions.snap(amount, 0...1), space: space) }

    private enum CodingKeys: String, CodingKey { case amount, space }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
      space = try c.decodeIfPresent(Space.self, forKey: .space) ?? .luma
    }
  }

  // MARK: - Grade (step 6)

  /// The basic grade, applied in this order: exposure, then temperature and tint, contrast,
  /// saturation and vibrance. All 0 leaves the image alone.
  struct Grade: Codable, Hashable, Sendable {
    /// Stops: the image times 2^exposure, grain.py's `expo`.
    var exposure: Double = 0
    /// Cooler (−) to warmer (+), −100 to 100.
    var temperature: Double = 0
    /// grain.py's `tint`, green (−) to magenta (+), −30 to 30, by its formula: green less
    /// tint/2, red and blue more tint/4 each, in 0–255 units.
    var tint: Double = 0
    /// −1 to 1 around mid grey.
    var contrast: Double = 0
    /// −1 (grey) to 1.
    var saturation: Double = 0
    /// Saturation that moves muted colors more than saturated ones, −1 to 1.
    var vibrance: Double = 0

    static let exposureRange = -3.0...3.0
    static let temperatureRange = -100.0...100.0
    static let tintRange = -30.0...30.0
    static let unitRange = -1.0...1.0

    init(exposure: Double = 0, temperature: Double = 0, tint: Double = 0, contrast: Double = 0, saturation: Double = 0, vibrance: Double = 0) {
      self.exposure = exposure
      self.temperature = temperature
      self.tint = tint
      self.contrast = contrast
      self.saturation = saturation
      self.vibrance = vibrance
    }

    var isIdentity: Bool { exposure == 0 && temperature == 0 && tint == 0 && contrast == 0 && saturation == 0 && vibrance == 0 }

    var snapped: Grade {
      Grade(
        exposure: EditOptions.snap(exposure, Self.exposureRange), temperature: EditOptions.snap(temperature, Self.temperatureRange, step: 0.1),
        tint: EditOptions.snap(tint, Self.tintRange, step: 0.1), contrast: EditOptions.snap(contrast, Self.unitRange),
        saturation: EditOptions.snap(saturation, Self.unitRange), vibrance: EditOptions.snap(vibrance, Self.unitRange))
    }

    private enum CodingKeys: String, CodingKey { case exposure, temperature, tint, contrast, saturation, vibrance }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
      temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
      tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
      contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
      saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
      vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
    }
  }

  // MARK: - LUT (step 7)

  /// Which 3D LUT is applied, and how strongly. The table itself is the context's
  /// (`EditPipeline.Context.lut`) and the record's (`Edit.Record.lut`); `digest` names its
  /// contents so a cache keyed by options tells two tables of the same name apart.
  struct LUTRef: Codable, Hashable, Sendable {
    /// The `.cube` file's name, nil for no LUT.
    var name: String?
    /// `Edit.LUTTable.digest` of the table loaded under `name`.
    var digest: String?
    /// 0 (leave it) to 1 (the LUT's output).
    var strength: Double = 1

    init(name: String? = nil, digest: String? = nil, strength: Double = 1) {
      self.name = name
      self.digest = digest
      self.strength = strength
    }

    var isIdentity: Bool { name == nil || strength <= 0 }
    var snapped: LUTRef { LUTRef(name: name, digest: digest, strength: EditOptions.snap(strength, 0...1)) }

    private enum CodingKeys: String, CodingKey { case name, digest, strength }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      name = try c.decodeIfPresent(String.self, forKey: .name)
      digest = try c.decodeIfPresent(String.self, forKey: .digest)
      strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
    }
  }

  // MARK: - Halation (step 8)

  /// Film halation: a warm glow spread around highlights. Only light above `threshold` glows.
  struct Halation: Codable, Hashable, Sendable {
    /// 0 (none) to 1.
    var amount: Double = 0
    /// The luminance, 0 to 1, above which light glows.
    var threshold: Double = 0.8
    /// The glow's spread, px at full size (a `Blur.gauss` sigma).
    var radius: Double = 20
    /// 0 (the highlight's own color) to 1 (film's red-orange).
    var warmth: Double = 0.6

    static let radiusRange = 1.0...200.0

    init(amount: Double = 0, threshold: Double = 0.8, radius: Double = 20, warmth: Double = 0.6) {
      self.amount = amount
      self.threshold = threshold
      self.radius = radius
      self.warmth = warmth
    }

    var isIdentity: Bool { amount <= 0 }

    var snapped: Halation {
      Halation(
        amount: EditOptions.snap(amount, 0...1), threshold: EditOptions.snap(threshold, 0...1),
        radius: EditOptions.snap(radius, Self.radiusRange, step: 0.1), warmth: EditOptions.snap(warmth, 0...1))
    }

    private enum CodingKeys: String, CodingKey { case amount, threshold, radius, warmth }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
      threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.8
      radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 20
      warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0.6
    }
  }

  // MARK: - Lens (steps 1 and 2)

  /// grain.py's motion smear and blur, px at full size (scaled by the preview's ratio when the
  /// preview is smaller, as Grain Studio does).
  ///
  /// The smear differs from grain.py's in one way, by the user's choice: grain.py shifts with
  /// `np.roll`, so the far edge wraps into the near one; here the shifted image clamps at the
  /// edges (repeats its edge pixels) instead. Inside the frame it's the same average.
  struct Lens: Codable, Hashable, Sendable {
    /// Slow-shutter smear length, px; grain.py smears only above 1 (`--motion`).
    var motion: Double = 0
    /// Smear direction, degrees, 0 = horizontal (`--angle`).
    var angle: Double = 0
    /// Softening before grain, a Gaussian sigma in px (`--blur`, default 3); none below 0.3.
    var blur: Double = 3

    static let motionRange = 0.0...200.0
    static let angleRange = -180.0...180.0
    static let blurRange = 0.0...50.0

    init(motion: Double = 0, angle: Double = 0, blur: Double = 3) {
      self.motion = motion
      self.angle = angle
      self.blur = blur
    }

    /// grain.py's thresholds: `motion > 1` smears, `gauss` returns the image for sigma < 0.3.
    var smears: Bool { motion > 1 }
    var blurs: Bool { blur >= 0.3 }
    var isIdentity: Bool { !smears && !blurs }

    var snapped: Lens {
      Lens(
        motion: EditOptions.snap(motion, Self.motionRange, step: 0.1), angle: EditOptions.snap(angle, Self.angleRange, step: 0.1),
        blur: EditOptions.snap(blur, Self.blurRange))
    }

    private enum CodingKeys: String, CodingKey { case motion, angle, blur }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      motion = try c.decodeIfPresent(Double.self, forKey: .motion) ?? 0
      angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
      blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 3
    }
  }

  // MARK: - Vignette (step 9)

  /// Darkens (or, below 0, lightens) toward the corners.
  struct Vignette: Codable, Hashable, Sendable {
    /// −1 (lighten) to 1 (darken).
    var amount: Double = 0
    /// Where the falloff starts, 0 (the centre) to 1 (the corners).
    var size: Double = 0.5
    /// 0 (a hard edge) to 1 (the softest).
    var softness: Double = 0.5

    init(amount: Double = 0, size: Double = 0.5, softness: Double = 0.5) {
      self.amount = amount
      self.size = size
      self.softness = softness
    }

    var isIdentity: Bool { amount == 0 }

    var snapped: Vignette {
      Vignette(amount: EditOptions.snap(amount, -1...1), size: EditOptions.snap(size, 0...1), softness: EditOptions.snap(softness, 0...1))
    }

    private enum CodingKeys: String, CodingKey { case amount, size, softness }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
      size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.5
      softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.5
    }
  }

  // MARK: - Grain (steps 10 and 11)

  /// grain.py's random and real grain, by its names and defaults. The grain's scale follows the
  /// profile's reference width (`EditPipeline.Context.refWidth`, 1440 without one), and its
  /// strength by brightness the profile's curve (`Context.curve`), as `process` does.
  struct Grain: Codable, Hashable, Sendable {
    /// Luminance grain strength (`--lum`, default 9).
    var lum: Double = 9
    /// Grain size, 1 = default, higher = coarser (`--size`).
    var size: Double = 1
    /// Colour noise strength (`--chroma`, default 3).
    var chroma: Double = 3
    /// Colour blotch size, 1 = default (`--csize`).
    var csize: Double = 1
    /// The profile's real reference noise, 1 = the reference's amount (`--real`). Does nothing
    /// without the profile's patches (`Context.realNoise`).
    var real: Double = 0
    /// grain.py's `--seed`: the luma field uses it, the two colour fields seed+99 and seed+199,
    /// the real-noise tiling seed+1.
    var seed: Int = 7

    /// grain.py's `SIZES`, the grain sizes Match Reference fits from.
    static let sizes: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.15, 1.3, 1.5, 1.75, 2, 2.4, 2.8, 3.3, 4, 5, 6, 8, 10, 13]
    static let strengthRange = 0.0...60.0
    static let sizeRange = 0.25...20.0
    static let realRange = 0.0...4.0

    init(lum: Double = 9, size: Double = 1, chroma: Double = 3, csize: Double = 1, real: Double = 0, seed: Int = 7) {
      self.lum = lum
      self.size = size
      self.chroma = chroma
      self.csize = csize
      self.real = real
      self.seed = seed
    }

    var isIdentity: Bool { lum == 0 && chroma == 0 && real <= 0 }

    var snapped: Grain {
      Grain(
        lum: EditOptions.snap(lum, Self.strengthRange, step: 0.1), size: EditOptions.snap(size, Self.sizeRange),
        chroma: EditOptions.snap(chroma, Self.strengthRange, step: 0.1), csize: EditOptions.snap(csize, Self.sizeRange),
        real: EditOptions.snap(real, Self.realRange), seed: seed)
    }

    private enum CodingKeys: String, CodingKey { case lum, size, chroma, csize, real, seed }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      lum = try c.decodeIfPresent(Double.self, forKey: .lum) ?? 9
      size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
      chroma = try c.decodeIfPresent(Double.self, forKey: .chroma) ?? 3
      csize = try c.decodeIfPresent(Double.self, forKey: .csize) ?? 1
      real = try c.decodeIfPresent(Double.self, forKey: .real) ?? 0
      seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? 7
    }
  }
}
