import Foundation
import UniformTypeIdentifiers
import _MediaGenerationKit

/// Writes each output as a PNG plus a JSON sidecar under ~/Pictures/Atelier/<date>/.
enum HistoryStore {
  struct Sidecar: Encodable {
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
  }

  @discardableResult
  static func save(
    _ result: MediaGenerationPipeline.Result,
    request: GenerationEngine.Request,
    configuration: MediaGenerationPipeline.Configuration,
    startedAt: Date,
    finishedAt: Date
  ) throws -> URL {
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
    try result.write(to: pngURL, type: .png)

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
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(sidecar).write(to: folder.appendingPathComponent(base + ".json"))
    return pngURL
  }
}

/// Minimal JSON tree for dumping Configuration, which isn't Codable in MGK.
enum JSONValue: Encodable {
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
