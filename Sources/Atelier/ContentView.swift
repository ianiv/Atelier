import SwiftUI

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

  @State private var section: Section? = .create

  var body: some View {
    NavigationSplitView {
      List(Section.allCases, selection: $section) { section in
        Label(section.rawValue, systemImage: section.symbol).tag(section)
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 180)
    } detail: {
      switch section {
      case .create, nil:
        CreateView()
      case .some(let section):
        ContentUnavailableView(
          section.rawValue, systemImage: section.symbol,
          description: Text("Coming in a later phase."))
      }
    }
  }
}
