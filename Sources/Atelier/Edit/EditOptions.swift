import Foundation

/// Every setting of the Edit screen's look, in pipeline order (`EditPipeline`): what the
/// inspector shows, what a saved step records (`Edit.Record.options`), and what the screen's
/// caches are keyed by, so it's `Hashable` and holds settings only. What a look is rendered
/// *with* (a profile's brightness curve and real noise, a reference's measurements, a LUT's
/// table) is `EditPipeline.Context`'s.
///
/// The grain and lens settings take grain.py's names and defaults (Lira's `grain.py`, the script
/// and Grain Studio this screen ports), so its `.grain.json` profiles map onto them one for one
/// (`GrainProfile.Settings`). That makes `EditOptions()` (also `grainDefaults`) grain.py's default
/// look (blur 3, grain 9, colour noise 3, seed 7), not a no-op: it's what the Edit screen starts
/// from. `identity` is the look that leaves an image alone. Every other section's defaults do
/// nothing.
///
/// Decoding is not `init()`: a key that's missing (or of the wrong type, or an unknown case)
/// means *no change*. Plain decoding starts from `identity`, so a record or remembered settings
/// saved before a setting existed, or an agent's partial JSON, leave out what they don't name
/// rather than adding grain.py's blur and grain. To lay a partial look over another, decode with
/// `decoded(from:over:)`: the keys it names replace the base's, the rest stay the base's. Nothing
/// here throws on a bad value, so one setting never loses the rest.
///
/// `off` names the stages turned off (the sidebar sections' checkboxes): their settings stay
/// here, so turning one back on brings them back, and what renders is `rendered`, with those
/// stages' settings as no change. A missing `off` key is the base's (all on from `identity`),
/// an unknown stage name is dropped, and an empty `off` isn't encoded, so an all-on look
/// encodes as it did before stages could be turned off. `lookOff` is the master switch over
/// them all (the sidebar's Look checkbox): it renders no look at all and leaves `off` as it is,
/// so turning it back on brings back the stages that were on. It's read and written the same
/// way: missing is on, and it's written only when it's off.
nonisolated struct EditOptions: Codable, Hashable, Sendable {
  var match = Match()
  var histogram = Histogram()
  var grade = Grade()
  var lut = LUTRef()
  var halation = Halation()
  var lens = Lens()
  var vignette = Vignette()
  var grain = Grain()
  /// The stages turned off, their settings kept (`rendered`).
  var off: Set<Stage> = []
  /// The whole look turned off, `off` and every setting kept (`rendered`).
  var lookOff = false

  init(
    match: Match = Match(), histogram: Histogram = Histogram(), grade: Grade = Grade(), lut: LUTRef = LUTRef(),
    halation: Halation = Halation(), lens: Lens = Lens(), vignette: Vignette = Vignette(), grain: Grain = Grain(),
    off: Set<Stage> = [], lookOff: Bool = false
  ) {
    self.match = match
    self.histogram = histogram
    self.grade = grade
    self.lut = lut
    self.halation = halation
    self.lens = lens
    self.vignette = vignette
    self.grain = grain
    self.off = off
    self.lookOff = lookOff
  }

  /// A part of the look the sidebar turns on and off as one, one per sidebar section, in
  /// pipeline order (`EditPipeline`).
  enum Stage: String, Codable, CaseIterable, Hashable, Sendable, Comparable {
    /// The motion smear and blur, steps 1 and 2 (`lens`).
    case lens
    /// The Reinhard Lab match, the histogram match and grain.py's colour match, steps 3 to 5
    /// (`match` and `histogram`, one sidebar section).
    case match
    /// Step 6 (`grade`).
    case grade
    /// Step 7 (`lut`).
    case lut
    /// Step 8 (`halation`).
    case halation
    /// Step 9 (`vignette`).
    case vignette
    /// The random grain and the real noise, steps 10 and 11 (`grain`).
    case grain

    /// The sidebar section's title.
    var title: String {
      switch self {
      case .lens: "Lens"
      case .match: "Match"
      case .grade: "Grade"
      case .lut: "LUT"
      case .halation: "Halation"
      case .vignette: "Vignette"
      case .grain: "Grain"
      }
    }

    static func < (a: Stage, b: Stage) -> Bool {
      allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
  }

  /// Whether `stage` is on.
  func isOn(_ stage: Stage) -> Bool { !off.contains(stage) }

  /// A copy with `stage` turned on or off, its settings left as they are.
  func setting(_ stage: Stage, on: Bool) -> EditOptions {
    var copy = self
    if on { copy.off.remove(stage) } else { copy.off.insert(stage) }
    return copy
  }

  /// What renders: these options with each stage that's off as no change (and `off` empty).
  /// Every renderer cache is keyed by the options it's handed (`EditRenderer`), and the renderer
  /// takes this of whatever it's given, so turning a stage off renders exactly as that stage set
  /// to nothing, and turning it back on asks for the earlier key again (a cache hit). Kept as
  /// they are: the match target and histogram space (not amounts) and the grain seed.
  /// With the whole look off (`lookOff`), it's `identity` (the seed kept), whatever `off` says.
  var rendered: EditOptions {
    if lookOff {
      var none = EditOptions.identity
      none.grain.seed = grain.seed
      return none
    }
    guard !off.isEmpty else { return self }
    var out = self
    out.off = []
    for stage in off {
      switch stage {
      case .lens: out.lens = .identity
      case .match:
        out.match = Match(target: match.target)
        out.histogram = Histogram(space: histogram.space)
      case .grade: out.grade = Grade()
      case .lut: out.lut = LUTRef()
      case .halation: out.halation = Halation()
      case .vignette: out.vignette = Vignette()
      case .grain:
        var grain = Grain.identity
        grain.seed = self.grain.seed
        out.grain = grain
      }
    }
    return out
  }

  /// grain.py's default look, `EditOptions()`: its blur and grain on, everything else off.
  static let grainDefaults = EditOptions()

  /// The look that leaves an image as it is: grain.py's defaults with the blur and grain off.
  /// What decoding starts from.
  static let identity = EditOptions(lens: .identity, grain: .identity)

  /// The `userInfo` key `decoded(from:over:)` passes its base under; every section reads its own
  /// part of it.
  static let decodingBase = CodingUserInfoKey(rawValue: "EditOptions.decodingBase")!

  /// Options decoded from JSON laid over `base`: what the JSON names replaces the base's, and
  /// what it leaves out stays as the base has it (with the default base, `identity`, as no change).
  static func decoded(from data: Data, over base: EditOptions = .identity) throws -> EditOptions {
    let decoder = JSONDecoder()
    decoder.userInfo[decodingBase] = base
    return try decoder.decode(EditOptions.self, from: data)
  }

  /// The base a decoder lays keys over (`decoded(from:over:)`), else `identity`.
  fileprivate static func base(_ decoder: Decoder) -> EditOptions {
    decoder.userInfo[decodingBase] as? EditOptions ?? .identity
  }

  /// Whether rendering with these options gives back the source unchanged (`EditPipeline.render`
  /// skips every step then); a stage that's off counts as doing nothing.
  var isIdentity: Bool {
    guard off.isEmpty, !lookOff else { return rendered.isIdentity }
    return match.isIdentity && histogram.isIdentity && grade.isIdentity && lut.isIdentity && halation.isIdentity
      && lens.isIdentity && vignette.isIdentity && grain.isIdentity
  }

  /// Every amount rounded to the inspector's steps, so two looks with the same settings compare
  /// equal (`Edit.Job.isSameEdit`) and key the same cache entry however their numbers were
  /// arrived at (a slider drag, an agent's JSON, a profile). Amounts with a natural range (0 to 1
  /// blends) are kept to it; the ones a grain.py profile sets (`GrainProfile.Settings`: blur,
  /// smear, exposure, tint, grain strengths and sizes, real noise, colour) aren't capped, as
  /// grain.py doesn't cap them, only kept from going below zero where that means nothing. The
  /// inspector's slider ranges (`exposureRange`, `strengthRange`…) are the sliders' alone.
  var snapped: EditOptions {
    EditOptions(
      match: match.snapped, histogram: histogram.snapped, grade: grade.snapped, lut: lut.snapped,
      halation: halation.snapped, lens: lens.snapped, vignette: vignette.snapped, grain: grain.snapped, off: off, lookOff: lookOff)
  }

  // `lookOff` is `look_off` in a step's `profile_data`, whose coder converts to and from snake case.
  private enum CodingKeys: String, CodingKey { case match, histogram, grade, lut, halation, lens, vignette, grain, off, lookOff }

  /// The synthesized encoding's keys, then `off` (its names in pipeline order, so the same
  /// stages always encode alike) only when a stage is off, and `lookOff` only when it's set.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(match, forKey: .match)
    try c.encode(histogram, forKey: .histogram)
    try c.encode(grade, forKey: .grade)
    try c.encode(lut, forKey: .lut)
    try c.encode(halation, forKey: .halation)
    try c.encode(lens, forKey: .lens)
    try c.encode(vignette, forKey: .vignette)
    try c.encode(grain, forKey: .grain)
    if !off.isEmpty { try c.encode(off.sorted().map(\.rawValue), forKey: .off) }
    if lookOff { try c.encode(true, forKey: .lookOff) }
  }

  init(from decoder: Decoder) throws {
    let base = Self.base(decoder)
    let c = try decoder.container(keyedBy: CodingKeys.self)
    match = lenient(c, Match.self, .match) ?? base.match
    histogram = lenient(c, Histogram.self, .histogram) ?? base.histogram
    grade = lenient(c, Grade.self, .grade) ?? base.grade
    lut = lenient(c, LUTRef.self, .lut) ?? base.lut
    halation = lenient(c, Halation.self, .halation) ?? base.halation
    lens = lenient(c, Lens.self, .lens) ?? base.lens
    vignette = lenient(c, Vignette.self, .vignette) ?? base.vignette
    grain = lenient(c, Grain.self, .grain) ?? base.grain
    // Read as names, so one unknown name (a later Atelier's stage) drops only itself.
    off = lenient(c, [String].self, .off).map { Set($0.compactMap(Stage.init(rawValue:))) } ?? base.off
    lookOff = lenient(c, Bool.self, .lookOff) ?? base.lookOff
  }

  /// No bound: grain.py's own settings aren't capped.
  static let unbounded = -Double.infinity...Double.infinity
  /// Zero and up.
  static let nonNegative = 0...Double.infinity

  /// `value` kept to `range` and rounded to a multiple of `step`; a value that isn't a number is
  /// 0 (kept to `range`).
  static func snap(_ value: Double, _ range: ClosedRange<Double> = unbounded, step: Double = 0.01) -> Double {
    guard value.isFinite else { return min(max(0, range.lowerBound), range.upperBound) }
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
      /// The reference image picked in Profile (a file, a History step, a moodboard image).
      case reference
      /// The image the step was made from (`CreateModel.originalImage`), as Match Colors… uses.
      case original
    }

    var target: Target = .reference
    /// As `ColorMatch.Options`: the means of a and b, their spreads, the mean of L, its spread.
    /// This `tint` is how far the Lab a/b means move to the target's, 0 to 1: not
    /// `Grade.tint`, grain.py's green–magenta shift.
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
        colour: EditOptions.snap(colour, EditOptions.nonNegative))
    }

    private enum CodingKeys: String, CodingKey { case target, tint, saturation, brightness, contrast, colour }

    init(from decoder: Decoder) throws {
      let base = EditOptions.base(decoder).match
      let c = try decoder.container(keyedBy: CodingKeys.self)
      target = lenient(c, Target.self, .target) ?? base.target
      tint = lenient(c, Double.self, .tint) ?? base.tint
      saturation = lenient(c, Double.self, .saturation) ?? base.saturation
      brightness = lenient(c, Double.self, .brightness) ?? base.brightness
      contrast = lenient(c, Double.self, .contrast) ?? base.contrast
      colour = lenient(c, Double.self, .colour) ?? base.colour
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
      let base = EditOptions.base(decoder).histogram
      let c = try decoder.container(keyedBy: CodingKeys.self)
      amount = lenient(c, Double.self, .amount) ?? base.amount
      space = lenient(c, Space.self, .space) ?? base.space
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
    /// grain.py's `tint`, green (−) to magenta (+), −30 to 30 on the slider, by its formula: green
    /// less tint/2, red and blue more tint/4 each, in 0–255 units. Not `Match.tint`, which is how
    /// far a colour match moves the Lab a/b means.
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
        exposure: EditOptions.snap(exposure), temperature: EditOptions.snap(temperature, Self.temperatureRange, step: 0.1),
        tint: EditOptions.snap(tint, step: 0.1), contrast: EditOptions.snap(contrast, Self.unitRange),
        saturation: EditOptions.snap(saturation, Self.unitRange), vibrance: EditOptions.snap(vibrance, Self.unitRange))
    }

    private enum CodingKeys: String, CodingKey { case exposure, temperature, tint, contrast, saturation, vibrance }

    init(from decoder: Decoder) throws {
      let base = EditOptions.base(decoder).grade
      let c = try decoder.container(keyedBy: CodingKeys.self)
      exposure = lenient(c, Double.self, .exposure) ?? base.exposure
      temperature = lenient(c, Double.self, .temperature) ?? base.temperature
      tint = lenient(c, Double.self, .tint) ?? base.tint
      contrast = lenient(c, Double.self, .contrast) ?? base.contrast
      saturation = lenient(c, Double.self, .saturation) ?? base.saturation
      vibrance = lenient(c, Double.self, .vibrance) ?? base.vibrance
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

    /// The name and digest go together: a key naming one replaces both.
    init(from decoder: Decoder) throws {
      let base = EditOptions.base(decoder).lut
      let c = try decoder.container(keyedBy: CodingKeys.self)
      if c.contains(.name) || c.contains(.digest) {
        name = lenient(c, String.self, .name)
        digest = lenient(c, String.self, .digest)
      } else {
        name = base.name
        digest = base.digest
      }
      strength = lenient(c, Double.self, .strength) ?? base.strength
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
      let base = EditOptions.base(decoder).halation
      let c = try decoder.container(keyedBy: CodingKeys.self)
      amount = lenient(c, Double.self, .amount) ?? base.amount
      threshold = lenient(c, Double.self, .threshold) ?? base.threshold
      radius = lenient(c, Double.self, .radius) ?? base.radius
      warmth = lenient(c, Double.self, .warmth) ?? base.warmth
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

    /// No smear and no blur, what a missing key decodes to.
    static let identity = Lens(blur: 0)

    /// grain.py's thresholds: `motion > 1` smears, `gauss` returns the image for sigma < 0.3.
    var smears: Bool { motion > 1 }
    var blurs: Bool { blur >= 0.3 }
    var isIdentity: Bool { !smears && !blurs }

    var snapped: Lens {
      Lens(
        motion: EditOptions.snap(motion, EditOptions.nonNegative, step: 0.1), angle: EditOptions.snap(angle, step: 0.1),
        blur: EditOptions.snap(blur, EditOptions.nonNegative))
    }

    private enum CodingKeys: String, CodingKey { case motion, angle, blur }

    init(from decoder: Decoder) throws {
      let base = EditOptions.base(decoder).lens
      let c = try decoder.container(keyedBy: CodingKeys.self)
      motion = lenient(c, Double.self, .motion) ?? base.motion
      angle = lenient(c, Double.self, .angle) ?? base.angle
      blur = lenient(c, Double.self, .blur) ?? base.blur
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
      let base = EditOptions.base(decoder).vignette
      let c = try decoder.container(keyedBy: CodingKeys.self)
      amount = lenient(c, Double.self, .amount) ?? base.amount
      size = lenient(c, Double.self, .size) ?? base.size
      softness = lenient(c, Double.self, .softness) ?? base.softness
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

    /// No grain (sizes and seed as grain.py's defaults), what a missing key decodes to.
    static let identity = Grain(lum: 0, chroma: 0)

    /// The smallest grain size kept: grain.py divides by it.
    static let smallestSize = 0.01

    var isIdentity: Bool { lum == 0 && chroma == 0 && real <= 0 }

    var snapped: Grain {
      Grain(
        lum: EditOptions.snap(lum, EditOptions.nonNegative, step: 0.1),
        size: EditOptions.snap(size, Self.smallestSize...Double.infinity),
        chroma: EditOptions.snap(chroma, EditOptions.nonNegative, step: 0.1),
        csize: EditOptions.snap(csize, Self.smallestSize...Double.infinity),
        real: EditOptions.snap(real, EditOptions.nonNegative), seed: seed)
    }

    private enum CodingKeys: String, CodingKey { case lum, size, chroma, csize, real, seed }

    init(from decoder: Decoder) throws {
      let base = EditOptions.base(decoder).grain
      let c = try decoder.container(keyedBy: CodingKeys.self)
      lum = lenient(c, Double.self, .lum) ?? base.lum
      size = lenient(c, Double.self, .size) ?? base.size
      chroma = lenient(c, Double.self, .chroma) ?? base.chroma
      csize = lenient(c, Double.self, .csize) ?? base.csize
      real = lenient(c, Double.self, .real) ?? base.real
      seed = lenient(c, Int.self, .seed) ?? base.seed
    }
  }
}

/// The key's value, nil when it's missing, null, of the wrong type or an unknown case.
private nonisolated func lenient<T: Decodable, Key: CodingKey>(_ c: KeyedDecodingContainer<Key>, _ type: T.Type, _ key: Key) -> T? {
  (try? c.decodeIfPresent(type, forKey: key)) ?? nil
}
