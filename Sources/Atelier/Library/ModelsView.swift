import SwiftUI
import UniformTypeIdentifiers
import _MediaGenerationKit

struct ModelsView: View {
  enum Filter: String, CaseIterable, Identifiable {
    case downloaded = "Downloaded"
    case available = "Available"
    case all = "All"
    var id: String { rawValue }
  }

  @Environment(ModelLibrary.self) private var library
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var search = ""
  @AppStorage("modelsFilter") private var filter = Filter.downloaded
  @State private var selection: String?
  @State private var pendingDelete: MediaGenerationResolvedModel?
  @State private var dropTargeted = false

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
      .overlay {
        if dropTargeted {
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .padding(4)
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        library.prepareModelImport(urls)
        return true
      } isTargeted: { dropTargeted = $0 }
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
        ToolbarItem {
          Button("Import…", systemImage: "plus") { chooseFiles() }
            .help("Import .safetensors model checkpoints (or drop them here)")
        }
      }
      .searchable(text: $search, placement: .toolbar, prompt: "Filter models")
      .safeAreaBar(edge: .bottom, spacing: 0) { footer }
      .detailInspector(selection: selection, isEmpty: selected == nil, clearSelection: { selection = nil }) {
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
      .sheet(
        isPresented: Binding(
          get: { !library.importingModels.isEmpty },
          set: { if !$0 { library.cancelModelImports() } })
      ) {
        ModelImportSheet()
      }
      #if DEBUG
        // Download checks: -AtelierDownload FILE starts that model's download once the catalog
        // is in, and logs its progress and any error.
        .task {
          guard let file = UserDefaults.standard.string(forKey: "AtelierDownload") else { return }
          while library.catalog.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
          guard let model = library.catalog.first(where: { $0.file == file }) else {
            return NSLog("AtelierDownload: %@ isn't in the catalog", file)
          }
          library.download(model)
          while library.downloads[file] != nil {
            if let progress = library.downloads[file] {
              NSLog("AtelierDownload: %@ %lld of %lld", progress.file, progress.bytesWritten, progress.totalBytes)
            }
            try? await Task.sleep(for: .seconds(2))
          }
          NSLog("AtelierDownload: finished, error: %@", library.errorMessage ?? "none")
        }
      #endif
      .debugPresents("modelImport", .constant(false)) {
        library.prepareModelImport([URL(fileURLWithPath: "/tmp/Example Checkpoint.safetensors")])
      }
      .confirmationDialog(
        "Move \(pendingDelete?.name ?? "this model") to the Trash?",
        isPresented: Binding(
          get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        presenting: pendingDelete
      ) { model in
        Button("Move to Trash", role: .destructive) {
          pendingDelete = nil
          Task {
            await library.delete(model)
            // The deleted model can drop out of the list (or the catalog); show the first one.
            if !filtered.contains(where: { $0.file == selection }) {
              selection = filtered.first?.file
            }
          }
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: { model in
        Text(
          library.isCustom(model)
            ? "\(model.file) is moved to the Trash and removed from custom.json. Shared files such as text encoders and VAEs stay in the models folder."
            : "\(model.file) is moved to the Trash. Shared files such as text encoders and VAEs stay in the models folder."
        )
      }
      .libraryErrorAlert()
      .deleteCommand {
        if let selected, library.canDelete(selected) { pendingDelete = selected }
      }
      .task {
        if library.catalog.isEmpty { await library.refresh() }
      }
      .onChange(of: library.create.modelsDirectory) {
        Task { await library.refresh() }
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
            #if os(iOS)
              // A compact-width table shows only this column, so it carries the status too.
              if horizontalSizeClass == .compact {
                Spacer()
                ModelStatus(model: model, library: library)
              }
            #endif
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
            Button(Finder.revealTitle) { library.reveal(model.file) }
            Divider()
            Button("Move to Trash", role: .destructive) { pendingDelete = model }
              .disabled(!library.canDelete(model))
          } else if library.downloads[model.file] != nil {
            Button("Cancel Download") { library.cancelDownload(model.file) }
          } else if library.isCustom(model) {
            Button("Remove from Library", role: .destructive) { pendingDelete = model }
          } else {
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
  }

  private func chooseFiles() {
    fileDialogs.open = FileDialogs.Open(
      types: ModelLibrary.checkpointExtensions.compactMap { UTType(filenameExtension: $0) },
      multiple: true,
      directory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
      message: "Choose model checkpoints to import"
    ) { urls in
      library.prepareModelImport(urls)
    }
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
        // In a table row on iPad, a plain button's tap selects the row instead.
        .formRowButtons()
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
  @Environment(FileDialogs.self) private var fileDialogs

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
          ButtonRow {
            Button(Finder.revealTitle) { library.reveal(model.file) }
            Button("Move to Trash", role: .destructive, action: delete)
              .disabled(!library.canDelete(model))
          }
          ForEach(MOSSImporter.EightBit.allCases, id: \.self) { format in
            let output = ModelLibrary.eightBitFile(for: model.file, format)
            if let progress = library.quantizing[output] {
              VStack(alignment: .leading) {
                ProgressView(value: progress)
                Text("Writing an \(format.title) copy…").font(.caption)
                  .foregroundStyle(.secondary)
              }
            } else if library.canMake8BitCopy(model, format) {
              Button("Make \(format.title) Copy") { library.make8BitCopy(model, format) }
                .help(
                  format == .palettized
                    ? "Writes an 8-bit version, about half the size, like Draw Things' \"8-bit\" models. Slow to write."
                    : "Writes an 8-bit S version, about half the size, like Draw Things' \"8-bit S\" models."
                )
            }
          }
        } else if library.isCustom(model) {
          Text("This imported model's file isn't in the models folder.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Remove from Library", role: .destructive, action: delete)
            .disabled(!library.canDelete(model))
        } else {
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

struct ModelImportSheet: View {
  @Environment(ModelLibrary.self) private var library
  @Environment(FileDialogs.self) private var fileDialogs

  private var importable: Int { library.importingModels.count(where: \.canImport) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import Models").font(.headline)
      Text(
        "Each checkpoint is converted into the models folder and added to custom.json, then the text encoders and VAE it needs are downloaded. Leave the name empty to use the file name."
      )
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(spacing: 10) {
          ForEach(library.importingModels) { item in
            row(item)
            Divider()
          }
        }
      }
      .frame(minHeight: 120, maxHeight: 320)
      if library.isImportingModels {
        Text("Converting a checkpoint takes a few minutes and a lot of memory.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { library.cancelModelImports() }
          .keyboardShortcut(.cancelAction)
          .disabled(library.isImportingModels)
        Button(importable == 1 ? "Import" : "Import \(importable)") {
          library.runModelImports()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(library.isImportingModels || importable == 0)
      }
    }
    .padding(20)
    .sheetFrame(width: 520)
  }

  private func row(_ item: ModelLibrary.ModelImport) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(item.source.lastPathComponent).bold().lineLimit(1).truncationMode(.middle)
        Spacer()
        if let progress = item.progress {
          ProgressView(value: progress).frame(width: 120)
        } else if !library.isImportingModels {
          Button {
            library.removeModelImport(item.id)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Don't import this file")
        }
      }
      Group {
        if item.isInspecting {
          Text("Detecting model family…")
        } else if let problem = item.problem {
          Label(problem, systemImage: "exclamationmark.triangle")
        } else if let family = item.family {
          Text("Detected: \(family)")
        }
      }
      .font(.caption).foregroundStyle(.secondary)
      if item.problem == nil {
        TextField(
          "Name",
          text: Binding(
            get: { item.name }, set: { library.updateModelImport(item.id, name: $0) }),
          prompt: Text(item.source.deletingPathExtension().lastPathComponent)
        )
        .labelsHidden()
        .disabled(library.isImportingModels)
      }
    }
  }
}
