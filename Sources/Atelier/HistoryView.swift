import ImageIO
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
      .searchable(text: $search, placement: .toolbar, prompt: "Filter by prompt")
      .toolbar {
        ToolbarItem {
          Picker("Model", selection: $modelFilter) {
            Text("All models").tag(String?.none)
            ForEach(modelNames, id: \.self) { Text($0).tag(Optional($0)) }
          }
          .frame(minWidth: 180)
        }
      }
      .inspector(isPresented: .constant(true)) {
        Group {
          if let selected {
            HistoryDetail(
              item: selected, use: { use(selected, newSeed: false) },
              rerun: { use(selected, newSeed: true) },
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
        "Move this image to the Trash?",
        isPresented: Binding(
          get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        presenting: pendingDelete
      ) { item in
        Button("Move to Trash", role: .destructive) { delete(item) }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: { _ in
        Text("The PNG and its settings file are moved to the Trash.")
      }
      .alert(
        "Couldn't delete",
        isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }),
        actions: { Button("OK") { deleteError = nil } },
        message: { Text(deleteError ?? "") })
      .onDeleteCommand { pendingDelete = selected }
      .task(id: history.isLoaded) { if selected == nil { selection = filtered.first?.id } }
  }

  @ViewBuilder
  private var grid: some View {
    if !history.isLoaded {
      ProgressView()
    } else if history.items.isEmpty {
      ContentUnavailableView(
        "No history yet", systemImage: "clock",
        description: Text("Images you generate in Create show up here."))
    } else if filtered.isEmpty {
      ContentUnavailableView.search(text: search)
    } else {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
          ForEach(filtered) { item in
            Color.clear
              .aspectRatio(1, contentMode: .fit)
              .overlay { Thumbnail(url: item.imageURL) }
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
                Button("Reveal in Finder") { reveal(item) }
                Divider()
                Button("Move to Trash", role: .destructive) { pendingDelete = item }
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

  private func reveal(_ item: HistoryItem) {
    NSWorkspace.shared.activateFileViewerSelecting([item.imageURL])
  }

  private func delete(_ item: HistoryItem) {
    pendingDelete = nil
    do {
      try history.delete(item)
      if selection == item.id { selection = nil }
    } catch {
      deleteError = error.localizedDescription
    }
  }
}

struct HistoryDetail: View {
  @Environment(CreateModel.self) private var create
  var item: HistoryItem
  var use: () -> Void
  var rerun: () -> Void
  var delete: () -> Void

  var body: some View {
    let sidecar = item.sidecar
    Form {
      Section {
        Thumbnail(url: item.imageURL, maxPixel: 1024, fill: false)
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
          Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.imageURL])
          }
          Button("Move to Trash", role: .destructive, action: delete)
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

/// A downsampled image loaded off the main thread.
struct Thumbnail: View {
  var url: URL
  var maxPixel = 440
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
    .task(id: url) {
      let url = url
      let maxPixel = maxPixel
      image = await Task.detached { Self.load(url, maxPixel: maxPixel) }.value
    }
  }

  private static let cache = NSCache<NSString, CGImage>()

  private nonisolated static func load(_ url: URL, maxPixel: Int) -> CGImage? {
    let key = "\(url.path)#\(maxPixel)" as NSString
    if let cached = cache.object(forKey: key) { return cached }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixel,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    cache.setObject(image, forKey: key)
    return image
  }
}
