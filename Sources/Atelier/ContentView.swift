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

  var body: some View {
    @Bindable var navigation = navigation
    NavigationSplitView {
      List(Section.allCases, selection: $navigation.section) { section in
        Label(section.rawValue, systemImage: section.symbol).tag(section)
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 180)
    } detail: {
      switch navigation.section {
      case .create, nil:
        CreateView()
      case .history:
        HistoryView()
      case .models:
        ModelsView()
      case .loras:
        LoRAsView()
      case .some(let section):
        ContentUnavailableView(
          section.rawValue, systemImage: section.symbol,
          description: Text("Coming in a later phase."))
      }
    }
    .background(WindowFrameAutosave(name: "Main"))
  }
}
