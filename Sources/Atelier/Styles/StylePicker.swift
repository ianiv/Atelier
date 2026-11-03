import SwiftUI

/// The style beside the prompt, and the Setting field its `{{SETTING}}` slot takes. The field is
/// always there, disabled for a style without the slot, so the row never shifts.
struct StyleControls: View {
  @Environment(CreateModel.self) private var model
  @State private var picking = false

  var body: some View {
    @Bindable var model = model
    let style = model.style
    HStack(spacing: 6) {
      Button {
        picking = true
      } label: {
        Label(style?.name ?? "No Style", systemImage: "paintpalette")
          .lineLimit(1)
          .frame(maxWidth: 180)
      }
      .buttonStyle(.bordered)
      .compactPickerSize()
      .fixedSize()
      .help(style.map { "Style: \($0.name). Generate writes the prompt into its template." } ?? "Pick a style to write the prompt into at Generate")
      .debugPresents("stylePicker", $picking)
      .popover(isPresented: $picking) {
        StylePicker(selection: model.styleID) { picked in
          model.styleID = picked
          picking = false
        }
      }
      TextField("Setting", text: $model.styleSetting, prompt: Text("Setting"))
        .textFieldStyle(.roundedBorder)
        .compactPickerSize()
        .frame(width: 150)
        .disabled(style?.takesSetting != true)
        .help(
          style?.takesSetting == true
            ? "Where the scene takes place, for this style's {{SETTING}} slot. Left empty, the slot is dropped."
            : "Only for styles with a {{SETTING}} slot")
    }
  }
}

/// Searchable list of the styles by category, with No Style first.
struct StylePicker: View {
  let selection: UUID?
  let pick: (UUID?) -> Void
  @Environment(CreateModel.self) private var model
  @Environment(Navigation.self) private var navigation
  @State private var query = ""

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
            Section(category.isEmpty ? "Uncategorized" : category) {
              ForEach(inCategory) { style in
                row(name: style.name, detail: style.subcategory, id: style.id)
              }
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
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }
}
