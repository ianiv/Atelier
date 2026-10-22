import SwiftUI
import _MediaGenerationKit

struct CreateView: View {
  @Environment(CreateModel.self) private var model
  @AppStorage("inspectorShown") private var inspectorShown = true

  var body: some View {
    VStack(spacing: 0) {
      CanvasView()
      Divider()
      PromptComposer()
    }
    .inspector(isPresented: $inspectorShown) {
      InspectorView()
        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
    }
    .toolbar(id: "create") {
      ToolbarItem(id: "model", placement: .navigation) {
        ModelPicker()
      }
      ToolbarItem(id: "presets", placement: .primaryAction) {
        PresetMenu()
      }
      ToolbarItem(id: "generate", placement: .primaryAction) {
        if model.isBusy, model.phase != .loadingModel {
          Button("Cancel", systemImage: "stop.fill") { model.cancel() }
            .disabled(model.phase == .cancelling)
            .help("Cancel the running generation (⎋)")
        } else {
          Button("Generate", systemImage: "sparkles") { model.generate() }
            .disabled(!model.canGenerate)
            .help("Generate (⌘↩)")
        }
      }
      ToolbarItem(id: "inspector", placement: .primaryAction) {
        Button("Inspector", systemImage: "sidebar.trailing") { inspectorShown.toggle() }
          .help(inspectorShown ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
      }
    }
  }
}

struct ModelPicker: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    @Bindable var model = model
    Picker("Model", selection: $model.selectedModel) {
      if model.models.isEmpty {
        Text("No downloaded models").tag(String?.none)
      }
      ForEach(model.models, id: \.file) { entry in
        Text(entry.name).tag(Optional(entry.file))
      }
    }
    .pickerStyle(.menu)
    .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
    .help(model.selectedModelInfo.map { "\($0.name) (\($0.version ?? "unknown family"))" } ?? "Model")
  }
}

struct CanvasView: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Color(nsColor: .underPageBackgroundColor)
        if let image = model.image {
          Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .padding(24)
        } else {
          ContentUnavailableView(
            "No image yet", systemImage: "photo",
            description: Text("Write a prompt below and press Generate (⌘↩)."))
        }
      }
      statusBar
    }
  }

  private var statusBar: some View {
    HStack(spacing: 12) {
      switch model.phase {
      case .idle:
        if let error = model.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .lineLimit(2)
        } else if let url = model.lastSavedURL {
          Text("Saved \(url.lastPathComponent)").foregroundStyle(.secondary)
          Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .buttonStyle(.link)
        } else {
          Text("Ready").foregroundStyle(.secondary)
        }
      case .loadingModel:
        ProgressView().controlSize(.small)
        Text("Loading model…").foregroundStyle(.secondary)
      case .running(let message):
        Text(message).monospacedDigit()
        if model.totalSteps > 0 {
          ProgressView(value: Double(model.step), total: Double(model.totalSteps))
            .frame(maxWidth: 320)
        }
      case .cancelling:
        ProgressView().controlSize(.small)
        Text("Cancelling…")
      }
      Spacer()
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .frame(height: 32)
    .background(.bar)
  }
}

/// The prompt box under the canvas: grows to about six lines, with the negative prompt tucked
/// under a disclosure and Generate beside it.
struct PromptComposer: View {
  @Environment(CreateModel.self) private var model
  @AppStorage("showNegativePrompt") private var showNegative = false
  @FocusState private var promptFocused: Bool

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .bottom, spacing: 10) {
        TextField("Describe the image…", text: $model.prompt, axis: .vertical)
          .lineLimit(3...6)
          .textFieldStyle(.plain)
          .font(.body)
          .focused($promptFocused)
          .onSubmit { model.generate() }
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(promptFocused ? Color.accentColor : Color(nsColor: .separatorColor))
          )
          .help("Prompt. Return generates; ⌥↩ adds a line. ⌘L focuses this field.")
        if model.isBusy, model.phase != .loadingModel {
          Button {
            model.cancel()
          } label: {
            Label("Cancel", systemImage: "stop.fill").frame(minWidth: 90)
          }
          .controlSize(.large)
          .keyboardShortcut(.escape, modifiers: [])
          .disabled(model.phase == .cancelling)
        } else {
          Button {
            model.generate()
          } label: {
            Label("Generate", systemImage: "sparkles").frame(minWidth: 90)
          }
          .controlSize(.large)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!model.canGenerate)
        }
      }
      DisclosureGroup(isExpanded: $showNegative) {
        TextField("What to avoid", text: $model.negativePrompt, axis: .vertical)
          .lineLimit(1...4)
          .textFieldStyle(.roundedBorder)
      } label: {
        ClickableLabel("Negative Prompt", isExpanded: $showNegative)
      }
      .font(.callout)
    }
    .padding(12)
    .background(.bar)
    .onChange(of: model.focusPromptRequest) { promptFocused = true }
  }
}

struct SeedControls: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    @Bindable var model = model
    LabeledContent("Seed") {
      HStack(spacing: 6) {
        TextField(
          "Seed",
          value: Binding(
            get: { model.seed },
            set: {
              model.seed = $0
              model.seedLocked = true
            }), format: .number.grouping(.never)
        )
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 120)
        Button {
          model.rollSeed()
        } label: {
          Image(systemName: "dice")
        }
        .buttonStyle(.borderless)
        .help("New random seed (⌘R)")
        Toggle("Random", isOn: Binding(get: { !model.seedLocked }, set: { model.seedLocked = !$0 }))
          .toggleStyle(.checkbox)
          .help(
            model.seedLocked
              ? "Every generation uses this seed. Check to roll a new one each time."
              : "Always random: every generation rolls a new seed. The field shows the last one.")
      }
    }
    .help("The random seed. Uncheck Random and set a seed to reproduce an image.")
  }
}

struct SettingsView: View {
  @Environment(CreateModel.self) private var model
  @State private var directory = ""

  var body: some View {
    Form {
      LabeledContent("Models directory") {
        HStack {
          TextField("Path", text: $directory).frame(minWidth: 320)
          Button("Choose…") { choose() }
        }
      }
      HStack {
        Spacer()
        Button("Apply") { model.setModelsDirectory(directory) }
          .disabled(directory == model.modelsDirectory)
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear { directory = model.modelsDirectory }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = URL(fileURLWithPath: directory)
    if panel.runModal() == .OK, let url = panel.url {
      directory = url.path
    }
  }
}
