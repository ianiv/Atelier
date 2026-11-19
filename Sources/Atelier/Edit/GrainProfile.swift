import Foundation

/// A noise profile, a `.grain.json` file as grain.py's `save_profile` and Grain Studio write it:
/// the settings `--match` fitted (or any set by hand), the brightness curve, the reference's RGB
/// statistics and up to 120 patches of its real noise. Profiles Atelier writes must load in
/// grain.py and Grain Studio, so the keys are theirs exactly, nulls included; unknown keys are
/// ignored on reading. Slice A adds the library store and Match Reference's measuring.
nonisolated struct GrainProfile: Codable, Hashable, Sendable {
  var type = "grain-profile"
  var version = 1
  var name: String
  /// The reference photo's file name, when it was measured from one.
  var source: String?
  /// The day it was made, ISO 8601 (`2026-11-19`).
  var created: String?
  /// The reference's width in px, which the grain's scale follows (grain.py's `ref_w`).
  var refWidth: Int = 1440
  var settings: Settings
  /// Grain gain at grain.py's four brightness band centres (24, 65, 125, 197 of 255).
  var curve: [Double]?
  var refStats: ChannelStats?
  var real: RealNoise?

  init(
    name: String, source: String? = nil, created: String? = nil, refWidth: Int = 1440, settings: Settings = Settings(),
    curve: [Double]? = nil, refStats: ChannelStats? = nil, real: RealNoise? = nil
  ) {
    self.name = name
    self.source = source
    self.created = created
    self.refWidth = refWidth
    self.settings = settings
    self.curve = curve
    self.refStats = refStats
    self.real = real
  }

  /// The file extension, after the profile's name.
  static let fileExtension = "grain.json"

  /// grain.py's `PROFILE_KEYS` and `DEFAULTS`, as numbers. `seed` isn't one of grain.py's keys;
  /// a profile without it reads as grain.py's default, 7.
  struct Settings: Codable, Hashable, Sendable {
    var blur = 3.0
    var motion = 0.0
    var angle = 0.0
    var lum = 9.0
    var chroma = 3.0
    var size = 1.0
    var csize = 1.0
    var colour = 0.0
    var tint = 0.0
    var expo = 0.0
    var real = 0.0
    var seed: Int?

    init() {}

    /// The grain.py settings of a look.
    init(_ options: EditOptions) {
      blur = options.lens.blur
      motion = options.lens.motion
      angle = options.lens.angle
      lum = options.grain.lum
      chroma = options.grain.chroma
      size = options.grain.size
      csize = options.grain.csize
      colour = options.match.colour
      tint = options.grade.tint
      expo = options.grade.exposure
      real = options.grain.real
      seed = options.grain.seed
    }

    /// `options` with these settings over the ones grain.py has; the rest are left as they were.
    func applied(to options: EditOptions) -> EditOptions {
      var options = options
      options.lens.blur = blur
      options.lens.motion = motion
      options.lens.angle = angle
      options.grain.lum = lum
      options.grain.chroma = chroma
      options.grain.size = size
      options.grain.csize = csize
      options.match.colour = colour
      options.grade.tint = tint
      options.grade.exposure = expo
      options.grain.real = real
      options.grain.seed = seed ?? 7
      return options
    }

    private enum CodingKeys: String, CodingKey { case blur, motion, angle, lum, chroma, size, csize, colour, tint, expo, real, seed }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      func number(_ key: CodingKeys, _ fallback: Double) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? fallback }
      blur = try number(.blur, 3)
      motion = try number(.motion, 0)
      angle = try number(.angle, 0)
      lum = try number(.lum, 9)
      chroma = try number(.chroma, 3)
      size = try number(.size, 1)
      csize = try number(.csize, 1)
      colour = try number(.colour, 0)
      tint = try number(.tint, 0)
      expo = try number(.expo, 0)
      real = try number(.real, 0)
      // grain.py writes every setting as a float, a seed among them if a tool ever adds one.
      seed = try c.decodeIfPresent(Double.self, forKey: .seed).map { Int($0) }
    }
  }

  /// The reference's per-channel RGB mean and spread, 0–255 (grain.py's `channel_stats`, keys
  /// `m` and `s`).
  struct ChannelStats: Codable, Hashable, Sendable {
    var m: [Double]
    var s: [Double]
  }

  /// grain.py's real-noise patches: `count` patches of `patch`×`patch` RGB, each value stored as
  /// a byte `128 + value × enc`, base64 in `data` (Swift's `Data` coding, which is plain base64
  /// as grain.py's), with the noise strength per brightness band. Kept as the bytes, as the
  /// file has them, so a profile written back is byte-identical and a record stays compact.
  struct RealNoise: Codable, Hashable, Sendable {
    var patch = 48
    var count: Int
    var enc = 24.0
    var curve: [Double]
    var data: Data

    init(patch: Int = 48, count: Int, enc: Double = 24, curve: [Double], data: Data) {
      self.patch = patch
      self.count = count
      self.enc = enc
      self.curve = curve
      self.data = data
    }

    private enum CodingKeys: String, CodingKey { case patch, count, enc, curve, data }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      patch = try c.decodeIfPresent(Int.self, forKey: .patch) ?? 48
      count = try c.decode(Int.self, forKey: .count)
      enc = try c.decodeIfPresent(Double.self, forKey: .enc) ?? 24
      curve = try c.decode([Double].self, forKey: .curve)
      data = try c.decode(Data.self, forKey: .data)
    }

    /// Patch `index`'s values, HWC interleaved RGB, as grain.py's `load_profile` decodes them:
    /// `(byte − 128) / enc`. Empty when `data` is too short.
    func values(ofPatch index: Int) -> [Float] {
      let length = patch * patch * 3
      let start = index * length
      guard index >= 0, index < count, data.count >= start + length else { return [] }
      let enc = Float(enc)
      return data[data.startIndex + start..<data.startIndex + start + length].map { (Float($0) - 128) / enc }
    }
  }

  private enum CodingKeys: String, CodingKey { case type, version, name, source, created, refWidth, settings, curve, refStats, real }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
    guard type == "grain-profile" else {
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Not a grain profile.")
    }
    version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    source = try c.decodeIfPresent(String.self, forKey: .source)
    created = try c.decodeIfPresent(String.self, forKey: .created)
    refWidth = try c.decodeIfPresent(Double.self, forKey: .refWidth).map { Int($0) } ?? 1440
    settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
    curve = try c.decodeIfPresent([Double].self, forKey: .curve)
    refStats = try c.decodeIfPresent(ChannelStats.self, forKey: .refStats)
    real = try c.decodeIfPresent(RealNoise.self, forKey: .real)
  }

  /// Writes every key grain.py does, a missing one as null.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(type, forKey: .type)
    try c.encode(version, forKey: .version)
    try c.encode(name, forKey: .name)
    try c.encode(source, forKey: .source)
    try c.encode(created, forKey: .created)
    try c.encode(refWidth, forKey: .refWidth)
    try c.encode(settings, forKey: .settings)
    try c.encode(curve, forKey: .curve)
    try c.encode(refStats, forKey: .refStats)
    try c.encode(real, forKey: .real)
  }

  /// Reads a `.grain.json` file's contents.
  static func decoded(from data: Data) throws -> GrainProfile {
    try JSONDecoder().decode(GrainProfile.self, from: data)
  }

  /// The file's contents, laid out as grain.py's `json.dump(indent=1)`: one space per level.
  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    let text = String(decoding: try encoder.encode(self), as: UTF8.self)
    // JSONEncoder indents by two spaces; strings never hold a raw newline, so every line's
    // leading spaces are indentation.
    let lines = text.split(separator: "\n" as Character, omittingEmptySubsequences: false).map { (line: Substring) -> String in
      let spaces = line.prefix { $0 == " " }.count
      return String(repeating: " ", count: spaces / 2) + line.dropFirst(spaces)
    }
    return Data(lines.joined(separator: "\n").utf8)
  }
}
