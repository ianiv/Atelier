import AppKit
import Observation
import UniformTypeIdentifiers

/// Which settings the inspector shows, in what order, and which sections start expanded.
/// Settings not in `shown` are tucked under their section's "More" disclosure.
struct InspectorLayout: Codable, Hashable, Identifiable {
  var name: String
  /// Shown setting ids, in display order (each stays in its registry section).
  var shown: [String]
  /// Section ids that start expanded.
  var expanded: [String]
  /// Section ids in display order; nil (older layout files) means the registry order.
  var sectionOrder: [String]? = nil

  var id: String { name }

  /// Every section in display order; sections missing from `sectionOrder` keep registry order at
  /// the end.
  var sections: [SettingSection] {
    let ordered = (sectionOrder ?? []).compactMap(SettingSection.init(rawValue:))
    return ordered + SettingSection.allCases.filter { !ordered.contains($0) }
  }

  func isShown(_ id: String) -> Bool { shown.contains(id) }

  /// Section's settings in display order: shown ones in layout order, then tucked in registry order.
  func ordered(_ section: SettingSection) -> (shown: [SettingDescriptor], tucked: [SettingDescriptor]) {
    let all = SettingsRegistry.descriptors(in: section)
    let shownList = shown.compactMap { id in all.first { $0.id == id } }
    let tucked = all.filter { !shown.contains($0.id) }
    return (shownList, tucked)
  }

  static let simple = InspectorLayout(
    name: "Simple", shown: ["size", "steps", "guidanceScale", "sampler"],
    expanded: [SettingSection.essentials.id])

  static let standard = InspectorLayout(
    name: "Standard",
    shown: [
      "size", "steps", "guidanceScale", "sampler", "loras", "shift", "resolutionDependentShift",
      "seedMode", "speedUpWithGuidanceEmbed", "guidanceEmbed", "hiresFix", "hiresFixWidth",
      "hiresFixHeight", "hiresFixStrength", "refinerModel", "refinerStart", "upscaler",
      "numFrames", "fps", "strength", "teaCache", "teaCacheThreshold", "cfgZeroStar",
      "cfgZeroInitSteps",
    ],
    expanded: [SettingSection.essentials.id, SettingSection.loras.id, SettingSection.sampling.id,
      SettingSection.video.id])

  static let everything = InspectorLayout(
    name: "Everything", shown: SettingsRegistry.all.map(\.id),
    expanded: SettingSection.allCases.map(\.id))

  static let builtIns = [simple, standard, everything]
}

/// Built-in and custom inspector layouts; custom ones are JSON files in Application Support.
@MainActor
@Observable
final class LayoutStore {
  private(set) var custom: [InspectorLayout] = []
  private(set) var current: InspectorLayout
  /// Sections expanded right now; starts from the layout's and persists across launches.
  private(set) var expandedSections: Set<String>

  // Inspector view state shared with the menu bar and Automation.
  var searchText = ""
  var showAll = false
  var customizing = false

  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier/Layouts", isDirectory: true)
  }

  private static let currentKey = "inspectorLayout"
  private static let expandedKey = "inspectorExpandedSections"

  init() {
    let custom: [InspectorLayout] = Self.loadAll(from: Self.directory)
    self.custom = custom
    let name = UserDefaults.standard.string(forKey: Self.currentKey) ?? InspectorLayout.standard.name
    let layout =
      (InspectorLayout.builtIns + custom).first { $0.name == name } ?? InspectorLayout.standard
    current = layout
    if let saved = UserDefaults.standard.stringArray(forKey: Self.expandedKey) {
      expandedSections = Set(saved)
    } else {
      expandedSections = Set(layout.expanded)
    }
  }

  var all: [InspectorLayout] { InspectorLayout.builtIns + custom }

  func isBuiltIn(_ layout: InspectorLayout) -> Bool {
    InspectorLayout.builtIns.contains { $0.name == layout.name }
  }

  func select(_ layout: InspectorLayout) {
    current = layout
    UserDefaults.standard.set(layout.name, forKey: Self.currentKey)
    setExpanded(Set(layout.expanded))
  }

  func isExpanded(_ section: SettingSection) -> Bool { expandedSections.contains(section.id) }

  func setExpanded(_ section: SettingSection, _ expanded: Bool) {
    var sections = expandedSections
    if expanded { sections.insert(section.id) } else { sections.remove(section.id) }
    setExpanded(sections)
  }

  private func setExpanded(_ sections: Set<String>) {
    expandedSections = sections
    UserDefaults.standard.set(Array(sections).sorted(), forKey: Self.expandedKey)
  }

  /// Shows or hides one setting. Editing a built-in layout first copies it to a custom one.
  func setShown(_ id: String, _ shown: Bool) {
    var layout = current
    layout.shown.removeAll { $0 == id }
    if shown {
      // Append after the last shown setting of the same section, keeping sections together.
      let section = SettingsRegistry.byID[id]?.section
      let index = layout.shown.lastIndex { SettingsRegistry.byID[$0]?.section == section }
      layout.shown.insert(id, at: index.map { $0 + 1 } ?? layout.shown.count)
    }
    update(layout)
  }

  /// Saves `layout` as the current one, copying built-ins under a new name.
  func update(_ layout: InspectorLayout) {
    var layout = layout
    if isBuiltIn(layout) {
      layout.name = uniqueName("\(layout.name) Custom")
    }
    save(layout)
    current = layout
    UserDefaults.standard.set(layout.name, forKey: Self.currentKey)
  }

  /// Moves a section up (-1) or down (+1) among the sections.
  func moveSection(_ section: SettingSection, by offset: Int) {
    var order = current.sections
    guard let index = order.firstIndex(of: section),
      order.indices.contains(index + offset)
    else { return }
    order.swapAt(index, index + offset)
    var layout = current
    layout.sectionOrder = order.map(\.id)
    update(layout)
  }

  func delete(_ layout: InspectorLayout) {
    guard !isBuiltIn(layout) else { return }
    try? FileManager.default.trashItem(at: Self.url(for: layout.name), resultingItemURL: nil)
    custom.removeAll { $0.name == layout.name }
    if current.name == layout.name { select(.standard) }
  }

  func export(_ layout: InspectorLayout, to url: URL) throws {
    try Self.encoder.encode(layout).write(to: url)
  }

  /// Imports a layout file, renaming it if the name is taken, and selects it.
  @discardableResult
  func importLayout(from url: URL) throws -> InspectorLayout {
    var layout = try JSONDecoder().decode(InspectorLayout.self, from: Data(contentsOf: url))
    layout.shown = layout.shown.filter { SettingsRegistry.byID[$0] != nil }
    if all.contains(where: { $0.name == layout.name }) { layout.name = uniqueName(layout.name) }
    save(layout)
    select(layout)
    return layout
  }

  func uniqueName(_ base: String) -> String {
    var name = base
    var n = 2
    while all.contains(where: { $0.name == name }) {
      name = "\(base) \(n)"
      n += 1
    }
    return name
  }

  private func save(_ layout: InspectorLayout) {
    do {
      try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
      try Self.encoder.encode(layout).write(to: Self.url(for: layout.name))
    } catch {
      NSLog("Atelier: couldn't save layout \(layout.name): \(error)")
    }
    if let index = custom.firstIndex(where: { $0.name == layout.name }) {
      custom[index] = layout
    } else {
      custom.append(layout)
      custom.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
  }

  static func url(for name: String) -> URL {
    directory.appendingPathComponent(fileName(name)).appendingPathExtension("json")
  }

  static func fileName(_ name: String) -> String {
    String(name.map { "/:\\".contains($0) ? "-" : $0 })
  }

  static func loadAll<T: Decodable>(from directory: URL) -> [T] where T: Identifiable {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return files.filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
      .compactMap { try? JSONDecoder().decode(T.self, from: Data(contentsOf: $0)) }
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()
}

/// Saved setting values, applied on top of the selected model's defaults.
struct Preset: Codable, Hashable, Identifiable {
  var name: String
  /// Registry id → value, in the same encoding as history sidecars.
  var values: [String: JSONValue]
  /// The model file this preset belongs to; nil for presets offered with every model.
  var model: String? = nil
  /// The seed's Random checkbox. Nil (saved before presets stored it) leaves it alone, except that
  /// a model's default preset turns it on.
  var randomSeed: Bool? = nil

  var id: String { name }
}

/// Presets stored as JSON next to the layouts.
@MainActor
@Observable
final class PresetStore {
  private(set) var presets: [Preset] = []
  /// Model file → name of the preset applied as that model's defaults.
  private(set) var defaults: [String: String] = [:]
  private static let defaultsKey = "defaultPresets"

  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Atelier/Presets", isDirectory: true)
  }

  init() {
    presets = LayoutStore.loadAll(from: Self.directory)
    defaults = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
  }

  /// Presets that can be used with `model`: its own, then the ones for every model.
  func presets(for model: String?) -> (own: [Preset], shared: [Preset]) {
    (presets.filter { $0.model != nil && $0.model == model }, presets.filter { $0.model == nil })
  }

  func defaultPreset(for model: String) -> Preset? {
    defaults[model].flatMap { name in presets.first { $0.name == name } }
  }

  func setDefault(_ preset: Preset?, for model: String) {
    defaults[model] = preset?.name
    UserDefaults.standard.set(defaults, forKey: Self.defaultsKey)
  }

  func save(_ preset: Preset) throws {
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    try LayoutStore.encoder.encode(preset).write(to: Self.url(for: preset.name))
    presets.removeAll { $0.name == preset.name }
    presets.append(preset)
    presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func delete(_ preset: Preset) {
    try? FileManager.default.trashItem(at: Self.url(for: preset.name), resultingItemURL: nil)
    presets.removeAll { $0.name == preset.name }
    for (model, name) in defaults where name == preset.name { setDefault(nil, for: model) }
  }

  func export(_ preset: Preset, to url: URL) throws {
    try LayoutStore.encoder.encode(preset).write(to: url)
  }

  @discardableResult
  func importPreset(from url: URL) throws -> Preset {
    var preset = try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
    preset.values = preset.values.filter { SettingsRegistry.byID[$0.key] != nil }
    var name = preset.name
    var n = 2
    while presets.contains(where: { $0.name == name }) {
      name = "\(preset.name) \(n)"
      n += 1
    }
    preset.name = name
    try save(preset)
    return preset
  }

  static func url(for name: String) -> URL {
    directory.appendingPathComponent(LayoutStore.fileName(name)).appendingPathExtension("json")
  }
}

/// Save and open panels for layout and preset files.
@MainActor
enum FilePanels {
  static func saveJSON(named name: String) -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = LayoutStore.fileName(name) + ".json"
    return panel.runModal() == .OK ? panel.url : nil
  }

  static func openJSON() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.canChooseDirectories = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}
