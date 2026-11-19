import CryptoKit
import Foundation

/// The Edit screen's queued saves and what a saved step records. Rendering is `EditPipeline`'s;
/// the job runs in `CreateModel.runEdit(_:request:job:)`.
nonisolated enum Edit {
  /// The Edit screen's sidebar symbol, also its Queue rows' icon.
  static let symbol = "slider.horizontal.below.rectangle"

  /// A queued Save to History from the Edit screen (`GenerationEngine.Request.edit`), as
  /// `ColorMatch.Job` is for Match Colors…: which step, in which project, with which look. It
  /// names its project because it saves there whichever project is open when it runs. Unlike a
  /// colour match it carries its `record` from the moment it's queued: the profile, reference
  /// and LUT it renders with may be files that are gone by the time it runs (after a quit, say),
  /// so the job keeps what it needs of them (`SavedQueue` writes it as JSON beside the rest).
  struct Job: Codable, Hashable, Sendable {
    var project: String
    /// The source step's image tensor, which stays the same when steps are renumbered.
    var sourceTensorId: Int64
    var options: EditOptions
    /// The grain profile the look came from, for the Queue row and the record; nil for none.
    var profileName: String?
    /// The reference image, when it's a step of `project` (matched to with `Match.target`
    /// `.reference`); nil for none, or one from a file (its measurements are in `record`).
    var referenceTensorId: Int64?
    /// Everything it's rendered with, and what the saved step keeps.
    var record: Record

    init(
      project: String, sourceTensorId: Int64, options: EditOptions, profileName: String? = nil,
      referenceTensorId: Int64? = nil, record: Record? = nil
    ) {
      self.project = project
      self.sourceTensorId = sourceTensorId
      self.options = options
      self.profileName = profileName
      self.referenceTensorId = referenceTensorId
      self.record =
        record
          ?? Record(options: options, sourceTensorId: sourceTensorId, profileName: profileName, referenceTensorId: referenceTensorId)
    }

    /// The same edit: the same step, with the same look rendered with the same profile data,
    /// reference and LUT, whose result would be the same image, so it's never queued twice.
    func isSameEdit(as other: Job) -> Bool {
      project == other.project && sourceTensorId == other.sourceTensorId && options.snapped == other.options.snapped
        && profileName == other.profileName && referenceTensorId == other.referenceTensorId
        && record.renderInputs == other.record.renderInputs
    }
  }

  /// What a step saved from the Edit screen records (`profile_data` `edit`): its look, and
  /// everything it was rendered with, so opening it in Edit goes back to its source with the
  /// same settings, and it renders again exactly even once the profile or LUT file is gone. The
  /// real-noise patches are copied in by the user's choice for that reason (about 830 KB of
  /// bytes for a full profile's 120, base64 in the JSON); the LUT's table goes in as Float16.
  struct Record: Codable, Hashable, Sendable {
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
    /// The profile's real-noise patches (grain.py's `real`), for `Grain.real`.
    var realNoise: GrainProfile.RealNoise?
    /// The Reinhard match target's Lab statistics (the reference's, or the original's).
    var referenceLab: LabStats?
    /// The match target's cumulative histograms, for `Histogram`.
    var referenceHistogram: HistogramTable?
    /// The LUT's table, for `EditOptions.lut`.
    var lut: LUTTable?

    init(
      options: EditOptions, sourceTensorId: Int64, profileName: String? = nil, referenceTensorId: Int64? = nil,
      referenceName: String? = nil, refWidth: Int = 1440, curve: [Double]? = nil, refStats: GrainProfile.ChannelStats? = nil,
      realNoise: GrainProfile.RealNoise? = nil, referenceLab: LabStats? = nil, referenceHistogram: HistogramTable? = nil,
      lut: LUTTable? = nil
    ) {
      self.options = options
      self.sourceTensorId = sourceTensorId
      self.profileName = profileName
      self.referenceTensorId = referenceTensorId
      self.referenceName = referenceName
      self.refWidth = refWidth
      self.curve = curve
      self.refStats = refStats
      self.realNoise = realNoise
      self.referenceLab = referenceLab
      self.referenceHistogram = referenceHistogram
      self.lut = lut
    }

    /// What it renders with besides its options (`EditPipeline.Context`).
    var context: EditPipeline.Context {
      EditPipeline.Context(
        refWidth: refWidth, curve: curve, refStats: refStats, realNoise: realNoise, referenceLab: referenceLab,
        referenceHistogram: referenceHistogram, lut: lut)
    }

    /// The context, for comparing two records' inputs.
    fileprivate var renderInputs: EditPipeline.Context { context }

    private enum CodingKeys: String, CodingKey {
      case options, sourceTensorId, profileName, referenceTensorId, referenceName, refWidth, curve, refStats, realNoise
      case referenceLab, referenceHistogram, lut
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      options = try c.decodeIfPresent(EditOptions.self, forKey: .options) ?? EditOptions()
      sourceTensorId = try c.decode(Int64.self, forKey: .sourceTensorId)
      profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
      referenceTensorId = try c.decodeIfPresent(Int64.self, forKey: .referenceTensorId)
      referenceName = try c.decodeIfPresent(String.self, forKey: .referenceName)
      refWidth = try c.decodeIfPresent(Int.self, forKey: .refWidth) ?? 1440
      curve = try c.decodeIfPresent([Double].self, forKey: .curve)
      refStats = try c.decodeIfPresent(GrainProfile.ChannelStats.self, forKey: .refStats)
      realNoise = try c.decodeIfPresent(GrainProfile.RealNoise.self, forKey: .realNoise)
      referenceLab = try c.decodeIfPresent(LabStats.self, forKey: .referenceLab)
      referenceHistogram = try c.decodeIfPresent(HistogramTable.self, forKey: .referenceHistogram)
      lut = try c.decodeIfPresent(LUTTable.self, forKey: .lut)
    }
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
    var digest: String {
      var hasher = SHA256()
      hasher.update(data: Data("\(size) \(domainMin) \(domainMax)".utf8))
      hasher.update(data: data)
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
}
