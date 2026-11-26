import CoreGraphics
import Foundation
import Observation

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

  /// grain.py's `PROFILE_KEYS` and `DEFAULTS`, as numbers. `seed` isn't one of grain.py's keys:
  /// it's read when a file has one, but never written (a profile is a look, the seed the
  /// screen's), so a profile reads as grain.py's default seed, 7.
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
      if let seed { options.grain.seed = seed }
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

    /// grain.py's keys only: no seed.
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(blur, forKey: .blur)
      try c.encode(motion, forKey: .motion)
      try c.encode(angle, forKey: .angle)
      try c.encode(lum, forKey: .lum)
      try c.encode(chroma, forKey: .chroma)
      try c.encode(size, forKey: .size)
      try c.encode(csize, forKey: .csize)
      try c.encode(colour, forKey: .colour)
      try c.encode(tint, forKey: .tint)
      try c.encode(expo, forKey: .expo)
      try c.encode(real, forKey: .real)
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

  /// The file's contents exactly as grain.py's `json.dump(prof, f, indent=1)` writes them: its
  /// key order, one space per level, `", "`/`": "` separators, floats as Python's `repr` (`3.0`,
  /// `1e-05`), whole-number fields (`version`, `refWidth`, `patch`, `count`, `enc`) as integers,
  /// non-ASCII escaped, no newline at the end. A profile read from grain.py's file writes back
  /// byte for byte (keys grain.py doesn't know are dropped).
  func encoded() throws -> Data {
    Data(PythonJSON.dump(jsonValue).utf8)
  }

  /// The profile as grain.py's `save_profile` builds its dict.
  private var jsonValue: PythonJSON.Value {
    func numbers(_ values: [Double]) -> PythonJSON.Value { .array(values.map { .double($0) }) }
    let settingsValue: [(String, PythonJSON.Value)] = [
      ("blur", .double(settings.blur)), ("motion", .double(settings.motion)), ("angle", .double(settings.angle)),
      ("lum", .double(settings.lum)), ("chroma", .double(settings.chroma)), ("size", .double(settings.size)),
      ("csize", .double(settings.csize)), ("colour", .double(settings.colour)), ("tint", .double(settings.tint)),
      ("expo", .double(settings.expo)), ("real", .double(settings.real)),
    ]
    let realValue: PythonJSON.Value = real.map { real in
      .object([
        ("patch", .int(real.patch)), ("count", .int(real.count)),
        ("enc", real.enc == real.enc.rounded() && abs(real.enc) < 1e15 ? .int(Int(real.enc)) : .double(real.enc)),
        ("curve", numbers(real.curve)), ("data", .string(real.data.base64EncodedString())),
      ])
    } ?? .null
    return .object([
      ("type", .string(type)), ("version", .int(version)), ("name", .string(name)), ("source", source.map { .string($0) } ?? .null),
      ("created", created.map { .string($0) } ?? .null), ("refWidth", .int(refWidth)), ("settings", .object(settingsValue)),
      ("curve", curve.map(numbers) ?? .null),
      ("refStats", refStats.map { .object([("m", numbers($0.m)), ("s", numbers($0.s))]) } ?? .null),
      ("real", realValue),
    ])
  }

  // MARK: - Measuring

  /// The profile grain.py's `--match REFERENCE --save-profile` makes from a reference photo:
  /// Match Reference's fitted size, colour size, strength and colour noise over grain.py's
  /// defaults, `colour` 0.6 (what `--match` sets), the brightness curve, the reference's RGB
  /// statistics, its width as the grain's scale, and 120 patches of its real noise. Nil when the
  /// image can't be read or has no flat, mid-bright area to measure. Takes a second or two at
  /// 1440 px; run it off the main actor.
  init?(measuring image: CGImage, name: String, source: String? = nil, created: Date = Date()) {
    guard let planes = EditPipeline.Planes(image) else { return nil }
    self.init(measuring: planes, name: name, source: source, created: created)
  }

  init?(measuring planes: EditPipeline.Planes, name: String, source: String? = nil, created: Date = Date()) {
    guard let match = Grain.matchReference(planes) else { return nil }
    self.init(match: match, of: planes, name: name, source: source, created: created)
  }

  /// The profile of a reference `planes` that Match Reference has already measured (`match`).
  init(match: Grain.Match, of planes: EditPipeline.Planes, name: String, source: String? = nil, created: Date = Date()) {
    var settings = Settings()
    settings.size = match.size
    settings.csize = match.csize
    settings.lum = match.lum
    settings.chroma = match.chroma
    settings.colour = 0.6
    self.init(
      name: name, source: source, created: Self.day(created), refWidth: planes.width, settings: settings, curve: match.curve,
      refStats: Grain.channelStats(planes), real: match.real)
  }

  /// grain.py's `created`: the local date, ISO 8601.
  static func day(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  // MARK: - Files

  /// Reads a `.grain.json` file anywhere (Open Profile…). A profile without a name takes the
  /// file's (grain.py's `basename(path).split(".")[0]`).
  static func load(from url: URL) throws -> GrainProfile {
    var profile = try decoded(from: Data(contentsOf: url))
    if profile.name.isEmpty { profile.name = baseName(of: url) }
    return profile
  }

  /// Writes the profile to a file anywhere (Save Profile…), as grain.py would.
  func write(to url: URL) throws {
    try encoded().write(to: url, options: .atomic)
  }

  /// The part of a file's name before its first dot, as grain.py names a profile.
  static func baseName(of url: URL) -> String {
    String(url.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false).first ?? "")
  }
}

/// The noise profile library: `.grain.json` files in Application Support/Atelier/Grain Profiles
/// (beside the presets, `PresetStore.defaultDirectory`), the Edit screen's profile menu.
///
/// A profile's file is named after it (`LayoutStore.fileName`), but the store remembers each
/// profile's own file rather than working it out from the name again: names that make the same
/// file name ("Day/Night" and "Day-Night", or "night" and "Night" on a case-insensitive volume)
/// get numbered files, and a file whose profile has a name already listed (a Finder copy of
/// "Night") is listed with a number ("Night 2"), so saving or deleting one never touches the
/// other's file. Saving a profile of a listed name replaces that file. Profiles opened from
/// elsewhere are added as copies (`add(contentsOf:)`).
@MainActor
@Observable
final class GrainProfileStore {
  /// The library's profiles, by name; every name is listed once.
  private(set) var profiles: [GrainProfile] = []
  /// Where the profile files are.
  let directory: URL
  /// Each listed profile's file, by its listed name.
  private var files: [String: URL] = [:]

  static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier/Grain Profiles", isDirectory: true)
  }

  /// `directory` is for tests; the default is Application Support.
  init(directory: URL? = nil) {
    self.directory = directory ?? Self.defaultDirectory
    reload()
  }

  /// Reads the folder again (files that aren't profiles are skipped). Of files with the same
  /// profile name, the one named after it keeps the name, then the first by file name.
  func reload() {
    let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
      .filter { $0.lastPathComponent.hasSuffix("." + GrainProfile.fileExtension) }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    files = [:]
    var loaded: [GrainProfile] = []
    // A file named after its profile keeps the name over a copy of it.
    let read = urls.compactMap { url in (try? GrainProfile.load(from: url)).map { (url, $0) } }
    let owners = read.filter { url, profile in
      url.lastPathComponent == LayoutStore.fileName(profile.name) + "." + GrainProfile.fileExtension
    }
    let others = read.filter { url, profile in
      url.lastPathComponent != LayoutStore.fileName(profile.name) + "." + GrainProfile.fileExtension
    }
    for (url, profile) in owners + others {
      var profile = profile
      profile.name = unusedName(profile.name)
      files[profile.name] = url
      loaded.append(profile)
    }
    profiles = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func profile(named name: String) -> GrainProfile? { profiles.first { $0.name == name } }

  /// The library file of the profile named `name`: its own when it's listed, else the one saving
  /// it would make.
  func url(for name: String) -> URL { files[name] ?? newFileURL(for: name) }

  /// Saves `profile` into the library, replacing the listed one of the same name (in its file).
  @discardableResult
  func save(_ profile: GrainProfile) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = files[profile.name] ?? newFileURL(for: profile.name)
    try profile.write(to: url)
    files[profile.name] = url
    profiles.removeAll { $0.name == profile.name }
    profiles.append(profile)
    profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return url
  }

  /// Adds `profile` to the library under its name, numbered ("Night 2") when that's taken.
  @discardableResult
  func add(_ profile: GrainProfile) throws -> GrainProfile {
    var profile = profile
    profile.name = unusedName(profile.name.isEmpty ? "Profile" : profile.name)
    try save(profile)
    return profile
  }

  /// Adds a copy of the profile file at `url` (Add to Library).
  @discardableResult
  func add(contentsOf url: URL) throws -> GrainProfile {
    try add(GrainProfile.load(from: url))
  }

  /// Renames the listed profile `name` to `newName`, a name that isn't listed: its file moves to
  /// one named after the new name (a numbered one when that's another profile's), so a rename
  /// that changes only case keeps its file on a case-insensitive volume.
  @discardableResult
  func rename(_ name: String, to newName: String) throws -> GrainProfile {
    guard var renamed = self.profile(named: name), let oldURL = files[name] else { throw RenameError.missing(name) }
    guard newName != name else { return renamed }
    guard files[newName] == nil else { throw RenameError.taken(newName) }
    renamed.name = newName
    files[name] = nil
    let ownFile = LayoutStore.fileName(newName) + "." + GrainProfile.fileExtension
    // A case-only change of the file name is the same file on a case-insensitive volume, which
    // `newFileURL` would see as taken.
    let newURL = ownFile.lowercased() == oldURL.lastPathComponent.lowercased()
      ? directory.appendingPathComponent(ownFile)
      : newFileURL(for: newName)
    do {
      if newURL != oldURL { try FileManager.default.moveItem(at: oldURL, to: newURL) }
      try renamed.write(to: newURL)
    } catch {
      files[name] = FileManager.default.fileExists(atPath: oldURL.path) ? oldURL : newURL
      throw error
    }
    files[newName] = newURL
    profiles.removeAll { $0.name == name }
    profiles.append(renamed)
    profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return renamed
  }

  enum RenameError: LocalizedError {
    case missing(String)
    case taken(String)

    var errorDescription: String? {
      switch self {
      case .missing(let name): "“\(name)” isn't in your profile library."
      case .taken(let name): "There's already a profile named “\(name)” in your library."
      }
    }
  }

  /// Moves the profile's file to the Trash, or deletes it where there's no Trash (iPad).
  func delete(_ profile: GrainProfile) throws {
    if let url = files[profile.name], FileManager.default.fileExists(atPath: url.path), (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
      try FileManager.default.removeItem(at: url)
    }
    files[profile.name] = nil
    profiles.removeAll { $0.name == profile.name }
  }

  /// `name`, or "name 2", "name 3"… when it's listed: what Add to Library suggests.
  func unusedName(_ name: String) -> String {
    var candidate = name
    var n = 2
    while files[candidate] != nil {
      candidate = "\(name) \(n)"
      n += 1
    }
    return candidate
  }

  /// A file for a profile named `name` that no file is at yet (numbered when its name's file is
  /// another profile's).
  private func newFileURL(for name: String) -> URL {
    let base = LayoutStore.fileName(name.isEmpty ? "Profile" : name)
    var stem = base
    var n = 2
    func url(_ stem: String) -> URL { directory.appendingPathComponent(stem + "." + GrainProfile.fileExtension) }
    let taken = Set(files.values.map { $0.lastPathComponent.lowercased() })
    while FileManager.default.fileExists(atPath: url(stem).path) || taken.contains(url(stem).lastPathComponent.lowercased()) {
      stem = "\(base) \(n)"
      n += 1
    }
    return url(stem)
  }
}

/// JSON as Python's `json.dump(obj, indent=n)` writes it, for files grain.py and Grain Studio
/// share with Atelier byte for byte.
nonisolated enum PythonJSON {
  indirect enum Value {
    case object([(String, Value)])
    case array([Value])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
  }

  static func dump(_ value: Value, indent: Int = 1) -> String {
    var out = ""
    write(value, level: 0, indent: indent, to: &out)
    return out
  }

  private static func write(_ value: Value, level: Int, indent: Int, to out: inout String) {
    let inner = String(repeating: " ", count: (level + 1) * indent)
    let outer = String(repeating: " ", count: level * indent)
    switch value {
    case .object(let items):
      guard !items.isEmpty else { return out += "{}" }
      out += "{\n"
      for (index, item) in items.enumerated() {
        out += inner + string(item.0) + ": "
        write(item.1, level: level + 1, indent: indent, to: &out)
        out += index == items.count - 1 ? "\n" : ",\n"
      }
      out += outer + "}"
    case .array(let items):
      guard !items.isEmpty else { return out += "[]" }
      out += "[\n"
      for (index, item) in items.enumerated() {
        out += inner
        write(item, level: level + 1, indent: indent, to: &out)
        out += index == items.count - 1 ? "\n" : ",\n"
      }
      out += outer + "]"
    case .string(let text): out += string(text)
    case .int(let number): out += String(number)
    case .double(let number): out += float(number)
    case .bool(let flag): out += flag ? "true" : "false"
    case .null: out += "null"
    }
  }

  /// Python's `float.__repr__`, which Swift's `description` matches (shortest round trip, the
  /// same switch to exponents below 1e-4 and from 1e16), with JSON's names for the rest.
  static func float(_ x: Double) -> String {
    if x.isNaN { return "NaN" }
    if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
    return x.description
  }

  /// A string as `json.dumps(ensure_ascii=True)` quotes it.
  static func string(_ text: String) -> String {
    var out = "\""
    for unit in text.utf16 {
      switch unit {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(unit)!)
      default: out += String(format: "\\u%04x", unit)
      }
    }
    return out + "\""
  }
}
