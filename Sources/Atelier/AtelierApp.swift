import SwiftUI

@main
struct AtelierApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @State private var history: HistoryStore
  @State private var create: CreateModel
  @State private var navigation: Navigation
  @State private var layouts: LayoutStore
  @State private var presets: PresetStore
  @State private var library: ModelLibrary
  @AppStorage("inspectorShown") private var inspectorShown = true

  init() {
    let history = HistoryStore()
    _history = State(initialValue: history)
    let create = CreateModel(history: history)
    _create = State(initialValue: create)
    let navigation = Navigation()
    _navigation = State(initialValue: navigation)
    let layouts = LayoutStore()
    _layouts = State(initialValue: layouts)
    let presets = PresetStore()
    create.presets = presets
    _presets = State(initialValue: presets)
    let library = ModelLibrary(create: create)
    _library = State(initialValue: library)
    // Started here rather than from a view's .task: SwiftUI doesn't put windows up while the
    // screen is locked, and scripted checks still need to run then.
    Task { @MainActor in
      Automation.runIfRequested(
        create, navigation: navigation, layouts: layouts, presets: presets, library: library)
    }
  }

  var body: some Scene {
    WindowGroup("Atelier") {
      ContentView()
        .environment(create)
        .environment(history)
        .environment(navigation)
        .environment(layouts)
        .environment(presets)
        .environment(library)
        .frame(minWidth: 960, minHeight: 640)
    }
    .commands {
      CommandGroup(after: .sidebar) {
        Button(inspectorShown ? "Hide Inspector" : "Show Inspector") { inspectorShown.toggle() }
          .keyboardShortcut("i", modifiers: [.command, .option])
      }
      CommandMenu("Image") {
        Button("Focus Prompt") {
          navigation.section = .create
          create.focusPromptRequest += 1
        }
        .keyboardShortcut("l", modifiers: .command)
        Button("Roll Seed") { create.rollSeed() }
          .keyboardShortcut("r", modifiers: .command)
      }
    }
    Settings {
      SettingsView()
        .environment(create)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
