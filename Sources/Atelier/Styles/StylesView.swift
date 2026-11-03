import SwiftUI
import UniformTypeIdentifiers

/// The Styles screen: browse the styles, edit them in the inspector, and import or export style
/// files (docs/styles.md).
struct StylesView: View {
  @Environment(\.undoManager) private var undoManager
  @Environment(StyleStore.self) private var styles
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @Environment(FileDialogs.self) private var fileDialogs
  // Kept in the store, so the screen comes back as you left it.
  private var search: String {
    get { styles.screenSearch }
    nonmutating set { styles.screenSearch = newValue }
  }
  private var category: String? {
    get { styles.screenCategory }
    nonmutating set { styles.screenCategory = newValue }
  }
  private var selection: Set<UUID> {
    get { styles.screenSelection }
    nonmutating set { styles.screenSelection = newValue }
  }
  @State private var pendingDelete: Set<UUID> = []
  @State private var message: (title: String, text: String)?
  @State private var exporting = false
  @State private var dropTargeted = false
  /// The modifier keys held now, for ⌘- and ⇧-click in the list.
  @State private var modifiers: EventModifiers = []
  /// Where a ⇧-click range starts: the last row clicked without ⇧.
  @State private var anchor: UUID?
  @FocusState private var listFocused: Bool
  /// The far end of a ⇧-arrow selection.
  @State private var lastExtended: UUID?
  /// The style the arrow keys moved to, scrolled to when it's off screen.
  @State private var revealed: UUID?
  /// The grid's width, for its column count and thumbnail size.
  @State private var gridWidth: CGFloat = 0

  /// The grid's cells: at least this wide, this far apart.
  private static let gridMinimum: CGFloat = 140
  private static let gridSpacing: CGFloat = 12
  private static let gridPadding: CGFloat = 16

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
    @Bindable var styles = styles
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
          Picker("View", selection: $styles.screenGrid) {
            Label("List", systemImage: "list.bullet").tag(false)
            Label("Grid", systemImage: "square.grid.2x2").tag(true)
          }
          .pickerStyle(.segmented)
          .help("Show the styles as a list or a grid of thumbnails")
        }
        ToolbarItem {
          Picker("Category", selection: $styles.screenCategory) {
            Text("All categories").tag(String?.none)
            ForEach(styles.categories, id: \.self) { Text($0.isEmpty ? "Uncategorized" : $0).tag(Optional($0)) }
          }
          .frame(minWidth: 160)
        }
        ToolbarItem {
          Menu {
            Button("Import Styles…", systemImage: "square.and.arrow.down") { chooseFiles() }
            Button("Export Styles…", systemImage: "square.and.arrow.up") { exporting = true }
              .disabled(styles.styles.isEmpty)
          } label: {
            Label("Import or Export", systemImage: "square.and.arrow.down.on.square")
          }
          .help("Import a style library or Markdown style file, or export these styles as a library page that works in any browser")
        }
        ToolbarItem {
          Button("New Style", systemImage: "plus") { newStyle() }
            .help("Add a style")
        }
      }
      .searchable(text: $styles.screenSearch, placement: .toolbar, prompt: "Filter styles")
      .safeAreaBar(edge: .bottom, spacing: 0) {
        ThumbnailBar(selected: styles.styles.filter { selection.contains($0.id) })
      }
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
      .debugPresents("exportStyles", $exporting)
      // Presented while there's a style to show, not per style, so the arrow keys in it change
      // the style shown without closing and reopening it.
      .sheet(
        isPresented: Binding(get: { styles.viewingThumbnail != nil }, set: { if !$0 { styles.viewingThumbnail = nil } })
      ) {
        ThumbnailViewer { key in
          let result = arrow(key, extend: false)
          if result == .handled, let anchor { styles.viewingThumbnail = anchor }
          return result
        }
      }
      .sheet(isPresented: $exporting) {
        ExportStylesSheet(
          selectedCount: selection.count, shownCount: filtered.count, suggestedTitle: category ?? "Styles"
        ) { options in
          exporting = false
          export(options)
        }
      }
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
      @Bindable var styles = styles
      // A scroll view rather than a List: a List can't reliably scroll back to a row, and the
      // screen comes back where you left it (`screenScrolledTo`). Selection follows a List's:
      // click, ⌘-click, ⇧-click, ⌘A and the arrow keys.
      ScrollViewReader { proxy in
        ScrollView {
          Group {
            if styles.screenGrid { grid } else { list }
          }
          .scrollTargetLayout()
          .padding(.bottom, 8)
        }
        .scrollPosition(id: $styles.screenScrolledTo, anchor: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        // Keep the moved-to style on screen (scrolling only when it's off it).
        .onChange(of: revealed) { _, id in if let id { proxy.scrollTo(id) } }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        #if os(macOS)
          // For ⌘- and ⇧-click; iPadOS has no such modifier, so a tap there selects one style.
          .onModifierKeysChanged { _, new in modifiers = new }
        #endif
          .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: .down) { press in
            arrow(press.key, extend: press.modifiers.contains(.shift))
          }
          // Space: the selected style's thumbnail full size, as Quick Look in History.
          .onKeyPress(.space) {
            guard let id = selected?.id ?? anchor, styles.thumbnail(id) != nil else { return .ignored }
            styles.viewingThumbnail = id
            return .handled
          }
          .onKeyPress(characters: ["a"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(filtered.map(\.id))
            return .handled
          }
      }
    }
  }

  private var list: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(sections, id: \.category) { section in
        Section {
          ForEach(section.styles) { style in
            item(style) { row(style) }
              .padding(.horizontal, 8)
          }
        } header: {
          header(section.category).padding(.horizontal, 18)
        }
      }
    }
  }

  /// Thumbnails filling the width, `gridColumns` across, with each style's name under its own.
  private var grid: some View {
    let columns = Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing, alignment: .top), count: gridColumns)
    return LazyVGrid(columns: columns, alignment: .leading, spacing: Self.gridSpacing) {
      ForEach(sections, id: \.category) { section in
        Section {
          ForEach(section.styles) { style in
            item(style) { cell(style) }
          }
        } header: {
          header(section.category).padding(.horizontal, 2)
        }
      }
    }
    .padding(.horizontal, Self.gridPadding)
  }

  /// How many grid cells fit across.
  private var gridColumns: Int {
    max(1, Int((gridWidth - 2 * Self.gridPadding + Self.gridSpacing) / (Self.gridMinimum + Self.gridSpacing)))
  }

  /// A grid cell's thumbnail size.
  private var gridSide: CGFloat {
    let count = CGFloat(gridColumns)
    let side = (gridWidth - 2 * Self.gridPadding - Self.gridSpacing * (count - 1)) / count - 12
    return max(side.rounded(.down), 64)
  }

  private func header(_ category: String) -> some View {
    Text(category.isEmpty ? "Uncategorized" : category)
      .font(.headline)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 12)
      .padding(.bottom, 4)
  }

  /// A row or grid cell: selected by clicks, highlighted when selected, with the context menu.
  private func item(_ style: Style, @ViewBuilder content: () -> some View) -> some View {
    content()
      .padding(.horizontal, styles.screenGrid ? 6 : 10)
      .padding(.vertical, styles.screenGrid ? 6 : 5)
      .background(
        selection.contains(style.id) ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
        in: .rect(cornerRadius: styles.screenGrid ? 10 : 6))
      .contentShape(.rect)
      .onTapGesture { click(style.id) }
      .contextMenu { menu(for: selection.contains(style.id) ? selection : [style.id]) }
      .id(style.id)
  }

  @ViewBuilder
  private func menu(for ids: Set<UUID>) -> some View {
    if ids.count == 1, let style = styles.style(id: ids.first) {
      Button("Use on Create") { use(style) }
      Button("Open Thumbnail in Create") {
        openThumbnail(style, styles: styles, create: create, navigation: navigation, undoManager: undoManager)
      }
      .disabled(!styles.canOpenThumbnail(style.id))
      Button("Duplicate") { duplicate(style) }
      Divider()
    }
    Button(ids.count > 1 ? "Delete \(ids.count) Styles…" : "Delete…", role: .destructive) {
      pendingDelete = ids
    }
  }

  /// A click on a row: selects it alone, or with ⌘ adds or removes it, or with ⇧ selects the rows
  /// from the last one clicked.
  private func click(_ id: UUID) {
    listFocused = true
    let ids = filtered.map(\.id)
    if modifiers.contains(.shift), let anchor, let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
      selection = Set(ids[min(from, to)...max(from, to)])
      return
    }
    if modifiers.contains(.command) {
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    } else {
      selection = [id]
    }
    anchor = id
  }

  /// An arrow key: in the list ↑/↓ move to the row above or below the last one clicked; in the
  /// grid ←/→ move to the cell before or after it and ↑/↓ to the one above or below. With ⇧, extends
  /// the selection to it.
  private func arrow(_ key: KeyEquivalent, extend: Bool) -> KeyPress.Result {
    let ids = filtered.map(\.id)
    guard !ids.isEmpty else { return .ignored }
    let current = (extend ? lastExtended : anchor).flatMap { ids.firstIndex(of: $0) }
      ?? ids.firstIndex { selection.contains($0) }
    let next: Int
    switch (key, styles.screenGrid) {
    case (.upArrow, false), (.leftArrow, true): next = current.map { max($0 - 1, 0) } ?? 0
    case (.downArrow, false), (.rightArrow, true): next = current.map { min($0 + 1, ids.count - 1) } ?? 0
    case (.upArrow, true), (.downArrow, true):
      next = current.map { gridIndex(from: $0, rows: key == .upArrow ? -1 : 1) } ?? 0
    default: return .ignored
    }
    if extend, let anchor, let from = ids.firstIndex(of: anchor) {
      selection = Set(ids[min(from, next)...max(from, next)])
      lastExtended = ids[next]
    } else {
      selection = [ids[next]]
      anchor = ids[next]
      lastExtended = nil
    }
    revealed = ids[next]
    return .handled
  }

  /// The grid cell `rows` rows above or below the one at `index` (in `filtered`), in the same
  /// column or the last cell of a shorter row. Each category starts a new row, as in the grid.
  private func gridIndex(from index: Int, rows: Int) -> Int {
    var gridRows: [Range<Int>] = []
    var start = 0
    for section in sections {
      for offset in stride(from: 0, to: section.styles.count, by: gridColumns) {
        gridRows.append((start + offset)..<(start + min(offset + gridColumns, section.styles.count)))
      }
      start += section.styles.count
    }
    guard let row = gridRows.firstIndex(where: { $0.contains(index) }) else { return index }
    let target = gridRows[min(max(row + rows, 0), gridRows.count - 1)]
    return min(target.lowerBound + (index - gridRows[row].lowerBound), target.upperBound - 1)
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
    HStack(alignment: .top, spacing: 10) {
      StyleThumbnail(id: style.id, side: 56) {
        click(style.id)
        styles.viewingThumbnail = style.id
      }
      rowText(style)
    }
  }

  private func cell(_ style: Style) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      StyleThumbnail(id: style.id, side: gridSide) {
        click(style.id)
        styles.viewingThumbnail = style.id
      }
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        VStack(alignment: .leading, spacing: 0) {
          Text(style.name).fontWeight(.medium).lineLimit(1)
          // Always laid out, so the cells in a row line up.
          Text(style.subcategory.isEmpty ? " " : style.subcategory)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.tint)
          .opacity(create.styleID == style.id ? 1 : 0)
          .help("Used on Create")
      }
      .frame(width: gridSide)
    }
    .help(style.name)
  }

  private func rowText(_ style: Style) -> some View {
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
      name: "New Style", category: category ?? "My Styles", template: "\(Style.subjectPlaceholder), ")
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
      types: [.html, .markdownText, .plainText], multiple: true,
      directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
      message: "Choose style files to import"
    ) { urls in
      importFiles(urls)
    }
  }

  private func importFiles(_ urls: [URL]) {
    var parsed: [Style] = []
    var thumbnails: [Data?] = []
    var unreadable: [String] = []
    for url in urls {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        unreadable.append(url.lastPathComponent)
        continue
      }
      // A library page (with its thumbnails), else a Markdown style file.
      let found = StyleLibrary.read(text) ?? StyleFile.parse(text).map { ($0, nil) }
      if found.isEmpty { unreadable.append(url.lastPathComponent) }
      parsed += found.map(\.style)
      thumbnails += found.map(\.thumbnail)
    }
    guard !parsed.isEmpty else {
      message = (
        "No styles found",
        "\(unreadable.formatted(.list(type: .and))) has no styles Atelier can read: a style library exported from Atelier, or Markdown with a ### heading per style and a TEMPLATE: section under it. See Styles in Atelier's help."
      )
      return
    }
    let result = styles.importStyles(parsed)
    for (id, thumbnail) in zip(result.ids, thumbnails) {
      if let thumbnail { styles.setThumbnail(data: thumbnail, for: id) }
    }
    var text = "\(result.added) added"
    if result.replaced > 0 { text += ", \(result.replaced) replaced (same category and name)" }
    text += "."
    if !unreadable.isEmpty { text += " No styles found in \(unreadable.formatted(.list(type: .and)))." }
    message = ("Imported \(parsed.count) \(parsed.count == 1 ? "style" : "styles")", text)
    search = ""
    category = nil
  }

  /// Writes a library page (styles and thumbnails, usable in any browser) or a Markdown style
  /// file, of the selected styles or the ones the filter shows.
  private func export(_ options: ExportStylesSheet.Options) {
    let chosen = options.selectedOnly ? styles.styles.filter { selection.contains($0.id) } : filtered
    let title = options.title
    if options.markdown {
      let text = StyleFile.write(chosen)
      fileDialogs.save = FileDialogs.Save(
        file: ExportedFile(type: .markdownText) { Data(text.utf8) }, name: title + ".md")
      return
    }
    let store = styles
    let thumbnails = Dictionary(uniqueKeysWithValues: chosen.compactMap { style in
      store.thumbnailJPEG(style.id).map { (style.id, $0) }
    })
    fileDialogs.save = FileDialogs.Save(
      file: ExportedFile(type: .html) {
        Data(try StyleLibrary.html(title: title, styles: chosen) { thumbnails[$0] }.utf8)
      },
      name: title + ".html")
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
      ThumbnailSection(style: style)
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
        Text("Each {{TAG}} (letters, digits and _) becomes a box on Create in place of the prompt box. Write {{TAG:text}} to give it a default for when the box is left empty; without one, an empty tag is dropped. {{SUBJECT}} is the prompt; without it, the prompt goes first.")
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

/// A style's thumbnail, or a placeholder the same size when it has none. With `open`, clicking a
/// thumbnail calls it (to show it full size); clicking the placeholder doesn't.
struct StyleThumbnail: View {
  let id: UUID
  let side: CGFloat
  var open: (() -> Void)?
  @Environment(StyleStore.self) private var styles

  private var opens: Bool { open != nil && styles.thumbnail(id) != nil }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: side / 8)
    Group {
      if let image = styles.thumbnail(id) {
        Image(decorative: image, scale: 1).resizable().scaledToFill()
      } else {
        Image(systemName: "paintpalette")
          .font(.system(size: side / 3))
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary)
      }
    }
    .frame(width: side, height: side)
    .clipShape(shape)
    .contentShape(shape)
    // Off for the placeholder, so a click there reaches the row beneath and selects it.
    .gesture(TapGesture().onEnded { open?() }, including: opens ? .all : .subviews)
    .help(opens ? "Show full size" : "")
    .task(id: id) { await styles.loadThumbnail(id) }
  }
}

/// The editor's thumbnail and the ways to change it.
private struct ThumbnailSection: View {
  let style: Style
  @Environment(StyleStore.self) private var styles
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @Environment(FileDialogs.self) private var fileDialogs
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    let blocker = styles.thumbnailBlocker(create, for: [style])
    Section {
      HStack(alignment: .top, spacing: 12) {
        StyleThumbnail(id: style.id, side: 128) { styles.viewingThumbnail = style.id }
        VStack(alignment: .leading, spacing: 8) {
          Button("Generate", systemImage: "sparkles") {
            styles.makeThumbnails(for: [style], create: create)
          }
          .disabled(blocker != nil || styles.thumbnailRun != nil)
          .help(blocker ?? "Generate a thumbnail in this style from the thumbnail boxes under the list, with the model, settings and seed on Create")
          Button("Use Canvas Image", systemImage: "photo") {
            styles.setThumbnail(create.image, for: style.id, source: create.canvasThumbnailSource)
          }
          .disabled(create.image == nil)
          .help("Use the image on Create's canvas")
          Button("Choose Image…", systemImage: "folder") {
            fileDialogs.open = FileDialogs.Open(types: [.image], message: "Choose a thumbnail for “\(style.name)”") { urls in
              guard let url = urls.first else { return }
              let access = url.startAccessingSecurityScopedResource()
              defer { if access { url.stopAccessingSecurityScopedResource() } }
              _ = styles.setThumbnail(contentsOf: url, for: style.id)
            }
          }
          Button("Open in Create", systemImage: "arrow.up.forward.app") {
            openThumbnail(style, styles: styles, create: create, navigation: navigation, undoManager: undoManager)
          }
          .disabled(!styles.canOpenThumbnail(style.id))
          .help(
            styles.canOpenThumbnail(style.id)
              ? "Put the thumbnail's image on Create's canvas and load the model, settings, seed and prompt it was made with"
              : "Only for thumbnails generated here, or taken from an image whose settings are known")
          Button("Remove", systemImage: "trash") { styles.setThumbnail(nil, for: style.id) }
            .disabled(styles.thumbnail(style.id) == nil)
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
      }
    } header: {
      Text("Thumbnail")
    }
  }
}

/// Under the list: the thumbnails' tag values, and making thumbnails for the selected styles.
private struct ThumbnailBar: View {
  let selected: [Style]
  @Environment(StyleStore.self) private var styles
  @Environment(CreateModel.self) private var create
  /// Too narrow for everything on one row (a narrow iPad window).
  @State private var narrow = false
  @FocusState private var focusedTag: String?

  /// The tags the selected styles use, `SUBJECT` first (alone when none is selected).
  private var tags: [String] {
    var seen: Set = [Style.subject]
    return [Style.subject] + selected.flatMap(\.tags).filter { seen.insert($0).inserted }
  }

  var body: some View {
    @Bindable var styles = styles
    let blocker = styles.thumbnailBlocker(create, for: selected)
    let row = narrow
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))
    row {
      // The Create screen's prompt box, with a box for each tag of the selected styles.
      StyleTagFields(
        tags: tags, lines: 3, focus: $focusedTag,
        text: { tag in
          Binding(get: { styles.thumbnailValues[tag] ?? "" }, set: { styles.thumbnailValues[tag] = $0 })
        },
        prompt: { tag in
          if let fallback = selected.lazy.compactMap({ $0.defaults[tag] }).first { return fallback }
          return tag == Style.subject ? "What every thumbnail shows" : "Optional: left out when empty"
        })
        .promptBox(focused: focusedTag != nil)
        .help("Written into each selected style's tags to make its thumbnail")
      HStack(spacing: 10) {
        Text(status)
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)
        // Both always there so the bar doesn't shift; each disabled when it can't act.
        Button("Stop", systemImage: "stop.fill") { styles.stopThumbnails() }
          .labelStyle(.iconOnly)
          .disabled(styles.thumbnailRun == nil)
          .help("Stop making thumbnails; the ones made are kept")
        Button(selected.count > 1 ? "Make \(selected.count) Thumbnails" : "Make Thumbnail") {
          styles.makeThumbnails(for: selected, create: create)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selected.isEmpty || blocker != nil || styles.thumbnailRun != nil)
        .help(blocker ?? (selected.isEmpty ? "Select styles to make their thumbnails" : "Generate a thumbnail for each selected style with the model, settings and seed on Create. The images aren't saved to the project."))
      }
      .fixedSize()
    }
    .padding(12)
    // Opaque, unlike the Create bar over the canvas: list rows would show through around the box.
    .background(.bar)
    #if os(iOS)
      .onGeometryChange(for: Bool.self) { $0.size.width < 560 } action: { narrow = $0 }
    #endif
  }

  private var status: String {
    if let run = styles.thumbnailRun {
      return "\(run.done + 1) of \(run.total): \(run.current)"
    }
    if let model = create.selectedModelInfo?.name { return model }
    return ""
  }
}

/// Opens a style's thumbnail in Create: its image on the canvas and the settings it was made with.
@MainActor
private func openThumbnail(
  _ style: Style, styles: StyleStore, create: CreateModel, navigation: Navigation, undoManager: UndoManager?
) {
  guard let (image, source) = styles.thumbnailSource(style.id) else { return }
  create.openThumbnail(image, source: source, undoManager: undoManager)
  navigation.section = .create
}

/// Export Styles…: which styles, the library page's title, and the format.
private struct ExportStylesSheet: View {
  struct Options {
    var selectedOnly: Bool
    var title: String
    var markdown: Bool
  }

  let selectedCount: Int
  let shownCount: Int
  let suggestedTitle: String
  let export: (Options) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selectedOnly = false
  @State private var title = ""
  @State private var markdown = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Export Styles").font(.headline).padding([.top, .horizontal])
      Form {
        Picker("Styles", selection: $selectedOnly) {
          Text("Selected (\(selectedCount))").tag(true)
          Text("All shown (\(shownCount))").tag(false)
        }
        .pickerStyle(.segmented)
        .disabled(selectedCount == 0)
        TextField("Title", text: $title, prompt: Text(suggestedTitle))
          .help("The library page's heading and the file's name")
        Picker("Format", selection: $markdown) {
          Text("Library page (.html)").tag(false)
          Text("Markdown (.md)").tag(true)
        }
        Text(
          markdown
            ? "A Markdown style file: styles only, no thumbnails. Atelier imports it."
            : "A self-contained web page that browses the styles and writes prompts in any browser, thumbnails included. Atelier imports it."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Export…") {
          let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
          export(Options(selectedOnly: selectedOnly, title: trimmed.isEmpty ? suggestedTitle : trimmed, markdown: markdown))
        }
        .keyboardShortcut(.defaultAction)
        .disabled((selectedOnly ? selectedCount : shownCount) == 0)
      }
      .padding()
    }
    .sheetFrame(width: 460)
    .onAppear { selectedOnly = selectedCount > 0 }
  }
}

/// A style's thumbnail full size, in a sheet sized to the image: fitted to start, then zoomed with
/// a pinch, the buttons or ⌘+ / ⌘- (⌘0 actual size, ⌘9 fit), and panned by dragging. A double
/// click switches between fit and actual size there. Space, Escape or Done closes it. It shows
/// `StyleStore.viewingThumbnail`; the arrow keys go to `arrow`, which moves that to another style.
struct ThumbnailViewer: View {
  let arrow: (KeyEquivalent) -> KeyPress.Result
  @Environment(StyleStore.self) private var styles
  @Environment(\.dismiss) private var dismiss
  @State private var image: CGImage?
  @State private var loaded = false
  /// Points per image pixel; nil while fitted, so the image keeps fitting as the sheet resizes.
  @State private var zoom: CGFloat?
  /// The image's centre from the view's, in points.
  @State private var offset: CGSize = .zero
  /// The offset when a drag began, and the zoom and offset when a pinch began.
  @State private var panStart: CGSize?
  @State private var magnifyStart: (zoom: CGFloat, offset: CGSize)?
  @State private var viewSize: CGSize = .zero
  @FocusState private var focused: Bool

  /// The largest the image area gets, before it's fitted to the image's shape.
  private static let maxArea = CGSize(width: 900, height: 700)

  var body: some View {
    VStack(spacing: 0) {
      canvas
      Divider()
      controls.padding(10)
    }
    .sheetFrame(width: sheetSize.width, height: sheetSize.height)
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(.space) {
      dismiss()
      return .handled
    }
    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: .down) { press in
      arrow(press.key)
    }
    // Kept from the last style while closing, so the sheet doesn't empty as it goes.
    .task(id: styles.viewingThumbnail) {
      guard let id = styles.viewingThumbnail else { return }
      let full = await styles.fullThumbnailImage(id)
      guard !Task.isCancelled else { return }
      image = full
      zoom = nil
      offset = .zero
      loaded = true
      focused = true
    }
  }

  /// The image area fitted to the image's aspect within `maxArea`, plus the controls.
  private var sheetSize: CGSize {
    let controls: CGFloat = 52
    guard let image, image.width > 0, image.height > 0 else { return CGSize(width: 560, height: 560 + controls) }
    let aspect = CGFloat(image.width) / CGFloat(image.height)
    var size = Self.maxArea
    if aspect > size.width / size.height { size.height = size.width / aspect } else { size.width = size.height * aspect }
    return CGSize(width: max(size.width, 480).rounded(), height: (max(size.height, 320) + controls).rounded())
  }

  private var pixels: CGSize {
    image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
  }

  /// The zoom that fits the whole image in the view.
  private var fitZoom: CGFloat {
    guard pixels.width > 0, pixels.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 1 }
    return min(viewSize.width / pixels.width, viewSize.height / pixels.height)
  }

  private var currentZoom: CGFloat { zoom ?? fitZoom }
  private var minZoom: CGFloat { min(fitZoom, 1) / 2 }
  private var maxZoom: CGFloat { max(fitZoom, 1) * 8 }

  private var canvas: some View {
    GeometryReader { geometry in
      ZStack {
        if let image {
          let scale = currentZoom
          Image(decorative: image, scale: 1)
            .resizable()
            // Pixels stay sharp when zoomed well in, for a close look at the detail.
            .interpolation(scale > 2 ? .none : .high)
            .frame(width: pixels.width * scale, height: pixels.height * scale)
            .offset(offset)
        } else if loaded {
          ContentUnavailableView("No Thumbnail", systemImage: "photo")
        } else {
          ProgressView()
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
      .contentShape(.rect)
      .gesture(panGesture)
      .simultaneousGesture(magnifyGesture)
      .gesture(
        SpatialTapGesture(count: 2).onEnded { value in
          let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
          let point = CGSize(width: value.location.x - center.x, height: value.location.y - center.y)
          setZoom(zoom == nil ? (fitZoom < 1 ? 1 : fitZoom * 2) : nil, around: point, animated: true)
        }
      )
      .onGeometryChange(for: CGSize.self) { $0.size } action: {
        viewSize = $0
        offset = clamped(offset, zoom: currentZoom)
      }
    }
    .background(.black.opacity(0.85))
  }

  private var controls: some View {
    HStack(spacing: 12) {
      Button("Zoom Out", systemImage: "minus.magnifyingglass") { step(1 / 1.5) }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(image == nil || currentZoom <= minZoom)
      Button("Zoom In", systemImage: "plus.magnifyingglass") { step(1.5) }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(image == nil || currentZoom >= maxZoom)
      Text(image == nil ? "" : "\(Int((currentZoom * 100).rounded()))%")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(minWidth: 48, alignment: .leading)
      Button("Actual Size") { setZoom(1, around: .zero, animated: true) }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(image == nil)
        .help("One image pixel per point")
      Button("Fit") { setZoom(nil, around: .zero, animated: true) }
        .keyboardShortcut("9", modifiers: .command)
        .disabled(image == nil || zoom == nil)
        .help("Show the whole image")
      Spacer()
      if let image {
        Text(verbatim: "\(image.width) × \(image.height)").foregroundStyle(.secondary)
      }
      Button("Done") { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .labelStyle(.iconOnly)
  }

  private var panGesture: some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { value in
        if panStart == nil { panStart = offset }
        let start = panStart ?? offset
        offset = clamped(
          CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height),
          zoom: currentZoom)
      }
      .onEnded { _ in panStart = nil }
  }

  private var magnifyGesture: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        if magnifyStart == nil { magnifyStart = (currentZoom, offset) }
        guard let start = magnifyStart else { return }
        let point = CGSize(
          width: value.startLocation.x - viewSize.width / 2, height: value.startLocation.y - viewSize.height / 2)
        setZoom(start.zoom * value.magnification, around: point, from: start, animated: false)
      }
      .onEnded { _ in magnifyStart = nil }
  }

  /// Zooms by `factor` about the view's centre.
  private func step(_ factor: CGFloat) {
    setZoom(currentZoom * factor, around: .zero, animated: true)
  }

  /// Sets the zoom (nil fits) keeping the image under `point` (from the view's centre) in place.
  private func setZoom(
    _ newZoom: CGFloat?, around point: CGSize, from start: (zoom: CGFloat, offset: CGSize)? = nil, animated: Bool
  ) {
    let start = start ?? (currentZoom, offset)
    let target = newZoom.map { min(max($0, minZoom), maxZoom) }
    let resolved = target ?? fitZoom
    let ratio = resolved / start.zoom
    let moved = CGSize(
      width: point.width - (point.width - start.offset.width) * ratio,
      height: point.height - (point.height - start.offset.height) * ratio)
    withAnimation(animated ? .snappy(duration: 0.2) : nil) {
      // Fitting (or zooming to exactly the fit) centres the image again.
      zoom = target.flatMap { abs($0 - fitZoom) < 0.001 ? nil : $0 }
      offset = zoom == nil ? .zero : clamped(moved, zoom: resolved)
    }
  }

  /// Keeps the image from being dragged away: a side larger than the view can move until its
  /// edge reaches the view's; a smaller one stays centred.
  private func clamped(_ offset: CGSize, zoom: CGFloat) -> CGSize {
    let limit = CGSize(
      width: max(0, (pixels.width * zoom - viewSize.width) / 2), height: max(0, (pixels.height * zoom - viewSize.height) / 2))
    return CGSize(
      width: min(max(offset.width, -limit.width), limit.width), height: min(max(offset.height, -limit.height), limit.height))
  }
}
