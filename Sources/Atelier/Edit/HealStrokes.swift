import Foundation

/// The Heal tool's strokes as data: what a step records (`StoredHeal`, the strokes themselves in
/// the project's tensor store) and the Aligned source rule (`HealSource`). `HealBrush` applies
/// them. All coordinates are the source image's pixels, top-left origin, pixel (x, y) covering
/// [x, x + 1) × [y, y + 1), so they survive a crop, which is applied after the heal.
nonisolated extension Edit {
  /// One stroke: a polyline brushed with discs of `radius`, filled from the pixels at `offset`
  /// from each of its pixels. The offset is stored explicitly (not the source point), so a stroke
  /// renders the same whichever source rule made it, and a later Fixed mode needs no new format.
  struct HealStroke: Hashable, Sendable {
    var points: [SIMD2<Float>]
    /// In image pixels.
    var radius: Float
    /// Source minus destination, in image pixels; rounded to whole pixels when applied so the
    /// copied texture isn't softened by resampling.
    var offset: SIMD2<Float>
    /// The soft edge's width as a share of `radius`.
    var feather: Float
    /// Reserved for frequency separation: 0 heals both bands (all there is today); later values
    /// name the low (colour) or high (texture) band. Kept in the encoding so adding the Band
    /// picker changes no layout, only `HealStrokes.version`; until then decoding refuses others.
    var band: UInt8

    static let defaultFeather: Float = 0.25

    init(points: [SIMD2<Float>], radius: Float, offset: SIMD2<Float>, feather: Float = Self.defaultFeather, band: UInt8 = 0) {
      self.points = points
      self.radius = radius
      self.offset = offset
      self.feather = feather
      self.band = band
    }
  }

  /// A step's strokes, applied in order (each heals the result of the ones before it), with the
  /// compact binary form the tensor store keeps. Strokes pass the ~10 KB `profile_data` keeps
  /// comfortably (50 spots × 30 points is 12 KB), so they go in the store by digest as the other
  /// large Edit data do; JSON (the queue's) carries `encoded` as base64.
  struct HealStrokes: Hashable, Sendable, Codable {
    var strokes: [HealStroke]

    static let empty = HealStrokes(strokes: [])
    /// The encoding's version; `init?(encoded:)` refuses any other, so an older app reading a
    /// newer project leaves Heal off rather than misreading it. Bump it when bands arrive (band
    /// values other than 0) and whenever `HealBrush`'s solver constants change the pixels a
    /// stroke heals to.
    static let version: UInt16 = 1

    init(strokes: [HealStroke]) { self.strokes = strokes }

    var isEmpty: Bool { strokes.isEmpty }

    /// Little-endian: `u16 version, u32 strokes`; per stroke `u32 n, f32 radius, f32 feather,
    /// f32 dx, f32 dy, u8 band, n × (f32 x, f32 y)`.
    var encoded: Data {
      var data = Data(capacity: 6 + strokes.reduce(0) { $0 + 21 + $1.points.count * 8 })
      func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
      func put(_ value: Float) { put(value.bitPattern) }
      put(Self.version)
      put(UInt32(strokes.count))
      for stroke in strokes {
        put(UInt32(stroke.points.count))
        put(stroke.radius)
        put(stroke.feather)
        put(stroke.offset.x)
        put(stroke.offset.y)
        put(stroke.band)
        for point in stroke.points {
          put(point.x)
          put(point.y)
        }
      }
      return data
    }

    /// Nil for another version, data that's cut short or runs on, a value that isn't finite, or a
    /// band other than 0 (no bands exist yet; HealBrush checks values again before using them).
    init?(encoded data: Data) {
      var reader = Reader(bytes: [UInt8](data))
      guard let version: UInt16 = reader.integer(), version == Self.version, let count: UInt32 = reader.integer() else { return nil }
      var strokes: [HealStroke] = []
      for _ in 0..<count {
        guard let n: UInt32 = reader.integer(), let radius = reader.float(), let feather = reader.float(),
              let dx = reader.float(), let dy = reader.float(), let band: UInt8 = reader.integer(),
              band == 0, radius.isFinite, feather.isFinite, dx.isFinite, dy.isFinite,
              reader.remaining >= Int(n) * 8
        else { return nil }
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(Int(n))
        for _ in 0..<n {
          guard let x = reader.float(), let y = reader.float(), x.isFinite, y.isFinite else { return nil }
          points.append(SIMD2(x, y))
        }
        strokes.append(HealStroke(points: points, radius: radius, offset: SIMD2(dx, dy), feather: feather, band: band))
      }
      guard reader.remaining == 0 else { return nil }
      self.strokes = strokes
    }

    /// SHA-256 of the encoding, as hex, for `StoredHeal.digest`.
    var digest: String { Edit.digest("heal", encoded) }

    init(from decoder: Decoder) throws {
      let data = try decoder.singleValueContainer().decode(Data.self)
      guard let strokes = HealStrokes(encoded: data) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unreadable heal strokes"))
      }
      self = strokes
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(encoded)
    }

    private struct Reader {
      let bytes: [UInt8]
      var offset = 0

      var remaining: Int { bytes.count - offset }

      mutating func integer<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        var value: T = 0
        for index in 0..<size { value |= T(bytes[offset + index]) << (8 * index) }
        offset += size
        return value
      }

      mutating func float() -> Float? { (integer() as UInt32?).map(Float.init(bitPattern:)) }
    }
  }

  /// A record's strokes: where they are (`edit_heal_<id>`, a UInt8 tensor of `HealStrokes.encoded`)
  /// and how many, so a step's record stays small however many spots it has.
  struct StoredHeal: Codable, Hashable, Sendable {
    /// Nil until the step is saved.
    var id: Int64?
    /// `HealStrokes.digest`.
    var digest: String
    var count: Int
    var version: Int

    init(_ strokes: HealStrokes) {
      digest = strokes.digest
      count = strokes.strokes.count
      version = Int(HealStrokes.version)
    }

    static let prefix = "edit_heal_"
    var tensorName: String? { id.map { "\(Self.prefix)\($0)" } }
  }

  /// Where the next stroke copies from, Aligned as Photoshop's clone brush is by default: the
  /// user sets a source point, the first stroke after it fixes the offset (source minus that
  /// stroke's first point), and later strokes keep the offset until a new source is set, so
  /// working along a cheek keeps sampling the skin beside it. It belongs to the session, not the
  /// record: only each stroke's offset is saved.
  enum HealSource: Hashable, Sendable {
    /// Set, with no stroke since.
    case point(SIMD2<Float>)
    /// Fixed by the first stroke after the source was set.
    case offset(SIMD2<Float>)

    /// The stroke `points` make with `source` (nil for no source: painting before a source is
    /// set does nothing), fixing the offset on the first stroke after a new source.
    static func stroke(points: [SIMD2<Float>], radius: Float, source: inout HealSource?) -> HealStroke? {
      guard let first = points.first, radius > 0, let current = source else { return nil }
      let offset: SIMD2<Float>
      switch current {
      case .point(let point):
        offset = point - first
        source = .offset(offset)
      case .offset(let kept):
        offset = kept
      }
      return HealStroke(points: points, radius: radius, offset: offset)
    }
  }
}
