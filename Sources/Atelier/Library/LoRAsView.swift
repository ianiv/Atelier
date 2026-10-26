import SwiftUI
import UniformTypeIdentifiers
import _MediaGenerationKit

struct LoRAsView: View {
  @Environment(ModelLibrary.self) private var library
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var search = ""
  @State private var family: String?
  @State private var selection: String?
  @State private var pendingDelete: ModelLibrary.LoRA?
  @State private var dropTargeted = false

  private var filtered: [ModelLibrary.LoRA] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return library.loras.filter { lora in
      (family == nil || lora.version == family)
        && (query.isEmpty || lora.name.localizedCaseInsensitiveContains(query)
          || lora.file.localizedCaseInsensitiveContains(query)
          || lora.prefix.localizedCaseInsensitiveContains(query))
    }
  }

  private var families: [String] {
    Array(Set(library.loras.map(\.version))).sorted {
      ModelLibrary.familyName($0).localizedStandardCompare(ModelLibrary.familyName($1))
        == .orderedAscending
    }
  }

  private var selected: ModelLibrary.LoRA? {
    library.loras.first { $0.file == selection }
  }

  var body: some View {
    content
      .overlay {
        if dropTargeted {
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .padding(4)
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        library.prepareImport(urls)
        return true
      } isTargeted: { dropTargeted = $0 }
      .toolbar {
        ToolbarItem {
          Picker("Family", selection: $family) {
            Text("All families").tag(String?.none)
            ForEach(families, id: \.self) { Text(ModelLibrary.familyName($0)).tag(Optional($0)) }
          }
          .frame(minWidth: 160)
        }
        ToolbarItem {
          Button("Import…", systemImage: "plus") { chooseFiles() }
            .help("Import .safetensors LoRA files (or drop them here)")
        }
      }
      .searchable(text: $search, placement: .toolbar, prompt: "Filter LoRAs")
      .detailInspector(selection: selection, isEmpty: selected == nil, clearSelection: { selection = nil }) {
        Group {
          if let selected {
            LoRADetail(lora: selected, delete: { pendingDelete = selected })
              .id(selected.file)
          } else {
            ContentUnavailableView(
              "No selection", systemImage: "slider.horizontal.3",
              description: Text("Select a LoRA to rename it or change its trigger words."))
          }
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
      }
      .sheet(
        isPresented: Binding(
          get: { !library.importing.isEmpty },
          set: { if !$0 { library.cancelImports() } })
      ) {
        LoRAImportSheet()
      }
      .confirmationDialog(
        "Move \(pendingDelete?.name ?? "this LoRA") to the Trash?",
        isPresented: Binding(
          get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        presenting: pendingDelete
      ) { lora in
        Button("Move to Trash", role: .destructive) {
          pendingDelete = nil
          library.delete(lora)
          if selection == lora.file { selection = filtered.first?.file }
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: { lora in
        Text("\(lora.file) is moved to the Trash and removed from custom_lora.json.")
      }
      .libraryErrorAlert()
      .deleteCommand { pendingDelete = selected }
      .onAppear { library.reloadLoRAs() }
  }

  @ViewBuilder
  private var content: some View {
    if library.loras.isEmpty {
      ContentUnavailableView {
        Label("No LoRAs", systemImage: "slider.horizontal.3")
      } description: {
        Text("Drop .safetensors LoRA files here, or click Import.")
      } actions: {
        Button("Import…") { chooseFiles() }
      }
    } else if filtered.isEmpty {
      ContentUnavailableView.search(text: search)
    } else {
      Table(filtered, selection: $selection) {
        TableColumn("Name") { lora in
          HStack(spacing: 6) {
            Text(lora.name).lineLimit(1)
            if !lora.isDownloaded {
              Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                .help("\(lora.file) isn't in the models folder")
            }
          }
          .help(lora.file)
        }
        TableColumn("For") { lora in
          Text(lora.family).foregroundStyle(.secondary)
        }
        .width(min: 90, ideal: 130)
        TableColumn("Trigger") { lora in
          Text(lora.prefix.trimmingCharacters(in: .whitespaces)).foregroundStyle(.secondary)
        }
        .width(min: 60, ideal: 120)
        TableColumn("Size") { lora in
          Text(lora.size.map(ModelsView.bytes) ?? "").monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .width(min: 60, ideal: 80)
      }
      .contextMenu(forSelectionType: String.self) { files in
        if let file = files.first, let lora = library.loras.first(where: { $0.file == file }) {
          Button(Finder.revealTitle) { library.reveal(lora.file) }
            .disabled(!lora.isDownloaded)
          Divider()
          Button("Move to Trash", role: .destructive) { pendingDelete = lora }
        }
      }
    }
  }

  private func chooseFiles() {
    fileDialogs.open = FileDialogs.Open(
      types: ModelLibrary.loraExtensions.compactMap { UTType(filenameExtension: $0) },
      multiple: true,
      directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
      message: "Choose LoRA files to import"
    ) { urls in
      library.prepareImport(urls)
    }
  }
}

struct LoRADetail: View {
  let lora: ModelLibrary.LoRA
  let delete: () -> Void
  @Environment(ModelLibrary.self) private var library
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var name = ""
  @State private var prefix = ""

  private var edited: Bool {
    name != lora.name || prefix != lora.prefix
  }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $name)
          .onSubmit(save)
        TextField("Trigger words", text: $prefix, prompt: Text("None"))
          .onSubmit(save)
          .help("Words the LoRA was trained on. Add them to your prompt to bring it in.")
        HStack {
          Spacer()
          Button("Revert") {
            name = lora.name
            prefix = lora.prefix
          }
          Button("Save", action: save)
            .keyboardShortcut(.defaultAction)
        }
        .formRowButtons()
        .disabled(!edited || name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      Section {
        LabeledContent("For", value: lora.family)
        LabeledContent("File") { Text(lora.file).textSelection(.enabled) }
        if let size = lora.size { LabeledContent("Size", value: ModelsView.bytes(size)) }
        ButtonRow {
          Button(Finder.revealTitle) { library.reveal(lora.file) }
            .disabled(!lora.isDownloaded)
          Button("Move to Trash", role: .destructive, action: delete)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      name = lora.name
      prefix = lora.prefix
    }
  }

  private func save() {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard edited, !trimmed.isEmpty else { return }
    library.update(lora, name: trimmed, prefix: prefix)
  }
}

struct LoRAImportSheet: View {
  @Environment(ModelLibrary.self) private var library
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var version: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import LoRAs").font(.headline)
      Text(
        "Each file is converted into the models folder and added to custom_lora.json. Leave the name empty to use the file name and the detected model family."
      )
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(spacing: 10) {
          ForEach(library.importing) { item in
            row(item)
            Divider()
          }
        }
      }
      .frame(minHeight: 120, maxHeight: 320)
      Picker("Model family", selection: $version) {
        Text("Detect automatically").tag(String?.none)
        Divider()
        ForEach(ModelLibrary.families, id: \.version) { family in
          Text(family.name).tag(Optional(family.version))
        }
      }
      .help("Override only if detection picks the wrong family.")
      .disabled(library.isImporting)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { library.cancelImports() }
          .keyboardShortcut(.cancelAction)
          .disabled(library.isImporting)
        Button(library.importing.count == 1 ? "Import" : "Import \(library.importing.count)") {
          library.runImports(version: version)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(library.isImporting)
      }
    }
    .padding(20)
    .frame(width: 520)
  }

  private func row(_ item: ModelLibrary.LoRAImport) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(item.source.lastPathComponent).bold().lineLimit(1).truncationMode(.middle)
        Spacer()
        if let progress = item.progress {
          ProgressView(value: progress).frame(width: 120)
        } else if !library.isImporting {
          Button {
            library.removeImport(item.id)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Don't import this file")
        }
      }
      HStack {
        TextField(
          "Name",
          text: Binding(
            get: { item.name }, set: { library.updateImport(item.id, name: $0) }),
          prompt: Text(item.source.deletingPathExtension().lastPathComponent))
        TextField(
          "Trigger words",
          text: Binding(
            get: { item.prefix }, set: { library.updateImport(item.id, prefix: $0) }),
          prompt: Text("Trigger words"))
      }
      .labelsHidden()
      .disabled(library.isImporting)
    }
  }
}
