import SwiftUI
import UniformTypeIdentifiers
import _MediaGenerationKit

struct CreateView: View {
  @Environment(CreateModel.self) private var model
  @AppStorage("inspectorShown") private var inspectorShown = true

  var body: some View {
    @Bindable var model = model
    CanvasView()
      .overlay(alignment: .topTrailing) {
        if model.usesReferences || !model.moodboard.items.isEmpty {
          MoodboardColumn().padding(12)
        }
      }
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
    // One Open panel for the canvas and the moodboard: two file importers in one view hierarchy
    // compete for the same presentation.
    .fileImporter(
      isPresented: Binding(get: { model.imageImport != nil }, set: { if !$0 { model.imageImport = nil } }),
      allowedContentTypes: [.image],
      allowsMultipleSelection: model.imageImport == .moodboard
    ) { result in
      let target = model.imageImport
      model.imageImport = nil
      guard case .success(let urls) = result else { return }
      for url in urls {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let image = ImageLoader.image(at: url) else { continue }
        if target == .moodboard {
          model.moodboard.add(image)
        } else {
          model.setCanvasImage(image, metadata: ImageMetadata.embedded(at: url))
        }
      }
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

/// The image canvas. Like Draw Things, the configured size stays put as an outlined frame fitted
/// to the view, and zooming and dragging move the image under it. Whatever falls outside the frame
/// shows dimmed and blurred: it won't be part of the next image. In Edit mode the frame's contents
/// are the image input (`CanvasState.render`).
struct CanvasView: View {
  @Environment(CreateModel.self) private var model
  @Environment(HistoryStore.self) private var history
  /// The zoom and offset when the current pinch or drag began.
  @State private var gestureStart: (scale: Double, offset: CGSize)?
  @State private var saveError: String?
  @State private var isTargeted = false
  @Environment(\.undoManager) private var undoManager

  private static let margin: Double = 24

  var body: some View {
    let canvas = model.canvas
    GeometryReader { geometry in
      let frame = frameSize
      // Points per frame pixel: the frame always fits the view.
      let points = max(
        min(
          (geometry.size.width - 2 * Self.margin) / frame.width,
          (geometry.size.height - 2 * Self.margin) / frame.height), 0.01)
      let frameRect = CGRect(
        x: (geometry.size.width - frame.width * points) / 2,
        y: (geometry.size.height - frame.height * points) / 2,
        width: frame.width * points, height: frame.height * points)
      let imageFit = model.image.map {
        min(frame.width / Double($0.width), frame.height / Double($0.height))
      } ?? 1
      let zoom = canvas.scale ?? imageFit
      let center = CGPoint(
        x: frameRect.midX + canvas.offset.width * points,
        y: frameRect.midY + canvas.offset.height * points)
      ZStack {
        if let image = model.image {
          let size = CGSize(
            width: Double(image.width) * zoom * points, height: Double(image.height) * zoom * points)
          let picture = Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(zoom * points > 2 ? .none : .high)
            .frame(width: size.width, height: size.height)
            .position(center)
          picture
            .blur(radius: 6)
            .opacity(0.45)
          picture
            .mask { Rectangle().frame(width: frameRect.width, height: frameRect.height).position(x: frameRect.midX, y: frameRect.midY) }
        }
        let isInput = model.effectiveCanvasMode == .edit && model.image != nil
        Rectangle()
          .strokeBorder(
            isInput || isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary.opacity(0.6)),
            style: StrokeStyle(lineWidth: isInput || isTargeted ? 2 : 1, dash: isInput ? [] : [4, 3]))
          .frame(width: frameRect.width + 2, height: frameRect.height + 2)
          .position(x: frameRect.midX, y: frameRect.midY)
          .allowsHitTesting(false)
        if isInput {
          Color.clear
            .frame(width: frameRect.width, height: frameRect.height)
            .overlay(alignment: .topLeading) {
              Label("Input", systemImage: "square.and.pencil")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular.tint(.accentColor), in: .capsule)
                .padding(8)
                .help("Edit mode: what's inside the frame is sent to the model. Empty areas are filled in.")
            }
            .position(x: frameRect.midX, y: frameRect.midY)
            .allowsHitTesting(false)
        }
        if model.image == nil {
          ContentUnavailableView(
            "No image yet", systemImage: "photo",
            description: Text("Write a prompt below and press Generate (⌘↩), or drop an image here to edit it."))
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
      .contentShape(.rect)
      .gesture(
        panGesture(canvas, points: points)
          .simultaneously(with: zoomGesture(canvas, frame: frameRect, points: points, in: geometry.size)))
      .onTapGesture(count: 2) {
        if canvas.scale == nil { canvas.zoom(to: 1) } else { canvas.zoomToFit() }
      }
      .contextMenu { contextMenu(canvas) }
      .dropDestination(for: DroppedImage.self) { images, _ in
        guard let image = images.first else { return false }
        model.setCanvasImage(image.image, metadata: image.metadata)
        return true
      } isTargeted: { isTargeted = $0 }
      .onChange(of: imageFit, initial: true) { canvas.fitScale = imageFit }
    }
    .background(Color(nsColor: .underPageBackgroundColor).ignoresSafeArea())
    // A new image starts fitted to the frame.
    .onChange(of: model.imageItem?.tensorId) { canvas.zoomToFit() }
    .alert(
      "Couldn't save the image",
      isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } }),
      actions: { Button("OK") { saveError = nil } },
      message: { Text(saveError ?? "") })
  }

  /// The configured output size in pixels, else the image's.
  private var frameSize: CGSize {
    if let settings = model.settings, settings.width > 0, settings.height > 0 {
      return CGSize(width: settings.width, height: settings.height)
    }
    if let image = model.image { return CGSize(width: image.width, height: image.height) }
    return CGSize(width: 1024, height: 1024)
  }

  private func panGesture(_ canvas: CanvasState, points: Double) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        let start = gestureStart ?? (canvas.effectiveScale, canvas.offset)
        gestureStart = start
        canvas.scale = start.scale
        canvas.offset = CGSize(
          width: start.offset.width + value.translation.width / points,
          height: start.offset.height + value.translation.height / points)
      }
      .onEnded { _ in gestureStart = nil }
  }

  /// Pinch zoom, keeping the image point under the fingers in place.
  private func zoomGesture(_ canvas: CanvasState, frame: CGRect, points: Double, in size: CGSize)
    -> some Gesture
  {
    MagnifyGesture()
      .onChanged { value in
        let start = gestureStart ?? (canvas.effectiveScale, canvas.offset)
        gestureStart = start
        let anchor = CGPoint(
          x: (value.startAnchor.x * size.width - frame.midX) / points,
          y: (value.startAnchor.y * size.height - frame.midY) / points)
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
    Button("Open Image…") { model.imageImport = .canvas }
    Button("Paste Image") { model.pasteImage() }
    Button("Load Settings from Image") { model.loadCanvasImageSettings(undoManager: undoManager) }
      .disabled(model.canvasImageSettings == nil)
    Button("Add to Moodboard") { model.addCanvasToMoodboard() }
      .disabled(model.image == nil)
    Button("Match Size to Image") { model.matchSizeToImage(undoManager: undoManager) }
      .disabled(model.image == nil)
    Button("Clear Canvas") { model.clearCanvas() }
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
    panel.nameFieldStringValue = (item.map(history.fileName(for:)) ?? history.project.name) + ".png"
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

/// − / zoom level / +, at the end of the status bar.
private struct ZoomControls: View {
  let canvas: CanvasState

  var body: some View {
    HStack(spacing: 2) {
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
  }
}

/// How the canvas is zoomed and moved. Owned by CreateModel so menu commands reach it.
@MainActor
@Observable
final class CanvasState {
  /// Frame pixels per image pixel (1 is actual size); nil fits the image to the frame.
  var scale: Double?
  /// The image's center relative to the frame's, in frame pixels.
  var offset: CGSize = .zero
  /// The scale that fits the image to the frame, kept current by the canvas.
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

  /// Zooms keeping `anchor` (relative to the frame's center, in frame pixels) in place.
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
      case .idle where model.isLoadingModel:
        ProgressView().controlSize(.small)
        Text("Loading model…").foregroundStyle(.secondary)
      case .idle:
        if let error = model.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .lineLimit(2)
        } else if let note = model.statusNote {
          Label(note, systemImage: "info.circle")
            .foregroundStyle(.secondary)
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
      case .running(let message):
        // Only while the canvas shows something else: the way back to the running image.
        if !model.canvasFollowsRun { LiveThumbnail() }
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
      QueueStatus()
      ZoomControls(canvas: model.canvas)
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .frame(height: 32)
  }
}

/// The running image's latest preview, in the status bar while the canvas shows something else.
/// Clicking it puts the canvas back on the run.
struct LiveThumbnail: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    Button {
      model.followRun()
    } label: {
      ZStack {
        Color(nsColor: .quaternaryLabelColor)
        if let image = model.livePreview {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
        }
      }
      .frame(width: 24, height: 24)
      .clipShape(.rect(cornerRadius: 3))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("The image being generated. Click to show it on the canvas.")
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

/// The latest images in the project, newest first. Clicking one makes it the current step (the
/// next run follows it, branching when it isn't the newest) and uses its settings. Chronological
/// lists the newest images of every branch; Current Lineage lists the current step's line: its
/// ancestors, it, and the newest images beyond it.
struct RecentStrip: View {
  @Environment(CreateModel.self) private var model
  @Environment(HistoryStore.self) private var history
  @Environment(\.undoManager) private var undoManager
  @AppStorage("recentStripMode") private var mode = Mode.chronological

  enum Mode: String {
    case chronological, lineage
  }

  var body: some View {
    if !history.items.isEmpty {
      let items = mode == .lineage ? history.currentLineage : Array(history.items.prefix(24))
      let current = history.currentItem?.tensorId
      HStack(spacing: 8) {
        Picker("Recent Images", selection: $mode) {
          Label("Chronological", systemImage: "clock").tag(Mode.chronological)
          Label("Current Lineage", systemImage: "arrow.triangle.branch").tag(Mode.lineage)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help(mode == .lineage
          ? "Current lineage: the current image's ancestors and the newest images after it"
          : "Chronological: the newest images on every branch")
        .padding(.leading, 12)
        ScrollViewReader { scroller in
          ScrollView(.horizontal) {
            LazyHStack(spacing: 6) {
              ForEach(items, id: \.tensorId) { item in
                thumbnail(item, isCurrent: current == item.tensorId)
                  .id(item.tensorId)
              }
            }
            .padding(.trailing, 12)
          }
          .scrollIndicators(.never)
          .onChange(of: current) { if let current { withAnimation { scroller.scrollTo(current) } } }
        }
      }
      .frame(height: 48)
    }
  }

  private func thumbnail(_ item: HistoryItem, isCurrent: Bool) -> some View {
    Thumbnail(item: item)
      .frame(width: 44, height: 44)
      .clipShape(.rect(cornerRadius: 4))
      .overlay(alignment: .bottomTrailing) {
        let branches = history.children(of: item).count
        if branches > 1 {
          HStack(spacing: 1) {
            Image(systemName: "arrow.triangle.branch")
            Text("\(branches)")
          }
          .font(.system(size: 8, weight: .semibold))
          .padding(.horizontal, 3)
          .padding(.vertical, 1)
          .background(.black.opacity(0.6), in: .capsule)
          .foregroundStyle(.white)
          .padding(2)
          .help("\(branches) branches follow this image")
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(Color.accentColor, lineWidth: isCurrent ? 2 : 0)
      }
      .contentShape(.rect)
      // Picks up from this image, itself on the canvas (not an Edit step's input). While a
      // run is going, or without its model, only the prompt and size come back.
      .onTapGesture {
        if model.canUse(item) {
          model.use(item, restoreInput: false)
        } else {
          model.showWithPrompt(item, undoManager: undoManager)
        }
      }
      .draggable(history.dragExport(item))
      .help("\(item.sidecar.prompt)\n\(GenerationTime.text(item.sidecar.durationSeconds)). Click to use its settings; the next image follows it.")
      .contextMenu {
        Button("Use Settings") { model.use(item, loadImage: false) }
          .disabled(!model.canUse(item))
        Button("Use as Input") {
          model.show(item)
          model.canvasMode = .edit
        }
        Button("Add to Moodboard") {
          Task { if let image = await history.image(for: item) { model.moodboard.add(image) } }
        }
        Button("Copy Image") { Task { await history.copyImage(item) } }
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
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 8) {
            // Always shown so the row never shifts; disabled while idle.
            Button {
              model.cancel()
            } label: {
              Label("Stop", systemImage: "stop.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .help("Stop this image; the queue goes on (Esc)")
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!model.isRunning || model.phase == .cancelling)
            CountControl()
            Button {
              model.generate()
            } label: {
              Label("Generate", systemImage: model.isRunning ? "text.badge.plus" : "sparkles")
            }
            .labelStyle(.iconOnly)
            .help(model.isRunning ? "Add to Queue (⌘↩)" : "Generate (⌘↩)")
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canGenerate)
          }
          .controlSize(.large)
        }
      }
      HStack(alignment: .top, spacing: 12) {
        DisclosureGroup(isExpanded: $showNegative) {
          TextField("What to avoid", text: $model.negativePrompt, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
        } label: {
          ClickableLabel("Negative Prompt", isExpanded: $showNegative)
        }
        .font(.callout)
        Picker(
          "Mode", selection: Binding(get: { model.effectiveCanvasMode }, set: { model.canvasMode = $0 })
        ) {
          Text("Generate").tag(CreateModel.CanvasMode.generate)
          Text("Edit").tag(CreateModel.CanvasMode.edit)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(!model.canEdit)
        .help(
          model.canEdit
            ? "Generate starts from the prompt alone. Edit also sends the canvas: what's inside the frame is the input, and empty areas are filled in."
            : "This model doesn't take image inputs, so it always generates from the prompt. Lower Strength below 100% in the inspector to edit from the canvas.")
      }
    }
    .padding(12)
    .onChange(of: model.focusPromptRequest) { promptFocused = true }
  }

  /// Follows the window's corners, never tighter than a text field's.
  private static let fieldShape = ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true)
}

/// How many images Generate makes, beside the Generate button.
struct CountControl: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    @Bindable var model = model
    Menu("×\(model.count)") {
      Picker("Images", selection: $model.count) {
        ForEach([1, 2, 3, 4, 6, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
      }
      .pickerStyle(.inline)
    }
    .menuIndicator(.hidden)
    .menuStyle(.button)
    .buttonStyle(.glass)
    .monospacedDigit()
    .fixedSize()
    .help(
      model.seedLocked
        ? "Images per Generate. With a set seed they count up from it."
        : "Images per Generate, each with its own random seed.")
  }
}

/// Waiting jobs, beside the zoom controls: a link to the Queue.
struct QueueStatus: View {
  @Environment(CreateModel.self) private var model
  @Environment(Navigation.self) private var navigation

  var body: some View {
    let queue = model.queue
    let waiting = queue.waiting.count
    if waiting > 0 || queue.isPaused {
      Button(queue.isPaused ? "Paused · \(waiting) waiting" : "\(waiting) waiting") {
        navigation.section = .queue
      }
      .buttonStyle(.link)
      .monospacedDigit()
      .help("Show the Queue")
    }
  }
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
            set: { model.seed = $0 }), format: .number.grouping(.never)
        )
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 120)
        // Always random rolls a new seed on every Generate, so the field only shows the last one.
        .disabled(!model.seedLocked)
        Button {
          model.rollSeed()
        } label: {
          Image(systemName: "dice")
        }
        .buttonStyle(.borderless)
        .disabled(!model.seedLocked)
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

/// Settings ▸ Models: where models and LoRAs live.
struct ModelsSettingsView: View {
  @Environment(CreateModel.self) private var model
  @State private var directory = ""
  @FocusState private var directoryFocused: Bool

  var body: some View {
    Form {
      Section {
        LabeledContent("Models directory") {
          HStack {
            TextField("Path", text: $directory)
              .labelsHidden()
              .focused($directoryFocused)
              .frame(minWidth: 320)
            Button("Choose…") { choose() }
          }
        }
        HStack {
          Spacer()
          Button("Apply") { model.setModelsDirectory(directory) }
            .disabled(directory == model.modelsDirectory)
        }
      }
    }
    .settingsForm()
    .onAppear {
      directory = model.modelsDirectory
      // The window focuses the first field, which selects the whole path; start unfocused.
      Task { directoryFocused = false }
    }
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

/// Settings ▸ Images: what saved images carry, and the output folder.
struct ImagesSettingsView: View {
  @AppStorage(AppSettings.embedsSettingsKey) private var embedsSettings = true
  @AppStorage(AppSettings.savesToOutputFolderKey) private var savesToOutputFolder = false
  @AppStorage(AppSettings.outputFolderKey) private var outputFolder = AppSettings.defaultOutputFolder
  @State private var choosingOutputFolder = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $embedsSettings) {
          Text("Include Generation Settings in Saved Images")
          Text(
            "Exported, saved and dragged images carry their prompt, model, seed and settings, in the format Draw Things reads."
          )
        }
      }
      Section {
        Toggle(isOn: $savesToOutputFolder) {
          Text("Save Generated Images to Output Folder")
          Text(
            "Each new image is also written to this folder as a PNG, named like an export. A project can use its own folder, or turn saving on or off for itself, from the project menu."
          )
        }
        LabeledContent("Output folder") {
          HStack {
            TextField("Path", text: $outputFolder, prompt: Text(AppSettings.defaultOutputFolder))
              .labelsHidden()
              .frame(minWidth: 320)
            Button("Choose…") { choosingOutputFolder = true }
          }
        }
      } header: {
        Text("Output Folder")
      }
      .fileImporter(isPresented: $choosingOutputFolder, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { outputFolder = url.path }
      }
    }
    .settingsForm()
  }
}

/// Settings ▸ Performance: Draw Things' Machine Settings.
struct PerformanceSettingsView: View {
  @AppStorage(PerformanceSetting.highResolutionPreviewKey)
  private var highResolutionPreview = PerformanceSetting.highResolutionPreview

  var body: some View {
    Form {
      Section {
        ForEach(PerformanceSetting.allCases) { PerformancePicker(setting: $0) }
        Toggle(isOn: $highResolutionPreview) {
          Text("Use High Resolution Preview When Possible")
          Text(
            "Decodes step previews with TAESD, on the Neural Engine when it can (typically 20–150 ms), so it rarely slows generation. Off shows the quicker low-resolution preview."
          )
        }
      } footer: {
        Text("Automatic picks what the engine chooses for this Mac. Changes apply from the next generation.")
          .foregroundStyle(.secondary)
      }
    }
    // Wider than the other tabs so the longest choice, Automatic (Yes, Prefer Quantized
    // Attention), isn't cut off.
    .settingsForm(width: 720)
  }
}

extension View {
  /// The grouped form, width and sizing every Settings tab shares.
  func settingsForm(width: CGFloat = 600) -> some View {
    formStyle(.grouped)
      .frame(width: width)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// One Performance setting: Automatic (the engine's choice, named in the label) or an override.
private struct PerformancePicker: View {
  let setting: PerformanceSetting
  @AppStorage private var value: Int

  init(setting: PerformanceSetting) {
    self.setting = setting
    _value = AppStorage(wrappedValue: PerformanceSetting.automatic, setting.defaultsKey)
  }

  var body: some View {
    Picker(selection: $value) {
      Text(setting.automaticLabel).tag(PerformanceSetting.automatic)
      Divider()
      ForEach(setting.options, id: \.value) { Text($0.label).tag($0.value) }
    } label: {
      Text(setting.title)
      Text(setting.detail)
    }
  }
}
