import SwiftUI

/// The knob panel: name, the sections of knobs, notes; and always in view under them the live
/// description, the style, and Render. Every control stays in place, disabled when it can't be
/// used.
struct CharacterPanel: View {
  let character: SavedCharacter
  @Environment(CharacterStore.self) private var store
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @Environment(\.undoManager) private var undoManager
  /// Sections you collapsed, remembered across launches (one id per line).
  @AppStorage("characterSectionsCollapsed") private var collapsedStorage = ""
  @State private var pickingStyle = false
  @State private var pickingStyles = false
  @FocusState private var focusedTag: String?

  private var knobs: CharacterKnobSet { store.knobs }
  /// Edit as Text stops the description following the knobs, so they're disabled.
  private var followsKnobs: Bool { character.editedDescription == nil }
  private var style: Style? { create.styles?.style(id: character.styleID) }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          header
          ForEach(knobs.sections) { section in sectionView(section) }
          notes
        }
        .padding(12)
      }
      Divider()
      footer.padding(12)
    }
  }

  // MARK: - Editing

  private func edit(_ change: (inout SavedCharacter) -> Void) {
    store.edit(character.id, change)
  }

  /// A change Undo can take back as one step.
  private func editWithUndo(_ name: String, _ change: (inout SavedCharacter) -> Void) {
    let before = character
    undoManager?.registerUndo(withTarget: store) { store in store.replace(before) }
    undoManager?.setActionName(name)
    edit(change)
  }

  private func setting(_ knob: CharacterKnobSet.Knob) -> Binding<KnobSetting> {
    Binding(
      get: { character.setting(knob.id) },
      set: { value in edit { $0.knobs[knob.id] = value } })
  }

  // MARK: - Knobs

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Name", text: Binding(get: { character.name }, set: { value in edit { $0.name = value } }))
        .font(.title3)
        // A field in this font is 4 points shorter while it has focus; the form mustn't move.
        .frame(height: 28)
        .help("Only for you: the name is never sent to the model")
      Button("Randomize All", systemImage: "dice") {
        editWithUndo("Randomize All") { knobs.randomizeAll(in: &$0) }
      }
      .disabled(!followsKnobs)
      .help("Change every knob that isn't locked or Custom. Kind and Pronoun stay.")
    }
  }

  private var collapsed: Set<String> {
    Set(collapsedStorage.split(separator: "\n").map(String.init))
  }

  private func sectionView(_ section: CharacterKnobSet.Section) -> some View {
    let open = !collapsed.contains(section.id)
    return VStack(alignment: .leading, spacing: 8) {
      sectionHeader(section, open: open)
      if open {
        ForEach(section.knobs) { knob in
          KnobRow(knob: knob, setting: setting(knob), phrase: phrase(knob, in: section))
        }
        TextField(
          "Free text", text: Binding(
            get: { character.texts[section.id] ?? "" },
            set: { value in edit { $0.texts[section.id] = value } }),
          prompt: Text(section.textPrompt), axis: .vertical
        )
        // Two lines always: a box that grew as it wrapped would move every section below it.
        .lineLimit(2, reservesSpace: true)
        .frame(height: 46)
        .help("Goes at the end of this section's sentence")
      }
    }
    .disabled(!followsKnobs)
    .padding(10)
    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
  }

  private func sectionHeader(_ section: CharacterKnobSet.Section, open: Bool) -> some View {
    HStack(spacing: 8) {
      Button {
        var set = collapsed
        if set.contains(section.id) { set.remove(section.id) } else { set.insert(section.id) }
        collapsedStorage = set.sorted().joined(separator: "\n")
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .rotationEffect(.degrees(open ? 90 : 0))
          Text(section.title).font(.headline)
          Spacer(minLength: 0)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      // The panel's disabled while Edit as Text is on; sections can still fold.
      .environment(\.isEnabled, true)
      if let noun = section.noun {
        Picker(
          "Noun", selection: Binding(
            get: { noun.option(character.nouns[section.id])?.label ?? noun.default },
            set: { value in edit { $0.nouns[section.id] = value } })
        ) {
          ForEach(noun.options, id: \.label) { Text($0.label).tag($0.label) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .compactPickerSize()
        .help("The word this section's description is built around")
      }
      Button("Randomize \(section.title)", systemImage: "dice") {
        editWithUndo("Randomize \(section.title)") { knobs.randomize(section, in: &$0) }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .disabled(!section.knobs.contains(where: \.randomizes))
      .help("Change this section's knobs that aren't locked or Custom")
    }
    .frame(height: 24)
  }

  /// What the knob writes now, shown beside it.
  private func phrase(_ knob: CharacterKnobSet.Knob, in section: CharacterKnobSet.Section) -> String {
    let current = character.setting(knob.id)
    let custom = knob.customPhrase(current.custom)
    if !custom.isEmpty { return custom }
    guard let option = knob.option(current.value) else { return "Unset" }
    return knob.phrase(option, noun: section.noun?.option(character.nouns[section.id])?.label ?? "")
  }

  private var notes: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Notes").font(.callout).foregroundStyle(.secondary)
      TextField(
        "Notes", text: Binding(get: { character.notes }, set: { value in edit { $0.notes = value } }),
        prompt: Text("Only for you: not sent to the model"), axis: .vertical
      )
      .lineLimit(3, reservesSpace: true)
      .frame(height: 62)
    }
  }

  // MARK: - Description, style and Render

  private var footer: some View {
    let blocker = store.renderBlocker(create, for: character)
    let running = store.renderRun != nil
    return VStack(alignment: .leading, spacing: 8) {
      description
      HStack(spacing: 6) {
        Button {
          pickingStyle = true
        } label: {
          Label(style?.name ?? "No Style", systemImage: "paintpalette")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .compactPickerSize()
        .help(style.map { "Render in \($0.name): the description fills its subject." } ?? "No Style renders a neutral reference: full body, facing the viewer, plain backdrop, deep focus.")
        .debugPresents("characterStylePicker", $pickingStyle)
        .popover(isPresented: $pickingStyle) {
          StylePicker(selection: character.styleID, noStyleDetail: "A neutral reference: full body, plain backdrop, deep focus") { picked in
            edit { $0.styleID = picked }
            pickingStyle = false
          }
        }
      }
      tagBoxes
      createSettings
      HStack(spacing: 8) {
        Text(status)
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(status)
        // All always there so the row doesn't shift; each disabled when it can't act.
        Button("Stop", systemImage: "stop.fill") { store.stopRendering() }
          .labelStyle(.iconOnly)
          .disabled(!running)
          .help("Stop rendering; the previews made are kept")
        Button("Render in Styles…") { pickingStyles = true }
          .disabled(blocker != nil || running)
          .help(blocker ?? "Render this character in several styles with one seed")
        Button("Render") { store.render(character, in: [style], create: create) }
          .buttonStyle(.borderedProminent)
          // As Generate has on Create; it works from a knob's text box too.
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(blocker != nil || running)
          .help(blocker ?? "Render a preview with the model, settings and seed on Create. It isn't saved to the project.")
      }
      .frame(height: 26)
    }
    .sheet(isPresented: $pickingStyles) {
      RenderInStylesSheet(settings: settingsText) { chosen in
        pickingStyles = false
        store.render(character, in: chosen, create: create)
      }
    }
  }

  /// Says what renders use, in place of asking you to remember: it isn't this screen's to change.
  private var createSettings: some View {
    HStack(spacing: 8) {
      Label(settingsText, systemImage: "paintbrush")
        .font(.callout)
        .foregroundStyle(settingsUsable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        .lineLimit(2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(settingsText)
      Button("Go to Create") { navigation.section = .create }
        .help("Change the model, settings or seed that renders use")
    }
  }

  private var settingsUsable: Bool {
    create.selectedModel != nil && create.settings != nil && !create.isLoadingModel && create.videoModel == nil
  }

  /// The model and main settings on Create, which every render uses.
  private var settingsText: String {
    guard let settings = create.settings, let name = create.selectedModelInfo?.name, !create.isLoadingModel else {
      return "Uses Create's settings: pick a model there first."
    }
    if create.videoModel != nil { return "Uses Create's settings: \(name) makes video. Pick an image model there." }
    return "Uses Create's settings: \(name), \(settings.width)×\(settings.height), \(settings.steps) steps, seed \(create.seed)"
  }

  private var description: some View {
    let text = store.description(of: character)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Description").font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button("Edit as Text", systemImage: "text.cursor") {
          editWithUndo("Edit as Text") { $0.editedDescription = text }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .font(.callout)
        .disabled(!followsKnobs || text.isEmpty)
        .help("Turn the description into text to edit. It stops following the knobs; Undo brings them back.")
      }
      Group {
        if let edited = character.editedDescription {
          TextEditor(text: Binding(get: { edited }, set: { value in edit { $0.editedDescription = value } }))
            .font(.body)
            .scrollContentBackground(.hidden)
        } else {
          ScrollView {
            Text(text.isEmpty ? "Set a knob and its words appear here." : text)
              .foregroundStyle(text.isEmpty ? .secondary : .primary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(height: 92)
      .promptBox(focused: false)
    }
  }

  /// A box for each tag of the style other than its subject; empty ones take the style's default
  /// or drop out. Their height is kept with no tags, so nothing below moves.
  private var tagBoxes: some View {
    let tags = (style?.tags ?? []).filter { $0 != Style.subject }
    return Group {
      if tags.isEmpty {
        Text("This style has no other tags to fill.")
          .font(.callout)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        StyleTagFields(
          tags: tags, lines: 2, focus: $focusedTag,
          text: { tag in
            Binding(get: { character.tagValues[tag] ?? "" }, set: { value in edit { $0.tagValues[tag] = value } })
          },
          prompt: { tag in style?.defaults[tag] ?? "Optional: left out when empty" })
      }
    }
    // The same with or without tags: a footer that changed height would resize the knobs above it.
    .frame(height: 36)
    .promptBox(focused: focusedTag != nil)
    .help("Used for this tag when a style has it. Framing, pose and setting belong here, not on the character.")
  }

  private var status: String {
    if let run = store.renderRun { return "\(run.done + 1) of \(run.total): \(run.current)" }
    return ""
  }
}

/// One knob: its name, what it writes and its lock, over the control and its Custom box. A phrase
/// in the Custom box replaces the knob's, which stays in place, disabled.
private struct KnobRow: View {
  let knob: CharacterKnobSet.Knob
  @Binding var setting: KnobSetting
  let phrase: String

  private var isCustom: Bool { !setting.custom.trimmed.isEmpty }
  private static let customWidth: CGFloat = 120

  // Fixed row heights: a text field's own height changes with focus, and any change here moves
  // every knob below it.
  private static let titleHeight: CGFloat = 18
  private static let controlHeight: CGFloat = 26

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(knob.title).font(.callout)
        if knob.control != .text {
          Spacer(minLength: 8)
          Text(phrase)
            .font(.callout)
            .foregroundStyle(setting.value == nil && !isCustom ? .tertiary : .secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .help(phrase)
          Button(setting.locked ? "Unlock" : "Lock", systemImage: setting.locked ? "lock.fill" : "lock.open") {
            setting.locked.toggle()
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(setting.locked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .disabled(!knob.randomizes)
          .help(knob.randomizes ? (setting.locked ? "Locked: Randomize leaves this knob alone" : "Lock this knob against Randomize") : "Randomize never changes this knob")
        }
      }
      .frame(height: Self.titleHeight)
      HStack(spacing: 8) {
        if knob.control == .text {
          TextField(knob.title, text: Binding(get: { setting.value ?? "" }, set: { setting.value = $0 }), prompt: Text(knob.placeholder ?? ""))
            .labelsHidden()
        } else {
          control.disabled(isCustom)
          TextField("Custom", text: $setting.custom, prompt: Text(knob.customPrompt ?? "Custom"))
            .frame(width: Self.customWidth)
            .help(knob.numericFormat == nil ? "Your own phrase, in place of this knob's" : "A number (35 writes “35-year-old”) or your own phrase, in place of this knob's")
        }
      }
      .frame(height: Self.controlHeight)
    }
  }

  @ViewBuilder
  private var control: some View {
    switch knob.control {
    case .slider:
      // The far left is unset: a knob writes nothing until you move it.
      Slider(
        value: Binding(
          get: { Double((knob.options.firstIndex { $0.label == setting.value } ?? -1) + 1) },
          set: { value in
            let index = Int(value.rounded())
            setting.value = index == 0 ? nil : knob.options[index - 1].label
          }),
        in: 0...Double(max(knob.options.count, 1)), step: 1)
    case .picker:
      Picker(
        knob.title, selection: Binding(get: { knob.option(setting.value)?.label }, set: { setting.value = $0 })
      ) {
        Text("Unset").tag(String?.none)
        Divider()
        ForEach(knob.options, id: \.label) { Text($0.label).tag(Optional($0.label)) }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
    case .text:
      EmptyView()
    }
  }
}

/// Render in Styles…: tick several styles, No Style among them, and render the character in each
/// with one seed.
private struct RenderInStylesSheet: View {
  /// What on Create the renders use.
  let settings: String
  let render: ([Style?]) -> Void
  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var chosen: Set<UUID> = []
  @State private var includeNoStyle = false

  private var styles: [Style] { create.styles?.styles ?? [] }

  private var matching: [Style] {
    query.isEmpty
      ? styles
      : styles.filter {
        $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
          || $0.subcategory.localizedCaseInsensitiveContains(query)
      }
  }

  private var count: Int { chosen.count + (includeNoStyle ? 1 : 0) }

  var body: some View {
    VStack(spacing: 0) {
      Text("Render in Styles").font(.headline).padding(.top)
      Text(settings)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(2, reservesSpace: true)
        .padding(.horizontal)
      SearchField(text: $query, prompt: "Search styles").padding(8)
      Divider()
      List {
        if query.isEmpty {
          Toggle("No Style", isOn: $includeNoStyle)
            .checkboxToggleStyle()
        }
        ForEach(create.styles?.categories ?? [], id: \.self) { category in
          let inCategory = matching.filter { $0.category == category }
          if !inCategory.isEmpty {
            Section(category.isEmpty ? "Uncategorized" : category) {
              ForEach(inCategory) { style in
                Toggle(
                  style.name,
                  isOn: Binding(
                    get: { chosen.contains(style.id) },
                    set: { on in
                      if on { chosen.insert(style.id) } else { chosen.remove(style.id) }
                    })
                )
                .checkboxToggleStyle()
              }
            }
          }
        }
      }
      .listStyle(.plain)
      Divider()
      HStack {
        Text(count == 1 ? "1 style" : "\(count) styles").foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Render") {
          // In the library's order, No Style first.
          let picked: [Style?] = styles.filter { chosen.contains($0.id) }
          render((includeNoStyle ? [nil] : []) + picked)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(count == 0)
      }
      .padding()
    }
    .sheetFrame(width: 420, height: 560)
  }
}
