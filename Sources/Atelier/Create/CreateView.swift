import SwiftUI
import UniformTypeIdentifiers
import _MediaGenerationKit

struct CreateView: View {
  @Environment(CreateModel.self) private var model
  @AppStorage("inspectorShown") private var inspectorShown = true

  var body: some View {
    CanvasView()
      // A safe-area bar rather than a stacked view: the canvas runs underneath it and the system
      // draws the bar's edge, so the composer sits on the canvas like the toolbar does.
      .safeAreaBar(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          PromptSplitter()
          RecentStrip()
          StatusBar()
          PromptComposer()
        }
      }
      .inspector(isPresented: $inspectorShown) {
      InspectorView()
        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
    }
    // A plain toolbar, not a customizable `.toolbar(id:)`: AppKit crashes ("NSToolbarItemViewer's
    // min/max size is nan") switching between a customizable toolbar and the other sections'
    // `.searchable` toolbars.
    .toolbar {
      // The same project menu as History: new images save to the project picked here.
      ToolbarItem(placement: .navigation) { ProjectMenu() }
      // Generate lives in the prompt composer only; the toolbar keeps presets and the inspector
      // toggle, each in its own glass capsule.
      ToolbarItem(placement: .primaryAction) {
        PresetMenu()
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
      ToolbarItem(placement: .primaryAction) {
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
    .help(model.selectedModelInfo.map { "\($0.name) (\($0.version ?? "unknown family"))" } ?? "Model")
  }
}

/// The image canvas. Like Draw Things, it outlines the configured size and lets you zoom and move
/// the view; the image sits centered on that frame at its own pixel size, so a size change shows
/// against the last image (where image to image will place its source).
struct CanvasView: View {
  @Environment(CreateModel.self) private var model
  @Environment(HistoryStore.self) private var history
  /// The zoom and offset when the current pinch or drag began.
  @State private var gestureStart: (scale: Double, offset: CGSize)?
  @State private var saveError: String?

  private static let margin: Double = 24

  var body: some View {
    let canvas = model.canvas
    GeometryReader { geometry in
      let frame = frameSize
      let fit = min(
        (geometry.size.width - 2 * Self.margin) / frame.width,
        (geometry.size.height - 2 * Self.margin) / frame.height)
      let scale = canvas.scale ?? max(fit, 0.01)
      let center = CGPoint(
        x: geometry.size.width / 2 + canvas.offset.width,
        y: geometry.size.height / 2 + canvas.offset.height)
      ZStack {
        if let image = model.image {
          Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(scale > 2 ? .none : .high)
            .frame(width: Double(image.width) * scale, height: Double(image.height) * scale)
            .position(center)
        }
        // Dims whatever lies outside the frame, which won't be in the next image.
        let frameRect = CGRect(
          x: center.x - frame.width * scale / 2, y: center.y - frame.height * scale / 2,
          width: frame.width * scale, height: frame.height * scale)
        Path { path in
          path.addRect(CGRect(origin: .zero, size: geometry.size).insetBy(dx: -4000, dy: -4000))
          path.addRect(frameRect)
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        Rectangle()
          .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .frame(width: frame.width * scale + 2, height: frame.height * scale + 2)
          .position(center)
          .allowsHitTesting(false)
        if model.image == nil {
          ContentUnavailableView(
            "No image yet", systemImage: "photo",
            description: Text("Write a prompt below and press Generate (⌘↩)."))
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .contentShape(.rect)
      .gesture(panGesture(canvas).simultaneously(with: zoomGesture(canvas, in: geometry.size)))
      .onTapGesture(count: 2) {
        if canvas.scale == nil { canvas.zoom(to: 1) } else { canvas.zoomToFit() }
      }
      .contextMenu { contextMenu(canvas) }
      .overlay(alignment: .bottomTrailing) {
        ZoomControls(canvas: canvas, export: dragExport).padding(12)
      }
      .onChange(of: fit, initial: true) { canvas.fitScale = max(fit, 0.01) }
    }
    .background(Color(nsColor: .underPageBackgroundColor).ignoresSafeArea())
    .alert(
      "Couldn't save the image",
      isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } }),
      actions: { Button("OK") { saveError = nil } },
      message: { Text(saveError ?? "") })
  }

  /// The canvas image as a PNG to drag out; a finished one carries its settings.
  private var dragExport: PNGExport? {
    if let item = model.imageItem { return history.dragExport(item) }
    guard let image = model.image else { return nil }
    let preview = image
    return PNGExport(name: history.project.name) {
      guard let png = ImageTensor.png(preview) else { throw ProjectError.badImage }
      return png
    }
  }

  /// The configured output size in pixels, else the image's.
  private var frameSize: CGSize {
    if let settings = model.settings, settings.width > 0, settings.height > 0 {
      return CGSize(width: settings.width, height: settings.height)
    }
    if let image = model.image { return CGSize(width: image.width, height: image.height) }
    return CGSize(width: 1024, height: 1024)
  }

  private func panGesture(_ canvas: CanvasState) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        let start = gestureStart ?? (canvas.effectiveScale, canvas.offset)
        gestureStart = start
        canvas.offset = CGSize(
          width: start.offset.width + value.translation.width,
          height: start.offset.height + value.translation.height)
      }
      .onEnded { _ in gestureStart = nil }
  }

  /// Pinch zoom, keeping the point under the fingers in place.
  private func zoomGesture(_ canvas: CanvasState, in size: CGSize) -> some Gesture {
    MagnifyGesture()
      .onChanged { value in
        let start = gestureStart ?? (canvas.effectiveScale, canvas.offset)
        gestureStart = start
        let anchor = CGPoint(
          x: value.startAnchor.x * size.width - size.width / 2,
          y: value.startAnchor.y * size.height - size.height / 2)
        canvas.offset = start.offset
        canvas.scale = start.scale
        canvas.zoom(to: start.scale * value.magnification, around: anchor)
      }
      .onEnded { _ in gestureStart = nil }
  }

  @ViewBuilder private func contextMenu(_ canvas: CanvasState) -> some View {
    Button("Copy Image") { if let image = model.image { HistoryStore.copy(image) } }
      .disabled(model.image == nil)
    Button("Save Image…") { save() }
      .disabled(model.image == nil)
    Divider()
    ZoomMenuItems(canvas: canvas)
  }

  /// Saves as PNG; a finished image carries its settings like History's Export.
  private func save() {
    guard let image = model.image else { return }
    let item = model.imageItem
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue =
      item.map { "\(history.project.name) \($0.id.logicalTime)-\($0.sidecar.seed).png" }
      ?? "\(history.project.name).png"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        if let item {
          try await history.exportPNG(item, to: url)
        } else {
          guard let png = ImageTensor.png(image) else { throw ProjectError.badImage }
          try png.write(to: url)
        }
      } catch {
        saveError = error.localizedDescription
      }
    }
  }
}

/// Zoom In, Zoom Out, Zoom to Fit and Actual Size, for the canvas menu and the View menu.
struct ZoomMenuItems: View {
  let canvas: CanvasState

  var body: some View {
    Button("Zoom In") { canvas.zoomIn() }
      .keyboardShortcut("=", modifiers: .command)
    Button("Zoom Out") { canvas.zoomOut() }
      .keyboardShortcut("-", modifiers: .command)
    Button("Zoom to Fit") { canvas.zoomToFit() }
      .keyboardShortcut("9", modifiers: .command)
    Button("Actual Size") { canvas.zoom(to: 1) }
      .keyboardShortcut("0", modifiers: .command)
  }
}

/// − / zoom level / + in a glass capsule at the canvas corner.
private struct ZoomControls: View {
  let canvas: CanvasState
  var export: PNGExport?

  var body: some View {
    HStack(spacing: 2) {
      if let export {
        Image(systemName: "photo")
          .frame(width: 22, height: 22)
          .contentShape(.rect)
          .draggable(export)
          .help("Drag the image into Finder or another app")
        Divider().frame(height: 14)
      }
      Button("Zoom Out", systemImage: "minus") { canvas.zoomOut() }
        .help("Zoom Out (⌘−)")
      Menu {
        Button("Zoom to Fit") { canvas.zoomToFit() }
        Divider()
        ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { scale in
          Button(scale.formatted(.percent)) { canvas.zoom(to: scale) }
        }
      } label: {
        Text(canvas.scale == nil ? "Fit" : canvas.effectiveScale.formatted(.percent.precision(.fractionLength(0))))
          .monospacedDigit()
          .frame(minWidth: 44)
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Zoom level. Pinch or use ⌘+ and ⌘− to zoom, drag to move, double-click to fit.")
      Button("Zoom In", systemImage: "plus") { canvas.zoomIn() }
        .help("Zoom In (⌘+)")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .glassEffect()
  }
}

/// How the canvas is zoomed and moved. Owned by CreateModel so menu commands reach it.
@MainActor
@Observable
final class CanvasState {
  /// Points per image pixel; nil fits the frame to the view.
  var scale: Double?
  /// The frame's center relative to the view's center, in points.
  var offset: CGSize = .zero
  /// The scale that fits the frame, kept current by the canvas.
  var fitScale: Double = 1

  var effectiveScale: Double { scale ?? fitScale }

  private static let levels: [Double] = [
    0.1, 0.125, 0.25, 1 / 3, 0.5, 2 / 3, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 16,
  ]
  static let range = 0.05...32.0

  func zoomIn() {
    zoom(to: Self.levels.first { $0 > effectiveScale * 1.01 } ?? Self.range.upperBound)
  }

  func zoomOut() {
    zoom(to: Self.levels.last { $0 < effectiveScale * 0.99 } ?? Self.range.lowerBound)
  }

  func zoomToFit() {
    scale = nil
    offset = .zero
  }

  /// Zooms keeping `anchor` (relative to the view's center, in points) in place.
  func zoom(to newScale: Double, around anchor: CGPoint = .zero) {
    let old = effectiveScale
    let new = min(max(newScale, Self.range.lowerBound), Self.range.upperBound)
    let ratio = new / old
    offset = CGSize(
      width: anchor.x - (anchor.x - offset.width) * ratio,
      height: anchor.y - (anchor.y - offset.height) * ratio)
    scale = new
  }
}

/// Generation progress, or what happened last, above the prompt composer.
struct StatusBar: View {
  @Environment(CreateModel.self) private var model
  @Environment(Navigation.self) private var navigation

  var body: some View {
    HStack(spacing: 12) {
      switch model.phase {
      case .idle:
        if let error = model.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .lineLimit(2)
        } else if model.lastSavedStep != nil {
          let took = model.imageItem.map { " in " + GenerationTime.text($0.sidecar.durationSeconds) } ?? ""
          Text("Saved to \(model.history.project.name)\(took)").foregroundStyle(.secondary)
          Button("Show in History") { navigation.section = .history }
            .buttonStyle(.link)
        } else if let item = model.imageItem {
          Text("Generated in \(GenerationTime.text(item.sidecar.durationSeconds))")
            .foregroundStyle(.secondary)
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
        if let started = model.runStartedAt {
          TimelineView(.periodic(from: started, by: 1)) { context in
            let elapsed = GenerationTime.clock(context.date.timeIntervalSince(started))
            let left = model.estimatedRemaining(at: context.date).map {
              " · about \(GenerationTime.clock($0)) left"
            }
            Text(elapsed + (left ?? "")).monospacedDigit().foregroundStyle(.secondary)
          }
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
  }
}

/// The handle between the canvas and the composer: drag it to make the prompt box taller or shorter.
struct PromptSplitter: View {
  static let linesKey = "promptLines"
  static let lines = 1...30
  @AppStorage(linesKey) private var promptLines = 3
  @State private var startLines: Int?

  var body: some View {
    Capsule()
      .fill(.tertiary)
      .frame(width: 36, height: 4)
      .frame(maxWidth: .infinity)
      .frame(height: 10)
      .contentShape(.rect)
      .pointerStyle(.rowResize)
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            let start = startLines ?? promptLines
            startLines = start
            // About one body-text line per 16 pt dragged; up makes the box taller.
            let lines = start + Int((-value.translation.height / 16).rounded())
            promptLines = min(max(lines, Self.lines.lowerBound), Self.lines.upperBound)
          }
          .onEnded { _ in startLines = nil }
      )
      .onTapGesture(count: 2) { promptLines = 3 }
      .help("Drag to resize the prompt box. Double-click for the default size.")
  }
}

/// The latest images in the project, newest first: click one to look at it, double-click to use
/// its settings.
struct RecentStrip: View {
  @Environment(CreateModel.self) private var model
  @Environment(HistoryStore.self) private var history

  var body: some View {
    let items = Array(history.items.prefix(24))
    if !items.isEmpty {
      let current = model.imageItem?.id
      ScrollView(.horizontal) {
        LazyHStack(spacing: 6) {
          ForEach(items) { item in
            Thumbnail(item: item)
              .frame(width: 44, height: 44)
              .clipShape(.rect(cornerRadius: 4))
              .overlay {
                RoundedRectangle(cornerRadius: 4)
                  .strokeBorder(Color.accentColor, lineWidth: current == item.id ? 2 : 0)
              }
              .contentShape(.rect)
              .onTapGesture(count: 2) { model.use(item) }
              .onTapGesture { model.show(item) }
              .draggable(history.dragExport(item))
              .help("\(item.sidecar.prompt)\n\(GenerationTime.text(item.sidecar.durationSeconds)). Double-click to use its settings.")
              .contextMenu {
                Button("Use Settings") { model.use(item) }
                  .disabled(!model.canUse(item))
                Button("Copy Image") { Task { await history.copyImage(item) } }
              }
          }
        }
        .padding(.horizontal, 12)
      }
      .scrollIndicators(.never)
      .frame(height: 48)
    }
  }
}

/// How generation times read in Create and History.
enum GenerationTime {
  /// "12.3s", "1m 4.2s".
  static func text(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.units(width: .narrow, fractionalPart: .show(length: 1)))
  }

  /// "0:12", for the running clock.
  static func clock(_ seconds: Double) -> String {
    Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
  }
}

/// The prompt box under the canvas: grows to about six lines, with the negative prompt tucked
/// under a disclosure and Generate beside it.
struct PromptComposer: View {
  @Environment(CreateModel.self) private var model
  @AppStorage("showNegativePrompt") private var showNegative = false
  @AppStorage(PromptSplitter.linesKey) private var promptLines = 3
  @FocusState private var promptFocused: Bool

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .bottom, spacing: 10) {
        TextField("Describe the image…", text: $model.prompt, axis: .vertical)
          .lineLimit(promptLines, reservesSpace: true)
          .textFieldStyle(.plain)
          .font(.body)
          .focused($promptFocused)
          .onSubmit { model.generate() }
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor), in: Self.fieldShape)
          .overlay(
            Self.fieldShape
              .stroke(promptFocused ? Color.accentColor : Color(nsColor: .separatorColor))
          )
          .help("Prompt. Return generates; ⌥↩ adds a line. ⌘L focuses this field.")
        if model.isBusy, model.phase != .loadingModel {
          Button {
            model.cancel()
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .labelStyle(.iconOnly)
          .controlSize(.large)
          .help("Stop (Esc)")
          .keyboardShortcut(.escape, modifiers: [])
          .disabled(model.phase == .cancelling)
        } else {
          Button {
            model.generate()
          } label: {
            Label("Generate", systemImage: "sparkles")
          }
          .labelStyle(.iconOnly)
          .controlSize(.large)
          .help("Generate (⌘↩)")
          .buttonStyle(.glassProminent)
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
    .onChange(of: model.focusPromptRequest) { promptFocused = true }
  }

  /// Follows the window's corners, never tighter than a text field's.
  private static let fieldShape = ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true)
}

struct SeedControls: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    @Bindable var model = model
    InspectorRow {
      Text("Seed")
    } control: {
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
        // Always random rolls a new seed on every Generate, so the field only shows the last one.
        .disabled(!model.seedLocked)
        Button {
          model.rollAndLockSeed()
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
