import CryptoKit
import Foundation

/// The Edit screen's queued saves and what a saved step records. Rendering is `EditPipeline`'s;
/// the job runs in `CreateModel.runEdit(_:request:job:)`.
nonisolated enum Edit {
  /// The Edit screen's sidebar symbol, also its Queue rows' icon.
  static let symbol = "slider.horizontal.below.rectangle"

  /// A queued Save to History from the Edit screen (`GenerationEngine.Request.edit`), as
  /// `ColorMatch.Job` is for Match Colors…: which step, in which project, with which look. It
  /// names its project because it saves there whichever project is open when it runs.
  ///
  /// The `record` is the single source of truth for the step, the look and what it's rendered
  /// with; `sourceTensorId`, `options`, `profileName` and `referenceTensorId` read and write it.
  /// Unlike a colour match the job carries the real data it renders with from the moment it's
  /// queued (`blobs`: the profile's real-noise patches, the reference's histograms, the LUT's
  /// table), because the profile, reference and LUT files may be gone by the time it runs, after
  /// a quit say. `SavedQueue` writes them into the queue's JSON with the rest: the queue file is
  /// temporary (it's removed when it's read back) and holds at most a full profile's 830 KB of
  /// patches and a LUT per job. Saving the step moves them into the project's tensor store
  /// (`Project.append(… edit:editBlobs:)`), and the step's record keeps only their ids and digests.
  struct Job: Codable, Hashable, Sendable {
    var project: String
    /// Everything it's rendered with, and what the saved step keeps.
    var record: Record
    /// The data the record names by digest, until the step is saved.
    var blobs: Blobs

    init(project: String, record: Record, blobs: Blobs) {
      self.project = project
      self.record = record
      self.blobs = blobs
    }

    /// A job for `options` rendered with `context`: the record takes the context's small
    /// measurements and the digests of its large data, the job the data itself.
    init(
      project: String, sourceTensorId: Int64, options: EditOptions, profileName: String? = nil,
      referenceTensorId: Int64? = nil, referenceName: String? = nil, context: EditPipeline.Context = .empty
    ) {
      self.init(
        project: project,
        record: Record(
          options: options, sourceTensorId: sourceTensorId, profileName: profileName, referenceTensorId: referenceTensorId,
          referenceName: referenceName, context: context),
        blobs: Blobs(context))
    }

    /// The source step's image tensor, which stays the same when steps are renumbered.
    var sourceTensorId: Int64 {
      get { record.sourceTensorId }
      set { record.sourceTensorId = newValue }
    }

    var options: EditOptions {
      get { record.options }
      set { record.options = newValue }
    }

    /// The grain profile the look came from, for the Queue row and the record; nil for none.
    var profileName: String? {
      get { record.profileName }
      set { record.profileName = newValue }
    }

    /// The reference image, when it's a step of `project` (matched to with `Match.target`
    /// `.reference`); nil for none, or one from a file (its measurements are in `record`).
    var referenceTensorId: Int64? {
      get { record.referenceTensorId }
      set { record.referenceTensorId = newValue }
    }

    /// What it renders with.
    var context: EditPipeline.Context { record.context(with: blobs) }

    /// The same edit: the same step, with the same look rendered with the same profile data,
    /// reference and LUT, whose result would be the same image, so it's never queued twice. The
    /// record's digests stand for the data.
    func isSameEdit(as other: Job) -> Bool {
      project == other.project && record.renderKey == other.record.renderKey
    }
  }

  /// The large data an edit renders with, which a saved step keeps in the project's tensor store
  /// rather than in its `profile_data` (`Record.realNoise`, `referenceHistogram`, `lut`).
  struct Blobs: Codable, Hashable, Sendable {
    var realNoise: GrainProfile.RealNoise?
    var referenceHistogram: HistogramTable?
    var lut: LUTTable?

    init(realNoise: GrainProfile.RealNoise? = nil, referenceHistogram: HistogramTable? = nil, lut: LUTTable? = nil) {
      self.realNoise = realNoise
      self.referenceHistogram = referenceHistogram
      self.lut = lut
    }

    init(_ context: EditPipeline.Context) {
      self.init(realNoise: context.realNoise, referenceHistogram: context.referenceHistogram, lut: context.lut)
    }
  }

  /// Which of a record's stored data couldn't be read back from its project: gone, or not what
  /// its digest says (`Project.editData(for:)`). Each counts on its own, so a lost histogram
  /// doesn't also turn off the real noise and LUT that are still there.
  struct MissingData: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let realNoise = MissingData(rawValue: 1)
    static let referenceHistogram = MissingData(rawValue: 2)
    static let lut = MissingData(rawValue: 4)

    /// "`owner` real noise and LUT data is missing from the project, so Real Noise and the LUT
    /// are off." Nil when nothing is.
    func note(_ owner: String) -> String? {
      let parts: [(data: String, setting: String)] = [
        contains(.realNoise) ? ("real noise", "Real Noise") : nil,
        contains(.referenceHistogram) ? ("reference histogram", "the histogram match") : nil,
        contains(.lut) ? ("LUT", "the LUT") : nil,
      ].compactMap(\.self)
      guard !parts.isEmpty else { return nil }
      func list(_ items: [String]) -> String {
        items.count < 3 ? items.joined(separator: " and ") : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
      }
      return "\(owner) \(list(parts.map(\.data))) data is missing from the project, so \(list(parts.map(\.setting))) "
        + (parts.count == 1 ? "is off." : "are off.")
    }
  }

  /// A record's data as read back from its project: what was there, and what wasn't.
  struct LoadedData: Sendable {
    var blobs: Blobs
    var missing: MissingData
  }

  /// What a step saved from the Edit screen records (`profile_data` `edit`): its look, and what it
  /// was rendered with, so opening it in Edit goes back to its source with the same settings, and
  /// it renders again exactly even once the profile or LUT file is gone. By the user's choice each
  /// step keeps its own copy of the profile's real noise, the reference's histograms and the LUT,
  /// but not here: they're tensors in the project's store (`StoredNoise`, `StoredHistogram`,
  /// `StoredLUT`), shared by every step with the same data (named by digest), so the record stays a
  /// few KB however many steps there are, and History, exported PNGs and Draw Things don't read
  /// the data on every load. `Project.editContext(for:)` loads them back.
  ///
  /// Decoding is lenient: a key that's missing, of the wrong type or holds an unknown case reads as
  /// its default (the options as no change, `EditOptions.identity`), so a record written by a
  /// later version still reads; only a record without its source step fails.
  struct Record: Codable, Hashable, Sendable {
    /// The layout this version writes. A record of a later version reads as well as it can.
    static let currentVersion = 1

    var version = Record.currentVersion
    var options: EditOptions
    /// The step it was made from, which Edit opens instead of this one.
    var sourceTensorId: Int64
    var profileName: String?
    var referenceTensorId: Int64?
    /// The reference's file name, when it came from a file, for saying what it was matched to.
    var referenceName: String?
    /// The profile's reference width (grain.py's `ref_w`, default 1440): the grain's scale.
    var refWidth: Int = 1440
    /// The profile's grain gain at grain.py's four brightness band centres; nil for grain.py's
    /// built-in curve.
    var curve: [Double]?
    /// The profile's reference RGB mean and spread (grain.py `refStats`), for `Match.colour`.
    var refStats: GrainProfile.ChannelStats?
    /// The Reinhard match target's Lab statistics (the reference's, or the original's).
    var referenceLab: LabStats?
    /// The profile's real-noise patches (grain.py's `real`), for `Grain.real`.
    var realNoise: StoredNoise?
    /// The match target's cumulative histograms, for `Histogram`.
    var referenceHistogram: StoredHistogram?
    /// The LUT's table, for `EditOptions.lut`.
    var lut: StoredLUT?

    init(
      options: EditOptions, sourceTensorId: Int64, profileName: String? = nil, referenceTensorId: Int64? = nil,
      referenceName: String? = nil, context: EditPipeline.Context = .empty
    ) {
      self.options = options
      self.sourceTensorId = sourceTensorId
      self.profileName = profileName
      self.referenceTensorId = referenceTensorId
      self.referenceName = referenceName
      refWidth = context.refWidth
      curve = context.curve
      refStats = context.refStats
      referenceLab = context.referenceLab
      realNoise = context.realNoise.map(StoredNoise.init)
      referenceHistogram = context.referenceHistogram.map(StoredHistogram.init)
      lut = context.lut.map(StoredLUT.init)
    }

    /// The context, with the data the record names: from the queued job, or loaded from the
    /// project (`Project.editContext(for:)`). Data whose digest isn't the record's is left out.
    func context(with blobs: Blobs) -> EditPipeline.Context {
      // Each digest is taken once, here, and the context keeps the record's for what matched.
      let noise = blobs.realNoise.flatMap { realNoise?.digest == $0.digest ? $0 : nil }
      let histogram = blobs.referenceHistogram.flatMap { referenceHistogram?.digest == $0.digest ? $0 : nil }
      let table = blobs.lut.flatMap { lut?.digest == $0.digest ? $0 : nil }
      return EditPipeline.Context(
        refWidth: refWidth, curve: curve, refStats: refStats, realNoise: noise, referenceLab: referenceLab,
        referenceHistogram: histogram, lut: table,
        digests: EditPipeline.Context.Digests(
          realNoise: noise == nil ? nil : realNoise?.digest, referenceHistogram: histogram == nil ? nil : referenceHistogram?.digest,
          lut: table == nil ? nil : lut?.digest))
    }

    /// Of `missing`, the data whose settings can't render as saved. A match to the original
    /// needs none of its stored histograms: the original is measured again when the step opens.
    func lost(_ missing: MissingData) -> MissingData {
      var lost = missing
      if options.match.target == .original { lost.remove(.referenceHistogram) }
      return lost
    }

    /// The look as it renders without the `lost` data: Real Noise off without its patches, the
    /// histogram match off without its tables, the LUT off without its table. The rest stays.
    func options(without lost: MissingData) -> EditOptions {
      var look = options
      if lost.contains(.realNoise) { look.grain.real = 0 }
      if lost.contains(.referenceHistogram) { look.histogram.amount = 0 }
      if lost.contains(.lut) { look.lut = EditOptions.LUTRef() }
      return look
    }

    /// What makes the image: everything but the names and where the data is stored, the options
    /// snapped (`EditOptions.snapped`).
    var renderKey: Record {
      var key = self
      key.version = 0
      key.options = options.snapped
      key.profileName = nil
      key.referenceName = nil
      key.realNoise?.id = nil
      key.referenceHistogram?.id = nil
      key.lut?.id = nil
      return key
    }

    /// The tensors it names in the project's store.
    var tensorNames: [String] {
      [realNoise.flatMap(\.tensorName), referenceHistogram.flatMap(\.tensorName), lut.flatMap(\.tensorName)].compactMap(\.self)
    }

    private enum CodingKeys: String, CodingKey {
      case version, options, sourceTensorId, profileName, referenceTensorId, referenceName, refWidth, curve, refStats
      case referenceLab, realNoise, referenceHistogram, lut
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      func lenient<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
      sourceTensorId = try c.decode(Int64.self, forKey: .sourceTensorId)
      version = lenient(Int.self, .version) ?? Record.currentVersion
      options = lenient(EditOptions.self, .options) ?? .identity
      profileName = lenient(String.self, .profileName)
      referenceTensorId = lenient(Int64.self, .referenceTensorId)
      referenceName = lenient(String.self, .referenceName)
      refWidth = lenient(Int.self, .refWidth) ?? 1440
      curve = lenient([Double].self, .curve)
      refStats = lenient(GrainProfile.ChannelStats.self, .refStats)
      referenceLab = lenient(LabStats.self, .referenceLab)
      realNoise = lenient(StoredNoise.self, .realNoise)
      referenceHistogram = lenient(StoredHistogram.self, .referenceHistogram)
      lut = lenient(StoredLUT.self, .lut)
    }
  }

  /// The band the stored data's ids come from, above the entry keys
  /// (`ProjectMapping.Profile.entryKeys`). An id starts from the data's digest, so the same data
  /// gets the same tensor (`Project.append`).
  static let blobIds: ClosedRange<Int64> = 3_000_000_000...3_999_999_999

  /// A record's real noise: where the patches are (`edit_noise_<id>`, a `[count, patch, patch, 3]`
  /// UInt8 tensor of grain.py's bytes) and what goes with them.
  struct StoredNoise: Codable, Hashable, Sendable {
    /// Nil until the step is saved.
    var id: Int64?
    /// `GrainProfile.RealNoise.digest`.
    var digest: String
    var patch: Int
    var count: Int
    var enc: Double
    var curve: [Double]

    init(_ noise: GrainProfile.RealNoise) {
      digest = noise.digest
      patch = noise.patch
      count = noise.count
      enc = noise.enc
      curve = noise.curve
    }

    static let prefix = "edit_noise_"
    var tensorName: String? { id.map { "\(Self.prefix)\($0)" } }
  }

  /// A record's match target histograms (`edit_histogram_<id>`, a `[4, levels]` Float64 tensor:
  /// luma, red, green, blue).
  struct StoredHistogram: Codable, Hashable, Sendable {
    var id: Int64?
    /// `HistogramTable.digest`.
    var digest: String

    init(_ table: HistogramTable) { digest = table.digest }

    static let prefix = "edit_histogram_"
    var tensorName: String? { id.map { "\(Self.prefix)\($0)" } }
  }

  /// A record's LUT (`edit_lut_<id>`, a `[size, size, size, 3]` Float16 tensor, red fastest as in
  /// `LUTTable.data`), with its name and domain.
  struct StoredLUT: Codable, Hashable, Sendable {
    var id: Int64?
    /// `LUTTable.digest`.
    var digest: String
    var name: String
    var size: Int
    var domainMin: [Double]
    var domainMax: [Double]

    init(_ table: LUTTable) {
      digest = table.digest
      name = table.name
      size = table.size
      domainMin = table.domainMin
      domainMax = table.domainMax
    }

    static let prefix = "edit_lut_"
    var tensorName: String? { id.map { "\(Self.prefix)\($0)" } }
  }

  /// SHA-256 of `parts` then `data`, as hex.
  static func digest(_ parts: String, _ data: Data) -> String {
    var hasher = SHA256()
    hasher.update(data: Data(parts.utf8))
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Where a digest's data is first looked for in `blobIds`.
  static func blobId(forDigest digest: String) -> Int64 {
    let value = UInt64(digest.prefix(16), radix: 16) ?? 0
    return blobIds.lowerBound + Int64(value % UInt64(blobIds.count))
  }

  /// Lab means and spreads (L, a, b), as `ColorMatch.Stats` holds them, in a form a record keeps.
  struct LabStats: Codable, Hashable, Sendable {
    var mean: [Double]
    var std: [Double]

    init(mean: [Double], std: [Double]) {
      self.mean = mean
      self.std = std
    }

    init(_ stats: ColorMatch.Stats) {
      mean = [stats.mean.x, stats.mean.y, stats.mean.z]
      std = [stats.std.x, stats.std.y, stats.std.z]
    }

    var stats: ColorMatch.Stats? {
      guard mean.count == 3, std.count == 3 else { return nil }
      return ColorMatch.Stats(mean: SIMD3(mean[0], mean[1], mean[2]), std: SIMD3(std[0], std[1], std[2]))
    }
  }

  /// A match target's cumulative histograms over the 256 levels, each running from the share of
  /// pixels at level 0 up to 1: luma, and red, green and blue, so either `Histogram.Space` matches
  /// without reading the image again.
  struct HistogramTable: Codable, Hashable, Sendable {
    var luma: [Double]
    var red: [Double]
    var green: [Double]
    var blue: [Double]

    /// The tables' contents, for `StoredHistogram.digest`: SHA-256 of their lengths and values'
    /// bits, as hex.
    var digest: String {
      var bytes = Data()
      for value in luma + red + green + blue {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
      }
      return Edit.digest("\(luma.count) \(red.count) \(green.count) \(blue.count)", bytes)
    }
  }

  /// A 3D LUT's table as a record keeps it: `size`³ RGB entries, red changing fastest as in a
  /// `.cube` file, as little-endian Float16 (`data`, base64 in JSON), with the `.cube`
  /// DOMAIN_MIN/DOMAIN_MAX its inputs are scaled from. Float16 is plenty for output values in
  /// 0–1 and halves the size: a 33³ table is about 210 KB.
  struct LUTTable: Codable, Hashable, Sendable {
    var name: String
    var size: Int
    var domainMin: [Double] = [0, 0, 0]
    var domainMax: [Double] = [1, 1, 1]
    var data: Data

    /// A table of `size`³ RGB `values` (red fastest).
    init(name: String, size: Int, values: [Float], domainMin: [Double] = [0, 0, 0], domainMax: [Double] = [1, 1, 1]) {
      self.name = name
      self.size = size
      self.domainMin = domainMin
      self.domainMax = domainMax
      var bytes = Data(capacity: values.count * 2)
      for value in values {
        let bits = Float16(value).bitPattern.littleEndian
        withUnsafeBytes(of: bits) { bytes.append(contentsOf: $0) }
      }
      data = bytes
    }

    /// The entries back as Float, `size`³ × 3; empty when `data` is the wrong length.
    var values: [Float] {
      let count = size * size * size * 3
      guard size > 0, data.count == count * 2 else { return [] }
      return data.withUnsafeBytes { raw in
        (0..<count).map { Float(Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)))) }
      }
    }

    /// The table's contents, for `EditOptions.LUTRef.digest`: SHA-256 of its size, domain and
    /// entries, as hex.
    var digest: String { Edit.digest("\(size) \(domainMin) \(domainMax)", data) }
  }
}

extension GrainProfile.RealNoise {
  /// The patches' contents, for `Edit.StoredNoise.digest`: SHA-256 of their layout, encoding and
  /// curve, then the bytes, as hex.
  nonisolated var digest: String { Edit.digest("\(patch) \(count) \(enc) \(curve)", data) }
}
