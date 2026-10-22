import AppKit
import SwiftUI
import _MediaGenerationKit

struct PresetMenu: View {
  @Environment(CreateModel.self) private var model
  @Environment(PresetStore.self) private var presets
  @Environment(\.undoManager) private var undoManager
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
        if let json = model.settingsJSON() {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(String(decoding: json, as: UTF8.self), forType: .string)
        }
      }
      .disabled(model.settings == nil)
      .help("Copies every setting, the model and the seed in Draw Things' configuration format.")
      Button("Paste Settings") {
        guard let text = NSPasteboard.general.string(forType: .string),
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
        if let url = FilePanels.openJSON() { _ = try? presets.importPreset(from: url) }
      }
      if !presets.presets.isEmpty {
        Menu("Export") {
          ForEach(presets.presets) { preset in
            Button(preset.name) {
              if let url = FilePanels.saveJSON(named: preset.name) {
                try? presets.export(preset, to: url)
              }
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
        NSWorkspace.shared.open(PresetStore.directory)
      }
    } label: {
      Label("Presets", systemImage: "square.stack.3d.up")
    }
    .help("Presets: saved setting values applied on top of the model's defaults")
    .sheet(isPresented: $saving) { SavePresetSheet() }
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
    .frame(width: 420, height: 500)
    .onAppear { included = Set(candidates.map(\.id)) }
    .onChange(of: allSettings) { included = Set(candidates.map(\.id)) }
  }
}

// MARK: - Search field

struct SearchField: NSViewRepresentable {
  @Binding var text: String
  var prompt: String

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = prompt
    field.delegate = context.coordinator
    field.controlSize = .regular
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    if field.stringValue != text { field.stringValue = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text.wrappedValue = field.stringValue
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
  where E.RawValue == Int8 {
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
