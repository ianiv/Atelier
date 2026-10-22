import SwiftUI
import UniformTypeIdentifiers
import _MediaGenerationKit

// MARK: - Models

struct ModelsView: View {
  enum Filter: String, CaseIterable, Identifiable {
    case downloaded = "Downloaded"
    case available = "Available"
    case all = "All"
    var id: String { rawValue }
  }

  @Environment(ModelLibrary.self) private var library
  @State private var search = ""
  @AppStorage("modelsFilter") private var filter = Filter.downloaded
  @State private var selection: String?
  @State private var pendingDelete: MediaGenerationResolvedModel?

  private var filtered: [MediaGenerationResolvedModel] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return library.catalog.filter { model in
      let downloading = library.downloads[model.file] != nil
      let shown =
        switch filter {
        case .downloaded: model.isDownloaded || downloading
        case .available: !model.isDownloaded
        case .all: true
        }
      return shown
        && (query.isEmpty || model.name.localizedCaseInsensitiveContains(query)
          || model.file.localizedCaseInsensitiveContains(query)
          || (model.version ?? "").localizedCaseInsensitiveContains(query))
    }
  }

  private var selected: MediaGenerationResolvedModel? {
    library.catalog.first { $0.file == selection }
  }

  var body: some View {
    table
      .toolbar {
        ToolbarItem {
          Picker("Show", selection: $filter) {
            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
        }
        ToolbarItem {
          Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await library.refresh() }
          }
          .disabled(library.isLoadingCatalog)
          .help("Reload the model catalog and the models folder")
        }
      }
      .searchable(text: $search, placement: .toolbar, prompt: "Filter models")
      .safeAreaInset(edge: .bottom, spacing: 0) { footer }
      .inspector(isPresented: .constant(true)) {
        Group {
          if let selected {
            ModelDetail(model: selected, delete: { pendingDelete = selected })
          } else {
            ContentUnavailableView(
              "No selection", systemImage: "shippingbox",
              description: Text("Select a model to see its details."))
          }
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
      }
      .confirmationDialog(
        "Move \(pendingDelete?.name ?? "this model") to the Trash?",
        isPresented: Binding(
          get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        presenting: pendingDelete
      ) { model in
        Button("Move to Trash", role: .destructive) {
          pendingDelete = nil
          Task { await library.delete(model) }
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: { model in
        Text(
          "\(model.file) is moved to the Trash. Shared files such as text encoders and VAEs stay in the models folder."
        )
      }
      .libraryErrorAlert()
      .onDeleteCommand {
        if let selected, library.canDelete(selected) { pendingDelete = selected }
      }
      .task {
        if library.catalog.isEmpty { await library.refresh() }
      }
  }

  @ViewBuilder
  private var table: some View {
    if library.catalog.isEmpty {
      if library.isLoadingCatalog {
        ProgressView("Loading catalog…")
      } else {
        ContentUnavailableView(
          "No models", systemImage: "shippingbox",
          description: Text("The model catalog couldn't be loaded."))
      }
    } else if filtered.isEmpty && !search.isEmpty {
      ContentUnavailableView.search(text: search)
    } else {
      Table(filtered, selection: $selection) {
        TableColumn("Name") { model in
          HStack(spacing: 6) {
            Text(model.name).lineLimit(1)
            if library.isCustom(model) {
              Text("Imported").font(.caption).foregroundStyle(.secondary)
            }
          }
          .help(model.file)
        }
        TableColumn("Family") { model in
          Text(model.version ?? "").foregroundStyle(.secondary)
        }
        .width(min: 90, ideal: 140)
        TableColumn("Size") { model in
          Text(library.sizes[model.file].map(Self.bytes) ?? "")
            .monospacedDigit().foregroundStyle(.secondary)
        }
        .width(min: 60, ideal: 80)
        TableColumn("") { model in
          ModelStatus(model: model, library: library)
        }
        .width(min: 130, ideal: 150)
      }
      .contextMenu(forSelectionType: String.self) { files in
        if let file = files.first, let model = library.catalog.first(where: { $0.file == file }) {
          if model.isDownloaded {
            Button("Reveal in Finder") { library.reveal(model.file) }
            Divider()
            Button("Move to Trash", role: .destructive) { pendingDelete = model }
              .disabled(!library.canDelete(model))
          } else if library.downloads[model.file] != nil {
            Button("Cancel Download") { library.cancelDownload(model.file) }
          } else if !library.isCustom(model) {
            Button("Download") { library.download(model) }
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Text(
        "\(library.downloadedCount) downloaded, \(Self.bytes(library.downloadedSize))"
          + (library.freeSpace.map { ", \(Self.bytes($0)) free" } ?? ""))
      Spacer()
      if library.isLoadingCatalog { ProgressView().controlSize(.small) }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
  }

  static func bytes(_ count: Int64) -> String {
    count.formatted(.byteCount(style: .file))
  }
}

/// Download button, progress or "Downloaded" for one catalog row. Gets the library passed in:
/// Table cells can be rebuilt in hosting views that lack the window's environment objects.
struct ModelStatus: View {
  let model: MediaGenerationResolvedModel
  let library: ModelLibrary

  var body: some View {
    if let download = library.downloads[model.file] {
      HStack(spacing: 6) {
        if let fraction = download.fraction {
          ProgressView(value: fraction).controlSize(.small)
        } else {
          ProgressView().controlSize(.small)
        }
        Button {
          library.cancelDownload(model.file)
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .help("Cancel download")
      }
      .help(Self.describe(download))
    } else if model.isDownloaded {
      Label("Downloaded", systemImage: "checkmark.circle.fill")
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
    } else if library.isCustom(model) {
      Text("File missing").foregroundStyle(.secondary)
        .help("This imported model's file isn't in the models folder.")
    } else {
      Button("Download") { library.download(model) }
        .controlSize(.small)
    }
  }

  static func describe(_ download: ModelLibrary.Download) -> String {
    guard download.totalFiles > 0 else { return "Checking files…" }
    let file = "\(download.file) (\(download.fileIndex) of \(download.totalFiles))"
    guard download.totalBytes > 0 else { return file }
    return
      "\(file): \(ModelsView.bytes(download.bytesWritten)) of \(ModelsView.bytes(download.totalBytes))"
  }
}

struct ModelDetail: View {
  let model: MediaGenerationResolvedModel
  let delete: () -> Void
  @Environment(ModelLibrary.self) private var library

  var body: some View {
    Form {
      Section {
        Text(model.name).font(.headline)
        LabeledContent("File") { Text(model.file).textSelection(.enabled) }
        if let version = model.version { LabeledContent("Family", value: version) }
        if let size = library.sizes[model.file] {
          LabeledContent("Size on disk", value: ModelsView.bytes(size))
        }
        if let download = library.downloads[model.file] {
          VStack(alignment: .leading) {
            ProgressView(value: download.fraction)
            Text(ModelStatus.describe(download)).font(.caption).foregroundStyle(.secondary)
          }
          Button("Cancel Download") { library.cancelDownload(model.file) }
        } else if model.isDownloaded {
          HStack {
            Button("Reveal in Finder") { library.reveal(model.file) }
            Button("Move to Trash", role: .destructive, action: delete)
              .disabled(!library.canDelete(model))
          }
        } else if !library.isCustom(model) {
          Button("Download") { library.download(model) }
          Text("Also downloads the text encoders and other files it needs.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let link = model.huggingFaceLink, let url = URL(string: link) {
          Link("Hugging Face page", destination: url)
        }
      }
      if !model.description.isEmpty {
        Section("Description") {
          Text(model.description).textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - LoRAs

struct LoRAsView: View {
  @Environment(ModelLibrary.self) private var library
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
      .inspector(isPresented: .constant(true)) {
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
          if selection == lora.file { selection = nil }
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: { lora in
        Text("\(lora.file) is moved to the Trash and removed from custom_lora.json.")
      }
      .libraryErrorAlert()
      .onDeleteCommand { pendingDelete = selected }
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
          Button("Reveal in Finder") { library.reveal(lora.file) }
            .disabled(!lora.isDownloaded)
          Divider()
          Button("Move to Trash", role: .destructive) { pendingDelete = lora }
        }
      }
    }
  }

  private func chooseFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = ModelLibrary.loraExtensions.compactMap {
      UTType(filenameExtension: $0)
    }
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
      .first
    panel.message = "Choose LoRA files to import"
    if panel.runModal() == .OK {
      library.prepareImport(panel.urls)
    }
  }
}

struct LoRADetail: View {
  let lora: ModelLibrary.LoRA
  let delete: () -> Void
  @Environment(ModelLibrary.self) private var library
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
        .disabled(!edited || name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      Section {
        LabeledContent("For", value: lora.family)
        LabeledContent("File") { Text(lora.file).textSelection(.enabled) }
        if let size = lora.size { LabeledContent("Size", value: ModelsView.bytes(size)) }
        HStack {
          Button("Reveal in Finder") { library.reveal(lora.file) }
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

extension View {
  /// Shows ModelLibrary's error message as an alert.
  func libraryErrorAlert() -> some View {
    modifier(LibraryErrorAlert())
  }
}

private struct LibraryErrorAlert: ViewModifier {
  @Environment(ModelLibrary.self) private var library

  func body(content: Content) -> some View {
    content.alert(
      "Something went wrong",
      isPresented: Binding(
        get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } }),
      actions: { Button("OK") { library.errorMessage = nil } },
      message: { Text(library.errorMessage ?? "") })
  }
}
