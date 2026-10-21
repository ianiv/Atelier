import Foundation
import Observation
import _MediaGenerationKit

/// One saved output: the PNG and its decoded sidecar.
struct HistoryItem: Identifiable, Hashable {
  var imageURL: URL
  var sidecar: HistoryStore.Sidecar

  var id: URL { imageURL }
  var sidecarURL: URL { imageURL.deletingPathExtension().appendingPathExtension("json") }

  static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool { lhs.imageURL == rhs.imageURL }
  func hash(into hasher: inout Hasher) { hasher.combine(imageURL) }
}

/// Outputs under ~/Pictures/Atelier/<date>/: a PNG plus a JSON sidecar each, indexed in memory
/// at launch (newest first).
@MainActor
@Observable
final class HistoryStore {
  struct Sidecar: Codable {
    var app = "Atelier"
    var createdAt: Date
    var durationSeconds: Double
    var prompt: String
    var negativePrompt: String
    var model: String
    var seed: UInt32
    var width: Int
    var height: Int
    var steps: Int
    var guidanceScale: Float
    var shift: Float
    var sampler: String
    var resolutionDependentShift: Bool
    var hiresFix: Bool
    /// Every public field of the pipeline configuration actually used.
    var configuration: [String: JSONValue]

    /// The inspector settings this output was made with; nil if the sampler name is unknown.
    var settings: GenerationSettings? {
      guard let sampler = SamplerType.allCases.first(where: { String(describing: $0) == sampler })
      else { return nil }
      return GenerationSettings(
        width: width, height: height, steps: steps, guidanceScale: guidanceScale, shift: shift,
        sampler: sampler, resolutionDependentShift: resolutionDependentShift, hiresFix: hiresFix)
    }
  }

  private(set) var items: [HistoryItem] = []
  private(set) var isLoaded = false

  init() {
    Task { await reload() }
  }

  func reload() async {
    let root = AppSettings.historyDirectory
    items = await Task.detached { Self.scan(root) }.value
    isLoaded = true
  }

  @discardableResult
  func save(
    _ result: MediaGenerationPipeline.Result,
    request: GenerationEngine.Request,
    configuration: MediaGenerationPipeline.Configuration,
    startedAt: Date,
    finishedAt: Date
  ) throws -> HistoryItem {
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    let time = DateFormatter()
    time.dateFormat = "HHmmss"
    let folder = AppSettings.historyDirectory.appendingPathComponent(
      day.string(from: finishedAt), isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    var base = "\(time.string(from: finishedAt))-\(request.seed)"
    var suffix = 1
    while FileManager.default.fileExists(
      atPath: folder.appendingPathComponent(base + ".png").path)
    {
      suffix += 1
      base = "\(time.string(from: finishedAt))-\(request.seed)-\(suffix)"
    }
    let pngURL = folder.appendingPathComponent(base + ".png")

    let settings = request.settings
    let sidecar = Sidecar(
      createdAt: finishedAt,
      durationSeconds: finishedAt.timeIntervalSince(startedAt),
      prompt: request.prompt,
      negativePrompt: request.negativePrompt,
      model: request.model,
      seed: request.seed,
      width: settings.width,
      height: settings.height,
      steps: settings.steps,
      guidanceScale: settings.guidanceScale,
      shift: settings.shift,
      sampler: String(describing: settings.sampler),
      resolutionDependentShift: settings.resolutionDependentShift,
      hiresFix: settings.hiresFix,
      configuration: JSONValue.fields(of: configuration)
    )
    let json = try Self.encoder.encode(sidecar)
    try json.write(to: folder.appendingPathComponent(base + ".json"))

    // MGK writes the encoded PNG directly, so embed the sidecar afterwards as an iTXt chunk
    // (UTF-8, unlike tEXt) to keep the file self-describing.
    try result.write(to: pngURL, type: .png)
    if let png = try? Data(contentsOf: pngURL),
      let tagged = PNGText.inserting(keyword: "Atelier", text: String(decoding: json, as: UTF8.self), into: png)
    {
      try tagged.write(to: pngURL)
    }

    let item = HistoryItem(imageURL: pngURL, sidecar: sidecar)
    items.insert(item, at: 0)
    return item
  }

  /// Moves the PNG and its sidecar to the Trash.
  func delete(_ item: HistoryItem) throws {
    let fileManager = FileManager.default
    try fileManager.trashItem(at: item.imageURL, resultingItemURL: nil)
    if fileManager.fileExists(atPath: item.sidecarURL.path) {
      try fileManager.trashItem(at: item.sidecarURL, resultingItemURL: nil)
    }
    items.removeAll { $0.id == item.id }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private nonisolated static func scan(_ root: URL) -> [HistoryItem] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let fileManager = FileManager.default
    let days = (try? fileManager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
    var items: [HistoryItem] = []
    for day in days {
      let files = (try? fileManager.contentsOfDirectory(
        at: day, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
      for json in files where json.pathExtension == "json" {
        let png = json.deletingPathExtension().appendingPathExtension("png")
        guard fileManager.fileExists(atPath: png.path),
          let data = try? Data(contentsOf: json),
          let sidecar = try? decoder.decode(Sidecar.self, from: data)
        else { continue }
        items.append(HistoryItem(imageURL: png, sidecar: sidecar))
      }
    }
    return items.sorted { $0.sidecar.createdAt > $1.sidecar.createdAt }
  }
}

/// Inserts a PNG iTXt chunk right after IHDR.
enum PNGText {
  static func inserting(keyword: String, text: String, into png: Data) -> Data? {
    let bytes = [UInt8](png)
    // 8-byte signature, then IHDR: length(4) type(4) data(13) crc(4).
    guard bytes.count > 33, bytes[12..<16].elementsEqual("IHDR".utf8) else { return nil }
    var body = [UInt8]("iTXt".utf8)
    body += Array(keyword.utf8) + [0]
    body += [0, 0]  // uncompressed, compression method 0
    body += [0, 0]  // empty language tag and translated keyword
    body += Array(text.utf8)
    var chunk = withUnsafeBytes(of: UInt32(body.count - 4).bigEndian, Array.init)
    chunk += body
    chunk += withUnsafeBytes(of: crc32(body).bigEndian, Array.init)
    return Data(bytes[..<33] + chunk + bytes[33...])
  }

  private static let table: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
  }

  private static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
  }
}

/// Minimal JSON tree for dumping Configuration, which isn't Codable in MGK.
enum JSONValue: Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  static func fields(of value: Any) -> [String: JSONValue] {
    var fields: [String: JSONValue] = [:]
    for child in Mirror(reflecting: value).children {
      guard let label = child.label else { continue }
      fields[label] = JSONValue(child.value)
    }
    return fields
  }

  init(_ value: Any) {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
      if let wrapped = mirror.children.first?.value {
        self = JSONValue(wrapped)
      } else {
        self = .null
      }
      return
    }
    switch value {
    case let value as Bool: self = .bool(value)
    case let value as Int: self = .number(Double(value))
    case let value as Int32: self = .number(Double(value))
    case let value as UInt32: self = .number(Double(value))
    case let value as Float: self = .number(Double(value))
    case let value as Double: self = .number(value)
    case let value as String: self = .string(value)
    default:
      switch mirror.displayStyle {
      case .collection, .set:
        self = .array(mirror.children.map { JSONValue($0.value) })
      case .struct, .class:
        self = .object(JSONValue.fields(of: value))
      default:
        // Enums (sampler, seed mode, …) encode as their case name.
        self = .string(String(describing: value))
      }
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}
