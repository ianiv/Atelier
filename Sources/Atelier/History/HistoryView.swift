import ImageIO
import QuickLook
import UniformTypeIdentifiers
import SwiftUI

struct HistoryView: View {
  @Environment(HistoryStore.self) private var history
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @State private var selection: Set<HistoryItem.ID> = []
  /// The item arrows move from, ⇧-click extends from and Quick Look shows.
  @State private var anchor: HistoryItem.ID?
  @State private var search = ""
  @State private var modelFilter: String?
  @State private var pendingDelete: [HistoryItem]?
  @State private var deleteError: String?
  @State private var columns = 1
  @State private var viewportHeight: CGFloat = 0
  /// Each cell's frame in the grid, for marquee selection.
  @State private var frames: [HistoryItem.ID: CGRect] = [:]
  @State private var marquee: CGRect?
  @State private var quickLookURL: URL?
  @FocusState private var gridFocused: Bool

  private var filtered: [HistoryItem] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return history.items.filter { item in
      (modelFilter == nil || item.sidecar.model == modelFilter)
        && (query.isEmpty || item.sidecar.prompt.localizedCaseInsensitiveContains(query))
    }
  }

  /// The selected items, in grid order.
  private var selectedItems: [HistoryItem] {
    history.items.filter { selection.contains($0.id) }
  }

  /// What an action on `item` applies to: the whole selection when it includes `item`.
  private func targets(_ item: HistoryItem) -> [HistoryItem] {
    selection.contains(item.id) ? selectedItems : [item]
  }

  var body: some View {
    grid
      .toolbar {
        ToolbarItem(placement: .navigation) { ProjectMenu() }
        ToolbarItem {
          Picker("Model", selection: $modelFilter) {
            Text("All models").tag(String?.none)
            ForEach(modelNames, id: \.self) { Text($0).tag(Optional($0)) }
          }
          .frame(minWidth: 180)
        }
      }
      .searchable(text: $search, placement: .toolbar, prompt: "Filter by prompt")
      .inspector(isPresented: .constant(true)) {
        Group {
          let selected = selectedItems
          if selected.count == 1, let item = selected.first {
            HistoryDetail(
              item: item, use: { use(item, newSeed: false) },
              rerun: { use(item, newSeed: true) },
              export: { export([item]) },
              delete: { pendingDelete = [item] })
          } else if selected.count > 1 {
            HistorySelectionDetail(
              items: selected, export: { export(selected) },
              delete: { pendingDelete = selected })
          } else {
            ContentUnavailableView(
              "No selection", systemImage: "photo.on.rectangle",
              description: Text("Select an image to see its settings."))
          }
        }
        .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
      }
      .confirmationDialog(
        pendingDelete?.count ?? 0 > 1
          ? "Delete \(pendingDelete?.count ?? 0) images from the project?"
          : "Delete this image from the project?",
        isPresented: Binding(
          get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        presenting: pendingDelete
      ) { items in
        Button("Delete", role: .destructive) { delete(items) }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: { items in
        Text("\(items.count > 1 ? "The images and their" : "The image and its") settings are removed from “\(history.project.name)”. This can't be undone.")
      }
      .alert(
        "Something went wrong",
        isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }),
        actions: { Button("OK") { deleteError = nil } },
        message: { Text(deleteError ?? "") })
      .onDeleteCommand {
        let selected = selectedItems
        if !selected.isEmpty { pendingDelete = selected }
      }
      .task(id: history.isLoaded) { if selection.isEmpty { selectOnly(filtered.first?.id) } }
      .safeAreaBar(edge: .bottom) {
        if let progress = history.importProgress {
          HStack {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
              .frame(maxWidth: 200)
            Text("Importing earlier images into “\(HistoryStore.defaultProjectName)”: \(progress.done) of \(progress.total)")
              .foregroundStyle(.secondary)
          }
          .padding(8)
          .frame(maxWidth: .infinity)
        }
      }
  }

  @ViewBuilder
  private var grid: some View {
    if !history.isLoaded {
      ProgressView()
    } else if history.items.isEmpty {
      ContentUnavailableView(
        "No images in “\(history.project.name)”", systemImage: "clock",
        description: Text("Images you generate in Create are saved to the current project."))
    } else if filtered.isEmpty {
      ContentUnavailableView.search(text: search)
    } else {
      ScrollViewReader { scroller in
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
          ForEach(filtered) { item in
            Color.clear
              .aspectRatio(1, contentMode: .fit)
              .overlay { Thumbnail(item: item) }
              .overlay(alignment: .bottomTrailing) {
                Text(GenerationTime.text(item.sidecar.durationSeconds))
                  .font(.caption2.monospacedDigit())
                  .padding(.horizontal, 5)
                  .padding(.vertical, 2)
                  .background(.black.opacity(0.55), in: .capsule)
                  .foregroundStyle(.white)
                  .padding(5)
                  .help("Generation time")
              }
              .clipShape(.rect(cornerRadius: 6))
              .overlay {
                RoundedRectangle(cornerRadius: 6)
                  .strokeBorder(Color.accentColor, lineWidth: selection.contains(item.id) ? 3 : 0)
              }
              .contentShape(.rect)
              .gesture(
                TapGesture(count: 2).onEnded { use(item, newSeed: false) }
                  .exclusively(before: TapGesture().modifiers(.command).onEnded { toggle(item.id) })
                  .exclusively(before: TapGesture().modifiers(.shift).onEnded { extend(to: item.id) })
                  .exclusively(before: TapGesture().onEnded {
                    selectOnly(item.id)
                    gridFocused = true
                  }))
              .help(item.sidecar.prompt)
              .draggable(containerItemID: item.id)
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: {
                frames[item.id] = $0
              }
              .id(item.id)
              .contextMenu { contextMenu(for: item) }
          }
        }
        .padding(12)
        .frame(minHeight: viewportHeight, alignment: .top)
        .coordinateSpace(.named(Self.gridSpace))
        .background {
          // Clicking between images clears the selection; dragging there draws a marquee.
          Color.clear
            .contentShape(.rect)
            .onTapGesture {
              selection = []
              gridFocused = true
            }
            .gesture(marqueeGesture)
        }
        .overlay(alignment: .topLeading) {
          if let marquee {
            Rectangle()
              .fill(Color.accentColor.opacity(0.15))
              .strokeBorder(Color.accentColor.opacity(0.6))
              .frame(width: marquee.width, height: marquee.height)
              .offset(x: marquee.minX, y: marquee.minY)
              .allowsHitTesting(false)
          }
        }
        .dragContainer(for: PNGExport.self) { ids in
          ids.compactMap { history.item($0).map(history.dragExport) }
        }
        .dragContainerSelection(selectedItems.map(\.id))
      }
      .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
        // The adaptive grid's column count: 150 pt minimum, 10 pt spacing, 12 pt padding.
        columns = max(1, Int((size.width - 24 + 10) / 160))
        viewportHeight = size.height
      }
      .focusable()
      .focusEffectDisabled()
      .focused($gridFocused)
      .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
        let offset = switch press.key {
        case .leftArrow: -1
        case .rightArrow: 1
        case .upArrow: -columns
        default: columns
        }
        moveSelection(by: offset, extending: press.modifiers.contains(.shift))
        if let anchor { withAnimation { scroller.scrollTo(anchor) } }
        return .handled
      }
      .onKeyPress(keys: ["a"]) { press in
        guard press.modifiers == .command else { return .ignored }
        selection = Set(filtered.map(\.id))
        return .handled
      }
      .onKeyPress(.space) {
        toggleQuickLook()
        return .handled
      }
      .quickLookPreview($quickLookURL)
      .background(Color(nsColor: .underPageBackgroundColor))
      }
    }
  }

  private static let gridSpace = "HistoryGrid"

  @ViewBuilder
  private func contextMenu(for item: HistoryItem) -> some View {
    let items = targets(item)
    if items.count > 1 {
      Button("Copy \(items.count) Images") { Task { await history.copyImages(items) } }
      Button("Export \(items.count) PNGs…") { export(items) }
      Divider()
      Button("Delete \(items.count) Images", role: .destructive) { pendingDelete = items }
    } else {
      Button("Use Settings") { use(item, newSeed: false) }
        .disabled(!create.canUse(item))
      Button("Rerun with New Seed") { use(item, newSeed: true) }
        .disabled(!create.canUse(item))
      Button("Copy Image") { Task { await history.copyImage(item) } }
      Button("Copy Prompt") { copy(item.sidecar.prompt) }
      Button("Copy Seed") { copy(String(item.sidecar.seed)) }
      Button("Export PNG…") { export([item]) }
      Divider()
      Button("Delete", role: .destructive) { pendingDelete = [item] }
    }
  }

  /// Selects the images the marquee touches.
  private var marqueeGesture: some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.gridSpace))
      .onChanged { drag in
        let rect = CGRect(
          x: min(drag.startLocation.x, drag.location.x),
          y: min(drag.startLocation.y, drag.location.y),
          width: abs(drag.location.x - drag.startLocation.x),
          height: abs(drag.location.y - drag.startLocation.y))
        marquee = rect
        let hit = filtered.filter { frames[$0.id]?.intersects(rect) == true }
        selection = Set(hit.map(\.id))
        anchor = hit.first?.id
        gridFocused = true
      }
      .onEnded { _ in marquee = nil }
  }

  private func selectOnly(_ id: HistoryItem.ID?) {
    selection = id.map { [$0] } ?? []
    anchor = id
  }

  /// ⌘-click: adds or removes one image.
  private func toggle(_ id: HistoryItem.ID) {
    if selection.remove(id) == nil { selection.insert(id) }
    anchor = id
    gridFocused = true
  }

  /// ⇧-click: adds the images from the anchor to `id`.
  private func extend(to id: HistoryItem.ID) {
    let items = filtered
    guard let from = items.firstIndex(where: { $0.id == anchor }),
      let to = items.firstIndex(where: { $0.id == id })
    else { return selectOnly(id) }
    selection.formUnion(items[min(from, to)...max(from, to)].map(\.id))
    gridFocused = true
  }

  private func moveSelection(by offset: Int, extending: Bool) {
    let items = filtered
    guard !items.isEmpty else { return }
    let index = items.firstIndex { $0.id == anchor } ?? 0
    let next = items[min(max(index + offset, 0), items.count - 1)].id
    if extending {
      selection.insert(next)
      anchor = next
    } else {
      selectOnly(next)
    }
    // Quick Look follows the selection while it's open.
    if quickLookURL != nil { quickLookURL = nil; toggleQuickLook() }
  }

  /// Space: the anchor image full size in Quick Look, or closes it.
  private func toggleQuickLook() {
    if quickLookURL != nil {
      quickLookURL = nil
      return
    }
    guard let item = history.items.first(where: { $0.id == anchor && selection.contains($0.id) })
    else { return }
    Task {
      guard let data = try? await history.pngData(item) else { return }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Atelier Quick Look", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      let file = url.appendingPathComponent(history.fileName(for: item)).appendingPathExtension("png")
      guard (try? data.write(to: file)) != nil, anchor == item.id else { return }
      quickLookURL = file
    }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private var modelNames: [String] {
    Array(Set(history.items.map(\.sidecar.model))).sorted()
  }

  private func use(_ item: HistoryItem, newSeed: Bool) {
    guard create.canUse(item) else { return }
    create.use(item, newSeed: newSeed)
    navigation.section = .create
  }

  /// One image: a save panel. Several: a folder, each named like a single export.
  private func export(_ items: [HistoryItem]) {
    var destinations: [(HistoryItem, URL)] = []
    if items.count == 1, let item = items.first {
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.png]
      panel.nameFieldStringValue = history.fileName(for: item) + ".png"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      destinations = [(item, url)]
    } else {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.prompt = "Export"
      panel.message = "Choose a folder for \(items.count) PNGs."
      guard panel.runModal() == .OK, let folder = panel.url else { return }
      destinations = items.map { item in
        (item, Self.unusedURL(in: folder, name: history.fileName(for: item)))
      }
    }
    Task {
      do {
        for (item, url) in destinations { try await history.exportPNG(item, to: url) }
      } catch {
        deleteError = error.localizedDescription
      }
    }
  }

  /// `name.png` in `folder`, or `name 2.png`, … when that's taken.
  private static func unusedURL(in folder: URL, name: String) -> URL {
    var url = folder.appendingPathComponent(name).appendingPathExtension("png")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension("png")
      n += 1
    }
    return url
  }

  private func delete(_ items: [HistoryItem]) {
    pendingDelete = nil
    Task {
      do {
        try await history.delete(items)
      } catch {
        deleteError = error.localizedDescription
      }
      // Later steps were renumbered, so the old ids may now name other images.
      selectOnly(filtered.first?.id)
    }
  }
}

/// The inspector when several images are selected.
struct HistorySelectionDetail: View {
  @Environment(HistoryStore.self) private var history
  var items: [HistoryItem]
  var export: () -> Void
  var delete: () -> Void

  var body: some View {
    Form {
      Section {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
          ForEach(items.prefix(24)) { item in
            Color.clear
              .aspectRatio(1, contentMode: .fit)
              .overlay { Thumbnail(item: item) }
              .clipShape(.rect(cornerRadius: 4))
          }
        }
        Text("\(items.count) images selected")
          .foregroundStyle(.secondary)
        HStack {
          Button("Copy Images") { Task { await history.copyImages(items) } }
          Button("Export PNGs…", action: export)
          Button("Delete", role: .destructive, action: delete)
        }
      }
    }
    .formStyle(.grouped)
  }
}

struct HistoryDetail: View {
  @Environment(CreateModel.self) private var create
  @Environment(HistoryStore.self) private var history
  var item: HistoryItem
  var use: () -> Void
  var rerun: () -> Void
  var export: () -> Void
  var delete: () -> Void

  var body: some View {
    let sidecar = item.sidecar
    Form {
      Section {
        Thumbnail(item: item, half: false, fill: false)
          .frame(maxWidth: .infinity)
          .frame(height: 260)
        HStack {
          Button("Use Settings", action: use)
          Button("Rerun with New Seed", action: rerun)
        }
        .disabled(!create.canUse(item))
        if !create.models.contains(where: { $0.file == sidecar.model }) {
          Label("\(sidecar.model) isn't downloaded.", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Copy Image") { Task { await history.copyImage(item) } }
          Button("Export PNG…", action: export)
          Button("Delete", role: .destructive, action: delete)
        }
      }
      Section("Prompt") {
        Text(sidecar.prompt).textSelection(.enabled)
        if !sidecar.negativePrompt.isEmpty {
          LabeledContent("Negative") { Text(sidecar.negativePrompt).textSelection(.enabled) }
        }
      }
      Section("Settings") {
        LabeledContent("Model", value: modelName(sidecar.model))
        LabeledContent("Size", value: "\(sidecar.width) × \(sidecar.height)")
        LabeledContent("Seed") { Text(String(sidecar.seed)).textSelection(.enabled) }
        LabeledContent("Steps", value: "\(sidecar.steps)")
        LabeledContent("Guidance", value: sidecar.guidanceScale.formatted())
        LabeledContent("Shift", value: sidecar.shift.formatted())
        LabeledContent("Sampler", value: sidecar.sampler)
        LabeledContent(
          "Resolution-dependent shift", value: sidecar.resolutionDependentShift ? "On" : "Off")
        LabeledContent("Hires fix", value: sidecar.hiresFix ? "On" : "Off")
        LabeledContent(
          "Created",
          value: sidecar.createdAt.formatted(date: .abbreviated, time: .shortened))
        LabeledContent(
          "Duration", value: Duration.seconds(sidecar.durationSeconds).formatted(.units(width: .abbreviated, fractionalPart: .show(length: 1))))
      }
    }
    .formStyle(.grouped)
  }

  private func modelName(_ file: String) -> String {
    create.models.first { $0.file == file }?.name ?? file
  }
}

/// A step's JPEG preview from the project, loaded off the main thread.
struct Thumbnail: View {
  @Environment(HistoryStore.self) private var history
  var item: HistoryItem
  /// The small grid preview, or the full-size one.
  var half = true
  var fill = true
  @State private var image: CGImage?

  var body: some View {
    ZStack {
      if fill { Color(nsColor: .quaternaryLabelColor) }
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: fill ? .fill : .fit)
      }
    }
    .task(id: "\(item.previewId)#\(half)") {
      image = await history.thumbnail(for: item, half: half)
    }
  }
}

/// The current project, with switching, New Project… and Rename….
struct ProjectMenu: View {
  @Environment(HistoryStore.self) private var history
  @State private var naming: Naming?
  @State private var error: String?

  enum Naming: Identifiable {
    case new(suggested: String), rename(current: String)
    var id: String { title }
    var title: String {
      if case .new = self { "New Project" } else { "Rename Project" }
    }
    var initialName: String {
      switch self {
      case .new(let suggested): suggested
      case .rename(let current): current
      }
    }
  }

  var body: some View {
    Menu {
      ForEach(history.projectNames, id: \.self) { project in
        Toggle(
          project,
          isOn: Binding(
            get: { project == history.project.name },
            set: { if $0 { Task { await history.open(project) } } }))
      }
      Divider()
      Button("New Project…") { naming = .new(suggested: history.availableName()) }
      Button("Rename “\(history.project.name)”…") { naming = .rename(current: history.project.name) }
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([history.project.url])
      }
    } label: {
      Label(history.project.name, systemImage: "folder")
        .labelStyle(.titleAndIcon)
    }
    .help("Project: images are saved to the current project")
    // A sheet rather than an alert with a text field: the alert showed an empty field and put
    // keyboard focus on Cancel.
    .sheet(item: $naming) { naming in
      ProjectNameSheet(naming: naming) { commit(naming, name: $0) }
    }
    .alert(
      "Couldn't rename the project",
      isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
      actions: { Button("OK") { error = nil } },
      message: { Text(error ?? "") })
  }

  private func commit(_ kind: Naming, name: String) {
    let name = name.trimmingCharacters(in: .whitespaces)
    guard HistoryStore.isValidName(name) else { return }
    Task {
      switch kind {
      case .new:
        await history.open(history.projectNames.contains(name) ? history.availableName(name) : name)
      case .rename:
        do {
          try await history.renameCurrent(to: name)
        } catch {
          self.error = error.localizedDescription
        }
      }
    }
  }
}

/// Names a new project or renames the current one. Opens with the name filled in and selected,
/// and Return confirms.
private struct ProjectNameSheet: View {
  let naming: ProjectMenu.Naming
  let commit: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @FocusState private var nameFocused: Bool

  private var isNew: Bool {
    if case .new = naming { true } else { false }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(naming.title).font(.headline)
      TextField("Name", text: $name)
        .focused($nameFocused)
        .onSubmit(confirm)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(isNew ? "Create" : "Rename", action: confirm)
          .keyboardShortcut(.defaultAction)
          .disabled(!HistoryStore.isValidName(name))
      }
    }
    .padding(20)
    .frame(width: 320)
    .onAppear {
      name = naming.initialName
      nameFocused = true
    }
  }

  private func confirm() {
    guard HistoryStore.isValidName(name) else { return }
    dismiss()
    commit(name)
  }
}
