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
    return ContentView.Section(rawValue: saved) ?? .create
  }
}

struct ContentView: View {
  enum Section: String, CaseIterable, Identifiable {
    case create = "Create"
    case queue = "Queue"
    case history = "History"
    case models = "Models"
    case loras = "LoRAs"

    var id: String { rawValue }

    var symbol: String {
      switch self {
      case .create: "paintbrush"
      case .queue: "list.number"
      case .history: "clock"
      case .models: "shippingbox"
      case .loras: "slider.horizontal.3"
      }
    }
  }

  @Environment(Navigation.self) private var navigation
  @Environment(CreateModel.self) private var create
  @Environment(FileDialogs.self) private var fileDialogs
  @Environment(\.undoManager) private var undoManager
  @State private var showingSettings = false

  /// Images running or waiting in the queue.
  private var queueCount: Int {
    create.queue.waiting.count + (create.queue.running == nil ? 0 : 1)
  }

  var body: some View {
    @Bindable var navigation = navigation
    @Bindable var create = create
    NavigationSplitView {
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
      case .models:
        ModelsView()
      case .loras:
        LoRAsView()
      }
    }
    .confirmationDialog(
      "Clear prompt history?", isPresented: $create.confirmClearRecentPrompts
    ) {
      Button("Clear", role: .destructive) { create.clearRecentPrompts() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Forgets the \(create.recentPrompts.count) recent prompts that ⌘↑ and ⌘↓ step through. Images in History keep their prompts. This can't be undone.")
    }
    // Open Image… and Add Images…, from the menus, the canvas and the moodboard.
    .onChange(of: create.imageImport, initial: true) {
      guard let target = create.imageImport else { return }
      create.imageImport = nil
      fileDialogs.open = FileDialogs.Open(types: [.image], multiple: target == .moodboard) { urls in
        create.importImages(urls, into: target)
      }
    }
    .fileDialogs(fileDialogs)
    #if os(iOS)
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
    // For menu commands, which act on the key window's undo stack.
    .focusedSceneValue(\.windowUndoManager, undoManager)
  }
}

extension FocusedValues {
  @Entry var windowUndoManager: UndoManager?
}
