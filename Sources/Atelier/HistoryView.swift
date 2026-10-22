import ImageIO
import UniformTypeIdentifiers
import SwiftUI

struct HistoryView: View {
  @Environment(HistoryStore.self) private var history
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @State private var selection: HistoryItem.ID?
  @State private var search = ""
  @State private var modelFilter: String?
  @State private var pendingDelete: HistoryItem?
  @State private var deleteError: String?

  private var filtered: [HistoryItem] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return history.items.filter { item in
      (modelFilter == nil || item.sidecar.model == modelFilter)
        && (query.isEmpty || item.sidecar.prompt.localizedCaseInsensitiveContains(query))
    }
  }

  private var selected: HistoryItem? {
    history.items.first { $0.id == selection }
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
          if let selected {
            HistoryDetail(
              item: selected, use: { use(selected, newSeed: false) },
              rerun: { use(selected, newSeed: true) },
              export: { export(selected) },
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
        "Delete this image from the project?",
        isPresented: Binding(
          get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        presenting: pendingDelete
      ) { item in
        Button("Delete", role: .destructive) { delete(item) }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: { _ in
        Text("The image and its settings are removed from “\(history.project.name)”. This can't be undone.")
      }
      .alert(
        "Something went wrong",
        isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }),
        actions: { Button("OK") { deleteError = nil } },
        message: { Text(deleteError ?? "") })
      .onDeleteCommand { pendingDelete = selected }
      .task(id: history.isLoaded) { if selected == nil { selection = filtered.first?.id } }
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
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
          ForEach(filtered) { item in
            Color.clear
              .aspectRatio(1, contentMode: .fit)
              .overlay { Thumbnail(item: item) }
              .clipShape(.rect(cornerRadius: 6))
              .overlay {
                RoundedRectangle(cornerRadius: 6)
                  .strokeBorder(Color.accentColor, lineWidth: selection == item.id ? 3 : 0)
              }
              .contentShape(.rect)
              .onTapGesture(count: 2) { use(item, newSeed: false) }
              .onTapGesture { selection = item.id }
              .help(item.sidecar.prompt)
              .contextMenu {
                Button("Use Settings") { use(item, newSeed: false) }
                  .disabled(!create.canUse(item))
                Button("Rerun with New Seed") { use(item, newSeed: true) }
                  .disabled(!create.canUse(item))
                Button("Export PNG…") { export(item) }
                Divider()
                Button("Delete", role: .destructive) { pendingDelete = item }
              }
          }
        }
        .padding(12)
      }
      .background(Color(nsColor: .underPageBackgroundColor))
    }
  }

  private var modelNames: [String] {
    Array(Set(history.items.map(\.sidecar.model))).sorted()
  }

  private func use(_ item: HistoryItem, newSeed: Bool) {
    guard create.canUse(item) else { return }
    create.use(item, newSeed: newSeed)
    navigation.section = .create
  }

  private func export(_ item: HistoryItem) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "\(history.project.name) \(item.id.logicalTime)-\(item.sidecar.seed).png"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        try await history.exportPNG(item, to: url)
      } catch {
        deleteError = error.localizedDescription
      }
    }
  }

  private func delete(_ item: HistoryItem) {
    pendingDelete = nil
    Task {
      do {
        try await history.delete(item)
        if selection == item.id { selection = filtered.first?.id }
      } catch {
        deleteError = error.localizedDescription
      }
    }
  }
}

struct HistoryDetail: View {
  @Environment(CreateModel.self) private var create
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
  @State private var name = ""
  @State private var error: String?

  enum Naming { case new, rename }

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
      Button("New Project…") {
        name = history.availableName()
        naming = .new
      }
      Button("Rename “\(history.project.name)”…") {
        name = history.project.name
        naming = .rename
      }
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([history.project.url])
      }
    } label: {
      Label(history.project.name, systemImage: "folder")
        .labelStyle(.titleAndIcon)
    }
    .help("Project: images are saved to the current project")
    .alert(
      naming == .rename ? "Rename Project" : "New Project",
      isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
    ) {
      TextField("Name", text: $name)
      Button(naming == .rename ? "Rename" : "Create") { commit() }
        .disabled(!HistoryStore.isValidName(name))
      Button("Cancel", role: .cancel) { naming = nil }
    }
    .alert(
      "Couldn't rename the project",
      isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
      actions: { Button("OK") { error = nil } },
      message: { Text(error ?? "") })
  }

  private func commit() {
    let kind = naming
    naming = nil
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
      case nil:
        break
      }
    }
  }
}
