import SwiftUI
import UniformTypeIdentifiers

/// The Styles screen: browse the styles, edit them in the inspector, and import or export style
/// files (docs/styles.md).
struct StylesView: View {
  @Environment(StyleStore.self) private var styles
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var search = ""
  @State private var category: String?
  @State private var selection: Set<UUID> = []
  @State private var pendingDelete: Set<UUID> = []
  @State private var message: (title: String, text: String)?
  @State private var dropTargeted = false

  private var filtered: [Style] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return styles.styles.filter { style in
      (category == nil || style.category == category)
        && (query.isEmpty || style.name.localizedCaseInsensitiveContains(query)
          || style.subcategory.localizedCaseInsensitiveContains(query)
          || style.template.localizedCaseInsensitiveContains(query))
    }
  }

  /// The one style selected, which the inspector edits.
  private var selected: Style? {
    selection.count == 1 ? styles.style(id: selection.first) : nil
  }

  var body: some View {
    @Bindable var create = create
    content
      .overlay {
        if dropTargeted {
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .padding(4)
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        importFiles(urls)
        return true
      } isTargeted: { dropTargeted = $0 }
      .toolbar {
        ToolbarItem {
          Picker("Category", selection: $category) {
            Text("All categories").tag(String?.none)
            ForEach(styles.categories, id: \.self) { Text($0.isEmpty ? "Uncategorized" : $0).tag(Optional($0)) }
          }
          .frame(minWidth: 160)
        }
        ToolbarItem {
          Menu {
            Button("Import Styles…", systemImage: "square.and.arrow.down") { chooseFiles() }
            Button("Export Styles…", systemImage: "square.and.arrow.up") { export() }
              .disabled(styles.styles.isEmpty)
          } label: {
            Label("Import or Export", systemImage: "square.and.arrow.down.on.square")
          }
          .help("Import a style file, or export these styles to one")
        }
        ToolbarItem {
          Button("New Style", systemImage: "plus") { newStyle() }
            .help("Add a style")
        }
      }
      .searchable(text: $search, placement: .toolbar, prompt: "Filter styles")
      .detailInspector(selection: selection, isEmpty: selected == nil, clearSelection: { selection = [] }) {
        Group {
          if let selected {
            StyleEditor(style: selected, delete: { pendingDelete = [selected.id] })
              .id(selected.id)
          } else {
            ContentUnavailableView(
              selection.count > 1 ? "\(selection.count) styles selected" : "No selection",
              systemImage: "paintpalette",
              description: Text("Select a style to edit it or use it on Create."))
          }
        }
        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
      }
      .confirmationDialog(
        pendingDelete.count == 1
          ? "Delete “\(styles.style(id: pendingDelete.first)?.name ?? "this style")”?"
          : "Delete \(pendingDelete.count) styles?",
        isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
      ) {
        Button("Delete", role: .destructive) {
          if let id = create.styleID, pendingDelete.contains(id) { create.styleID = nil }
          styles.delete(pendingDelete)
          selection.subtract(pendingDelete)
          pendingDelete = []
        }
        Button("Cancel", role: .cancel) { pendingDelete = [] }
      } message: {
        Text("This can't be undone. Export the styles first to keep a copy.")
      }
      .alert(
        message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
      ) {
        Button("OK") { message = nil }
      } message: {
        Text(message?.text ?? "")
      }
      .deleteCommand { pendingDelete = selection }
  }

  @ViewBuilder
  private var content: some View {
    if styles.styles.isEmpty {
      ContentUnavailableView {
        Label("No Styles", systemImage: "paintpalette")
      } description: {
        Text("A style is a prompt template your prompt is written into at Generate. Import a style file, drop one here, or add a style.")
      } actions: {
        Button("Import Styles…") { chooseFiles() }
        Button("New Style") { newStyle() }
      }
    } else if filtered.isEmpty {
      ContentUnavailableView.search(text: search)
    } else {
      List(selection: $selection) {
        ForEach(sections, id: \.category) { section in
          Section(section.category.isEmpty ? "Uncategorized" : section.category) {
            ForEach(section.styles) { style in
              row(style).tag(style.id)
            }
          }
        }
      }
      .contextMenu(forSelectionType: UUID.self) { ids in
        if ids.count == 1, let style = styles.style(id: ids.first) {
          Button("Use on Create") { use(style) }
          Button("Duplicate") { duplicate(style) }
          Divider()
        }
        Button(ids.count > 1 ? "Delete \(ids.count) Styles…" : "Delete…", role: .destructive) {
          pendingDelete = ids
        }
        .disabled(ids.isEmpty)
      }
    }
  }

  private var sections: [(category: String, styles: [Style])] {
    var order: [String] = []
    var grouped: [String: [Style]] = [:]
    for style in filtered {
      if grouped[style.category] == nil { order.append(style.category) }
      grouped[style.category, default: []].append(style)
    }
    return order.map { ($0, grouped[$0] ?? []) }
  }

  private func row(_ style: Style) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(style.name).fontWeight(.medium)
        if !style.subcategory.isEmpty {
          Text(style.subcategory).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        // Always laid out so the row doesn't shift; shown for the style Create uses.
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.tint)
          .opacity(create.styleID == style.id ? 1 : 0)
          .help("Used on Create")
      }
      Text(style.template)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.vertical, 2)
  }

  private func use(_ style: Style) {
    create.styleID = style.id
    navigation.section = .create
  }

  private func newStyle() {
    let style = Style(
      name: "New Style", category: category ?? "My Styles", template: "\(Style.subject), ")
    styles.save(style)
    search = ""
    selection = [style.id]
  }

  private func duplicate(_ style: Style) {
    var copy = style
    copy.id = UUID()
    copy.name += " copy"
    styles.save(copy)
    selection = [copy.id]
  }

  private func chooseFiles() {
    fileDialogs.open = FileDialogs.Open(
      types: [.markdownText, .plainText], multiple: true,
      directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
      message: "Choose style files to import"
    ) { urls in
      importFiles(urls)
    }
  }

  private func importFiles(_ urls: [URL]) {
    var parsed: [Style] = []
    var unreadable: [String] = []
    for url in urls {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      if let text = try? String(contentsOf: url, encoding: .utf8) {
        let found = StyleFile.parse(text)
        if found.isEmpty { unreadable.append(url.lastPathComponent) }
        parsed += found
      } else {
        unreadable.append(url.lastPathComponent)
      }
    }
    guard !parsed.isEmpty else {
      message = (
        "No styles found",
        "\(unreadable.formatted(.list(type: .and))) has no styles in Atelier's format: a ### heading per style with a TEMPLATE: section under it. See Styles in Atelier's help."
      )
      return
    }
    let result = styles.importStyles(parsed)
    var text = "\(result.added) added"
    if result.replaced > 0 { text += ", \(result.replaced) replaced (same category and name)" }
    text += "."
    if !unreadable.isEmpty { text += " No styles found in \(unreadable.formatted(.list(type: .and)))." }
    message = ("Imported \(parsed.count) \(parsed.count == 1 ? "style" : "styles")", text)
    search = ""
    category = nil
  }

  private func export() {
    // The selection when there is one, else what the filter shows.
    let chosen = selection.isEmpty ? filtered : styles.styles.filter { selection.contains($0.id) }
    let text = StyleFile.write(chosen)
    fileDialogs.save = FileDialogs.Save(
      file: ExportedFile(type: .markdownText) { Data(text.utf8) }, name: "Styles.md")
  }
}

/// Edits one style; changes are kept with Save.
struct StyleEditor: View {
  let style: Style
  let delete: () -> Void
  @Environment(StyleStore.self) private var styles
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @State private var draft: Style

  init(style: Style, delete: @escaping () -> Void) {
    self.style = style
    self.delete = delete
    _draft = State(initialValue: style)
  }

  private var edited: Bool { draft != style }
  private var valid: Bool {
    !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
      && !draft.template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $draft.name)
        TextField("Category", text: $draft.category, prompt: Text("Uncategorized"))
        TextField("Subcategory", text: $draft.subcategory, prompt: Text("None"))
      }
      Section {
        TextEditor(text: $draft.template)
          .font(.body)
          .frame(minHeight: 180)
          .scrollContentBackground(.hidden)
      } header: {
        Text("Template")
      } footer: {
        Text("{{SUBJECT}} is replaced by your prompt; without it, your prompt goes first. {{SETTING}} takes the Setting field beside the style on Create, and is dropped when that's empty.")
      }
      Section {
        TextField("Negative", text: $draft.negative, prompt: Text("None"), axis: .vertical)
          .lineLimit(1...4)
      } header: {
        Text("Negative Prompt")
      } footer: {
        Text("Added after your negative prompt.")
      }
      Section("Notes") {
        TextField("Notes", text: $draft.notes, prompt: Text("None"), axis: .vertical)
          .lineLimit(1...6)
      }
      Section {
        ButtonRow {
          Button("Revert") { draft = style }
            .disabled(!edited)
          Button("Save") { styles.save(trimmed) }
            .keyboardShortcut(.defaultAction)
            .disabled(!edited || !valid)
        }
        ButtonRow {
          Button("Use on Create") {
            if edited, valid { styles.save(trimmed) }
            create.styleID = style.id
            navigation.section = .create
          }
          Button("Delete…", role: .destructive, action: delete)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var trimmed: Style {
    var style = draft
    style.name = style.name.trimmingCharacters(in: .whitespaces)
    style.category = style.category.trimmingCharacters(in: .whitespaces)
    style.subcategory = style.subcategory.trimmingCharacters(in: .whitespaces)
    style.template = style.template.trimmingCharacters(in: .whitespacesAndNewlines)
    style.negative = style.negative.trimmingCharacters(in: .whitespacesAndNewlines)
    style.notes = style.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    return style
  }
}
