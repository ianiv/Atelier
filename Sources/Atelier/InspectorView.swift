import AppKit
import SwiftUI
import _MediaGenerationKit

/// The settings inspector: model, search, the current layout's sections, the Changed group and a
/// reset. Built from a lazy stack rather than a grouped Form: Form re-laid out every row on each
/// window resize frame (about 65 ms) and jumped when rows were inserted.
struct InspectorView: View {
  @Environment(CreateModel.self) private var model
  @Environment(LayoutStore.self) private var layouts
  @Environment(\.undoManager) private var undoManager
  @State private var optionHeld = false
  @State private var flagsMonitor: Any?
  private var showAll: Bool { layouts.showAll || optionHeld }
  private var query: String { layouts.searchText.trimmingCharacters(in: .whitespaces) }

  var body: some View {
    @Bindable var layouts = layouts
    VStack(spacing: 0) {
      // The model sits above search: it decides every default below and which settings apply.
      ModelPicker()
        .padding(.horizontal, 10)
        .padding(.top, 10)
      HStack(spacing: 6) {
        SearchField(text: $layouts.searchText, prompt: "Search Settings")
        LayoutMenu(customizing: $layouts.customizing)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      Divider()
      if model.settings == nil {
        ContentUnavailableView {
          if model.phase == .loadingModel { ProgressView() } else { Text("No model") }
        } description: {
          Text(model.phase == .loadingModel ? "Loading model defaults…" : "Choose a model.")
        }
        .frame(maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            if query.isEmpty { sections } else { searchResults }
          }
          .padding(10)
        }
      }
    }
    .sheet(isPresented: $layouts.customizing) { CustomizeInspectorSheet() }
    .onAppear {
      flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
        optionHeld = event.modifierFlags.contains(.option)
        return event
      }
    }
    .onDisappear {
      if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
      flagsMonitor = nil
    }
  }

  @ViewBuilder private var sections: some View {
    let traits = model.traits
    ForEach(layouts.current.sections) { section in
      InspectorSection(section: section, traits: traits, showAll: showAll)
    }
    // Changed sits at the bottom, by the reset, so it growing or shrinking never moves the rows
    // being edited above it.
    let changed = model.changedSettings
    if !changed.isEmpty {
      InspectorGroup {
        HStack {
          Text("Changed")
          Spacer()
          Text("\(changed.count)").monospacedDigit()
        }
      } content: {
        ForEach(changed) { descriptor in
          SettingRow(descriptor: descriptor).opacity(descriptor.applies(traits) ? 1 : 0.5)
        }
      }
    }
    Button("Reset All to Model Defaults") {
      model.resetToModelDefaults(undoManager: undoManager)
    }
    .disabled(changed.isEmpty)
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private var searchResults: some View {
    let matches = SettingsRegistry.all.filter { $0.matches(query) }
    let traits = model.traits
    let matchesSeed = "seed".localizedCaseInsensitiveContains(query)
    if matches.isEmpty && !matchesSeed {
      Text("No settings match “\(query)”.").foregroundStyle(.secondary)
    }
    if matchesSeed {
      InspectorGroup { Text(SettingSection.essentials.title) } content: { SeedControls() }
    }
    ForEach(layouts.current.sections) { section in
      let inSection = matches.filter { $0.section == section }
      if !inSection.isEmpty {
        InspectorGroup { Text(section.title) } content: {
          ForEach(inSection) { descriptor in
            SettingRow(descriptor: descriptor)
              .opacity(descriptor.applies(traits) ? 1 : 0.5)
          }
        }
      }
    }
  }
}

/// A titled, rounded group of rows, in the style of a grouped form section.
struct InspectorGroup<Header: View, Content: View>: View {
  var isExpanded = true
  @ViewBuilder var header: Header
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      header
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
      if isExpanded {
        VStack(alignment: .leading, spacing: 0) {
          content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(
        Color.primary.opacity(0.05),
        in: ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true))
      }
    }
  }
}

/// One label/control line inside a group.
struct InspectorRow<Label: View, Control: View>: View {
  @ViewBuilder var label: Label
  @ViewBuilder var control: Control

  var body: some View {
    HStack(spacing: 8) {
      label
      Spacer(minLength: 8)
      control
    }
    .frame(minHeight: 28)
    .padding(.vertical, 2)
  }
}

/// One registry section: header (with an enable checkbox for feature sections), shown rows, and
/// tucked rows under "More".
struct InspectorSection: View {
  let section: SettingSection
  let traits: ModelTraits
  let showAll: Bool
  @State private var moreExpanded = false
  @Environment(CreateModel.self) private var model
  @Environment(LayoutStore.self) private var layouts
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    let (layoutShown, layoutTucked) = layouts.current.ordered(section)
    let toggleID = section.featureToggle
    let applicable = { (d: SettingDescriptor) in d.applies(traits) && d.id != toggleID }
    let shown = (showAll ? layoutShown + layoutTucked : layoutShown).filter(applicable)
    let tucked = showAll ? [] : layoutTucked.filter(applicable)
    let toggle = toggleID.flatMap { SettingsRegistry.byID[$0] }.flatMap {
      $0.applies(traits) ? $0 : nil
    }
    let toggleShown = toggle.map { showAll || layouts.current.isShown($0.id) } ?? false
    if section == .essentials || !shown.isEmpty || toggleShown {
      let expanded = layouts.isExpanded(section)
      InspectorGroup(isExpanded: expanded) {
        header(toggle: toggle, descriptors: shown + tucked, expanded: expanded)
      } content: {
        Group {
          ForEach(shown) { SettingRow(descriptor: $0) }
          if section == .essentials { SeedControls() }
          if !tucked.isEmpty {
            HStack(spacing: 4) {
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(moreExpanded ? 90 : 0))
              Text("More: \(tucked.count)")
              Spacer()
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 26)
            .contentShape(.rect)
            .onTapGesture { moreExpanded.toggle() }
            if moreExpanded {
              ForEach(tucked) { SettingRow(descriptor: $0) }
            }
          }
        }
      }
    }
  }

  private func header(toggle: SettingDescriptor?, descriptors: [SettingDescriptor], expanded: Bool)
    -> some View
  {
    let all = descriptors + (toggle.map { [$0] } ?? [])
    let changed = all.filter(model.isChanged)
    let enable = section.enableSetting.flatMap { SettingsRegistry.byID[$0] }
    return HStack(spacing: 6) {
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.bold))
        .rotationEffect(.degrees(expanded ? 90 : 0))
        .frame(width: 10)
      if let toggle {
        Toggle(section.title, isOn: SettingBindings(descriptor: toggle, model: model, undoManager: undoManager).bool)
          .toggleStyle(.checkbox)
          .labelsHidden()
          .help(toggle.help)
          .contextMenu { SettingContextMenu(descriptor: toggle) }
      } else if let enable {
        Toggle(section.title, isOn: fileEnabled(enable))
          .toggleStyle(.checkbox)
          .labelsHidden()
          .disabled(model.enableFile(for: enable) == nil)
          .help("Use the \(section.title.lowercased()). Remembers the model you last picked.")
      }
      Text(section.title)
      Spacer()
      if !changed.isEmpty {
        Button {
          for descriptor in changed { model.reset(descriptor, undoManager: undoManager) }
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .help("Reset \(section.title) to the model defaults")
      }
    }
    // The whole header (except the checkbox and reset button) expands and collapses the section.
    .contentShape(.rect)
    .onTapGesture { layouts.setExpanded(section, !expanded) }
  }

  /// On when a file is picked; turning it on restores the last file picked.
  private func fileEnabled(_ descriptor: SettingDescriptor) -> Binding<Bool> {
    Binding(
      get: { model.value(descriptor).map { $0 != .null } ?? false },
      set: { on in
        let file = on ? model.enableFile(for: descriptor).map(JSONValue.string) : nil
        model.set(descriptor, to: file ?? .null, undoManager: undoManager)
      })
  }
}

/// A disclosure label that toggles its disclosure when clicked, not only via the chevron.
struct ClickableLabel: View {
  let title: String
  @Binding var isExpanded: Bool

  init(_ title: String, isExpanded: Binding<Bool>) {
    self.title = title
    _isExpanded = isExpanded
  }

  var body: some View {
    Text(title)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
      .onTapGesture { withAnimation { isExpanded.toggle() } }
  }
}

/// Typed bindings onto one registry setting of the current settings.
@MainActor
struct SettingBindings {
  let descriptor: SettingDescriptor
  let model: CreateModel
  let undoManager: UndoManager?

  var json: Binding<JSONValue> {
    Binding(
      get: { model.value(descriptor) ?? .null },
      set: { model.set(descriptor, to: $0, undoManager: undoManager) })
  }

  var bool: Binding<Bool> {
    Binding(
      get: { if case .bool(let v) = model.value(descriptor) { return v } else { return false } },
      set: { model.set(descriptor, to: .bool($0), undoManager: undoManager) })
  }

  var double: Binding<Double> {
    Binding(
      get: { model.value(descriptor)?.doubleValue ?? 0 },
      set: { model.set(descriptor, to: .number($0), undoManager: undoManager) })
  }

  var int: Binding<Int> {
    Binding(
      get: { Int(model.value(descriptor)?.doubleValue ?? 0) },
      set: { model.set(descriptor, to: .number(Double($0)), undoManager: undoManager) })
  }

  var text: Binding<String> {
    Binding(
      get: { if case .string(let v) = model.value(descriptor) { return v } else { return "" } },
      set: { model.set(descriptor, to: $0.isEmpty ? .null : .string($0), undoManager: undoManager) })
  }
}

/// A label/control row for one setting, with a changed marker, tooltip and context menu.
struct SettingRow: View {
  let descriptor: SettingDescriptor
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    control
      .help(help)
      .contextMenu { SettingContextMenu(descriptor: descriptor) }
  }

  private var bindings: SettingBindings {
    SettingBindings(descriptor: descriptor, model: model, undoManager: undoManager)
  }

  private var help: String {
    var help = descriptor.help
    if !descriptor.applies(model.traits) {
      help += " Not used by \(model.selectedModelInfo?.name ?? "this model")."
    }
    return help
  }

  private var label: some View {
    HStack(spacing: 4) {
      Text(descriptor.title).lineLimit(1)
      if model.isChanged(descriptor) {
        Button {
          model.reset(descriptor, undoManager: undoManager)
        } label: {
          Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(
          "Changed from the model default (\(SettingFormat.display(model.defaultValue(descriptor), for: descriptor))). Click to reset."
        )
      }
    }
  }

  private func snapped(_ binding: Binding<Double>, to step: Double) -> Binding<Double> {
    Binding(
      get: { binding.wrappedValue },
      set: { binding.wrappedValue = ($0 / step).rounded() * step })
  }

  /// Files offered for a file setting, plus the current value if it isn't among them.
  private func fileOptions(_ source: (SettingContext) -> [SettingOption]) -> [SettingOption] {
    var options = source(model.settingContext)
    if case .string(let file)? = model.value(descriptor),
      !options.contains(where: { $0.value == .string(file) })
    {
      options.append(SettingOption(value: .string(file), title: file))
    }
    return options
  }

  @ViewBuilder private var control: some View {
    switch descriptor.control {
    case .toggle:
      InspectorRow {
        label
      } control: {
        Toggle(descriptor.title, isOn: bindings.bool)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.mini)
      }
    case .integer(let range, let step):
      InspectorRow {
        label
      } control: {
        HStack(spacing: 4) {
          TextField("", value: bindings.int, format: .number.grouping(.never))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
          Stepper("", value: bindings.int, in: range, step: step).labelsHidden()
        }
      }
    case .slider(let range, let step, let digits):
      InspectorRow {
        label
      } control: {
        HStack(spacing: 6) {
          // No `step:` here: macOS draws tick marks for stepped sliders. Values snap in the binding.
          Slider(value: snapped(bindings.double, to: step), in: range) { editing in
            if editing {
              model.beginCoalescedEdit(descriptor, undoManager: undoManager)
            } else {
              model.endCoalescedEdit()
            }
          }
          .controlSize(.small)
          .frame(minWidth: 80, maxWidth: 150)
          TextField(
            "", value: bindings.double, format: .number.precision(.fractionLength(0...digits))
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 52)
        }
      }
    case .choice(let options):
      InspectorRow {
        label
      } control: {
        Picker(descriptor.title, selection: bindings.json) {
          ForEach(options, id: \.self) { Text($0.title).tag($0.value) }
        }
        .labelsHidden()
        .fixedSize()
      }
    case .file(let source):
      let options = fileOptions(source)
      // Sections with an enable checkbox (refiner, upscaler) show "Off" instead of a None choice.
      let hasEnable = descriptor.section.enableSetting == descriptor.id
      InspectorRow {
        label
      } control: {
        Picker(descriptor.title, selection: bindings.json) {
          if !hasEnable || model.value(descriptor) == .null {
            Text(hasEnable ? "Off" : "None").tag(JSONValue.null)
          }
          ForEach(options, id: \.self) { Text($0.title).tag($0.value) }
        }
        .labelsHidden()
        .frame(maxWidth: 190)
      }
    case .text:
      VStack(alignment: .leading, spacing: 4) {
        label
        TextField(descriptor.title, text: bindings.text, prompt: Text("Same as prompt"), axis: .vertical)
          .labelsHidden()
          .lineLimit(1...4)
          .textFieldStyle(.roundedBorder)
      }
      .padding(.vertical, 4)
    case .size:
      InspectorRow {
        label
      } control: {
        SizeButton(descriptor: descriptor)
      }
    case .loras:
      LoRAEditor(descriptor: descriptor)
        .padding(.vertical, 4)
    }
  }
}

struct SettingContextMenu: View {
  let descriptor: SettingDescriptor
  @Environment(CreateModel.self) private var model
  @Environment(LayoutStore.self) private var layouts
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    Button("Reset to Default") { model.reset(descriptor, undoManager: undoManager) }
      .disabled(!model.isChanged(descriptor))
    Button("Copy Value") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(
        SettingFormat.display(model.value(descriptor), for: descriptor), forType: .string)
    }
    Divider()
    if layouts.current.isShown(descriptor.id) {
      Button("Hide from Inspector") { layouts.setShown(descriptor.id, false) }
    } else {
      Button("Show in Inspector") { layouts.setShown(descriptor.id, true) }
    }
  }
}

enum SettingFormat {
  static func display(_ value: JSONValue?, for descriptor: SettingDescriptor) -> String {
    guard let value else { return "" }
    switch (descriptor.control, value) {
    case (_, .null): return "None"
    case (.toggle, .bool(let on)): return on ? "On" : "Off"
    case (.choice(let options), _): return options.first { $0.value == value }?.title ?? "\(value)"
    case (.size, .object(let size)):
      return "\(Int(size["width"]?.doubleValue ?? 0)) × \(Int(size["height"]?.doubleValue ?? 0))"
    case (.loras, .array(let entries)):
      if entries.isEmpty { return "None" }
      return entries.compactMap { entry -> String? in
        guard case .object(let fields) = entry, case .string(let file)? = fields["file"] else {
          return nil
        }
        return "\(file) \(fields["weight"]?.doubleValue?.formatted() ?? "")"
      }.joined(separator: ", ")
    case (_, .number(let number)): return number.formatted(.number.grouping(.never))
    case (_, .string(let text)): return text
    case (_, .bool(let on)): return on ? "On" : "Off"
    default: return "\(value)"
    }
  }
}

// MARK: - Size

struct SizeButton: View {
  let descriptor: SettingDescriptor
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager
  @State private var showing = false

  var body: some View {
    let size = model.settings.map { ($0.width, $0.height) } ?? (0, 0)
    Button {
      showing.toggle()
    } label: {
      HStack(spacing: 4) {
        Text(verbatim: "\(size.0) × \(size.1)").monospacedDigit()
        Image(systemName: "chevron.down").font(.caption2)
      }
    }
    .popover(isPresented: $showing, arrowEdge: .leading) {
      SizePopover(width: size.0, height: size.1) { width, height in
        model.set(
          descriptor,
          to: .object(["width": .number(Double(width)), "height": .number(Double(height))]),
          undoManager: undoManager)
      }
    }
  }
}

struct SizePopover: View {
  let width: Int
  let height: Int
  let set: (Int, Int) -> Void

  var body: some View {
    let match = SizePreset.match(width: width, height: height)
    let megapixels = match?.1 ?? closestMegapixels
    VStack(alignment: .leading, spacing: 12) {
      Text("Aspect Ratio").font(.headline)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 4), spacing: 8) {
        ForEach(SizePreset.aspectRatios) { aspect in
          let selected = match?.0 == aspect
          Button {
            let size = SizePreset.size(aspect: aspect, megapixels: megapixels)
            set(size.width, size.height)
          } label: {
            VStack(spacing: 4) {
              let scale = 28 / Double(max(aspect.width, aspect.height))
              RoundedRectangle(cornerRadius: 2)
                .strokeBorder(selected ? Color.accentColor : .secondary, lineWidth: selected ? 2 : 1)
                .frame(width: Double(aspect.width) * scale, height: Double(aspect.height) * scale)
                .frame(height: 30)
              Text(aspect.label).font(.caption).monospacedDigit()
            }
            .frame(width: 64, height: 52)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
        }
      }
      Picker("Megapixels", selection: Binding(
        get: { match?.1 },
        set: { mp in
          guard let mp else { return }
          let size = SizePreset.size(aspect: match?.0 ?? closestAspect, megapixels: mp)
          set(size.width, size.height)
        })
      ) {
        if match == nil { Text("Custom").tag(Double?.none) }
        ForEach(SizePreset.megapixels, id: \.self) { Text($0.formatted()).tag(Optional($0)) }
      }
      .pickerStyle(.segmented)
      HStack {
        dimension("W", value: width) { set($0, height) }
        Button {
          set(height, width)
        } label: {
          Image(systemName: "arrow.left.arrow.right")
        }
        .buttonStyle(.borderless)
        .help("Swap width and height")
        dimension("H", value: height) { set(width, $0) }
      }
      Text("\((Double(width * height) / 1_048_576).formatted(.number.precision(.fractionLength(2)))) megapixels; sizes snap to 64 px.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 320)
  }

  private func dimension(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
    let binding = Binding(get: { value }, set: { set(SizePreset.snap(min(max($0, 64), 4096))) })
    return HStack(spacing: 4) {
      Text(title).foregroundStyle(.secondary)
      TextField(title, value: binding, format: .number.grouping(.never))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 60)
      Stepper(title, value: binding, in: 64...4096, step: 64).labelsHidden()
    }
  }

  private var closestMegapixels: Double {
    let mp = Double(width * height) / 1_048_576
    return SizePreset.megapixels.min { abs($0 - mp) < abs($1 - mp) } ?? 1
  }

  private var closestAspect: SizePreset.AspectRatio {
    let ratio = Double(width) / Double(max(height, 1))
    return SizePreset.aspectRatios.min {
      abs(Double($0.width) / Double($0.height) - ratio)
        < abs(Double($1.width) / Double($1.height) - ratio)
    } ?? SizePreset.aspectRatios[0]
  }
}

// MARK: - LoRAs

struct LoRAEditor: View {
  let descriptor: SettingDescriptor
  @Environment(CreateModel.self) private var model
  @Environment(ModelLibrary.self) private var library
  @Environment(\.undoManager) private var undoManager
  @State private var picking = false

  private struct Item: Hashable {
    var file: String
    var weight: Double
    var mode: JSONValue
  }

  private var items: [Item] {
    guard case .array(let entries)? = model.value(descriptor) else { return [] }
    return entries.compactMap { entry in
      guard case .object(let fields) = entry, case .string(let file)? = fields["file"] else {
        return nil
      }
      return Item(
        file: file, weight: fields["weight"]?.doubleValue ?? 1,
        mode: fields["mode"] ?? .string("all"))
    }
  }

  /// LoRA families the engine applies with the selected model (and refiner); it skips others.
  private var compatibleFamilies: Set<String> {
    let refiner = model.settings?.refinerModel.flatMap { file in
      model.models.first { $0.file == file }?.version
    }
    return ModelLibrary.loraFamilies(forModel: model.selectedModelInfo?.version, refiner: refiner)
  }

  private func write(_ items: [Item], undo: Bool = true) {
    let value = JSONValue.array(items.map {
      .object(["file": .string($0.file), "weight": .number($0.weight), "mode": $0.mode])
    })
    model.set(descriptor, to: value, undoManager: undo ? undoManager : nil)
  }

  var body: some View {
    let items = items
    let compatible = compatibleFamilies
    VStack(alignment: .leading, spacing: 6) {
      if items.isEmpty {
        Text("No LoRAs").foregroundStyle(.secondary)
      }
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(name(item.file)).lineLimit(1).truncationMode(.middle)
              .help(item.file)
            if let lora = library.loras.first(where: { $0.file == item.file }),
              !compatible.contains(lora.family)
            {
              Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                .help("Made for \(lora.family), so it's skipped with this model.")
            }
            Spacer()
            Button {
              var items = items
              items.remove(at: index)
              write(items)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this LoRA")
          }
          HStack(spacing: 6) {
            Slider(
              value: Binding(
                get: { item.weight },
                set: { weight in
                  var items = items
                  items[index].weight = (weight * 100).rounded() / 100
                  write(items)
                }), in: -1.5...2.5
            ) { editing in
              if editing {
                model.beginCoalescedEdit(descriptor, undoManager: undoManager)
              } else {
                model.endCoalescedEdit()
              }
            }
            TextField(
              "", value: Binding(
                get: { item.weight },
                set: { weight in
                  var items = items
                  items[index].weight = weight
                  write(items)
                }), format: .number.precision(.fractionLength(0...2))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
          }
        }
      }
      Button("Add LoRA…", systemImage: "plus") { picking = true }
        .buttonStyle(.borderless)
        .popover(isPresented: $picking, arrowEdge: .leading) {
          LoRAPicker(
            catalog: library.loras.filter(\.isDownloaded), compatible: compatible,
            modelFamily: model.selectedModelInfo?.version
          ) { lora in
            write(items + [Item(file: lora.file, weight: 1, mode: .string("all"))])
            picking = false
          }
        }
    }
    .onAppear { library.reloadLoRAs() }
  }

  private func name(_ file: String) -> String {
    library.loras.first { $0.file == file }?.name ?? file
  }
}

/// Searchable list of downloaded LoRAs made for the selected model's family.
struct LoRAPicker: View {
  let catalog: [ModelLibrary.LoRA]
  let compatible: Set<String>
  let modelFamily: String?
  let pick: (ModelLibrary.LoRA) -> Void
  @State private var query = ""
  @AppStorage("loraPickerShowAll") private var showAll = false

  var body: some View {
    let matching = query.isEmpty
      ? catalog
      : catalog.filter {
        $0.name.localizedCaseInsensitiveContains(query)
          || $0.file.localizedCaseInsensitiveContains(query)
          || $0.prefix.localizedCaseInsensitiveContains(query)
      }
    let fitting = matching.filter { compatible.contains($0.family) }
    let others = matching.filter { !compatible.contains($0.family) }
    VStack(spacing: 0) {
      SearchField(text: $query, prompt: "Search LoRAs").padding(8)
      Divider()
      if catalog.isEmpty {
        Text("No LoRAs yet. Import them in the LoRAs section.")
          .foregroundStyle(.secondary).padding()
      } else if fitting.isEmpty && !showAll {
        Text("No LoRAs for \(modelFamily ?? "this model")\(query.isEmpty ? "" : " match").")
          .foregroundStyle(.secondary).padding()
      }
      List {
        ForEach(fitting) { lora in row(lora, enabled: true) }
        if showAll && !others.isEmpty {
          Section("For other models (skipped with this one)") {
            ForEach(others) { lora in row(lora, enabled: false) }
          }
        }
      }
      .listStyle(.plain)
      Divider()
      HStack {
        Toggle("Show LoRAs for other models", isOn: $showAll)
          .controlSize(.small)
        Spacer()
        if !showAll && !others.isEmpty {
          Text("\(others.count) hidden").font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(8)
    }
    .frame(width: 360, height: 400)
  }

  private func row(_ lora: ModelLibrary.LoRA, enabled: Bool) -> some View {
    Button {
      pick(lora)
    } label: {
      VStack(alignment: .leading) {
        Text(lora.name)
        Text(enabled ? lora.prefix.isEmpty ? lora.file : "Trigger: \(lora.prefix)" : lora.family)
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}

// MARK: - Layout menu and customization

struct LayoutMenu: View {
  @Binding var customizing: Bool
  @Environment(LayoutStore.self) private var layouts

  var body: some View {
    @Bindable var layouts = layouts
    Menu {
      Picker(
        "Layout",
        selection: Binding(
          get: { layouts.current.name },
          set: { name in
            if let layout = layouts.all.first(where: { $0.name == name }) { layouts.select(layout) }
          })
      ) {
        ForEach(InspectorLayout.builtIns) { Text($0.name).tag($0.name) }
        if !layouts.custom.isEmpty {
          Divider()
          ForEach(layouts.custom) { Text($0.name).tag($0.name) }
        }
      }
      .pickerStyle(.inline)
      Divider()
      Toggle("Show All Settings", isOn: $layouts.showAll)
      Button("Customize Inspector…") { customizing = true }
      Divider()
      Button("Export Layout…") {
        if let url = FilePanels.saveJSON(named: layouts.current.name) {
          try? layouts.export(layouts.current, to: url)
        }
      }
      Button("Import Layout…") {
        if let url = FilePanels.openJSON() { try? layouts.importLayout(from: url) }
      }
      Button("Delete “\(layouts.current.name)”") { layouts.delete(layouts.current) }
        .disabled(layouts.isBuiltIn(layouts.current))
      Button("Show Layouts Folder") {
        try? FileManager.default.createDirectory(
          at: LayoutStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(LayoutStore.directory)
      }
    } label: {
      Text(layouts.current.name)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Inspector layout. Hold ⌥ to show every setting.")
  }
}

struct CustomizeInspectorSheet: View {
  @Environment(LayoutStore.self) private var layouts
  @Environment(\.dismiss) private var dismiss

  private struct Item: Identifiable, Hashable {
    var id: String
    var title: String
    var shown: Bool
  }

  @State private var name = ""
  @State private var items: [SettingSection: [Item]] = [:]
  @State private var expanded: Set<String> = []
  @State private var sectionOrder: [SettingSection] = []
  @State private var selected: SettingSection? = .essentials

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Customize Inspector").font(.headline)
        Spacer()
        TextField("Layout name", text: $name).frame(width: 200)
      }
      .padding()
      Divider()
      // Sections on the left (drag to reorder), the selected section's settings on the right.
      HStack(spacing: 0) {
        List(selection: $selected) {
          ForEach(sectionOrder) { section in
            HStack {
              Text(section.title)
              Spacer()
              Text("\((items[section] ?? []).filter(\.shown).count)")
                .foregroundStyle(.secondary).monospacedDigit()
                .help("Settings shown")
            }
            .tag(section)
          }
          .onMove { sectionOrder.move(fromOffsets: $0, toOffset: $1) }
        }
        .frame(width: 200)
        Divider()
        if let section = selected {
          VStack(alignment: .leading, spacing: 0) {
            Toggle("Starts expanded", isOn: Binding(
              get: { expanded.contains(section.id) },
              set: { if $0 { expanded.insert(section.id) } else { expanded.remove(section.id) } }))
            .toggleStyle(.checkbox)
            .padding(10)
            List {
              ForEach(binding(section)) { $item in
                Toggle(item.title, isOn: $item.shown)
              }
              .onMove { from, to in items[section, default: []].move(fromOffsets: from, toOffset: to) }
            }
          }
        } else {
          Text("Select a section").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      Divider()
      HStack {
        Text("Drag sections and settings to reorder. Unchecked settings are tucked under More.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding()
    }
    .frame(width: 620, height: 560)
    .onAppear(perform: load)
  }

  private func binding(_ section: SettingSection) -> Binding<[Item]> {
    Binding(get: { items[section] ?? [] }, set: { items[section] = $0 })
  }

  private func load() {
    let layout = layouts.current
    name = layouts.isBuiltIn(layout) ? layouts.uniqueName("\(layout.name) Custom") : layout.name
    expanded = Set(layout.expanded)
    sectionOrder = layout.sections
    for section in SettingSection.allCases {
      let (shown, tucked) = layout.ordered(section)
      items[section] =
        shown.map { Item(id: $0.id, title: $0.title, shown: true) }
        + tucked.map { Item(id: $0.id, title: $0.title, shown: false) }
    }
  }

  private func save() {
    let shown = sectionOrder.flatMap { section in
      (items[section] ?? []).filter(\.shown).map(\.id)
    }
    var layout = InspectorLayout(
      name: name.trimmingCharacters(in: .whitespaces), shown: shown,
      expanded: sectionOrder.map(\.id).filter(expanded.contains),
      sectionOrder: sectionOrder.map(\.id))
    if layouts.isBuiltIn(layout) { layout.name = layouts.uniqueName("\(layout.name) Custom") }
    layouts.update(layout)
    layouts.select(layout)
    dismiss()
  }
}

// MARK: - Presets

struct PresetMenu: View {
  @Environment(CreateModel.self) private var model
  @Environment(PresetStore.self) private var presets
  @Environment(\.undoManager) private var undoManager
  @State private var saving = false

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
      Button("Import Preset…") {
        if let url = FilePanels.openJSON() { try? presets.importPreset(from: url) }
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
