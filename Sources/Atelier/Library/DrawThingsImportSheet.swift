import SwiftUI

/// Import from Draw Things: choose its folder, see what's there, tick what to bring over. Offered
/// once at first launch and from Settings ▸ Models. Nothing changes until Import.
struct DrawThingsImportSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(PresetStore.self) private var presets
  @Environment(HistoryStore.self) private var history
  @Environment(ModelLibrary.self) private var library
  @Environment(Navigation.self) private var navigation
  @Environment(\.dismiss) private var dismiss
  @State private var importer = DrawThingsImporter()
  @State private var choosing = false
  /// Runs once this sheet is gone: a sheet can't open while another is still up.
  @State private var afterDismiss: (() -> Void)?
  @State private var isDropTargeted = false

  var body: some View {
    @Bindable var importer = importer
    VStack(alignment: .leading, spacing: 12) {
      Text("Import from Draw Things").font(.headline)
      if let summary = importer.summary {
        ForEach(summary, id: \.self) { Text($0) }
        Spacer(minLength: 0)
      } else if !importer.selection.folders.isEmpty {
        review
      } else {
        chooser
      }
      footer
    }
    .sheetPadding()
    .sheetFrame(width: 560, height: 560)
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { Task { await importer.add(url, create: create) } }
    }
    .fileDialogDefaultDirectory(DrawThingsApp.documents)
    .onDisappear { afterDismiss?() }
    #if DEBUG
      // For layout checks: -AtelierDrawThingsFolders '(A, B)' goes straight to reviewing them.
      .task {
        for path in UserDefaults.standard.stringArray(forKey: "AtelierDrawThingsFolders") ?? [] {
          await importer.add(URL(fileURLWithPath: path), create: create)
        }
        // -AtelierDrawThingsImportFile FILE acts as an import button in the list would.
        if let file = UserDefaults.standard.string(forKey: "AtelierDrawThingsImportFile") {
          try? await Task.sleep(for: .seconds(1))
          showImport(.models) { library.prepareModelImport([URL(fileURLWithPath: file)]) }
        }
      }
    #endif
  }

  private var chooser: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Atelier can share Draw Things' models and bring over its saved configurations and projects. You choose what, after it has looked.")
      #if os(macOS)
        Text("macOS only lets Atelier read Draw Things' folder if you choose it yourself. Choose its Documents folder. If its models are somewhere else, you can add that folder next.")
          .foregroundStyle(.secondary)
        // The panel doesn't always open there: macOS won't show the folder until it's been chosen.
        if let documents = DrawThingsApp.documents {
          Text("If the panel opens somewhere else, press ⌘⇧G and paste this path:")
            .foregroundStyle(.secondary)
          HStack {
            Text(documents.path)
              .font(.callout.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
            Button("Copy") { Clipboard.copy(documents.path) }
          }
        }
      #else
        Text("Choose the folder Files shows for Draw Things. If its models are somewhere else, you can add that folder next.")
          .foregroundStyle(.secondary)
      #endif
      Button("Choose Folder…") { choosing = true }
        .disabled(importer.isScanning)
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), style: StrokeStyle(lineWidth: 1, dash: [4]))
        .overlay {
          if importer.isScanning {
            ProgressView("Looking through the folder…")
          } else {
            Text("Or drop the folder here").foregroundStyle(.secondary)
          }
        }
        .frame(minHeight: 120)
        .dropDestination(for: URL.self, action: { urls, _ in
          guard let url = urls.first else { return false }
          Task { await importer.add(url, create: create) }
          return true
        }, isTargeted: { isDropTargeted = $0 })
      if let problem = importer.problem {
        Text(problem).foregroundStyle(.red)
      }
      Spacer(minLength: 0)
    }
  }

  private var review: some View {
    @Bindable var importer = importer
    let selection = importer.selection
    let toShare = importer.foldersToShare(create: create)
    return List {
      Section("Folders") {
        ForEach(selection.folders, id: \.folder) { contents in
          HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(contents.folder.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Remove", systemImage: "minus.circle") {
              Task { await importer.remove(contents, create: create) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(importer.isImporting)
            .help("Leave this folder out of the import")
          }
        }
        Button("Add Another Folder…") { choosing = true }
          .disabled(importer.isScanning || importer.isImporting)
        if let problem = importer.problem {
          Text(problem).foregroundStyle(.red)
        }
      }
      Section("Found") {
        Toggle(isOn: $importer.sharesModels) { modelsLabel(selection, toShare: toShare) }
          .disabled(toShare.isEmpty)
        Toggle(isOn: $importer.importsConfigurations) {
          row("Saved Configurations", detail: importer.configurations.isEmpty
            ? "None found."
            : "\(importer.configurations.count) become presets. Their prompts stay behind, since presets hold settings only.")
        }
        .disabled(importer.configurations.isEmpty)
        Toggle(isOn: $importer.importsProjects) {
          row("Projects", detail: selection.projects.isEmpty
            ? "None found."
            : "Copies \(selection.projects.count) (\(ModelsView.bytes(selection.projectsSize))) into Atelier's projects folder and leaves the originals. Quit Draw Things first so they copy complete.")
        }
        .disabled(selection.projects.isEmpty)
      }
      Section {
        // Above the list: with hundreds of files, nothing below it gets seen.
        if importer.catalogMissing {
          Text("The community catalog couldn't be reached, so Atelier used the copy it shipped with. This list may include newer models it doesn't know yet. Try again when you're online.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if !importer.unmatched.isEmpty, let documents = DrawThingsApp.documents, DrawThingsApp.isDetected, !selection.contains(documents) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Draw Things can keep its lists of imported models and LoRAs in its Documents folder, even when the files are on another drive. Add that folder first: it may account for these files.")
            Button("Add Documents Folder…") { addDocuments(documents) }
              .disabled(importer.isScanning || importer.isImporting)
          }
        }
        bulkActions
        if importer.unmatched.isEmpty {
          Text("None.").foregroundStyle(.secondary)
        }
        ForEach(importer.unmatched) { file in unmatchedRow(file) }
      } header: {
        Text("Model Files Atelier Can't Match")
      }
    }
  }

  /// Adds Draw Things' Documents, directly if macOS already allows it, else through the panel, which
  /// opens there and is what gets it allowed.
  private func addDocuments(_ documents: URL) {
    if (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) != nil {
      Task { await importer.add(documents, create: create) }
    } else {
      choosing = true
    }
  }

  /// One action for many files, for libraries too large to set by hand. Each shows only with two or
  /// more files to act on.
  @ViewBuilder private var bulkActions: some View {
    let unmatched = importer.unmatched
    let converted = unmatched.filter { $0.kind == .converted && importer.canList($0, create: create) }
    let originals = unmatched.filter { $0.kind == .unconverted }
    if converted.filter(\.isLoRA).count > 1 || converted.count(where: { !$0.isLoRA }) > 1 || originals.count > 1 {
      HStack {
        familyMenu(for: converted.filter(\.isLoRA), noun: "LoRAs", isLoRA: true)
        familyMenu(for: converted.filter { !$0.isLoRA }, noun: "Models", isLoRA: false)
        if originals.count > 1 {
          Button("Import \(originals.count) as LoRAs…") { showImport(.loras) { library.prepareImport(originals.map(\.url)) } }
          Button("Import \(originals.count) as Models…") { showImport(.models) { library.prepareModelImport(originals.map(\.url)) } }
        }
      }
      .disabled(importer.isImporting)
    }
  }

  @ViewBuilder private func familyMenu(for files: [DrawThingsContents.UnmatchedFile], noun: String, isLoRA _: Bool) -> some View {
    if files.count > 1, let first = files.first {
      Menu("Set \(files.count) \(noun) To") {
        ForEach(importer.familyChoices(for: first), id: \.version) { family in
          Button(family.name) { for file in files { importer.families[file.url] = family.version } }
        }
        Divider()
        Button("Clear") { for file in files { importer.families[file.url] = nil } }
      }
      .fixedSize()
      .help("Applies one family to all of them. Listed when you click Import.")
    }
  }

  private func modelsLabel(_ selection: DrawThingsSelection, toShare: [URL]) -> some View {
    var detail = "No models folder found."
    if !selection.modelsFolders.isEmpty {
      let count = selection.modelFileCount
      detail = "\(count) model file\(count == 1 ? "" : "s"), used where they are. \(selection.registeredCount) imported model\(selection.registeredCount == 1 ? "" : "s") and LoRA\(selection.registeredCount == 1 ? "" : "s") listed in custom.json and custom_lora.json. "
      if toShare.isEmpty {
        detail += "Atelier already uses these folders."
      } else if count == 0 {
        detail += "If Draw Things keeps its models on another drive, add that folder too."
      } else if importer.replacesModelsFolder(create: create) {
        detail += "\(toShare[0].lastPathComponent) becomes Atelier's models folder, so downloads go there too."
      } else {
        detail += "\(toShare.count == 1 ? "Added as an additional folder" : "Added as additional folders"); downloads still go to \(URL(fileURLWithPath: create.modelsDirectory).lastPathComponent)."
      }
    }
    return row("Models Folders", detail: detail)
  }

  private func row(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func unmatchedRow(_ file: DrawThingsContents.UnmatchedFile) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(file.name).lineLimit(1).truncationMode(.middle)
        Spacer()
        Text(ModelsView.bytes(file.size)).foregroundStyle(.secondary)
      }
      Text(file.reason).font(.caption).foregroundStyle(.secondary)
      HStack {
        switch file.kind {
        case .unconverted:
          Button("Import as Model…") { showImport(.models) { library.prepareModelImport([file.url]) } }
          Button("Import as LoRA…") { showImport(.loras) { library.prepareImport([file.url]) } }
        case .converted:
          Picker("Model Family", selection: familyBinding(file)) {
            Text("Choose…").tag(String?.none)
            ForEach(importer.familyChoices(for: file), id: \.version) { family in
              Text(family.name).tag(String?.some(family.version))
            }
          }
          .fixedSize()
          .disabled(!importer.canList(file, create: create))
          .help("Which family this \(file.isLoRA ? "LoRA is for" : "model is"). Listed when you click Import.")
          if !importer.canList(file, create: create) {
            Text("Tick Models Folders first.").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .disabled(importer.isImporting)
    }
  }

  private func familyBinding(_ file: DrawThingsContents.UnmatchedFile) -> Binding<String?> {
    Binding(get: { importer.families[file.url] }, set: { importer.families[file.url] = $0 })
  }

  /// The import sheets belong to the Models and LoRAs screens, so this one gives way to them.
  private func showImport(_ section: ContentView.Section, _ prepare: @escaping () -> Void) {
    afterDismiss = {
      navigation.section = section
      prepare()
    }
    dismiss()
  }

  private var footer: some View {
    HStack {
      if importer.isImporting { ProgressView().controlSize(.small) }
      Spacer()
      if importer.summary != nil {
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      } else {
        Button("Not Now", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(importer.isImporting)
        Button("Import") {
          Task { await importer.run(create: create, presets: presets, history: history, library: library) }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!importer.canImport)
      }
    }
  }
}
