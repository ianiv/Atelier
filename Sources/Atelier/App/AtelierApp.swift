import SwiftUI

@main
struct AtelierApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
  #endif
  @FocusedValue(\.windowUndoManager) private var undoManager
  @State private var history: HistoryStore
  @State private var create: CreateModel
  @State private var navigation: Navigation
  @State private var layouts: LayoutStore
  @State private var presets: PresetStore
  @State private var library: ModelLibrary
  #if os(macOS)
    @State private var agents: AgentServer
    @State private var updater = Updater()
  #endif
  @State private var fileDialogs = FileDialogs()
  @AppStorage("inspectorShown") private var inspectorShown = true
  @AppStorage("moodboardShown") private var moodboardShown = true

  init() {
    #if os(iOS)
      // Made up front so Files shows them, ready for models copied in.
      for folder in [URL(fileURLWithPath: AppSettings.modelsDirectory), AppSettings.historyDirectory] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
      // A models folder picked outside the app stays readable while Atelier runs.
      FolderBookmarks.keepOpen(AppSettings.modelsDirectory)
    #endif
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
    #if os(macOS)
      _agents = State(initialValue: AgentServer(create: create, presets: presets))
      // Started here rather than from a view's .task: SwiftUI doesn't put windows up while the
      // screen is locked, and scripted checks still need to run then.
      Task { @MainActor in
        Automation.runIfRequested(
          create, navigation: navigation, layouts: layouts, presets: presets, library: library)
      }
    #endif
  }

  var body: some Scene {
    // A fixed id keeps the window's saved frame under a stable name; without one SwiftUI names it
    // after the view's modifier types, so the frame is forgotten whenever a modifier changes.
    WindowGroup("Atelier", id: "main") {
      LayoutCheckFrame {
        ContentView()
          .environment(create)
          .environment(create.timelines)
          .environment(history)
          .environment(navigation)
          .environment(layouts)
          .environment(presets)
          .environment(library)
          .environment(fileDialogs)
      }
      #if os(macOS)
        .frame(minWidth: 960, minHeight: 640)
      #endif
    }
    .commands {
      CommandGroup(after: .sidebar) {
        Button(inspectorShown ? "Hide Inspector" : "Show Inspector") { inspectorShown.toggle() }
          .keyboardShortcut("i", modifiers: [.command, .option])
        Button(moodboardShown ? "Hide Moodboard" : "Show Moodboard") { moodboardShown.toggle() }
        Divider()
        if navigation.section == .timeline {
          TimelineZoomMenuItems(store: create.timelines, history: history)
        } else {
          ZoomMenuItems(canvas: create.canvas)
            .disabled(navigation.section != .create)
        }
      }
      CommandMenu("Image") {
        Button("Focus Prompt") {
          navigation.section = .create
          create.focusPromptRequest += 1
        }
        .keyboardShortcut("l", modifiers: .command)
        Button("Roll Seed") { create.rollSeed() }
          .keyboardShortcut("r", modifiers: .command)
        Divider()
        Button("Previous Prompt") {
          navigation.section = .create
          create.previousPrompt()
        }
        .keyboardShortcut(.upArrow, modifiers: .command)
        .disabled(create.recentPrompts.isEmpty)
        Button("Next Prompt") {
          navigation.section = .create
          create.nextPrompt()
        }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .disabled(create.recentPrompts.isEmpty)
        Button("Clear Prompt History…") { create.confirmClearRecentPrompts = true }
          .disabled(create.recentPrompts.isEmpty)
        Divider()
        Button("Open Image…") {
          navigation.section = .create
          create.imageImport = .canvas
        }
        .keyboardShortcut("o", modifiers: .command)
        Button("Paste Image") {
          navigation.section = .create
          create.pasteImage()
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        Button("Load Settings from Image") {
          navigation.section = .create
          create.loadCanvasImageSettings(undoManager: undoManager)
        }
        .disabled(create.canvasImageSettings == nil)
        Button("Clear Canvas") { create.clearCanvas() }
          .disabled(navigation.section != .create)
        Divider()
        Picker("Mode", selection: Binding(get: { create.effectiveCanvasMode }, set: { create.canvasMode = $0 })) {
          Text("Generate").tag(CreateModel.CanvasMode.generate)
          Text("Edit").tag(CreateModel.CanvasMode.edit)
        }
        .pickerStyle(.inline)
        .disabled(!create.canEdit)
      }
      #if os(macOS)
        UpdateCommands(updater: updater)
      #endif
    }
    #if os(macOS)
    Settings {
      SettingsTabs(agents: agents)
        .environment(create)
    }
    #endif
  }
}

/// Settings' tabs: the Settings window on the Mac, a sheet on iPad (without Agents, which is Mac
/// only).
struct SettingsTabs: View {
  #if os(macOS)
    let agents: AgentServer
  #endif

  /// The first tab, or in Debug builds the one `-AtelierSettingsTab NAME` names (layout checks).
  @State private var tab: String = {
    #if DEBUG
      UserDefaults.standard.string(forKey: "AtelierSettingsTab") ?? "Models"
    #else
      "Models"
    #endif
  }()

  var body: some View {
    TabView(selection: $tab) {
      Tab("Models", systemImage: "shippingbox", value: "Models") {
        ModelsSettingsView()
      }
      Tab("Images", systemImage: "photo.on.rectangle", value: "Images") {
        ImagesSettingsView()
      }
      Tab("Performance", systemImage: "gauge.with.dots.needle.67percent", value: "Performance") {
        PerformanceSettingsView()
      }
      #if os(macOS)
        Tab("Agents", systemImage: "sparkles", value: "Agents") {
          AgentSettingsView()
            .environment(agents)
        }
      #endif
      Tab("About", systemImage: "info.circle", value: "About") {
        AboutSettingsView()
      }
    }
  }
}

/// Settings ▸ About: the version, Atelier's license and the open-source work it builds on (as in
/// NOTICE).
struct AboutSettingsView: View {
  private struct Credit: Identifiable {
    let name: String
    let detail: String
    let url: String
    var id: String { name }
  }

  private static var credits: [Credit] {
    var credits = [
      Credit(
        name: "draw-things-community", detail: "The generation engine. Draw Things, GPL-3.0.",
        url: "https://github.com/drawthingsai/draw-things-community"),
      Credit(
        name: "vpipe", detail: "FlashVSR+ upscaling follows its Metal port. T-Go LLC, Apache-2.0.",
        url: "https://github.com/tgo-app-dev/vpipe"),
      Credit(
        name: "FlashVSR and FlashVSR+", detail: "The Quality upscaler and its weights. OpenImagingLab, Apache-2.0.",
        url: "https://github.com/OpenImagingLab/FlashVSR"),
    ]
    #if os(macOS)
      credits.append(
        Credit(name: "Sparkle", detail: "Updates. MIT.", url: "https://github.com/sparkle-project/Sparkle"))
    #endif
    return credits
  }

  private var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Version", value: version)
        LabeledContent("License") {
          Link("GNU GPL v3.0", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
        }
        Link("Source and documentation", destination: URL(string: "https://github.com/ianiv/Atelier")!)
      } header: {
        Text("Atelier")
      }
      Section {
        ForEach(Self.credits) { credit in
          VStack(alignment: .leading, spacing: 2) {
            Link(credit.name, destination: URL(string: credit.url)!)
            Text(credit.detail).foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Acknowledgements")
      } footer: {
        Text("Their licenses and notices are in the NOTICE file with Atelier's source. Models you use keep their own licenses.")
          .foregroundStyle(.secondary)
      }
    }
    .settingsForm()
  }
}
