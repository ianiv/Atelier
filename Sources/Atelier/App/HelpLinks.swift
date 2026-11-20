import SwiftUI

/// Where each screen's user guide lives. The guide is the repo's `docs/` folder on GitHub (the
/// same pages Settings ▸ About links to), so help always matches the latest docs without
/// bundling a copy into the app.
enum HelpLinks {
  static let base = URL(string: "https://github.com/ianiv/Atelier/blob/main/")!

  /// The guide's table of contents, for the Help menu.
  static let index = base.appending(path: "docs/README.md")

  static func page(for section: ContentView.Section) -> URL {
    switch section {
    case .create: base.appending(path: "docs/creating-images.md")
    case .queue: base.appending(path: "docs/queue.md")
    case .history: base.appending(path: "docs/history.md")
    case .edit: base.appending(path: "docs/editing.md")
    case .videoEditor: base.appending(path: "docs/video-editor.md")
    case .models: anchored("docs/models-and-loras.md", "models")
    case .loras: anchored("docs/models-and-loras.md", "loras")
    case .styles: base.appending(path: "docs/styles.md")
    }
  }

  private static func anchored(_ path: String, _ fragment: String) -> URL {
    var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
    components.fragment = fragment
    return components.url!
  }
}

/// Each screen's help button, last in its toolbar (before Create's inspector toggle, which stays
/// at the edge) and in a capsule of its own rather than merged into the screen's buttons.
struct HelpToolbarItem: ToolbarContent {
  let section: ContentView.Section
  var placement: ToolbarItemPlacement = .automatic

  var body: some ToolbarContent {
    ToolbarSpacer(.fixed, placement: placement)
    ToolbarItem(placement: placement) { HelpButton(section: section) }
  }
}

/// The toolbar's help button: opens the guide page for the screen it's on.
struct HelpButton: View {
  let section: ContentView.Section
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button("Help", systemImage: "questionmark") { openURL(HelpLinks.page(for: section)) }
      .help("Open the \(section.rawValue) guide")
  }
}

/// Help ▸ Atelier Help, in place of the system item (which on the Mac only says help isn't
/// available, since the app ships no Help Book).
struct HelpCommands: Commands {
  var body: some Commands {
    CommandGroup(replacing: .help) {
      HelpIndexButton()
    }
  }
}

/// A view, not a button inside `HelpCommands`, so it can read `openURL` from the environment.
private struct HelpIndexButton: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button("Atelier Help") { openURL(HelpLinks.index) }
      .keyboardShortcut("?", modifiers: .command)
  }
}
