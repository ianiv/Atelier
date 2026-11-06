import SwiftUI

/// The style button under the prompt. With a style, the prompt box becomes one box per tag of
/// its template (PromptComposer).
struct StyleControls: View {
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager
  @State private var picking = false

  var body: some View {
    let style = model.style
    HStack(spacing: 6) {
      picker(style)
      // Always there so the row doesn't shift; disabled without a style.
      Button("Edit Full Prompt", systemImage: "text.cursor") { model.expandStyle(undoManager: undoManager) }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .compactPickerSize()
        .disabled(style == nil)
        .help(
          style == nil
            ? "With a style, puts its whole prompt in the prompt box to edit"
            : "Put the whole prompt this style writes in the prompt box to edit, and stop using the style. Can't be turned back into the boxes.")
    }
  }

  private func picker(_ style: Style?) -> some View {
    Button {
      picking = true
    } label: {
      Label(style?.name ?? "No Style", systemImage: "paintpalette")
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .compactPickerSize()
    .help(style.map { "Style: \($0.name). Generate writes the boxes above into its template." } ?? "Pick a style to write the prompt into at Generate")
    .debugPresents("stylePicker", $picking)
    .popover(isPresented: $picking) {
      StylePicker(selection: model.styleID) { picked in
        model.styleID = picked
        picking = false
      }
    }
  }
}

/// Searchable list of the styles in collapsible categories, with No Style first, from every library
/// or the one picked beside the search. While searching, every category with a match is open.
struct StylePicker: View {
  let selection: UUID?
  let pick: (UUID?) -> Void
  @Environment(CreateModel.self) private var model
  @Environment(Navigation.self) private var navigation
  @State private var query = ""
  /// Categories you collapsed, remembered across launches (one name per line); every other one
  /// is open, new ones included.
  @AppStorage("stylePickerCollapsed") private var collapsedStorage = ""
  /// The library to list: a library's id or a `RemoteSection`'s; empty, or one that's gone, for all
  /// of them.
  @AppStorage("stylePickerLibrary") private var libraryStorage = ""

  private static let thumbnailSide: CGFloat = 40

  private var libraries: [StyleCollection] { model.styles?.libraries ?? [] }

  /// A library of a paired server.
  private struct RemoteSection: Identifiable {
    /// The server's id and the library's, as one: only the two together are unique.
    let id: String
    let serverID: UUID
    let server: String
    let library: RemoteStyleGroup

    var title: String { library.name.map { "\(server): \($0)" } ?? server }
  }

  private var remoteSections: [RemoteSection] {
    model.remoteServers.servers.flatMap { server in
      model.remoteStyles.libraries(of: server.id).map {
        RemoteSection(id: "\(server.id.uuidString)/\($0.id)", serverID: server.id, server: server.name, library: $0)
      }
    }
  }

  private var showsAll: Bool {
    !libraries.contains { $0.id.uuidString == libraryStorage } && !remoteSections.contains { $0.id == libraryStorage }
  }

  private func matches(_ style: Style) -> Bool {
    query.isEmpty || style.name.localizedCaseInsensitiveContains(query) || style.category.localizedCaseInsensitiveContains(query)
      || style.subcategory.localizedCaseInsensitiveContains(query)
  }

  var body: some View {
    let shown = showsAll ? libraries : libraries.filter { $0.id.uuidString == libraryStorage }
    let styles = shown.flatMap(\.styles)
    let matching = styles.filter(matches)
    let sections = remoteSections
    let shownRemote = showsAll ? sections : sections.filter { $0.id == libraryStorage }
    let anyMatch = !matching.isEmpty || shownRemote.contains { $0.library.styles.contains { matches($0.style) } }
    VStack(spacing: 0) {
      // Far enough in to clear the popover's rounded corners.
      HStack(spacing: 8) {
        SearchField(text: $query, prompt: "Search styles")
        Picker("Library", selection: Binding(get: { showsAll ? "" : libraryStorage }, set: { libraryStorage = $0 })) {
          Text("All Libraries").tag("")
          ForEach(libraries) { Text($0.name).tag($0.id.uuidString) }
          ForEach(model.remoteServers.servers) { server in
            let own = sections.filter { $0.id.hasPrefix(server.id.uuidString + "/") }
            if !own.isEmpty {
              Section(server.name) {
                ForEach(own) { Text($0.library.name ?? server.name).tag($0.id) }
              }
            }
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 120)
        .disabled(libraries.count < 2 && sections.isEmpty)
        .help(libraries.count < 2 && sections.isEmpty ? "Add libraries on the Styles screen" : "Which library to list")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      Divider()
      List {
        if query.isEmpty {
          row(name: "No Style", detail: "The prompt as typed", id: nil) {
            Image(systemName: "nosign")
              .font(.system(size: Self.thumbnailSide / 3))
              .foregroundStyle(.tertiary)
              .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
              .accessibilityHidden(true)
          }
        }
        ForEach(shown) { library in
          ForEach(library.categories, id: \.self) { category in
            let inCategory = library.styles.filter { $0.category == category && matches($0) }
            if !inCategory.isEmpty {
              // Bare for the first library, so what was collapsed before there were libraries stays so.
              let key = library.id == StyleStore.mainLibraryID ? category : "\(library.id)/\(category)"
              let open = !query.isEmpty || !collapsed.contains(key)
              Section {
                if open {
                  ForEach(inCategory) { style in
                    row(name: style.name, detail: style.subcategory, id: style.id) {
                      StyleThumbnail(id: style.id, side: Self.thumbnailSide)
                    }
                  }
                }
              } header: {
                header(category, key: key, library: showsAll && libraries.count > 1 ? library.name : nil, count: inCategory.count, open: open)
              }
            }
          }
        }
        ForEach(shownRemote) { section in
          ForEach(section.library.categories, id: \.self) { category in
            let inCategory = section.library.styles.filter { $0.style.category == category && matches($0.style) }
            if !inCategory.isEmpty {
              let key = "\(section.id)/\(category)"
              let open = !query.isEmpty || !collapsed.contains(key)
              Section {
                if open {
                  ForEach(inCategory) { remote in
                    row(name: remote.style.name, detail: remote.style.subcategory, id: remote.id) {
                      ServerStyleThumbnail(remote: remote, server: section.serverID, side: Self.thumbnailSide)
                    }
                  }
                }
              } header: {
                header(category, key: key, library: showsAll ? section.title : nil, count: inCategory.count, open: open)
              }
            }
          }
        }
        if styles.isEmpty, model.remoteStyles.all.isEmpty {
          Text("No styles yet. Add or import them in the Styles section.")
            .foregroundStyle(.secondary)
        } else if !anyMatch {
          Text("No styles match.").foregroundStyle(.secondary)
        }
      }
      .listStyle(.plain)
      Divider()
      HStack {
        Spacer()
        Button("Manage Styles…") {
          pick(selection)
          navigation.section = .styles
        }
        .controlSize(.small)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .frame(width: 380, height: 520)
  }

  private var collapsed: Set<String> {
    Set(collapsedStorage.split(separator: "\n").map(String.init))
  }

  private func header(_ category: String, key: String, library: String?, count: Int, open: Bool) -> some View {
    Button {
      var set = collapsed
      if set.contains(key) { set.remove(key) } else { set.insert(key) }
      collapsedStorage = set.sorted().joined(separator: "\n")
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .rotationEffect(.degrees(open ? 90 : 0))
          .accessibilityHidden(true)
        Text(category.isEmpty ? "Uncategorized" : category).lineLimit(1)
        Spacer()
        if let library { Text(library).lineLimit(1).foregroundStyle(.secondary) }
        Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!query.isEmpty)
    .accessibilityValue(open ? "Expanded" : "Collapsed")
  }

  private func row(name: String, detail: String, id: UUID?, @ViewBuilder thumbnail: () -> some View) -> some View {
    Button {
      pick(id)
    } label: {
      HStack(spacing: 10) {
        thumbnail()
        VStack(alignment: .leading) {
          Text(name)
          if !detail.isEmpty {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer()
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
          .opacity(selection == id ? 1 : 0)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selection == id ? .isSelected : [])
  }
}

/// One labelled box per style tag, sized to `lines` lines of text and scrolling past them: the
/// Create screen's prompt box with a style selected, and the thumbnail values on the Styles screen.
struct StyleTagFields: View {
  let tags: [String]
  let lines: Int
  var focus: FocusState<String?>.Binding
  let text: (String) -> Binding<String>
  let prompt: (String) -> String
  var submit: () -> Void = {}

  var body: some View {
    Text(verbatim: " ")
      .lineLimit(lines, reservesSpace: true)
      .font(.body)
      .frame(maxWidth: .infinity)
      .hidden()
      .overlay {
        ScrollView {
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
              GridRow {
                Text(Style.label(tag))
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .gridColumnAlignment(.trailing)
                TextField(Style.label(tag), text: text(tag), prompt: Text(prompt(tag)), axis: .vertical)
                  .textFieldStyle(.plain)
                  .font(.body)
                  .focused(focus, equals: tag)
                  #if os(iOS)
                    .onSubmit(submit)
                  #endif
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
      }
  }
}

extension View {
  /// The prompt box's look: a text background in the window's corner shape, outlined in the
  /// accent colour while it has focus.
  func promptBox(focused: Bool) -> some View {
    padding(8)
      .background(Color.textBackground, in: PromptComposer.fieldShape)
      .overlay(PromptComposer.fieldShape.stroke(focused ? Color.accentColor : Color.separator))
  }
}
