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

/// Searchable list of the styles in collapsible categories, with No Style first. While searching,
/// every category with a match is open.
struct StylePicker: View {
  let selection: UUID?
  let pick: (UUID?) -> Void
  @Environment(CreateModel.self) private var model
  @Environment(Navigation.self) private var navigation
  @State private var query = ""
  /// Categories you collapsed, remembered across launches (one name per line); every other one
  /// is open, new ones included.
  @AppStorage("stylePickerCollapsed") private var collapsedStorage = ""

  var body: some View {
    let styles = model.styles?.styles ?? []
    let matching = query.isEmpty
      ? styles
      : styles.filter {
        $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
          || $0.subcategory.localizedCaseInsensitiveContains(query)
      }
    let categories = model.styles?.categories ?? []
    VStack(spacing: 0) {
      SearchField(text: $query, prompt: "Search styles").padding(8)
      Divider()
      List {
        if query.isEmpty { row(name: "No Style", detail: "The prompt as typed", id: nil) }
        ForEach(categories, id: \.self) { category in
          let inCategory = matching.filter { $0.category == category }
          if !inCategory.isEmpty {
            let open = !query.isEmpty || !collapsed.contains(category)
            Section {
              if open {
                ForEach(inCategory) { style in
                  row(name: style.name, detail: style.subcategory, id: style.id)
                }
              }
            } header: {
              header(category, count: inCategory.count, open: open)
            }
          }
        }
        if styles.isEmpty {
          Text("No styles yet. Add or import them in the Styles section.")
            .foregroundStyle(.secondary)
        } else if matching.isEmpty {
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
      .padding(8)
    }
    .frame(width: 360, height: 440)
  }

  private var collapsed: Set<String> {
    Set(collapsedStorage.split(separator: "\n").map(String.init))
  }

  private func header(_ category: String, count: Int, open: Bool) -> some View {
    Button {
      var set = collapsed
      if set.contains(category) { set.remove(category) } else { set.insert(category) }
      collapsedStorage = set.sorted().joined(separator: "\n")
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .rotationEffect(.degrees(open ? 90 : 0))
          .accessibilityHidden(true)
        Text(category.isEmpty ? "Uncategorized" : category)
        Spacer()
        Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!query.isEmpty)
    .accessibilityValue(open ? "Expanded" : "Collapsed")
  }

  private func row(name: String, detail: String, id: UUID?) -> some View {
    Button {
      pick(id)
    } label: {
      HStack {
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
