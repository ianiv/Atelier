import _MediaGenerationKit
import SwiftUI

/// The settings inspector: model, search, the current layout's sections, the Changed group and a
/// reset. Built from a lazy stack rather than a grouped Form: Form re-laid out every row on each
/// window resize frame (about 65 ms) and jumped when rows were inserted.
struct InspectorView: View {
  @Environment(CreateModel.self) private var model
  @Environment(LayoutStore.self) private var layouts
  @Environment(\.undoManager) private var undoManager
  @State private var optionHeld = false
  @AppStorage("changedExpanded") private var changedExpanded = true
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
          if model.isLoadingModel { ProgressView() } else { Text("No model") }
        } description: {
          Text(model.isLoadingModel ? "Loading model defaults…" : "Choose a model.")
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
    .debugPresents("customizeInspector", $layouts.customizing)
    .onOptionKeyChanged { optionHeld = $0 }
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
      InspectorGroup(isExpanded: changedExpanded) {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .rotationEffect(.degrees(changedExpanded ? 90 : 0))
            .frame(width: 10)
          Text("Changed")
          Spacer()
          Text("\(changed.count)").monospacedDigit()
        }
        .contentShape(.rect)
        .onTapGesture { changedExpanded.toggle() }
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
    if matches.isEmpty, !matchesSeed {
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
          .checkboxToggleStyle()
          .labelsHidden()
          .help(toggle.help)
          .contextMenu { SettingContextMenu(descriptor: toggle) }
      } else if let enable {
        Toggle(section.title, isOn: fileEnabled(enable))
          .checkboxToggleStyle()
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
    case .frames:
      InspectorRow {
        label
      } control: {
        FramesControl(frames: bindings.int, video: model.videoModel)
      }
    }
  }
}

/// A video's length: the frame count, snapped to the counts the model takes, and how many
/// seconds that plays for. The stepper moves between those counts.
struct FramesControl: View {
  @Binding var frames: Int
  let video: VideoModel?

  var body: some View {
    let snapped = video?.snapped(frames) ?? frames
    HStack(spacing: 4) {
      if let video {
        Text(video.seconds(snapped).formatted(.number.precision(.fractionLength(1))) + " s")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      TextField(
        "", value: Binding(get: { snapped }, set: { frames = video?.snapped($0) ?? $0 }),
        format: .number.grouping(.never)
      )
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .frame(width: 52)
      Text("frames").foregroundStyle(.secondary)
      Stepper(
        "",
        onIncrement: { frames = video?.stepped(snapped, by: 1) ?? snapped + 1 },
        onDecrement: { frames = video?.stepped(snapped, by: -1) ?? max(snapped - 1, 1) }
      )
      .labelsHidden()
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
      Clipboard.copy(SettingFormat.display(model.value(descriptor), for: descriptor))
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
