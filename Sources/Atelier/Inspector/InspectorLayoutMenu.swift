import AppKit
import SwiftUI
import _MediaGenerationKit

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
