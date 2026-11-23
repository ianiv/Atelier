import Observation
import SwiftUI

/// The selected sidebar section, shared so other screens (and Automation) can switch it.
@MainActor
@Observable
final class Navigation {
  var section: ContentView.Section? = Navigation.savedSection {
    didSet {
      guard SessionState.isEnabled else { return }
      UserDefaults.standard.set(section?.rawValue, forKey: "section")
    }
  }

  private static var savedSection: ContentView.Section {
    guard SessionState.isEnabled, let saved = UserDefaults.standard.string(forKey: "section") else {
      return .create
    }
    // Before 0.4 the Video Editor was called Timeline.
    return ContentView.Section(rawValue: saved == "Timeline" ? "Video Editor" : saved) ?? .create
  }
}

struct ContentView: View {
  enum Section: String, CaseIterable, Identifiable {
    case create = "Create"
    case queue = "Queue"
    case history = "History"
    case edit = "Edit"
    case videoEditor = "Video Editor"
    case models = "Models"
    case loras = "LoRAs"
    case styles = "Styles"

    var id: String { rawValue }

    var symbol: String {
      switch self {
      case .create: "paintbrush"
      case .queue: "list.number"
      case .history: "clock"
      case .edit: Edit.symbol
      case .videoEditor: "film.stack"
      case .models: "shippingbox"
      case .loras: "slider.horizontal.3"
      case .styles: "paintpalette"
      }
    }
  }

  @Environment(Navigation.self) private var navigation
  @Environment(CreateModel.self) private var create
  @Environment(HistoryStore.self) private var history
  @Environment(FileDialogs.self) private var fileDialogs
  @Environment(\.undoManager) private var undoManager
  @State private var showingSettings = false
  @State private var offeringDrawThingsImport = false
  @State private var columns = NavigationSplitViewVisibility.automatic

  /// Images running or waiting in the queue.
  private var queueCount: Int {
    create.queue.waiting.count + (create.queue.running == nil ? 0 : 1)
  }

  @State private var windowSize: CGSize = .zero

  var body: some View {
    @Bindable var navigation = navigation
    @Bindable var create = create
    NavigationSplitView(columnVisibility: $columns) {
      List(Section.allCases, selection: $navigation.section) { section in
        HStack {
          Label(section.rawValue, systemImage: section.symbol)
          Spacer()
          if section == .queue, queueCount > 0 {
            // A pill rather than `.badge`, which the sidebar draws small and faint. Inverted on
            // the selected row, whose highlight is the accent colour.
            let selected = navigation.section == .queue
            Text("\(queueCount)")
              .font(.callout.bold().monospacedDigit())
              .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
              .padding(.horizontal, 7)
              .padding(.vertical, 1)
              .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint), in: .capsule)
              .help("\(queueCount) running or waiting")
          }
        }
        .tag(section)
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 180)
      #if os(iOS)
        // iPad has no Settings window: Settings is a sheet from the sidebar.
        .toolbar {
          ToolbarItem {
            Button("Settings", systemImage: "gear") { showingSettings = true }
              .keyboardShortcut(",", modifiers: .command)
          }
        }
      #endif
    } detail: {
      switch navigation.section {
      case .create, nil:
        CreateView()
      case .queue:
        QueueView()
      case .history:
        HistoryView()
      case .edit:
        EditScreen()
      case .videoEditor:
        TimelineScreen()
      case .models:
        ModelsView()
      case .loras:
        LoRAsView()
      case .styles:
        StylesView()
      }
    }
    // Offered when a project opens with a lot of unused space; it doesn't stop anything.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let offer = history.compactionOffer, !create.showsCompactProject {
        CompactionOfferBar(offer: offer)
      }
    }
    .sheet(isPresented: $create.showsCompactProject) { CompactProjectSheet() }
    .debugPresents("compactProject", $create.showsCompactProject)
    .confirmationDialog(
      "Clear prompt history?", isPresented: $create.confirmClearRecentPrompts
    ) {
      Button("Clear", role: .destructive) { create.clearRecentPrompts() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Forgets the \(create.recentPrompts.count) recent prompts that ⌘↑ and ⌘↓ step through. Images in History keep their prompts. This can't be undone.")
    }
    #if os(iOS)
      // A window too narrow for the sidebar, the screen and its inspector side by side hides the
      // sidebar (the toolbar button shows it over the screen), so the inspector stays a column
      // rather than covering the screen. Recomputed only when the window crosses the width.
      .onGeometryChange(for: Bool.self) { $0.size.width >= Self.sidebarMinimumWidth } action: { wide in
        columns = wide ? .all : .detailOnly
      }
    #endif
      // Open Image… and Add Images…, from the menus, the canvas and the moodboard.
      .onChange(of: create.imageImport, initial: true) {
        guard let target = create.imageImport else { return }
        create.imageImport = nil
        fileDialogs.open = FileDialogs.Open(types: [.image], multiple: target == .moodboard) { urls in
          create.importImages(urls, into: target)
        }
      }
      // Open from Photos… and Add from Photos…, likewise.
      .onChange(of: create.photosImport, initial: true) {
        guard let target = create.photosImport else { return }
        create.photosImport = nil
        fileDialogs.photos = FileDialogs.Photos(multiple: target == .moodboard) { photos, failed in
          create.importPhotos(photos, failed: failed, into: target)
        }
      }
      // Open Video… and Open Video from Photos…: the video joins the project.
      .onChange(of: create.videoOpen, initial: true) {
        guard create.videoOpen else { return }
        create.videoOpen = false
        fileDialogs.open = FileDialogs.Open(types: [.movie]) { urls in create.importVideos(urls) }
      }
      .onChange(of: create.videoPhotosOpen, initial: true) {
        guard create.videoPhotosOpen else { return }
        create.videoPhotosOpen = false
        fileDialogs.photos = FileDialogs.Photos(videos: true) { _, _ in } videoCompletion: { videos, failed in
          if let video = videos.first { create.importVideo(video, name: "Video from Photos", moving: true) }
          if failed > 0 { create.errorMessage = "Couldn't load the video." }
        }
      }
      .fileDialogs(fileDialogs)
    #if os(iOS)
      .onChange(of: create.isRunning, initial: true) {
        AppLifecycle.keepScreenAwake(create.isRunning)
      }
      #if DEBUG
        // For layout checks (Scripts/ipad-layout-shots.sh): -AtelierShowSettings YES.
        .onAppear { if UserDefaults.standard.bool(forKey: "AtelierShowSettings") { showingSettings = true } }
      #endif
      .sheet(isPresented: $showingSettings) {
        NavigationStack {
          SettingsTabs()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showingSettings = false }
              }
            }
        }
      }
    #endif
      .sheet(isPresented: $offeringDrawThingsImport) { DrawThingsImportSheet() }
      .debugPresents("drawThingsImport", $offeringDrawThingsImport)
      .onAppear { if DrawThingsApp.takeFirstRunOffer() { offeringDrawThingsImport = true } }
      // For menu commands, which act on the key window's undo stack.
      .focusedSceneValue(\.windowUndoManager, undoManager)
      // Sheets size themselves from it: SwiftUI gives them no way to ask about the window or screen.
      .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
      .environment(\.mainWindowSize, windowSize)
  }
}

#if os(iOS)
  extension ContentView {
    /// The narrowest window that keeps the sidebar beside a screen and its inspector.
    nonisolated static let sidebarMinimumWidth: CGFloat = 1000
  }
#endif

extension EnvironmentValues {
  /// The size of the window's content, for a sheet to size itself by.
  @Entry var mainWindowSize: CGSize = .zero
}

extension FocusedValues {
  @Entry var windowUndoManager: UndoManager?
  /// Opens History's selected image full size, for Show Image Full Size (⌘Y); nil with none.
  @Entry var showHistoryImageFullSize: (() -> Void)?
}
