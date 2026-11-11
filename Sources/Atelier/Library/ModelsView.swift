@preconcurrency import _MediaGenerationKit
import SwiftUI
import UniformTypeIdentifiers

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
  @State private var pendingMove: ModelLibrary.Move?
  @State private var dropTargeted = false
  @State private var showingH3ImageInstall = false

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

  /// MiniMax H3 Image isn't in the download catalog (it needs two manual downloads and a
  /// conversion), so until it's installed it has a row of its own, shown like a model that isn't
  /// downloaded: under Available and All, under Downloaded while it installs, and by the filter.
  private var showsH3ImageRow: Bool {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown =
      switch filter {
      case .downloaded: library.h3ImageInstall.isRunning
      case .available, .all: true
      }
    return !library.h3ImageInstalled && shown
      && (query.isEmpty || ModelRow.h3ImageName.localizedCaseInsensitiveContains(query))
  }

  /// The filtered catalog, with the MiniMax H3 Image row in its place by name.
  private var rows: [ModelRow] {
    var rows = filtered.map(ModelRow.model)
    if showsH3ImageRow {
      let index = rows.firstIndex {
        $0.name.localizedCaseInsensitiveCompare(ModelRow.h3ImageName) == .orderedDescending
      } ?? rows.endIndex
      rows.insert(.h3Image, at: index)
    }
    return rows
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
          .toolbarNaturalWidth()
        }
        .segmentedToolbarItem()
        #if os(iOS)
          ToolbarSpacer(.fixed)
        #endif
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
      .detailInspector(
        selection: selection, isEmpty: selected == nil && selection != ModelRow.h3ImageID,
        clearSelection: { selection = nil }
      ) {
        Group {
          if selection == ModelRow.h3ImageID {
            H3ImageDetail { showingH3ImageInstall = true }
          } else if let selected {
            ModelDetail(
              model: selected, delete: { pendingDelete = selected },
              move: { pendingMove = library.planMove(selected, to: $0) })
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
      .sheet(isPresented: $showingH3ImageInstall) {
        H3ImageInstallSheet()
      }
      .debugPresents("h3ImageInstall", $showingH3ImageInstall)
      #if DEBUG
        // Download checks: -AtelierDownload FILE starts that model's download once the catalog
        // is in, and logs its progress and any error.
        .task {
          guard let file = UserDefaults.standard.string(forKey: "AtelierDownload") else { return }
          await waitUntil { [library] in !library.catalog.isEmpty }
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
        .moveConfirmation($pendingMove)
        .libraryErrorAlert()
        .deleteCommand {
          if let selected, library.canDelete(selected) { pendingDelete = selected }
        }
        .task {
          if library.catalog.isEmpty { await library.refresh() }
        }
        .onChange(of: library.create.availableModelsDirectories) {
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
    } else if rows.isEmpty, !search.isEmpty {
      ContentUnavailableView.search(text: search)
    } else {
      Table(rows, selection: $selection) {
        TableColumn("Name") { row in
          HStack(spacing: 6) {
            Text(row.name).lineLimit(1)
            if case .model(let model) = row, library.isCustom(model) {
              Text("Imported").font(.caption).foregroundStyle(.secondary)
            }
            #if os(iOS)
              // A compact-width table shows only this column, so it carries the status too.
              if horizontalSizeClass == .compact {
                Spacer()
                status(row)
              }
            #endif
          }
          .help(row.model?.file ?? "")
        }
        TableColumn("Family") { row in
          Text(row.model.map { $0.version ?? "" } ?? ModelLibrary.h3ImageFamily)
            .foregroundStyle(.secondary)
        }
        .width(min: 90, ideal: 140)
        TableColumn("Size") { row in
          Text(row.model.flatMap { library.sizes[$0.file] }.map(Self.bytes) ?? "")
            .monospacedDigit().foregroundStyle(.secondary)
        }
        .width(min: 60, ideal: 80)
        TableColumn("Folder") { row in
          Text(row.model.flatMap { library.folders[$0.file] }.map(library.folderName) ?? "")
            .foregroundStyle(.secondary)
        }
        .width(min: 70, ideal: 110)
        TableColumn("") { row in
          status(row)
        }
        .width(min: 130, ideal: 150)
      }
      .contextMenu(forSelectionType: String.self) { files in
        if files.first == ModelRow.h3ImageID {
          Button("Install…") { showingH3ImageInstall = true }
            .disabled(library.h3ImageInstall.isRunning)
        } else if let file = files.first, let model = library.catalog.first(where: { $0.file == file }) {
          if model.isDownloaded {
            Button(Finder.revealTitle) { library.reveal(model.file) }
            MoveToFolderMenu(library: library, file: model.file, folder: library.folders[model.file], enabled: library.canMove(model)) {
              pendingMove = library.planMove(model, to: $0)
            }
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

  @ViewBuilder
  private func status(_ row: ModelRow) -> some View {
    switch row {
    case .model(let model):
      ModelStatus(model: model, library: library)
    case .h3Image:
      H3ImageStatus(library: library) { showingH3ImageInstall = true }
    }
  }

  private var footer: some View {
    HStack {
      Text("\(library.downloadedCount) downloaded, \(Self.bytes(library.downloadedSize))")
      Spacer()
      if library.isLoadingCatalog { ProgressView().controlSize(.small) }
      AddFolderPicker().controlSize(.small)
      if let free = library.freeSpace { Text("\(Self.bytes(free)) free") }
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

/// A row of the Models list: a catalog model, or MiniMax H3 Image before it's installed, which
/// isn't in the catalog until its install (`H3ImageInstallSheet`) has imported it.
enum ModelRow: Identifiable {
  case model(MediaGenerationResolvedModel)
  case h3Image

  static let h3ImageID = "minimax-h3-image-install"
  static let h3ImageName = "MiniMax H3 Image"

  var id: String { model?.file ?? Self.h3ImageID }
  var name: String { model?.name ?? Self.h3ImageName }
  var model: MediaGenerationResolvedModel? {
    if case .model(let model) = self { model } else { nil }
  }
}

/// The MiniMax H3 Image row's Install button, or the install's progress while it runs.
struct H3ImageStatus: View {
  let library: ModelLibrary
  let install: () -> Void

  var body: some View {
    let state = library.h3ImageInstall
    if state.isRunning {
      Group {
        if let progress = state.progress {
          ProgressView(value: progress).controlSize(.small)
        } else {
          ProgressView().controlSize(.small)
        }
      }
      .help(state.stage.map { $0.title(state.format) } ?? "Installing…")
    } else {
      Button("Install…", action: install)
        .controlSize(.small)
        .formRowButtons()
        .help("Download the MiniMax H3 Image files and convert them on this Mac")
    }
  }
}

/// The detail of the MiniMax H3 Image row, before it's installed.
struct H3ImageDetail: View {
  let install: () -> Void
  @Environment(ModelLibrary.self) private var library

  var body: some View {
    Form {
      Section {
        Text(ModelRow.h3ImageName).font(.headline)
        LabeledContent("Family", value: ModelLibrary.h3ImageFamily)
        Button("Install…", action: install)
          .disabled(library.h3ImageInstall.isRunning)
        Text("Installed from two downloads, converted on this Mac.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Description") {
        Text("Text to image and editing, in 6 steps.").textSelection(.enabled)
      }
    }
    .formStyle(.grouped)
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
        .accessibilityLabel("Cancel download")
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
  let move: (URL) -> Void
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
        if let folder = library.folders[model.file] {
          LabeledContent("Folder", value: library.folderName(folder))
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
            MoveToFolderMenu(
              library: library, file: model.file, folder: library.folders[model.file], enabled: library.canMove(model), choose: move)
            Button("Move to Trash", role: .destructive, action: delete)
              .disabled(!library.canDelete(model))
          }
          MoveProgressRow(file: model.file)
          // 4-bit S is only made by the MiniMax H3 Image install.
          ForEach([MOSSImporter.EightBit.palettized, .rowwise], id: \.self) { format in
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

/// "Move to" with the other models folders. Always there, disabled when a move can't start now
/// or there's only one folder; a folder that already has the file is disabled in it.
/// Gets the library passed in, for context menus built without the window's environment.
struct MoveToFolderMenu: View {
  let library: ModelLibrary
  let file: String
  let folder: URL?
  let enabled: Bool
  let choose: (URL) -> Void

  var body: some View {
    Menu("Move To") {
      ForEach(library.destinations(from: folder), id: \.self) { destination in
        Button(library.folderName(destination)) { choose(destination) }
          .disabled(library.has(file, in: destination))
      }
    }
    .disabled(!enabled)
    .help(
      library.hasOtherFolders
        ? "Move its files to another models folder"
        : "Add another models folder in Settings to move files between folders")
  }
}

/// The progress of a move of `file`, while there is one.
struct MoveProgressRow: View {
  let file: String
  @Environment(ModelLibrary.self) private var library

  var body: some View {
    if let moving = library.moving, moving.file == file {
      HStack(spacing: 6) {
        VStack(alignment: .leading) {
          ProgressView(value: moving.fraction)
          Text(
            moving.fraction == nil
              ? "Waiting to move to \(library.folderName(moving.destination))…"
              : "Moving to \(library.folderName(moving.destination))…"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Button {
          library.cancelMove()
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .help("Cancel move")
        .accessibilityLabel("Cancel move")
      }
    }
  }
}

extension View {
  /// Asks before running a planned move, saying what it moves and copies.
  func moveConfirmation(_ move: Binding<ModelLibrary.Move?>) -> some View {
    modifier(MoveConfirmation(move: move))
  }
}

private struct MoveConfirmation: ViewModifier {
  @Binding var move: ModelLibrary.Move?
  @Environment(ModelLibrary.self) private var library

  func body(content: Content) -> some View {
    content.confirmationDialog(
      "Move \(move?.name ?? "it") to \(move.map { library.folderName($0.destination) } ?? "another folder")?",
      isPresented: Binding(get: { move != nil }, set: { if !$0 { move = nil } }),
      presenting: move
    ) { planned in
      Button("Move") {
        move = nil
        library.runMove(planned)
      }
      Button("Cancel", role: .cancel) { move = nil }
    } message: { planned in
      Text(library.describe(planned))
    }
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
        "Each checkpoint is converted into the folder below and added to its custom.json, then the text encoders and VAE it needs are downloaded there. Leave the name empty to use the file name."
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
      AddFolderPicker()
        .disabled(library.isImportingModels)
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
    .sheetPadding()
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
          .accessibilityLabel("Don't import this file")
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

/// Guided install of MiniMax H3 Image: links to the two files, a picker for the downloads, and the
/// progress of `ModelLibrary.installH3Image`.
struct H3ImageInstallSheet: View {
  @Environment(ModelLibrary.self) private var library
  @Environment(\.dismiss) private var dismiss
  @State private var choosing = false
  @State private var trashFullPrecision = true
  @State private var format = MOSSImporter.EightBit.rowwise

  private var install: ModelLibrary.H3ImageInstall { library.h3ImageInstall }

  private static let modelURL = URL(
    string: "https://huggingface.co/Comfy-Org/MiniMax-H3-Image/resolve/main/diffusion_models/minimax_h3_image_pruned_bf16.safetensors")!
  private static let vaeURL = URL(
    string: "https://huggingface.co/Comfy-Org/MiniMax-H3-Image/resolve/main/vae/minimax_h3_image_vae_fp16.safetensors")!
  private static let licenseURL = URL(
    string: "https://huggingface.co/MiniMaxAI/MiniMax-H3-Image/blob/main/LICENSE")!

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Install MiniMax H3 Image").font(.headline)
      Text(
        "MiniMax H3 Image makes images from text and edits pictures, in 6 steps. It's converted on this Mac from two downloads. The install needs about 90 GB of free space while it runs and about \(format == .rowwise4Bit ? "40" : "50") GB afterwards: the \(Self.size(format)) model, the 1.2 GB VAE and the 26 GB text encoder, if you don't have it yet. Its license, the MiniMax-H3-Image Community License, doesn't cover use in the European Union, the United Kingdom, South Korea or the United States."
      )
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Link("Read the license", destination: Self.licenseURL).font(.callout)

      Divider()
      Text("1. Download").font(.subheadline.bold())
      VStack(alignment: .leading, spacing: 4) {
        Link("minimax_h3_image_pruned_bf16.safetensors (40 GB)", destination: Self.modelURL)
        Link("minimax_h3_image_vae_fp16.safetensors (1.2 GB)", destination: Self.vaeURL)
      }
      .font(.callout)

      Divider()
      Text("2. Import").font(.subheadline.bold())
      HStack {
        Button("Choose Downloaded Files…") { choosing = true }
          .disabled(install.isRunning)
        Spacer()
      }
      Picker("Install", selection: $format) {
        Text("8-bit S (\(Self.size(.rowwise)))").tag(MOSSImporter.EightBit.rowwise)
        Text("4-bit S (\(Self.size(.rowwise4Bit)), for Macs with less memory; takes a few hours to write)").tag(MOSSImporter.EightBit.rowwise4Bit)
      }
      .disabled(install.isRunning)
      Toggle("Move the full-precision copy to the Trash afterwards", isOn: $trashFullPrecision)
        .disabled(install.isRunning)
      AddFolderPicker()
        .disabled(install.isRunning)

      VStack(alignment: .leading, spacing: 6) {
        ForEach(ModelLibrary.H3ImageInstall.Stage.allCases, id: \.self) { stage in
          stageRow(stage)
        }
        Text("The text encoder then downloads in the Models list.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = install.error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      } else if install.isFinished {
        Label("MiniMax H3 Image is installed.", systemImage: "checkmark.circle")
          .font(.callout)
      }

      HStack {
        Spacer()
        Button(install.isFinished ? "Done" : "Cancel", role: install.isFinished ? nil : .cancel) { dismiss() }
          .keyboardShortcut(install.isFinished ? .defaultAction : .cancelAction)
          .disabled(install.isRunning)
      }
    }
    .sheetPadding()
    .sheetFrame(width: 520)
    .interactiveDismissDisabled(install.isRunning)
    .onAppear { library.resetH3ImageInstall() }
    .fileImporter(
      isPresented: $choosing,
      allowedContentTypes: [UTType(filenameExtension: "safetensors") ?? .data],
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result, !urls.isEmpty else { return }
      let trash = trashFullPrecision
      let format = format
      Task { await library.installH3Image(files: urls, format: format, trashFullPrecision: trash) }
    }
    .fileDialogDefaultDirectory(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
  }

  /// The size of the copy the install makes in `format`.
  private static func size(_ format: MOSSImporter.EightBit) -> String {
    format == .rowwise4Bit ? "12 GB" : "21 GB"
  }

  private func stageRow(_ stage: ModelLibrary.H3ImageInstall.Stage) -> some View {
    HStack(spacing: 8) {
      if install.completed.contains(stage) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      } else if install.stage == stage {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: "circle").foregroundStyle(.secondary)
      }
      Text(stage.title(install.isRunning || install.isFinished ? install.format : format))
      Spacer()
      if install.stage == stage, let progress = install.progress {
        ProgressView(value: progress).frame(width: 120)
      }
    }
    .font(.callout)
    .foregroundStyle(install.completed.contains(stage) || install.stage == stage ? .primary : .secondary)
  }
}
