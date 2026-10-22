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

/// A search field for a section's toolbar, used instead of `.searchable(placement: .toolbar)`.
/// Switching from Create's customizable toolbar to one with a `.searchable` item crashes AppKit
/// ("NSToolbarItemViewer's min/max size is nan"), so the sections own a plain toolbar item.
struct ToolbarSearchField: NSViewRepresentable {
  let prompt: String
  @Binding var text: String

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = prompt
    field.sendsSearchStringImmediately = true
    field.target = context.coordinator
    field.action = #selector(Coordinator.changed(_:))
    field.widthAnchor.constraint(equalToConstant: 200).isActive = true
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.text = $text
    if field.stringValue != text { field.stringValue = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  /// Sent on every keystroke (`sendsSearchStringImmediately`) and when the clear button is pressed.
  final class Coordinator: NSObject {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }

    @objc func changed(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
  }
}
