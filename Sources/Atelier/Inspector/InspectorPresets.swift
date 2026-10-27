import _MediaGenerationKit
import ImageIO
import SwiftUI

struct PresetMenu: View {
  @Environment(CreateModel.self) private var model
  @Environment(PresetStore.self) private var presets
  @Environment(\.undoManager) private var undoManager
  @Environment(FileDialogs.self) private var fileDialogs
  @Environment(\.openURL) private var openURL
  @State private var saving = false
  @State private var pasteFailed = false

  var body: some View {
    let modelName = model.selectedModelInfo?.name ?? "This Model"
    let (own, shared) = presets.presets(for: model.selectedModel)
    let others = presets.presets.filter { $0.model != nil && $0.model != model.selectedModel }
    let current = model.selectedModel.flatMap(presets.defaultPreset(for:))
    Menu {
      if presets.presets.isEmpty {
        Text("No presets yet")
      }
      if !own.isEmpty {
        Section(modelName) { presetButtons(own, default: current) }
      }
      if !shared.isEmpty {
        Section("All Models") { presetButtons(shared, default: current) }
      }
      if !others.isEmpty {
        Menu("Other Models") {
          ForEach(others) { preset in
            Button("\(preset.name) (\(name(of: preset.model)))") {
              model.apply(preset, undoManager: undoManager)
            }
          }
        }
      }
      Divider()
      Menu("Default for \(modelName)") {
        Button {
          model.setDefaultPreset(nil)
        } label: {
          if current == nil { Label("Model Defaults Only", systemImage: "checkmark") } else {
            Text("Model Defaults Only")
          }
        }
        if !(own + shared).isEmpty { Divider() }
        ForEach(own + shared) { preset in
          Button {
            model.setDefaultPreset(preset)
          } label: {
            if current?.name == preset.name {
              Label(preset.name, systemImage: "checkmark")
            } else {
              Text(preset.name)
            }
          }
        }
      }
      .disabled(model.selectedModel == nil)
      Button("Save Current Settings as Preset…") { saving = true }
        .disabled(model.settings == nil)
      Button("Copy Settings as JSON") {
        if let json = model.settingsJSON() { Clipboard.copy(String(decoding: json, as: UTF8.self)) }
      }
      .disabled(model.settings == nil)
      .help("Copies every setting, the model and the seed in Draw Things' configuration format.")
      Button("Paste Settings") {
        guard let text = Clipboard.string,
              let pasted = DrawThingsJSON.decode(Data(text.utf8))
        else {
          pasteFailed = true
          return
        }
        model.paste(pasted, undoManager: undoManager)
      }
      .disabled(model.settings == nil)
      .help("Applies settings copied from Draw Things or Atelier, on top of the model's defaults.")
      Divider()
      Button("Import Preset…") {
        fileDialogs.open = FileDialogs.Open(types: [.json]) { urls in
          guard let url = urls.first else { return }
          let access = url.startAccessingSecurityScopedResource()
          defer { if access { url.stopAccessingSecurityScopedResource() } }
          _ = try? presets.importPreset(from: url)
        }
      }
      if !presets.presets.isEmpty {
        Menu("Export") {
          ForEach(presets.presets) { preset in
            Button(preset.name) {
              fileDialogs.save = FileDialogs.Save(
                file: ExportedFile(type: .json) { try presets.exportData(preset) },
                name: LayoutStore.fileName(preset.name) + ".json")
            }
          }
        }
        Menu("Delete") {
          ForEach(presets.presets) { preset in
            Button(preset.name) { presets.delete(preset) }
          }
        }
      }
      Button("Show Presets Folder") {
        try? FileManager.default.createDirectory(
          at: PresetStore.directory, withIntermediateDirectories: true)
        openURL(PresetStore.directory)
      }
    } label: {
      Label("Presets", systemImage: "square.stack.3d.up")
    }
    .help("Presets: saved setting values applied on top of the model's defaults")
    .sheet(isPresented: $saving) { SavePresetSheet() }
    .debugPresents("savePreset", $saving)
    .alert("The clipboard has no settings", isPresented: $pasteFailed) {
      Button("OK") {}
    } message: {
      Text("Copy a configuration in Draw Things, or settings in Atelier, then paste again.")
    }
  }

  private func presetButtons(_ list: [Preset], default current: Preset?) -> some View {
    ForEach(list) { preset in
      Button(current?.name == preset.name ? "\(preset.name) (Default)" : preset.name) {
        model.apply(preset, undoManager: undoManager)
      }
      .help(preset.values.keys.sorted().joined(separator: ", "))
    }
  }

  private func name(of file: String?) -> String {
    model.models.first { $0.file == file }?.name ?? file ?? ""
  }
}

struct SavePresetSheet: View {
  @Environment(CreateModel.self) private var model
  @Environment(PresetStore.self) private var presets
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var included: Set<String> = []
  @State private var forThisModel = true
  @State private var makeDefault = false
  @State private var allSettings = true
  @State private var error: String?

  /// Every setting the current model uses (like Draw Things' saved configurations), or only the
  /// ones changed from its defaults.
  private var candidates: [SettingDescriptor] {
    allSettings
      ? SettingsRegistry.all.filter { $0.applies(model.traits) || model.isChanged($0) }
      : model.changedSettings
  }

  var body: some View {
    let candidates = candidates
    VStack(alignment: .leading, spacing: 12) {
      Text("Save Preset").font(.headline)
      TextField("Name", text: $name)
      Toggle("Only for \(model.selectedModelInfo?.name ?? "this model")", isOn: $forThisModel)
      Toggle("Use as this model's defaults", isOn: $makeDefault)
        .help("Applied whenever you switch to this model, and used by Reset.")
      if presets.presets.contains(where: { $0.name == name }) {
        Text("Replaces the existing preset “\(name)”.").font(.caption).foregroundStyle(.secondary)
      }
      Picker("Save", selection: $allSettings) {
        Text("All Current Settings").tag(true)
        Text("Changed Settings Only").tag(false)
      }
      .pickerStyle(.segmented)
      .help("Changed Only keeps the preset small, so the model's own defaults fill in the rest.")
      if candidates.isEmpty {
        Text("Nothing differs from the model defaults.").foregroundStyle(.secondary)
      }
      List(candidates) { descriptor in
        Toggle(isOn: Binding(
          get: { included.contains(descriptor.id) },
          set: { if $0 { included.insert(descriptor.id) } else { included.remove(descriptor.id) } })
        ) {
          HStack {
            Text(descriptor.title)
            Spacer()
            Text(SettingFormat.display(model.value(descriptor), for: descriptor))
              .foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      .frame(minHeight: 160)
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          do {
            let preset = Preset(
              name: name.trimmingCharacters(in: .whitespaces),
              values: model.values(for: Array(included)),
              model: forThisModel ? model.selectedModel : nil)
            try presets.save(preset)
            if makeDefault { model.setDefaultPreset(preset) }
            dismiss()
          } catch {
            self.error = error.localizedDescription
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || included.isEmpty)
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 500)
    .onAppear {
      included = Set(candidates.map(\.id))
    }
    .onChange(of: allSettings) { included = Set(candidates.map(\.id)) }
  }
}

// MARK: - Search field

/// A search field: a magnifying glass, the text and a clear button. Not `.searchable`, which puts
/// the field in the toolbar, and crashes alongside the customizable toolbar there.
struct SearchField: View {
  @Binding var text: String
  var prompt: String

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
      // Hidden rather than removed while empty, so the text doesn't shift.
      Button {
        text = ""
      } label: {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .opacity(text.isEmpty ? 0 : 1)
      .disabled(text.isEmpty)
      .accessibilityLabel("Clear")
    }
    .padding(.horizontal, 7)
    .frame(minHeight: 24)
    .background(.fill.quinary, in: .capsule)
    .overlay(Capsule().strokeBorder(.separator))
    .onKeyPress(.escape) {
      guard !text.isEmpty else { return .ignored }
      text = ""
      return .handled
    }
  }
}

// MARK: - Draw Things JSON

/// Settings as the flat JSON Draw Things copies and pastes (its `JSGenerationConfiguration`): the
/// same property names Atelier uses, but sampler and seed mode as their Int8 raw values and
/// lowercase names for the post-processing enums.
@MainActor
enum DrawThingsJSON {
  /// Registry values (keyed by setting id, as in presets) as Draw Things JSON.
  static func encode(_ values: [String: JSONValue], model: String?, seed: UInt32?) -> Data? {
    var json: [String: JSONValue] = [:]
    for (id, value) in values {
      switch (id, value) {
      case ("size", .object(let size)):
        json["width"] = size["width"]
        json["height"] = size["height"]
      case ("sampler", .string(let name)):
        json[id] = rawValue(of: SamplerType.self, named: name).map(JSONValue.number) ?? value
      case ("seedMode", .string(let name)):
        json[id] = rawValue(of: SeedMode.self, named: name).map(JSONValue.number) ?? value
      case ("colorCalibration", .string(let name)):
        json[id] = .string(name == "disabled" ? "none" : name.lowercased())
      case ("compressionArtifacts", .string(let name)):
        json[id] = .string(name.lowercased())
      default:
        json[id] = value
      }
    }
    if let model { json["model"] = .string(model) }
    if let seed { json["seed"] = .number(Double(seed)) }
    return try? LayoutStore.encoder.encode(json)
  }

  /// Settings read from pasted JSON: Draw Things' flat configuration, one of its custom_configs.json
  /// entries (`{name, configuration}`), or an Atelier preset file.
  struct Pasted {
    /// Keyed by property name with Atelier's enum names, like a history sidecar's dump.
    var dump: [String: JSONValue]
    var model: String?
    /// Nil when absent or negative (Draw Things' "random").
    var seed: UInt32?
  }

  static func decode(_ data: Data) -> Pasted? {
    if let preset = try? JSONDecoder().decode(Preset.self, from: data) {
      return Pasted(preset)
    }
    guard case .object(var json)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      return nil
    }
    if case .object(let configuration)? = json["configuration"] { json = configuration }
    var dump: [String: JSONValue] = [:]
    for (key, value) in json {
      switch (key, value) {
      case ("sampler", .number(let raw)):
        dump[key] = name(of: SamplerType.self, raw: raw).map(JSONValue.string)
      case ("seedMode", .number(let raw)):
        dump[key] = name(of: SeedMode.self, raw: raw).map(JSONValue.string)
      case ("colorCalibration", .string(let name)):
        dump[key] = caseName(of: ColorCalibration.self, matching: name == "none" ? "disabled" : name)
      case ("compressionArtifacts", .string(let name)):
        dump[key] = caseName(of: CompressionMethod.self, matching: name)
      default:
        dump[key] = value
      }
    }
    // Only settings Atelier knows, so a stray object with a "name" doesn't count as settings.
    let known = dump.filter {
      SettingsRegistry.byID[$0.key] != nil || $0.key == "width" || $0.key == "height"
    }
    guard !known.isEmpty else { return nil }
    var seed: UInt32?
    if let value = json["seed"]?.doubleValue, value >= 0, value <= Double(UInt32.max) {
      seed = UInt32(value)
    }
    var model: String?
    if case .string(let file)? = json["model"], !file.isEmpty { model = file }
    return Pasted(dump: known, model: model, seed: seed)
  }

  private static func rawValue<E: CaseIterable & RawRepresentable>(of _: E.Type, named name: String)
    -> Double? where E.RawValue == Int8
  {
    E.allCases.first { String(describing: $0) == name }.map { Double($0.rawValue) }
  }

  private static func name<E: CaseIterable & RawRepresentable>(of _: E.Type, raw: Double) -> String?
    where E.RawValue == Int8
  {
    E.allCases.first { Double($0.rawValue) == raw }.map { String(describing: $0) }
  }

  private static func caseName<E: CaseIterable>(of _: E.Type, matching name: String) -> JSONValue? {
    E.allCases.first { String(describing: $0).caseInsensitiveCompare(name) == .orderedSame }
      .map { .string(String(describing: $0)) }
  }
}

extension DrawThingsJSON.Pasted {
  /// A preset's values as a dump (its size split into width and height), with its model.
  init(_ preset: Preset) {
    var dump: [String: JSONValue] = [:]
    for (id, value) in preset.values {
      if id == "size", case .object(let size) = value {
        dump["width"] = size["width"]
        dump["height"] = size["height"]
      } else {
        dump[id] = value
      }
    }
    self.init(dump: dump, model: preset.model, seed: nil)
  }
}

// MARK: - Settings in image files

/// Generation settings carried in an image file. Draw Things writes a JSON object to the EXIF
/// UserComment (ImageIO also writes it to PNGs as XMP `exif:UserComment`): the prompt (`c`), the
/// negative prompt (`uc`), a few summary fields and the whole configuration (`v2`, the flat JSON
/// of Copy Settings), with a readable summary as the image description. Older builds put the same
/// JSON in the PNG Comment. Atelier's exports carry the same plus their sidecar in an `Atelier`
/// iTXt chunk.
enum ImageMetadata {
  /// What an image file embeds, read off the main actor; `settings(from:)` interprets it.
  struct Embedded: Sendable {
    /// EXIF UserComment and PNG Comment, in that order.
    var comments: [String]
    /// The `Atelier` iTXt chunk: a history sidecar.
    var atelier: String?
  }

  struct Settings {
    var prompt: String
    var negativePrompt: String
    var pasted: DrawThingsJSON.Pasted
  }

  static func embedded(at url: URL) -> Embedded? {
    (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(embedded(in:))
  }

  static func embedded(in data: Data) -> Embedded? {
    var comments: [String] = []
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    {
      let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
      let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
      comments = [exif?[kCGImagePropertyExifUserComment], png?[kCGImagePropertyPNGComment]]
        .compactMap { $0 as? String }
    }
    let atelier = PNGText.text(keyword: "Atelier", in: data)
    guard !comments.isEmpty || atelier != nil else { return nil }
    return Embedded(comments: comments, atelier: atelier)
  }

  /// The prompts, model, seed and settings an image carries: Atelier's sidecar when there is one
  /// (exact), else Draw Things' JSON.
  @MainActor static func settings(from embedded: Embedded) -> Settings? {
    if let atelier = embedded.atelier,
       let sidecar = try? sidecarDecoder.decode(HistoryStore.Sidecar.self, from: Data(atelier.utf8))
    {
      return Settings(
        prompt: sidecar.prompt, negativePrompt: sidecar.negativePrompt,
        pasted: DrawThingsJSON.Pasted(
          dump: sidecar.configuration, model: sidecar.model, seed: sidecar.seed))
    }
    for comment in embedded.comments {
      if let settings = drawThings(comment) { return settings }
    }
    return nil
  }

  @MainActor private static func drawThings(_ comment: String) -> Settings? {
    guard case .object(let json)? = try? JSONDecoder().decode(JSONValue.self, from: Data(comment.utf8))
    else { return nil }
    var flat = legacy(json)
    if case .object(let v2)? = json["v2"] { flat = v2 }
    guard let data = try? JSONEncoder().encode(JSONValue.object(flat)),
          let pasted = DrawThingsJSON.decode(data)
    else { return nil }
    func text(_ key: String) -> String {
      if case .string(let value)? = json[key] { return value }
      return ""
    }
    return Settings(prompt: text("c"), negativePrompt: text("uc"), pasted: pasted)
  }

  /// The summary fields of an image without `v2`, under its configuration's names.
  @MainActor private static func legacy(_ json: [String: JSONValue]) -> [String: JSONValue] {
    var flat: [String: JSONValue] = [:]
    for (key, name) in [
      ("steps", "steps"), ("scale", "guidanceScale"), ("seed", "seed"), ("model", "model"),
      ("strength", "strength"), ("shift", "shift"),
    ] {
      flat[name] = json[key]
    }
    if case .string(let size)? = json["size"] {
      let sides = size.split(separator: "x").compactMap { Double($0) }
      if sides.count == 2 {
        flat["width"] = .number(sides[0])
        flat["height"] = .number(sides[1])
      }
    }
    if case .string(let title)? = json["sampler"],
       let sampler = SettingsRegistry.samplerTitles.first(where: { $0.value == title })?.key
    {
      flat["sampler"] = .number(Double(sampler.rawValue))
    }
    if case .string(let title)? = json["seed_mode"],
       let mode = seedModeTitles.first(where: { $0.value == title })?.key
    {
      flat["seedMode"] = .number(Double(mode.rawValue))
    }
    return flat
  }

  /// ImageIO properties that embed a history item's settings as Draw Things does.
  @MainActor static func properties(for sidecar: HistoryStore.Sidecar) -> [CFString: Any] {
    let dump = sidecar.configuration
    var values: [String: JSONValue] = [:]
    for descriptor in SettingsRegistry.all {
      if let value = descriptor.read(dump) { values[descriptor.id] = value }
    }
    let prompt = sidecar.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let negativePrompt = sidecar.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let sampler =
      SamplerType.allCases.first { String(describing: $0) == sidecar.sampler }
        .flatMap { SettingsRegistry.samplerTitles[$0] } ?? sidecar.sampler
    var seedMode = ""
    if case .string(let name)? = dump["seedMode"],
       let mode = SeedMode.allCases.first(where: { String(describing: $0) == name })
    {
      seedMode = seedModeTitles[mode] ?? name
    }
    let strength = dump["strength"]?.doubleValue ?? 1
    let size = "\(sidecar.width)x\(sidecar.height)"

    var json: [String: Any] = [
      "c": prompt, "uc": negativePrompt, "steps": sidecar.steps, "sampler": sampler,
      "scale": Double(sidecar.guidanceScale), "seed": sidecar.seed, "size": size,
      "model": sidecar.model, "strength": strength, "seed_mode": seedMode,
    ]
    var description = prompt + "\n"
    if !negativePrompt.isEmpty { description += "-\(negativePrompt)\n" }
    description +=
      "Steps: \(sidecar.steps), Sampler: \(sampler), Guidance Scale: \(sidecar.guidanceScale), Seed: \(sidecar.seed), Size: \(size), Model: \(sidecar.model), Strength: \(strength), Seed Mode: \(seedMode)"
    if sidecar.shift != 1 {
      json["shift"] = Double(sidecar.shift)
      description += ", Shift: \(sidecar.shift)"
    }
    if let data = DrawThingsJSON.encode(values, model: sidecar.model, seed: sidecar.seed),
       let v2 = try? JSONSerialization.jsonObject(with: data)
    {
      json["v2"] = v2
    }
    var properties: [CFString: Any] = [
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFImageDescription: description, kCGImagePropertyTIFFSoftware: "Atelier",
      ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys) {
      properties[kCGImagePropertyExifDictionary] = [
        kCGImagePropertyExifUserComment: String(decoding: data, as: UTF8.self)
      ]
    }
    return properties
  }

  /// Draw Things' names for the seed modes, as in its image descriptions.
  private static let seedModeTitles: [SeedMode: String] = [
    .legacy: "Legacy", .torchCpuCompatible: "Torch CPU Compatible", .scaleAlike: "Scale Alike",
    .nvidiaGpuCompatible: "NVIDIA GPU Compatible",
  ]

  private static let sidecarDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
