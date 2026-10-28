import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
  @Environment(HistoryStore.self) private var history
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @Environment(FileDialogs.self) private var fileDialogs
  @Environment(TimelineStore.self) private var timelines
  @Environment(\.undoManager) private var undoManager
  /// Selected images by image tensor, which stays the same when a fork or delete renumbers steps.
  @State private var selection: Set<Int64> = []
  /// Counts selections made by hand, not the one the screen starts with, so a narrow window opens
  /// the detail pane only for those.
  @State private var picks = 0
  #if os(iOS)
    /// Select mode: taps add and remove images, as ⌘-click does on the Mac.
    @State private var selecting = false
  #endif
  /// The item arrows move from, ⇧-click extends from and Quick Look shows.
  @State private var anchor: Int64?
  @State private var search = ""
  @State private var modelFilter: String?
  @State private var kindFilter = Kind.all
  @State private var ratingFilter = RatingFilter.any
  @State private var pendingDelete: [HistoryItem]?
  @State private var deleteError: String?
  @State private var columns = 1
  @State private var viewportHeight: CGFloat = 0
  /// Each cell's frame in the grid, for marquee selection.
  @State private var frames: [Int64: CGRect] = [:]
  @State private var marquee: CGRect?
  @State private var quickLookURL: URL?
  @State private var upscaling: HistoryItem?
  /// Export Video… is choosing how.
  @State private var exportingVideo: HistoryItem?
  @FocusState private var gridFocused: Bool
  @AppStorage("historyLayout") private var layout = Layout.grid

  enum Layout: String {
    case grid, graph
  }

  enum Kind {
    case all, images, videos
  }

  /// Which ratings History shows: any, only unrated, or at least some stars.
  enum RatingFilter: Hashable {
    case any, unrated, atLeast(Int)

    func matches(_ stars: Int) -> Bool {
      switch self {
      case .any: true
      case .unrated: stars == 0
      case .atLeast(let minimum): stars >= minimum
      }
    }
  }

  private var filtered: [HistoryItem] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return history.items.filter { item in
      (modelFilter == nil || item.sidecar.model == modelFilter)
        && (kindFilter == .all || item.isVideo == (kindFilter == .videos))
        && ratingFilter.matches(history.rating(of: item))
        && (query.isEmpty || item.sidecar.prompt.localizedCaseInsensitiveContains(query))
    }
  }

  /// The selected items, in grid order.
  private var selectedItems: [HistoryItem] {
    history.items.filter { selection.contains($0.tensorId) }
  }

  /// What an action on `item` applies to: the whole selection when it includes `item`.
  private func targets(_ item: HistoryItem) -> [HistoryItem] {
    selection.contains(item.tensorId) ? selectedItems : [item]
  }

  var body: some View {
    grid
      .toolbar {
        ToolbarItem(placement: .navigation) { ProjectMenu() }
        ToolbarItem {
          Picker("Layout", selection: $layout) {
            Label("Grid", systemImage: "square.grid.2x2").tag(Layout.grid)
            Label("Graph", systemImage: "arrow.triangle.branch").tag(Layout.graph)
          }
          .pickerStyle(.segmented)
          .help("Show the images as a grid, or as a graph of their branches")
        }
        if history.items.contains(where: \.isVideo) {
          ToolbarItem {
            Picker("Kind", selection: $kindFilter) {
              Text("Images and Videos").tag(Kind.all)
              Text("Images").tag(Kind.images)
              Text("Videos").tag(Kind.videos)
            }
            .help("Show images, videos or both")
          }
        }
        ToolbarItem {
          Picker("Rating", selection: $ratingFilter) {
            Text("Any rating").tag(RatingFilter.any)
            Divider()
            ForEach((1...5).reversed(), id: \.self) { stars in
              Text(StarRating.text(stars) + (stars < 5 ? " or more" : "")).tag(RatingFilter.atLeast(stars))
            }
            Divider()
            Text("Unrated").tag(RatingFilter.unrated)
          }
          .help("Show only images with at least this many stars, or only unrated ones")
        }
        ToolbarItem {
          Picker("Model", selection: $modelFilter) {
            Text("All models").tag(String?.none)
            ForEach(modelNames, id: \.self) { Text($0).tag(Optional($0)) }
          }
          .frame(minWidth: 180)
        }
        #if os(iOS)
          ToolbarItem {
            Button(selecting ? "Done" : "Select") { selecting.toggle() }
              .help("Select several images to copy, export, save or delete together")
          }
        #endif
      }
      .searchable(text: $search, placement: .toolbar, prompt: "Filter by prompt")
      .detailInspector(selection: picks, isEmpty: selection.isEmpty, clearSelection: { selection = [] }) {
        Group {
          let selected = selectedItems
          if selected.count == 1, let item = selected.first {
            HistoryDetail(
              item: item, use: { use(item, newSeed: false, loadImage: false) },
              rerun: { use(item, newSeed: true) },
              export: { export([item]) },
              delete: { pendingDelete = [item] }, saveToPhotos: photosAction([item]),
              upscale: { upscaling = item })
          } else if selected.count > 1 {
            HistorySelectionDetail(
              items: selected, export: { export(selected) },
              delete: { pendingDelete = selected }, saveToPhotos: photosAction(selected))

          } else {
            ContentUnavailableView(
              "No selection", systemImage: "photo.on.rectangle",
              description: Text("Select an image to see its settings."))
          }
        }
        .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
      }
      .sheet(item: $upscaling) { UpscaleSheet(item: $0) }
      .sheet(item: $exportingVideo) { item in
        VideoExportSheet(
          width: item.sidecar.width, height: item.sidecar.height,
          frameCount: item.clip?.frames.count ?? 0
        ) { upscale in
          if let upscale {
            queueUpscaledExport(item, upscale)
          } else {
            ClipActions.save(item, history: history, dialogs: fileDialogs)
          }
        }
      }
      .confirmationDialog(
        pendingDelete?.count ?? 0 > 1
          ? "Delete \(pendingDelete?.count ?? 0) items from the project?"
          : pendingDelete?.first?.isVideo == true
          ? "Delete this video from the project?" : "Delete this image from the project?",
        isPresented: Binding(
          get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        presenting: pendingDelete
      ) { items in
        Button("Delete", role: .destructive) { delete(items) }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: { items in
        Text("\(items.count > 1 ? "They and their" : items.first?.isVideo == true ? "The video and its" : "The image and its") settings are removed from “\(history.project.name)”\(timelineNote(items)). This can't be undone.")
      }
      .alert(
        "Something went wrong",
        isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }),
        actions: { Button("OK") { deleteError = nil } },
        message: { Text(deleteError ?? "") })
      .deleteCommand {
        let selected = selectedItems
        if !selected.isEmpty { pendingDelete = selected }
      }
      .task(id: history.isLoaded) {
        if selection.isEmpty { selectOnly(history.currentItem?.tensorId ?? filtered.first?.tensorId) }
      }
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
    } else if filtered.isEmpty, ratingFilter != .any, search.isEmpty {
      ContentUnavailableView {
        Label("No images with this rating", systemImage: "star")
      } actions: {
        Button("Show All Ratings") { ratingFilter = .any }
      }
    } else if filtered.isEmpty {
      ContentUnavailableView.search(text: search)
    } else {
      ScrollViewReader { scroller in
        ScrollView {
          Group {
            if layout == .graph { graph } else { gridCells }
          }
          .dragContainer(for: PNGExport.self) { ids in
            ids.compactMap { history.item(tensorId: $0).map(history.dragExport) }
          }
          .dragContainerSelection(selectedItems.map(\.tensorId))
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
          let rows = layout == .graph ? 1 : columns
          let offset = switch press.key {
          case .leftArrow: -1
          case .rightArrow: 1
          case .upArrow: -rows
          default: rows
          }
          moveSelection(by: offset, extending: press.modifiers.contains(.shift))
          if let anchor { withAnimation { scroller.scrollTo(anchor) } }
          return .handled
        }
        .onKeyPress(keys: ["a"]) { press in
          guard press.modifiers == .command else { return .ignored }
          selection = Set(filtered.map(\.tensorId))
          return .handled
        }
        .onKeyPress(.space) {
          toggleQuickLook()
          return .handled
        }
        // 1 to 5 rate the selection, 0 clears its rating, as in Photos and Lightroom.
        .onKeyPress(characters: .decimalDigits) { press in
          guard press.modifiers.isEmpty, let stars = Int(press.characters), stars <= 5,
                !selection.isEmpty
          else { return .ignored }
          history.setRating(stars, for: selectedItems)
          return .handled
        }
        .quickLookPreview($quickLookURL)
        .background(Color.underPageBackground)
      }
    }
  }

  private static let gridSpace = "HistoryGrid"

  private var gridCells: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
      ForEach(filtered, id: \.tensorId) { item in
        cell(
          Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
              if item.isVideo { ClipThumbnail(item: item) } else { Thumbnail(item: item) }
            }
            .overlay(alignment: .bottomLeading) {
              if let clip = item.clip { ClipBadge(clip: clip).padding(5) }
            }
            .overlay(alignment: .topLeading) {
              let stars = history.rating(of: item)
              if stars > 0 { RatingBadge(stars: stars).padding(5) }
            }
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
                .strokeBorder(Color.accentColor, lineWidth: selection.contains(item.tensorId) ? 3 : 0)
            },
          item: item)
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
  }

  /// One row per image, newest first, with the branches drawn in a lane column as `git log
  /// --graph` does: each image's line runs down to the image it follows.
  private var graph: some View {
    let items = filtered
    let layout = HistoryGraph(items: items, parent: { visibleParent(of: $0, in: items) })
    let current = history.currentItem?.tensorId
    return LazyVStack(spacing: 0) {
      ForEach(Array(zip(items, layout.rows)), id: \.0.tensorId) { item, row in
        cell(
          HistoryGraphRow(
            item: item, row: row, lanes: layout.lanes, isCurrent: item.tensorId == current,
            isSelected: selection.contains(item.tensorId), stars: history.rating(of: item)),
          item: item)
      }
    }
    .padding(.vertical, 8)
    .frame(minHeight: viewportHeight, alignment: .top)
    .background {
      Color.clear
        .contentShape(.rect)
        .onTapGesture {
          selection = []
          gridFocused = true
        }
    }
  }

  /// The nearest image `item` follows among those listed (a filter can hide the ones between).
  private func visibleParent(of item: HistoryItem, in items: [HistoryItem]) -> HistoryItem? {
    var next = history.parent(of: item)
    var seen: Set<Int64> = []
    while let parent = next, seen.insert(parent.tensorId).inserted {
      if items.contains(parent) { return parent }
      next = history.parent(of: parent)
    }
    return nil
  }

  /// Double-click uses the image; a click picks it, ⌘-click toggles it, ⇧-click extends to it. On
  /// iPad, a tap picks and a double tap uses (tap gestures there take no modifier keys); in Select
  /// mode a tap toggles.
  private func tapGesture(_ item: HistoryItem) -> some Gesture {
    #if os(macOS)
      let pickItem = TapGesture().onEnded {
        pick(item)
        gridFocused = true
      }
      return TapGesture(count: 2).onEnded { use(item, newSeed: false) }
        .exclusively(before: TapGesture().modifiers(.command).onEnded { toggle(item.tensorId) })
        .exclusively(before: TapGesture().modifiers(.shift).onEnded { extend(to: item.tensorId) })
        .exclusively(before: pickItem)
    #else
      return TapGesture(count: 2).onEnded { if !selecting { use(item, newSeed: false) } }
        .exclusively(
          before: TapGesture().onEnded {
            if selecting { toggle(item.tensorId) } else { pick(item) }
            gridFocused = true
          })
    #endif
  }

  /// Selection, use, drag and the context menu, shared by grid cells and graph rows.
  private func cell(_ content: some View, item: HistoryItem) -> some View {
    content
      .contentShape(.rect)
      .gesture(tapGesture(item))
      .help(item.sidecar.prompt)
      .draggable(containerItemID: item.tensorId)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: {
        frames[item.tensorId] = $0
      }
      .id(item.tensorId)
      .contextMenu { contextMenu(for: item) }
  }

  @ViewBuilder
  private func contextMenu(for item: HistoryItem) -> some View {
    let items = targets(item)
    if items.count > 1 {
      if items.allSatisfy(\.isVideo) {
        Button("Add \(items.count) Videos to Timeline") { addToTimeline(items) }
        Divider()
      }
      Button("Copy \(items.count) Images") { Task { await history.copyImages(items) } }
      Button("Export \(items.count) Files…") { export(items) }
      #if os(iOS)
        Button("Save \(items.count) Images to Photos") { saveToPhotos(items) }
      #endif
      Divider()
      ratingMenu(items)
      Divider()
      Button("Delete \(items.count) Images", role: .destructive) { pendingDelete = items }
    } else {
      Button("Use Settings") { use(item, newSeed: false, loadImage: false) }
        .disabled(!create.canUse(item))
      Button("Rerun with New Seed") { use(item, newSeed: true) }
        .disabled(!create.canUse(item))
      Button(item.isVideo ? "Copy First Frame" : "Copy Image") { Task { await history.copyImage(item) } }
      Button("Copy Prompt") { copy(item.sidecar.prompt) }
      Button("Copy Seed") { copy(String(item.sidecar.seed)) }
      Button(item.isVideo ? "Export Video…" : "Export PNG…") { export([item]) }
      #if os(iOS)
        Button("Save to Photos") { saveToPhotos([item]) }
      #endif
      if item.isVideo {
        Divider()
        Button("Add to Timeline") { addToTimeline([item]) }
        Button("Upscale…") { upscaling = item }
      }
      Divider()
      ratingMenu(items)
      Divider()
      Button("Delete", role: .destructive) { pendingDelete = [item] }
    }
  }

  /// Rating: a check on the items' rating when they share one.
  private func ratingMenu(_ items: [HistoryItem]) -> some View {
    let ratings = Set(items.map(history.rating(of:)))
    return Menu("Rating") {
      ForEach(0...5, id: \.self) { stars in
        Toggle(
          stars == 0 ? "None" : StarRating.text(stars),
          isOn: Binding(
            get: { ratings == [stars] }, set: { _ in history.setRating(stars, for: items) }))
          .keyboardShortcut(KeyEquivalent(Character(String(stars))), modifiers: [])
      }
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
        let hit = filtered.filter { frames[$0.tensorId]?.intersects(rect) == true }
        selection = Set(hit.map(\.tensorId))
        anchor = hit.first?.tensorId
        gridFocused = true
      }
      .onEnded { _ in marquee = nil }
  }

  private func selectOnly(_ id: Int64?) {
    selection = id.map { [$0] } ?? []
    anchor = id
  }

  /// A click (or arrow) on one image: selects it and makes it the current step, on the canvas, so
  /// the next run follows it.
  private func pick(_ item: HistoryItem) {
    selectOnly(item.tensorId)
    picks += 1
    create.show(item)
  }

  /// ⌘-click: adds or removes one image.
  private func toggle(_ id: Int64) {
    if selection.remove(id) == nil { selection.insert(id) }
    anchor = id
    picks += 1
    gridFocused = true
  }

  /// ⇧-click: adds the images from the anchor to `id`.
  private func extend(to id: Int64) {
    let items = filtered
    guard let from = items.firstIndex(where: { $0.tensorId == anchor }),
          let to = items.firstIndex(where: { $0.tensorId == id })
    else { return selectOnly(id) }
    selection.formUnion(items[min(from, to)...max(from, to)].map(\.tensorId))
    picks += 1
    gridFocused = true
  }

  private func moveSelection(by offset: Int, extending: Bool) {
    let items = filtered
    guard !items.isEmpty else { return }
    let index = items.firstIndex { $0.tensorId == anchor } ?? 0
    let next = items[min(max(index + offset, 0), items.count - 1)]
    if extending {
      selection.insert(next.tensorId)
      anchor = next.tensorId
    } else {
      pick(next)
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
    guard let item = history.items.first(where: { $0.tensorId == anchor && selection.contains($0.tensorId) })
    else { return }
    Task {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Atelier Quick Look", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      let file = url.appendingPathComponent(history.fileName(for: item))
        .appendingPathExtension(item.isVideo ? "mp4" : "png")
      if item.isVideo {
        guard (try? await history.exportVideo(item, to: file)) != nil else { return }
      } else {
        guard let data = try? await history.pngData(item), (try? data.write(to: file)) != nil
        else { return }
      }
      guard anchor == item.tensorId else { return }
      quickLookURL = file
    }
  }

  private func copy(_ text: String) {
    Clipboard.copy(text)
  }

  private var modelNames: [String] {
    Array(Set(history.items.map(\.sidecar.model))).sorted()
  }

  private func use(_ item: HistoryItem, newSeed: Bool, loadImage: Bool = true) {
    guard create.canUse(item) else { return }
    create.use(item, newSeed: newSeed, loadImage: loadImage)
    navigation.section = .create
  }

  #if os(iOS)
    /// Adds the images to Photos as PNGs carrying their settings, like Export.
    private func saveToPhotos(_ items: [HistoryItem]) {
      Task {
        do {
          var pngs: [Data] = []
          var videos: [URL] = []
          for item in items {
            if item.isVideo {
              videos.append(try await history.videoFile(for: item))
            } else {
              pngs.append(try await history.pngData(item))
            }
          }
          try await PhotoLibrary.save(pngs, videos: videos)
        } catch {
          deleteError = error.localizedDescription
        }
      }
    }
  #endif

  /// Save to Photos for the detail panes' buttons, which only iPad shows.
  private func photosAction(_ items: [HistoryItem]) -> () -> Void {
    #if os(iOS)
      { saveToPhotos(items) }
    #else
      {}
    #endif
  }

  /// One clip: the export sheet (as it is, or upscaled). One image: a save panel. Several: a
  /// folder, each named like a single export.
  private func export(_ items: [HistoryItem]) {
    if items.count == 1, let item = items.first, item.isVideo {
      exportingVideo = item
    } else if items.count == 1, let item = items.first {
      let history = history
      fileDialogs.save = FileDialogs.Save(
        file: ExportedFile(type: .png) { try await history.pngData(item) },
        name: history.fileName(for: item) + ".png"
      ) { result in
        if case .failure(let error) = result { deleteError = error.localizedDescription }
      }
    } else {
      fileDialogs.open = FileDialogs.Open(
        types: [.folder], confirmation: "Export",
        message: "Choose a folder for \(items.count) files: images as PNG, videos as MP4."
      ) { urls in
        guard let folder = urls.first else { return }
        let destinations = items.map { item in
          (
            item,
            Self.unusedURL(
              in: folder, name: history.fileName(for: item), extension: item.isVideo ? "mp4" : "png")
          )
        }
        Task {
          let access = folder.startAccessingSecurityScopedResource()
          defer { if access { folder.stopAccessingSecurityScopedResource() } }
          do {
            for (item, url) in destinations {
              if item.isVideo {
                try await history.exportVideo(item, to: url)
              } else {
                try await history.exportPNG(item, to: url)
              }
            }
          } catch {
            deleteError = error.localizedDescription
          }
        }
      }
    }
  }

  /// Asks where to save `item` upscaled, then queues the export.
  private func queueUpscaledExport(_ item: HistoryItem, _ upscale: TimelineUpscale) {
    let history = history, create = create
    let name = "\(history.fileName(for: item)) \(upscale.scale)x"
    fileDialogs.save = FileDialogs.Save(
      // An empty file holds the place until the export replaces it.
      file: ExportedFile(type: .mpeg4Movie) { Data() }, name: name + ".mp4"
    ) { result in
      guard case .success(let url) = result else { return }
      Task {
        do {
          let composition = try await TimelineComposition.make(clip: item, history: history)
          create.queue(
            TimelineExportJob(
              composition: composition, upscale: upscale, title: history.fileName(for: item),
              destination: url))
        } catch {
          deleteError = error.localizedDescription
        }
      }
    }
  }

  /// `name.png` in `folder`, or `name 2.png`, … when that's taken.
  private static func unusedURL(in folder: URL, name: String, extension ext: String) -> URL {
    var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
      n += 1
    }
    return url
  }

  /// Appends videos to the timeline on screen in the Video Editor (a new one when there's none).
  private func addToTimeline(_ items: [HistoryItem]) {
    timelines.append(items, undoManager: undoManager)
  }

  /// ", and from the timeline “Timeline 1”" when deleting takes clips off timelines.
  private func timelineNote(_ items: [HistoryItem]) -> String {
    let names = Set(items.filter(\.isVideo).flatMap { timelines.timelines(using: $0.tensorId) }.map(\.name))
    guard !names.isEmpty else { return "" }
    let list = names.sorted().map { "“\($0)”" }.formatted(.list(type: .and))
    return ", and from the timeline\(names.count > 1 ? "s" : "") \(list)"
  }

  private func delete(_ items: [HistoryItem]) {
    pendingDelete = nil
    Task {
      do {
        try await history.delete(items)
        timelines.removeClips(Set(items.filter(\.isVideo).map(\.tensorId)))
      } catch {
        deleteError = error.localizedDescription
      }
      selectOnly(history.currentItem?.tensorId ?? filtered.first?.tensorId)
    }
  }
}

/// The inspector when several images are selected.
struct HistorySelectionDetail: View {
  @Environment(HistoryStore.self) private var history
  var items: [HistoryItem]
  var export: () -> Void
  var delete: () -> Void
  /// iPad only.
  var saveToPhotos: () -> Void = {}

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
        Text("\(items.count) selected")
          .foregroundStyle(.secondary)
        LabeledContent("Rating") {
          let ratings = Set(items.map(history.rating(of:)))
          StarRating(stars: ratings.count == 1 ? ratings.first ?? 0 : 0) {
            history.setRating($0, for: items)
          }
        }
        ButtonRow {
          Button("Copy Images") { Task { await history.copyImages(items) } }
          Button("Export…", action: export)
          #if os(iOS)
            Button("Save to Photos", action: saveToPhotos)
          #endif
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
  @Environment(TimelineStore.self) private var timelines
  @Environment(\.undoManager) private var undoManager
  var item: HistoryItem
  var use: () -> Void
  var rerun: () -> Void
  var export: () -> Void
  var delete: () -> Void
  /// iPad only.
  var saveToPhotos: () -> Void = {}
  var upscale: () -> Void = {}

  var body: some View {
    let sidecar = item.sidecar
    Form {
      Section {
        if item.isVideo {
          ClipPlayer(item: item, autoplay: false)
            .frame(maxWidth: .infinity)
            .frame(height: 260)
        } else {
          Thumbnail(item: item, half: false, fill: false)
            .frame(maxWidth: .infinity)
            .frame(height: 260)
        }
        ButtonRow {
          Button("Use Settings", action: use)
          Button("Rerun with New Seed", action: rerun)
        }
        .disabled(!create.canUse(item))
        LabeledContent("Rating") {
          StarRating(stars: history.rating(of: item)) { history.setRating($0, for: [item]) }
        }
        if !create.models.contains(where: { $0.file == sidecar.model }) {
          Label("\(sidecar.model) isn't downloaded.", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.secondary)
        }
        ButtonRow {
          Button(item.isVideo ? "Copy Frame" : "Copy Image") { Task { await history.copyImage(item) } }
          Button(item.isVideo ? "Export Video…" : "Export PNG…", action: export)
          #if os(iOS)
            Button("Save to Photos", action: saveToPhotos)
          #endif
          Button("Delete", role: .destructive, action: delete)
        }
        if item.isVideo {
          ButtonRow {
            Button("Add to Timeline") { timelines.append([item], undoManager: undoManager) }
              .help("Add the video to the end of the timeline open in the Video Editor")
            Button("Upscale…", action: upscale)
              .help("Make a sharper, larger copy of the video with FlashVSR+ or Apple Super Resolution")
          }
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
        if let clip = item.clip {
          LabeledContent("Length", value: ClipBadge.length(clip))
        }
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

/// Five stars to click: a star sets that rating, the current rating's star clears it.
struct StarRating: View {
  var stars: Int
  var set: (Int) -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(1...5, id: \.self) { n in
        Button {
          set(n == stars ? 0 : n)
        } label: {
          Image(systemName: n <= stars ? "star.fill" : "star")
            .foregroundStyle(n <= stars ? Color.yellow : Color.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(n == stars ? "Clear the rating" : "Rate \(Self.text(n))")
        .accessibilityLabel(n == 1 ? "1 star" : "\(n) stars")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityValue(stars == 0 ? "Unrated" : "\(stars) of 5 stars")
  }

  /// "★★★".
  static func text(_ stars: Int) -> String {
    String(repeating: "★", count: stars)
  }
}

/// An image's rating in grids and graph rows.
struct RatingBadge: View {
  let stars: Int
  /// Without the dark capsule grids draw over images.
  var plain = false

  var body: some View {
    let label = Text(StarRating.text(stars))
      .font(.caption2)
      .foregroundStyle(.yellow)
      .help(stars == 1 ? "Rated 1 star" : "Rated \(stars) stars")
    if plain {
      label
    } else {
      label
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: .capsule)
    }
  }
}

/// A clip's mark in grids: a film icon and how long it plays (a speaker when it has sound).
struct ClipBadge: View {
  let clip: ClipInfo

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "film")
      Text(clip.duration.formatted(.number.precision(.fractionLength(1))) + "s")
      if clip.audioId != nil { Image(systemName: "speaker.wave.2.fill") }
    }
    .font(.caption2.monospacedDigit())
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(.black.opacity(0.55), in: .capsule)
    .foregroundStyle(.white)
    .help(Self.length(clip))
  }

  /// "5.0 seconds, 121 frames at 24 fps, with sound".
  static func length(_ clip: ClipInfo) -> String {
    let seconds = clip.duration.formatted(.number.precision(.fractionLength(1)))
    let fps = clip.framesPerSecond.formatted(.number.precision(.fractionLength(0...2)))
    return "\(seconds) seconds, \(clip.frames.count) frames at \(fps) fps"
      + (clip.audioId != nil ? ", with sound" : "")
  }
}

/// A clip in grids: its first frame; on the Mac, moving the pointer across it scrubs through the
/// frames.
struct ClipThumbnail: View {
  let item: HistoryItem
  @State private var shown: Int?

  var body: some View {
    var frame = item
    if let clip = item.clip, let shown, clip.frames.indices.contains(shown) {
      frame.previewId = clip.previewId(shown)
    }
    return Thumbnail(item: frame)
      .onContinuousHover { phase in
        guard let count = item.clip?.frames.count, count > 1 else { return }
        switch phase {
        case .active(let location):
          // The width maps onto the frames, through the thumbnail's own coordinates.
          shown = min(max(Int(location.x / max(width, 1) * Double(count)), 0), count - 1)
        case .ended:
          shown = nil
        }
      }
      .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
  }

  @State private var width: Double = 1
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
      if fill { Color.quaternaryLabel }
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
  @State private var editingOutput = false

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
      Button("Output Folder…") { editingOutput = true }
      Button(Finder.showTitle) {
        Finder.reveal([history.project.url])
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
    .debugPresents(
      "newProject",
      Binding(get: { naming != nil }, set: { if $0 { naming = .new(suggested: history.availableName()) } }))
    .debugPresents("projectOutput", $editingOutput)
    .sheet(isPresented: $editingOutput) {
      ProjectOutputSheet(projectName: history.project.name, output: history.output) {
        history.setOutput($0)
      }
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

/// The current project's output folder: whether its new images are saved there, and where. Each
/// follows Settings until the project sets its own.
private struct ProjectOutputSheet: View {
  let projectName: String
  let output: ProjectOutput
  let commit: (ProjectOutput) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var saves: Bool?
  @State private var hasFolder = false
  @State private var folder = ""
  @State private var choosing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Output Folder for “\(projectName)”").font(.headline)
      Form {
        Picker("Save generated images", selection: $saves) {
          Text("As in Settings (\(AppSettings.savesToOutputFolder ? "On" : "Off"))").tag(Bool?.none)
          Divider()
          Text("On").tag(Bool?.some(true))
          Text("Off").tag(Bool?.some(false))
        }
        Toggle("Use a different folder for this project", isOn: $hasFolder)
        LabeledContent("Folder") {
          HStack {
            TextField("Path", text: $folder, prompt: Text(AppSettings.outputFolder))
              .labelsHidden()
              .disabled(!hasFolder)
            Button("Choose…") { choosing = true }
              .disabled(!hasFolder)
          }
        }
      }
      .formStyle(.grouped)
      .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result {
          FolderBookmarks.remember(url)
          folder = url.path
        }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save", action: confirm)
          .keyboardShortcut(.defaultAction)
          .disabled(hasFolder && trimmedFolder.isEmpty)
      }
    }
    .padding(20)
    .sheetFrame(width: 520)
    .onAppear {
      saves = output.saves
      hasFolder = output.folder != nil
      folder = output.folder ?? ""
    }
  }

  private var trimmedFolder: String { folder.trimmingCharacters(in: .whitespaces) }

  private func confirm() {
    dismiss()
    commit(ProjectOutput(saves: saves, folder: hasFolder ? trimmedFolder : nil))
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
    .sheetFrame(width: 320)
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

/// History's graph lanes, laid out as `git log --graph` does: rows newest first, each image in a
/// lane whose line runs down to the image it follows, where the lines of the images following
/// the same one meet.
struct HistoryGraph {
  struct Row {
    var column: Int
    /// Lanes whose line ends at this image: the images following it, above.
    var incoming: [Int]
    /// Lanes passing by.
    var through: [Int]
    /// Whether a line leaves this image downward, to the one it follows.
    var continues: Bool
  }

  private(set) var rows: [Row] = []
  private(set) var lanes = 1

  init(items: [HistoryItem], parent: (HistoryItem) -> HistoryItem?) {
    // The image each lane is waiting for, by tensor; nil while the lane is free.
    var open: [Int64?] = []
    for item in items {
      let incoming = open.indices.filter { open[$0] == item.tensorId }
      let column = incoming.first ?? open.firstIndex { $0 == nil } ?? open.count
      if column == open.count { open.append(nil) }
      let through = open.indices.filter { open[$0] != nil && !incoming.contains($0) }
      for lane in incoming { open[lane] = nil }
      let next = parent(item)?.tensorId
      open[column] = next
      while let last = open.last, last == nil { open.removeLast() }
      rows.append(Row(column: column, incoming: incoming, through: through, continues: next != nil))
      lanes = max(lanes, column + 1, (through.max() ?? 0) + 1, (incoming.max() ?? 0) + 1)
    }
  }
}

/// A row of History's graph: the lanes, then the thumbnail, prompt, model and time.
struct HistoryGraphRow: View {
  @Environment(CreateModel.self) private var create
  var item: HistoryItem
  var row: HistoryGraph.Row
  var lanes: Int
  var isCurrent: Bool
  var isSelected: Bool
  var stars = 0

  private static let height: CGFloat = 60
  private static let laneWidth: CGFloat = 14
  private static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red]

  var body: some View {
    let sidecar = item.sidecar
    HStack(spacing: 10) {
      Canvas { context, size in draw(in: &context, size: size) }
        .frame(width: CGFloat(min(lanes, 16)) * Self.laneWidth, height: Self.height)
      Thumbnail(item: item)
        .frame(width: 48, height: 48)
        .clipShape(.rect(cornerRadius: 4))
      VStack(alignment: .leading, spacing: 2) {
        Text(sidecar.prompt.isEmpty ? "No prompt" : sidecar.prompt)
          .lineLimit(2)
        Text(
          [
            modelName(sidecar.model),
            item.clip.map { "Video, " + $0.duration.formatted(.number.precision(.fractionLength(1))) + " s" },
            sidecar.createdAt.formatted(date: .abbreviated, time: .shortened),
          ].compactMap(\.self).joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if stars > 0 { RatingBadge(stars: stars, plain: true) }
      if isCurrent {
        Text("Current")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("The next image follows this one")
      }
    }
    .padding(.horizontal, 12)
    .frame(height: Self.height)
    .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
  }

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    let middle = size.height / 2
    func x(_ lane: Int) -> CGFloat { Self.laneWidth * (CGFloat(lane) + 0.5) }
    func color(_ lane: Int) -> Color { Self.colors[lane % Self.colors.count] }
    func stroke(_ path: Path, _ lane: Int) {
      context.stroke(path, with: .color(color(lane)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
    for lane in row.through {
      stroke(Path { $0.move(to: CGPoint(x: x(lane), y: 0)); $0.addLine(to: CGPoint(x: x(lane), y: size.height)) }, lane)
    }
    let dot = CGPoint(x: x(row.column), y: middle)
    for lane in row.incoming {
      stroke(
        Path {
          $0.move(to: CGPoint(x: x(lane), y: 0))
          $0.addCurve(
            to: dot, control1: CGPoint(x: x(lane), y: middle * 0.8),
            control2: CGPoint(x: dot.x, y: middle * 0.4))
        }, lane)
    }
    if row.continues {
      stroke(Path { $0.move(to: dot); $0.addLine(to: CGPoint(x: dot.x, y: size.height)) }, row.column)
    }
    let radius: CGFloat = 4.5
    context.fill(
      Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2)),
      with: .color(color(row.column)))
    if isCurrent {
      let ring = radius + 2.5
      context.stroke(
        Path(ellipseIn: CGRect(x: dot.x - ring, y: dot.y - ring, width: ring * 2, height: ring * 2)),
        with: .color(.primary), lineWidth: 1.5)
    }
  }

  private func modelName(_ file: String) -> String {
    create.models.first { $0.file == file }?.name ?? file
  }
}
