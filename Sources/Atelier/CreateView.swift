import SwiftUI
import _MediaGenerationKit

struct CreateView: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    CanvasView()
      .inspector(isPresented: .constant(true)) {
        InspectorView()
          .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
      }
      .toolbar {
        ToolbarItemGroup {
          if model.isBusy, model.phase != .loadingModel {
            Button("Cancel", systemImage: "stop.fill") { model.cancel() }
              .keyboardShortcut(.escape, modifiers: [])
              .disabled(model.phase == .cancelling)
          } else {
            Button("Generate", systemImage: "sparkles") { model.generate() }
              .keyboardShortcut(.return, modifiers: .command)
              .disabled(!model.canGenerate)
          }
        }
      }
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
            description: Text("Write a prompt and press Generate (⌘↩)."))
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

struct InspectorView: View {
  @Environment(CreateModel.self) private var model
  @State private var advancedExpanded = false

  var body: some View {
    @Bindable var model = model
    Form {
      Section("Essentials") {
        Picker("Model", selection: $model.selectedModel) {
          if model.models.isEmpty {
            Text("No downloaded models").tag(String?.none)
          }
          ForEach(model.models, id: \.file) { entry in
            Text(entry.name).tag(Optional(entry.file))
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Prompt")
          TextEditor(text: $model.prompt)
            .font(.body)
            .frame(minHeight: 90)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
        }
        TextField("Negative prompt", text: $model.negativePrompt, axis: .vertical)
          .lineLimit(1...4)
        if let settings = Binding($model.settings) {
          SizeControls(settings: settings)
        }
        SeedControls()
      }
      if let settings = Binding($model.settings) {
        Section("Advanced", isExpanded: $advancedExpanded) {
          AdvancedControls(settings: settings)
          Button("Reset to model defaults") { model.resetToModelDefaults() }
            .disabled(model.settings == nil)
        }
      }
    }
    .formStyle(.grouped)
    .disabled(model.isBusy && model.phase != .loadingModel)
  }
}

struct SizeControls: View {
  @Binding var settings: GenerationSettings

  var body: some View {
    let match = SizePreset.match(width: settings.width, height: settings.height)
    Picker(
      "Aspect",
      selection: Binding(
        get: { match?.0 },
        set: { aspect in
          guard let aspect else { return }
          let mp = match?.1 ?? closestMegapixels
          (settings.width, settings.height) = SizePreset.size(aspect: aspect, megapixels: mp)
        })
    ) {
      if match == nil { Text("Custom").tag(SizePreset.AspectRatio?.none) }
      ForEach(SizePreset.aspectRatios) { Text($0.label).tag(Optional($0)) }
    }
    Picker(
      "Megapixels",
      selection: Binding(
        get: { match?.1 },
        set: { mp in
          guard let mp else { return }
          let aspect = match?.0 ?? closestAspect
          (settings.width, settings.height) = SizePreset.size(aspect: aspect, megapixels: mp)
        })
    ) {
      if match == nil { Text("Custom").tag(Double?.none) }
      ForEach(SizePreset.megapixels, id: \.self) { mp in
        Text(mp.formatted()).tag(Optional(mp))
      }
    }
    HStack {
      Stepper(value: $settings.width, in: 256...4096, step: 64) {
        Text("W \(settings.width)").monospacedDigit()
      }
      Spacer()
      Stepper(value: $settings.height, in: 256...4096, step: 64) {
        Text("H \(settings.height)").monospacedDigit()
      }
    }
  }

  private var closestMegapixels: Double {
    let mp = Double(settings.width * settings.height) / 1_048_576
    return SizePreset.megapixels.min { abs($0 - mp) < abs($1 - mp) } ?? 1
  }

  private var closestAspect: SizePreset.AspectRatio {
    let ratio = Double(settings.width) / Double(settings.height)
    return SizePreset.aspectRatios.min {
      abs(Double($0.width) / Double($0.height) - ratio)
        < abs(Double($1.width) / Double($1.height) - ratio)
    } ?? SizePreset.aspectRatios[0]
  }
}

struct SeedControls: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    @Bindable var model = model
    LabeledContent("Seed") {
      HStack(spacing: 6) {
        TextField("Seed", value: $model.seed, format: .number.grouping(.never))
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 120)
        Button {
          model.rollSeed()
        } label: {
          Image(systemName: "dice")
        }
        .help("New random seed")
        Toggle(isOn: $model.seedLocked) {
          Image(systemName: model.seedLocked ? "lock.fill" : "lock.open")
        }
        .toggleStyle(.button)
        .help(model.seedLocked ? "Seed is locked" : "A new seed is rolled for each generation")
      }
    }
  }
}

struct AdvancedControls: View {
  @Binding var settings: GenerationSettings

  var body: some View {
    explained("Number of denoising steps. More is slower and usually finer.") {
      Stepper(value: $settings.steps, in: 1...150) {
        LabeledContent("Steps", value: "\(settings.steps)")
      }
    }
    explained("How strongly the image follows the prompt.") {
      LabeledContent("Guidance") {
        HStack {
          Slider(value: $settings.guidanceScale, in: 0...20, step: 0.5)
          Text(settings.guidanceScale.formatted(.number.precision(.fractionLength(1))))
            .monospacedDigit().frame(width: 36, alignment: .trailing)
        }
      }
    }
    explained("Shifts the noise schedule toward high noise; flow models like 3 to 6.") {
      LabeledContent("Shift") {
        HStack {
          Slider(value: $settings.shift, in: 0...12, step: 0.1)
          Text(settings.shift.formatted(.number.precision(.fractionLength(1))))
            .monospacedDigit().frame(width: 36, alignment: .trailing)
        }
      }
    }
    explained("Scale shift with image size. Off uses the shift above as is.") {
      Toggle("Resolution-dependent shift", isOn: $settings.resolutionDependentShift)
    }
    explained("The sampling algorithm and its noise schedule.") {
      Picker("Sampler", selection: $settings.sampler) {
        ForEach(SamplerType.allCases, id: \.self) { Text(String(describing: $0)).tag($0) }
      }
    }
    explained("Renders small, then upscales and runs a second sampling pass. Off by default.") {
      Toggle("Hires fix", isOn: $settings.hiresFix)
    }
  }

  private func explained<Content: View>(_ text: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 2) {
      content()
      Text(text).font(.caption).foregroundStyle(.secondary)
    }
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
