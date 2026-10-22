import CoreGraphics
import Diffusion
import Foundation
import ImageIO
import NNC
import Observation
import _MediaGenerationKit

/// One generated image: a step in the current project.
struct HistoryItem: Identifiable, Hashable {
  var id: StepID
  var tensorId: Int64
  var previewId: Int64
  var sidecar: HistoryStore.Sidecar

  static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// History lives in projects: Draw Things-format `.sqlite3` files under
/// ~/Pictures/Atelier/Projects/. One is current; Create appends to it and History lists its main
/// line (newest first).
@MainActor
@Observable
final class HistoryStore {
  /// A history item's settings summary. Built from the project's step; also the format of the
  /// JSON sidecars Atelier wrote before projects (imported once, see `importLegacyHistory`) and
  /// of the iTXt chunk in exported PNGs.
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
  }

  private(set) var project: Project
  /// Project names (file names without `.sqlite3`), sorted.
  private(set) var projectNames: [String] = []
  private(set) var items: [HistoryItem] = []
  private(set) var isLoaded = false
  /// Progress of the one-time import of the old PNG history, while it runs.
  private(set) var importProgress: (done: Int, total: Int)?

  static let defaultProjectName = "Atelier"
  private static let currentProjectKey = "currentProject"

  init() {
    // Scripted runs (Automation) pass `--project NAME` to keep their images out of the user's.
    let args = CommandLine.arguments
    let scripted = args.firstIndex(of: "--project").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let saved = SessionState.isEnabled
      ? UserDefaults.standard.string(forKey: Self.currentProjectKey) : nil
    project = Project(url: Self.url(for: scripted ?? saved ?? Self.defaultProjectName))
    Task {
      await reload()
      await importLegacyHistory()
    }
  }

  nonisolated static var projectsDirectory: URL {
    AppSettings.historyDirectory.appendingPathComponent("Projects", isDirectory: true)
  }

  nonisolated static func url(for name: String) -> URL {
    try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    return projectsDirectory.appendingPathComponent(name).appendingPathExtension("sqlite3")
  }

  func reload() async {
    let project = project
    let loaded = await Task.detached { project.items() }.value
    guard project === self.project else { return }
    items = loaded
    projectNames = Self.scanProjectNames()
    if !projectNames.contains(project.name) { projectNames = (projectNames + [project.name]).sorted() }
    isLoaded = true
  }

  // MARK: - Projects

  /// Makes `name` the current project, creating it if needed.
  func open(_ name: String) async {
    guard name != project.name else { return }
    project = Project(url: Self.url(for: name))
    if SessionState.isEnabled { UserDefaults.standard.set(name, forKey: Self.currentProjectKey) }
    isLoaded = false
    items = []
    await reload()
  }

  /// A name not taken yet: `base`, else `base 2`, `base 3`, …
  func availableName(_ base: String = "Untitled") -> String {
    let names = Set(Self.scanProjectNames() + [project.name])
    var name = base
    var n = 2
    while names.contains(name) {
      name = "\(base) \(n)"
      n += 1
    }
    return name
  }

  static func isValidName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.hasPrefix(".")
  }

  /// Renames the current project's file (and its -wal/-shm).
  func renameCurrent(to name: String) async throws {
    let name = name.trimmingCharacters(in: .whitespaces)
    guard Self.isValidName(name), name != project.name else { return }
    let target = Self.url(for: name)
    guard !FileManager.default.fileExists(atPath: target.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let old = project.url
    // Close the workspace first so nothing writes while the files move.
    await project.close()
    try FileManager.default.moveItem(at: old, to: target)
    for suffix in ["-wal", "-shm"] {
      let side = URL(fileURLWithPath: old.path + suffix)
      if FileManager.default.fileExists(atPath: side.path) {
        try? FileManager.default.moveItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
      }
    }
    project = Project(url: target)
    if SessionState.isEnabled { UserDefaults.standard.set(name, forKey: Self.currentProjectKey) }
    await reload()
  }

  private nonisolated static func scanProjectNames() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: projectsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return files.filter { $0.pathExtension == "sqlite3" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  // MARK: - Items

  @discardableResult
  func save(
    _ result: MediaGenerationPipeline.Result,
    request: GenerationEngine.Request,
    startedAt: Date,
    finishedAt: Date
  ) async throws -> HistoryItem {
    var settings = request.configuration
    settings.seed = request.seed
    let project = project
    let item = try await project.append(
      tensor: result.tensor, model: request.model, prompt: request.prompt,
      negativePrompt: request.negativePrompt, seed: request.seed,
      settings: JSONValue.fields(of: settings), createdAt: finishedAt,
      duration: finishedAt.timeIntervalSince(startedAt))
    if project === self.project { items.insert(item, at: 0) }
    return item
  }

  /// Removes the step from the project. Later steps move down by one, so the list is reloaded.
  func delete(_ item: HistoryItem) async throws {
    try await project.delete(item.id)
    await reload()
  }

  func item(_ id: StepID) -> HistoryItem? {
    items.first { $0.id == id }
  }

  /// The step's JPEG preview (`half` for grids), decoded off the main actor.
  func thumbnail(for item: HistoryItem, half: Bool) async -> CGImage? {
    let key = "\(project.url.path)#\(item.previewId)#\(half)" as NSString
    if let cached = Self.thumbnails.object(forKey: key) { return cached }
    let project = project
    let image = await Task.detached { project.thumbnail(previewId: item.previewId, half: half) }.value
    if let image { Self.thumbnails.setObject(image, forKey: key) }
    return image
  }

  /// The full-resolution image, decoded from the project's tensor.
  func image(for item: HistoryItem) async -> CGImage? {
    let project = project
    return await Task.detached { project.image(for: item) }.value
  }

  /// The full-resolution image of a step in `projectName` (when that's the current project).
  func image(at id: StepID, in projectName: String) async -> CGImage? {
    guard projectName == project.name else { return nil }
    let project = project
    return await Task.detached { project.image(at: id) }.value
  }

  /// Writes the image as a PNG carrying its settings (an `Atelier` iTXt chunk).
  func exportPNG(_ item: HistoryItem, to url: URL) async throws {
    guard let image = await image(for: item), let png = ImageTensor.png(image) else {
      throw ProjectError.badImage
    }
    let json = try Self.encoder.encode(item.sidecar)
    let tagged = PNGText.inserting(
      keyword: "Atelier", text: String(decoding: json, as: UTF8.self), into: png)
    try (tagged ?? png).write(to: url)
  }

  private static let thumbnails = NSCache<NSString, CGImage>()

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  // MARK: - Old PNG history

  private static let legacyImportedKey = "legacyHistoryImported"

  /// Copies the PNG + JSON history from before projects (~/Pictures/Atelier/<date>/) into the
  /// default project, oldest first, once. The old files are left where they are.
  func importLegacyHistory() async {
    guard SessionState.isEnabled, !UserDefaults.standard.bool(forKey: Self.legacyImportedKey)
    else { return }
    let legacy = await Task.detached { Self.scanLegacy(AppSettings.historyDirectory) }.value
    guard !legacy.isEmpty else {
      UserDefaults.standard.set(true, forKey: Self.legacyImportedKey)
      return
    }
    let target = project.name == Self.defaultProjectName
      ? project : Project(url: Self.url(for: Self.defaultProjectName))
    importProgress = (0, legacy.count)
    for (index, entry) in legacy.reversed().enumerated() {
      let tensor = await Task.detached { () -> Tensor<FloatType>? in
        guard let source = CGImageSourceCreateWithURL(entry.png as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return ImageTensor.tensor(from: image)
      }.value
      if let tensor {
        let sidecar = entry.sidecar
        _ = try? await target.append(
          tensor: tensor, model: sidecar.model, prompt: sidecar.prompt,
          negativePrompt: sidecar.negativePrompt, seed: sidecar.seed,
          settings: sidecar.configuration, createdAt: sidecar.createdAt,
          duration: sidecar.durationSeconds)
      }
      importProgress = (index + 1, legacy.count)
    }
    importProgress = nil
    UserDefaults.standard.set(true, forKey: Self.legacyImportedKey)
    if target === project { await reload() }
  }

  private nonisolated static func scanLegacy(_ root: URL) -> [(png: URL, sidecar: Sidecar)] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let fileManager = FileManager.default
    let days = (try? fileManager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
    var items: [(png: URL, sidecar: Sidecar)] = []
    for day in days where day.lastPathComponent != "Projects" {
      let files = (try? fileManager.contentsOfDirectory(
        at: day, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
      for json in files where json.pathExtension == "json" {
        let png = json.deletingPathExtension().appendingPathExtension("png")
        guard fileManager.fileExists(atPath: png.path),
          let data = try? Data(contentsOf: json),
          let sidecar = try? decoder.decode(Sidecar.self, from: data)
        else { continue }
        items.append((png, sidecar))
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
enum JSONValue: Codable, Hashable {
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
    case let value as Float: self = JSONValue(value)
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
