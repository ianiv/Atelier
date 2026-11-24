@preconcurrency import _MediaGenerationKit
@preconcurrency import Diffusion
@preconcurrency import ModelZoo
import SwiftUI
import UniformTypeIdentifiers

struct LoRAsView: View {
  @Environment(ModelLibrary.self) private var library
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var pendingTrash: ModelLibrary.TrashBatch?
  @State private var pendingMove: ModelLibrary.MoveBatch?
  #if os(iOS)
    /// Select mode, for picking several rows by touch (a pointer's ⌘- and ⇧-click work anyway).
    @State private var editMode = EditMode.inactive
    /// The selection when Select mode began: the inspector follows it rather than each tap, so
    /// in a narrow window it doesn't open over the list until Done.
    @State private var selectionBeforeSelecting: Set<String> = []
  #endif
  @State private var dropTargeted = false
  @State private var linkRequest: LinkSheetRequest?
  /// Search, family, selection and sort live on the library, so they're still there after
  /// visiting another screen.
  private var search: String { library.loraScreen.search }
  private var family: String? { library.loraScreen.family }
  private var selection: Set<String> {
    get { library.loraScreen.selection }
    nonmutating set { library.loraScreen.selection = newValue }
  }

  private var screen: Bindable<ModelLibrary> { Bindable(library) }

  private var filtered: [ModelLibrary.LoRA] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return library.loras.filter { lora in
      (family == nil || lora.version == family)
        && (query.isEmpty || lora.name.localizedCaseInsensitiveContains(query)
          || lora.file.localizedCaseInsensitiveContains(query)
          || lora.prefix.localizedCaseInsensitiveContains(query))
    }
  }

  /// `filtered` with the values each column sorts by, in the order the column headers ask for.
  private var tableRows: [LoRATableRow] {
    let rows = filtered.map { lora in
      LoRATableRow(
        lora: lora,
        name: lora.name,
        family: lora.family,
        trigger: lora.prefix.trimmingCharacters(in: .whitespaces),
        size: lora.size ?? 0,
        folder: lora.folder.map(library.folderName) ?? "")
    }
    let sortOrder = library.loraScreen.sortOrder
    return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
  }

  private var families: [String] {
    Array(Set(library.loras.map(\.version))).sorted {
      ModelLibrary.familyName($0).localizedStandardCompare(ModelLibrary.familyName($1))
        == .orderedAscending
    }
  }

  /// The selected LoRAs the list shows, in its order; actions never reach a hidden one.
  private var selectedLoRAs: [ModelLibrary.LoRA] {
    let visible = Set(ModelLibrary.visibleSelection(selection, visible: tableRows.map(\.id)))
    return tableRows.map(\.lora).filter { visible.contains($0.file) }
  }

  /// The one selected LoRA, when exactly one is selected.
  private var selected: ModelLibrary.LoRA? {
    let selected = selectedLoRAs
    return selected.count == 1 ? selected[0] : nil
  }

  /// What the inspector follows: on iPad in Select mode, the selection as it was.
  private var inspectorSelection: Set<String> {
    #if os(iOS)
      editMode.isEditing ? selectionBeforeSelecting : selection
    #else
      selection
    #endif
  }

  private func loras(_ files: Set<String>) -> [ModelLibrary.LoRA] {
    tableRows.map(\.lora).filter { files.contains($0.file) }
  }

  private var familyPicker: some View {
    Picker("Family", selection: screen.loraScreen.family) {
      Text("All families").tag(String?.none)
      ForEach(families, id: \.self) { Text(ModelLibrary.familyName($0)).tag(Optional($0)) }
    }
  }

  /// The list, in Select mode on iPad while that's on.
  private var selectableContent: some View {
    #if os(iOS)
      content.environment(\.editMode, $editMode)
    #else
      content
    #endif
  }

  var body: some View {
    selectableContent
      .overlay {
        if dropTargeted {
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .padding(4)
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        // A link dropped from a browser opens the link sheet; files go to the import sheet.
        if let link = urls.first(where: { !$0.isFileURL }) {
          linkRequest = LinkSheetRequest(kind: .lora, link: link.absoluteString)
        } else {
          library.prepareImport(urls)
        }
        return true
      } isTargeted: { dropTargeted = $0 }
      .toolbar {
        #if os(iOS)
          ToolbarItem {
            Menu {
              familyPicker.pickerStyle(.inline)
            } label: {
              Label(
                "Family",
                systemImage: family == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Show only one family")
          }
        #else
          ToolbarItem {
            ToolbarPickerMenu(title: family.map(ModelLibrary.familyName) ?? "All families", width: 130) { familyPicker }
          }
        #endif
        ToolbarItem {
          importMenu
            .help("Import .safetensors LoRA files (or drop them here) or a Hugging Face link")
        }
        #if os(iOS)
          ToolbarItem {
            Button(editMode.isEditing ? "Done" : "Select") {
              if !editMode.isEditing { selectionBeforeSelecting = selection }
              editMode = editMode.isEditing ? .inactive : .active
            }
            .help("Select several LoRAs to move or delete together")
          }
        #endif
        HelpToolbarItem(section: .loras)
      }
      .searchable(text: screen.loraScreen.search, placement: .toolbar, prompt: "Filter LoRAs")
      .detailInspector(
        selection: inspectorSelection, isEmpty: selectedLoRAs.isEmpty, clearSelection: { selection = [] }
      ) {
        Group {
          let selectedLoRAs = selectedLoRAs
          if let selected {
            LoRADetail(
              lora: selected, delete: { pendingTrash = library.planTrash([selected]) },
              move: { pendingMove = library.planMoves([selected], to: $0) })
              .id(selected.file)
          } else if selectedLoRAs.count > 1 {
            LibrarySelectionSummary(
              loras: selectedLoRAs, trash: { pendingTrash = library.planTrash(selectedLoRAs) },
              move: { pendingMove = library.planMoves(selectedLoRAs, to: $0) })
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
          get: { !library.importing.isEmpty && linkRequest == nil },
          set: { if !$0 { library.cancelImports() } })
      ) {
        LoRAImportSheet()
      }
      .sheet(item: $linkRequest) { HuggingFaceImportSheet(request: $0) }
      // A link download that finishes while a link sheet is open hands over to the import sheet,
      // on this screen or the other kind's, so the link sheet closes either way.
      .onChange(of: library.linkHandOffCount) { linkRequest = nil }
      .safeAreaBar(edge: .bottom, spacing: 0) {
        HStack {
          Spacer()
          LinkDownloadsStatus(library: library, kind: .lora)
        }
        .padding(.horizontal, 12)
      }
      .debugPresents("loraImport", .constant(false)) {
        library.prepareImport([URL(fileURLWithPath: "/tmp/Example LoRA.safetensors")])
      }
      .trashConfirmation($pendingTrash) { _ in
        let visible = tableRows.map(\.id)
        selection.formIntersection(visible)
        if selection.isEmpty, let first = visible.first { selection = [first] }
      }
      .moveConfirmation($pendingMove)
      .libraryErrorAlert()
      .deleteCommand { pendingTrash = library.planTrash(selectedLoRAs) }
      // ⌘A, then a search or family that hides rows, mustn't leave hidden rows selected.
      .onChange(of: tableRows.map(\.id)) { _, visible in
        if !library.loras.isEmpty { selection.formIntersection(visible) }
      }
      .task { await library.reloadLoRAsIfRegistriesChanged() }
  }

  private var importMenu: some View {
    Menu {
      Button("Choose Files…", systemImage: "folder") { chooseFiles() }
      Button("From Hugging Face Link…", systemImage: "link") { linkRequest = LinkSheetRequest(kind: .lora) }
    } label: {
      Label("Import…", systemImage: "plus")
    }
  }

  @ViewBuilder
  private var content: some View {
    if library.loras.isEmpty {
      ContentUnavailableView {
        Label("No LoRAs", systemImage: "slider.horizontal.3")
      } description: {
        Text("Drop .safetensors LoRA files here, or click Import.")
      } actions: {
        importMenu.fixedSize()
      }
    } else if filtered.isEmpty {
      ContentUnavailableView.search(text: search)
    } else {
      Table(tableRows, selection: screen.loraScreen.selection, sortOrder: screen.loraScreen.sortOrder) {
        TableColumn("Name", value: \.name) { row in
          let lora = row.lora
          HStack(spacing: 6) {
            Text(lora.name).lineLimit(1)
            if !lora.isDownloaded {
              Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                .help("\(lora.file) isn't in the models folder")
                .accessibilityLabel("\(lora.file) isn't in the models folder")
            }
          }
          .help(lora.file)
        }
        TableColumn("For", value: \.family) { row in
          Text(row.family).foregroundStyle(.secondary)
        }
        .width(min: 90, ideal: 130)
        TableColumn("Trigger", value: \.trigger) { row in
          Text(row.trigger).foregroundStyle(.secondary)
        }
        .width(min: 60, ideal: 120)
        TableColumn("Size", value: \.size) { row in
          Text(row.lora.size.map(ModelsView.bytes) ?? "").monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .width(min: 60, ideal: 80)
        TableColumn("Folder", value: \.folder) { row in
          Text(row.folder).foregroundStyle(.secondary)
        }
        .width(min: 70, ideal: 110)
      }
      .contextMenu(forSelectionType: String.self) { files in
        if files.count > 1 {
          let loras = loras(files)
          let present = loras.filter(\.isDownloaded)
          Button(Finder.revealTitle) { library.reveal(present.map(\.file)) }
            .disabled(!LibrarySelectionSummary.canReveal(present.map(\.folder)))
          MoveToFolderMenu(
            library: library, files: present.map(\.file), folders: present.map(\.folder),
            enabled: present.contains(where: library.canMove)
          ) {
            pendingMove = library.planMoves(loras, to: $0)
          }
          Divider()
          Button("Move to Trash", role: .destructive) { pendingTrash = library.planTrash(loras) }
            .disabled(loras.allSatisfy { library.moving?.files.contains($0.file) == true })
        } else if let file = files.first, let lora = library.loras.first(where: { $0.file == file }) {
          Button(Finder.revealTitle) { library.reveal(lora.file) }
            .disabled(!lora.isDownloaded)
          MoveToFolderMenu(library: library, file: lora.file, folder: lora.folder, enabled: library.canMove(lora)) {
            pendingMove = library.planMoves([lora], to: $0)
          }
          Divider()
          Button("Move to Trash", role: .destructive) { pendingTrash = library.planTrash([lora]) }
            .disabled(library.moving?.files.contains(lora.file) == true)
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
  let move: (URL) -> Void
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
        if let folder = lora.folder { LabeledContent("Folder", value: library.folderName(folder)) }
        ButtonRow {
          Button(Finder.revealTitle) { library.reveal(lora.file) }
            .disabled(!lora.isDownloaded)
          MoveToFolderMenu(library: library, file: lora.file, folder: lora.folder, enabled: library.canMove(lora), choose: move)
          Button("Move to Trash", role: .destructive, action: delete)
            .disabled(library.moving?.files.contains(lora.file) == true)
        }
        MoveProgressRow(file: lora.file)
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
        "Each file is converted into the folder below and added to its custom_lora.json. Leave the name empty to use the file name and the detected model family. The number after the trigger words is the scale factor, which multiplies the LoRA's effect; 1 keeps it as trained."
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
      AddFolderPicker()
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
        .disabled(library.isImporting || !library.canRunImports)
      }
    }
    .sheetPadding()
    .sheetFrame(width: 520)
    // The weights of H3 Image and H3 video LoRAs look alike but convert differently, so a file
    // that doesn't say which is asked about before anything is converted.
    .confirmationDialog(
      "Is \u{201C}\(library.h3Question?.source.deletingPathExtension().lastPathComponent ?? "this LoRA")\u{201D} for MiniMax H3 Image or MiniMax H3 video?",
      isPresented: Binding(
        get: { library.h3Question != nil },
        // A dismissal without a button (Escape, a tap outside on iPad) skips the file. Deferred, so
        // a button's answer comes first whichever order SwiftUI runs the two in; the late nil then
        // finds no question and does nothing.
        set: { presented in
          guard !presented, let id = library.h3Question?.id else { return }
          Task { @MainActor in library.answerH3Question(nil, for: id) }
        }),
      titleVisibility: .visible
    ) {
      Button(ModelZoo.humanReadableNameForVersion(.minimaxH3Image)) { answerH3(.minimaxH3Image) }
      Button("\(ModelZoo.humanReadableNameForVersion(.minimaxH3)) (Video)") { answerH3(.minimaxH3) }
      Button("Don\u{2019}t Import", role: .cancel) { answerH3(nil) }
    } message: {
      Text("Its weights fit both, and the file doesn\u{2019}t say which model it was trained on. Pick the one it was made for; a LoRA imported as the other won\u{2019}t work.")
    }
  }

  private func answerH3(_ version: ModelVersion?) {
    guard let id = library.h3Question?.id else { return }
    library.answerH3Question(version, for: id)
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
          .accessibilityLabel("Don't import this file")
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
        TextField(
          "Scale",
          value: Binding(
            get: { item.scaleFactor }, set: { library.updateImport(item.id, scaleFactor: $0) }),
          format: .number.precision(.fractionLength(0...3)))
          .multilineTextAlignment(.trailing)
          .frame(width: 60)
          .foregroundStyle(item.hasValidScaleFactor ? Color.primary : Color.red)
          .help("Scale factor, baked into the converted LoRA: 0.5 halves its effect, 2 doubles it. A stored alpha ÷ rank is already applied, so leave it at 1 unless the LoRA is too strong or weak at weight 100%.")
          .accessibilityLabel("Scale factor")
      }
      .labelsHidden()
      .disabled(library.isImporting)
    }
  }
}

/// A LoRAs table row with the values its columns sort by.
struct LoRATableRow: Identifiable {
  let lora: ModelLibrary.LoRA
  let name: String
  let family: String
  let trigger: String
  let size: Int64
  let folder: String
  var id: String { lora.id }
}

/// What the LoRAs screen shows, kept on `ModelLibrary` while other screens are open.
struct LoRAScreenState {
  var search = ""
  var family: String?
  var selection: Set<String> = []
  /// The column the table is sorted by; empty keeps the list's order.
  var sortOrder: [KeyPathComparator<LoRATableRow>] = []
}
