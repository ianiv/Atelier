@preconcurrency import _MediaGenerationKit
import SwiftUI
import UniformTypeIdentifiers

struct CreateView: View {
  @Environment(CreateModel.self) private var model
  @AppStorage("inspectorShown") private var inspectorShown = true
  #if os(iOS)
    /// The window is too narrow for the canvas beside the inspector.
    @State private var narrow = false
    @State private var shownWhileNarrow = false
    @State private var measured = false
  #endif

  /// Whether the inspector shows: the saved choice, or in a narrow iPad window, only once opened.
  private var inspectorPresented: Binding<Bool> {
    #if os(iOS)
      // Read here, in the body, rather than in the getter, so a change redraws the view.
      // Closed until the width is known: an inspector opened over the canvas in the first layout
      // pass stays open even when the binding turns false right after.
      let presented = measured && (narrow ? shownWhileNarrow : inspectorShown)
      return Binding(
        get: { presented },
        set: { if narrow { shownWhileNarrow = $0 } else { inspectorShown = $0 } })
    #else
      $inspectorShown
    #endif
  }

  var body: some View {
    @Bindable var model = model
    HStack(spacing: 0) {
      if model.layout != nil {
        LayoutPanel()
        Divider()
      }
      CanvasView()
        .overlay(alignment: .topTrailing) {
          if model.usesReferences || !model.moodboard.items.isEmpty || model.videoModel?.takesAudio == true {
            MoodboardColumn().padding(12)
          }
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
    .inspector(isPresented: inspectorPresented) {
      InspectorView()
        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
    }
    #if DEBUG
      // The moodboard weight popover's layout check needs an image on the moodboard.
      .debugPresents("moodboardWeight", .constant(false)) {
        if model.moodboard.items.isEmpty,
          let image = HistoryStore.sampleImage(width: 512, height: 512, seed: 3)
        {
          model.moodboard.add(image)
        }
      }
    #endif
    #if os(iOS)
      // In a window too narrow for the canvas beside the inspector, the inspector would cover the
      // canvas: it starts hidden there (the toolbar button still opens it), and the window's
      // saved choice applies again once it's wider.
      .onGeometryChange(for: Bool.self) { $0.size.width < iPadInspectorMinimumWidth } action: {
        narrow = $0
        shownWhileNarrow = false
        measured = true
      }
      .onChange(of: inspectorShown) { if narrow { shownWhileNarrow = inspectorShown } }
    #endif
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
          Button("Inspector", systemImage: "sidebar.trailing") { inspectorPresented.wrappedValue.toggle() }
            .help(inspectorPresented.wrappedValue ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        }
      }
  }
}

struct ModelPicker: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    @Bindable var model = model
    Picker("Model", selection: $model.selectedModel) {
      if model.availableModels.isEmpty {
        Text(model.runTargetServerName.map { "No models on \($0)" } ?? "No downloaded models").tag(String?.none)
      }
      ForEach(model.availableModels, id: \.file) { entry in
        Text(entry.name).tag(Optional(entry.file))
      }
    }
    .pickerStyle(.menu)
    .help(model.selectedModelInfo.map { "\($0.name) (\($0.version ?? "unknown family"))" } ?? "Model")
  }
}

/// Where new jobs run: this device, or a paired server, whose models and LoRAs the pickers then
/// offer. A server that doesn't answer stays listed, disabled.
struct RunOnPicker: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    @Bindable var model = model
    Picker("Run on", selection: $model.runTarget) {
      Text(CreateModel.thisDeviceName).tag(JobTarget.local)
      ForEach(model.remoteServers.servers) { server in
        let isOffline = model.remoteServers.status(of: server.id) == .offline
        Text(isOffline ? "\(server.name) (Offline)" : server.name)
          .tag(JobTarget.remote(serverID: server.id))
          .disabled(isOffline)
      }
    }
    .pickerStyle(.menu)
    .help(model.runTargetProblem ?? "Where new jobs run. Add servers in Settings ▸ Compute.")
    .onAppear {
      model.remoteServers.loadIfNeeded()
      if !model.remoteServers.servers.isEmpty { model.remoteServers.startBrowsing() }
    }
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
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var saveError: String?
  @State private var isTargeted = false
  /// A video dropped on the canvas, choosing how to upscale it.
  @State private var droppedVideo: DroppedVideo?
  @State private var videoError: String?
  @Environment(\.undoManager) private var undoManager
  /// The brush stroke being drawn, in image pixels, until it's added to the mask.
  @State private var liveStroke: CanvasMask.Stroke?
  /// The red tint of the canvas mask, redrawn when the mask changes.
  @State private var maskTint: CGImage?
  /// The Select tool's drag: where it began and is now, in image pixels.
  @State private var selectDrag: (start: CGPoint, end: CGPoint)?
  #if os(macOS)
    /// Space is held: a drag moves the image whatever the tool.
    @State private var spaceDown = false
    /// Option is held: a Select click marks what to leave out.
    @State private var optionDown = false
    @FocusState private var canvasFocused: Bool
  #else
    /// Where each finger's drag began, for moving with one finger.
    @State private var touchStart: CGPoint?
    /// Where the Pencil's Select drag began (view points).
    @State private var pencilStart: CGPoint?
    /// When the Pencil last marked a point or box, so the same touch's tap doesn't mark again.
    @State private var pencilMarkedAt: Date?
  #endif

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
        if let clip = model.canvasClip {
          // A finished video plays in the frame.
          ClipPlayer(item: clip, onCanvas: true)
            .frame(width: frameRect.width, height: frameRect.height)
            .position(x: frameRect.midX, y: frameRect.midY)
        } else if let image = model.image {
          let size = CGSize(
            width: Double(image.width) * zoom * points, height: Double(image.height) * zoom * points)
          let frames = model.canvasPreviewFrames
          let picture = Group {
            // A video run's preview plays its frames.
            if frames.count > 1 {
              FlipBook(frames: frames, framesPerSecond: model.videoModel?.framesPerSecond ?? 12)
            } else {
              Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(zoom * points > 2 ? .none : .high)
                .accessibilityElement()
                .accessibilityLabel("Canvas image")
                .accessibilityAddTraits(.isImage)
            }
          }
          .frame(width: size.width, height: size.height)
          .position(center)
          picture
            .blur(radius: 6)
            .opacity(0.45)
          picture
            .mask { Rectangle().frame(width: frameRect.width, height: frameRect.height).position(x: frameRect.midX, y: frameRect.midY) }
          if model.canvasShowsImage {
            maskOverlay(imageSize: CGSize(width: image.width, height: image.height), scale: zoom * points)
              .frame(width: size.width, height: size.height)
              .position(center)
              .allowsHitTesting(false)
            if model.canvasTool == .select {
              selectionOverlay(image: image, scale: zoom * points)
                .frame(width: size.width, height: size.height)
                .position(center)
                .allowsHitTesting(false)
            }
          }
        }
        let isInput = model.effectiveCanvasMode == .edit && model.image != nil && model.canvasClip == nil
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
                .help("Edit mode: what's inside the frame is sent to the model. Empty areas are filled in; with a mask, only the painted area changes.")
            }
            .position(x: frameRect.midX, y: frameRect.midY)
            .allowsHitTesting(false)
        }
        if model.layout != nil {
          LayoutCanvas(size: frameRect.size)
            .position(x: frameRect.midX, y: frameRect.midY)
        } else if model.image == nil, !model.isLoadingCanvasImage {
          ContentUnavailableView(
            "No image yet", systemImage: "photo",
            description: Text("Write a prompt below and press Generate (⌘↩), or drop an image here to edit it."))
        }
        if model.isLoadingCanvasImage, model.canvasClip == nil {
          CanvasLoadingIndicator()
            .position(x: frameRect.midX, y: frameRect.midY)
            .allowsHitTesting(false)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
      .contentShape(.rect)
      .gesture(
        dragGesture(canvas, points: points, center: center, zoom: zoom, frame: frameRect)
          .simultaneously(with: zoomGesture(canvas, frame: frameRect, points: points, in: geometry.size)))
      #if os(macOS)
        .focusable(model.canPaintMask)
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onKeyPress(.space, phases: .all) { press in
          spaceDown = press.phase != .up
          return .handled
        }
        // Esc clears the Select tool's points; otherwise it stops the run as before.
        .onKeyPress(.escape) {
          guard model.canvasTool == .select, model.autoMask.hasPrompt || model.autoMask.preview != nil else { return .ignored }
          model.autoMask.clearPoints()
          return .handled
        }
        .onModifierKeysChanged(mask: .option) { _, keys in optionDown = keys.contains(.option) }
        // A Space let go after focus moved elsewhere never arrives here.
        .onChange(of: canvasFocused) { if !canvasFocused { spaceDown = false } }
      #endif
        .onTapGesture(count: 2) {
          if canvas.scale == nil { canvas.zoom(to: 1) } else { canvas.zoomToFit() }
        }
      #if os(iOS)
        // A finger tap with Select marks a point (the Pencil's taps and drags go through
        // `dragGesture`).
        .onTapGesture { location in
          guard model.canvasTool == .select, model.canPaintMask,
                pencilMarkedAt.map({ Date().timeIntervalSince($0) > 0.5 }) ?? true,
                let point = selectPoint(location, frame: frameRect, points: points)
          else { return }
          model.autoMask.addPoint(point, positive: !model.autoMask.negative, model: model)
        }
      #endif
        // The margin around a video offers its menu too, not the image one.
        .contextMenu {
          if let clip = model.canvasClip {
            CanvasClipMenu(item: clip, playback: model.canvasPlayback)
          } else {
            contextMenu(canvas)
          }
        }
        .onDrop(of: CanvasDrop.types, isTargeted: $isTargeted) { providers in
          guard let provider = providers.first else { return false }
          open(dropped: provider)
          return true
        }
        .onChange(of: imageFit, initial: true) { canvas.fitScale = imageFit }
        // The Select tool's own controls, over the canvas while it's the tool: outside the
        // canvas's gestures, so a click on them doesn't mark the image.
        // At the bottom: the moodboard sits at the top right.
        .overlay(alignment: .bottom) {
          if model.canvasTool == .select {
            AutoMaskBar().padding(.bottom, 8).padding(.horizontal, 16)
          }
        }
    }
    .background(Color.underPageBackground.ignoresSafeArea())
    .onChange(of: model.canvasMask, initial: true) { updateMaskTint() }
    .onChange(of: model.image.map(ObjectIdentifier.init)) {
      updateMaskTint()
      model.autoMask.follow(model.image)
    }
    .alert(
      "Couldn't save the image",
      isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } }),
      actions: { Button("OK") { saveError = nil } },
      message: { Text(saveError ?? "") })
    .alert(
      "Couldn't open the video",
      isPresented: Binding(get: { videoError != nil }, set: { if !$0 { videoError = nil } }),
      actions: { Button("OK") { videoError = nil } },
      message: { Text(videoError ?? "") })
    .sheet(isPresented: Bindable(model).upscalingCanvasImage) {
      ImageUpscaleSheet(width: model.image?.width ?? 0, height: model.image?.height ?? 0)
    }
    .sheet(item: $droppedVideo) { video in
      VideoExportSheet(
        width: video.composition.width, height: video.composition.height,
        frameCount: video.composition.frameCount, name: video.name
      ) { upscale in
        if let upscale { queueUpscaledExport(video, upscale) }
      }
    }
    // The canvas's image as it is now: a run that finishes while it's open shows its result here.
    .sheet(isPresented: Bindable(model).viewingCanvasImage) {
      ImageViewer(
        image: model.image, imageID: model.imageItem?.tensorId, accessibilityLabel: "Canvas image, full size",
        emptyTitle: "No Image")
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

  /// Moves the image by `translation` (view points) from where the drag began.
  private func pan(_ canvas: CanvasState, by translation: CGSize, points: Double) {
    let start = gestureStart ?? (canvas.effectiveScale, canvas.offset)
    gestureStart = start
    canvas.scale = start.scale
    canvas.offset = CGSize(
      width: start.offset.width + translation.width / points,
      height: start.offset.height + translation.height / points)
  }

  /// The image pixel under `location` (view points).
  private func imagePoint(_ location: CGPoint, center: CGPoint, zoom: Double, points: Double) -> CGPoint? {
    guard let image = model.image else { return nil }
    let perPixel = zoom * points
    return CGPoint(
      x: (location.x - center.x) / perPixel + Double(image.width) / 2,
      y: (location.y - center.y) / perPixel + Double(image.height) / 2)
  }

  /// Extends the stroke being painted (or starts one) at `location`.
  private func paint(at location: CGPoint, erases: Bool, center: CGPoint, zoom: Double, points: Double) {
    guard let point = imagePoint(location, center: center, zoom: zoom, points: points) else { return }
    if liveStroke == nil {
      // The brush is sized in frame pixels, so it covers the same part of the frame at any zoom.
      liveStroke = CanvasMask.Stroke(kind: .brush, radius: model.brushSize / 2 / zoom, erases: erases)
    }
    liveStroke?.points.append(point)
  }

  private func endStroke() {
    if let stroke = liveStroke { model.addMaskStrokes([stroke], undoManager: undoManager) }
    liveStroke = nil
  }

  /// The image pixel under `location` (view points), through the frame's placement of the image
  /// (`CanvasPlacement`), for the Select tool.
  private func selectPoint(_ location: CGPoint, frame: CGRect, points: Double) -> CGPoint? {
    guard let placement = model.canvasPlacement else { return nil }
    return placement.sourcePoint(fromFrame: CGPoint(x: (location.x - frame.minX) / points, y: (location.y - frame.minY) / points))
  }

  /// Follows a Select drag (or tap) from `start` to `location` (view points).
  private func dragSelection(from start: CGPoint, to location: CGPoint, frame: CGRect, points: Double) {
    guard let from = selectPoint(start, frame: frame, points: points),
          let to = selectPoint(location, frame: frame, points: points)
    else { return }
    selectDrag = (from, to)
  }

  /// Ends a Select drag: a short one is a click (a point, `positive` or not), a longer one a box.
  private func endSelection(from start: CGPoint, to location: CGPoint, positive: Bool) {
    defer { selectDrag = nil }
    guard let drag = selectDrag else { return }
    if hypot(location.x - start.x, location.y - start.y) < 4 {
      model.autoMask.addPoint(drag.start, positive: positive, model: model)
    } else {
      model.autoMask.setBox(
        CGRect(x: drag.start.x, y: drag.start.y, width: drag.end.x - drag.start.x, height: drag.end.y - drag.start.y), model: model)
    }
  }

  #if os(macOS)
    /// A drag paints with Brush or Eraser, selects with Select (a click marks a point, Option-click
    /// one to leave out, a drag a box), and moves the image with Move or while Space is held.
    private func dragGesture(_ canvas: CanvasState, points: Double, center: CGPoint, zoom: Double, frame: CGRect) -> some Gesture {
      let paints = model.canPaintMask && model.canvasTool != .move
      let selects = model.canvasTool == .select
      return DragGesture(minimumDistance: paints ? 0 : 2)
        .onChanged { value in
          if paints, !spaceDown, gestureStart == nil {
            canvasFocused = true
            if selects {
              dragSelection(from: value.startLocation, to: value.location, frame: frame, points: points)
            } else {
              paint(at: value.location, erases: model.canvasTool == .eraser, center: center, zoom: zoom, points: points)
            }
          } else if liveStroke == nil, selectDrag == nil {
            pan(canvas, by: value.translation, points: points)
          }
        }
        .onEnded { value in
          gestureStart = nil
          endStroke()
          if selectDrag != nil {
            endSelection(from: value.startLocation, to: value.location, positive: !optionDown)
          }
        }
    }
  #else
    /// Apple Pencil paints (Eraser erases), whatever the tool; one finger moves the image, and two
    /// zoom (`zoomGesture`).
    private func dragGesture(_ canvas: CanvasState, points: Double, center: CGPoint, zoom: Double, frame: CGRect) -> some Gesture {
      SpatialEventGesture()
        .onChanged { events in
          let active = events.filter { $0.phase == .active }
          if model.canvasTool == .select, let pencil = events.first(where: { $0.kind == .pencil }) {
            // With Select the Pencil marks: a tap a point, a drag a box.
            guard model.canPaintMask else { return }
            let start = pencilStart ?? pencil.location
            pencilStart = start
            dragSelection(from: start, to: pencil.location, frame: frame, points: points)
            if pencil.phase != .active {
              endSelection(from: start, to: pencil.location, positive: !model.autoMask.negative)
              pencilStart = nil
              pencilMarkedAt = Date()
            }
          } else if let pencil = active.first(where: { $0.kind == .pencil }) {
            guard model.canPaintMask else { return }
            paint(at: pencil.location, erases: model.canvasTool == .eraser, center: center, zoom: zoom, points: points)
          } else if active.count == 1, let touch = active.first, liveStroke == nil {
            let start = touchStart ?? touch.location
            touchStart = start
            pan(canvas, by: CGSize(width: touch.location.x - start.x, height: touch.location.y - start.y), points: points)
          } else {
            touchStart = nil
          }
          if events.contains(where: { $0.kind == .pencil && $0.phase != .active }) { endStroke() }
        }
        .onEnded { events in
          gestureStart = nil
          touchStart = nil
          // A Pencil lifted in the gesture's last events, which `onChanged` doesn't see.
          if let start = pencilStart, let pencil = events.first(where: { $0.kind == .pencil }) {
            endSelection(from: start, to: pencil.location, positive: !model.autoMask.negative)
            pencilMarkedAt = Date()
          }
          pencilStart = nil
          selectDrag = nil
          endStroke()
        }
    }
  #endif

  /// The mask in red over the image, with the stroke being painted.
  private func maskOverlay(imageSize _: CGSize, scale: Double) -> some View {
    ZStack {
      if let maskTint {
        Image(decorative: maskTint, scale: 1)
          .resizable()
          .interpolation(.none)
      }
      if let liveStroke {
        Canvas { context, _ in
          var path = Path()
          let points = liveStroke.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
          if points.count == 1, let point = points.first {
            let r = liveStroke.radius * scale
            path.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
            context.fill(path, with: .color(liveStroke.erases ? .white.opacity(0.5) : .red.opacity(0.45)))
          } else {
            path.addLines(points)
            context.stroke(
              path, with: .color(liveStroke.erases ? .white.opacity(0.5) : .red.opacity(0.45)),
              style: StrokeStyle(lineWidth: liveStroke.radius * 2 * scale, lineCap: .round, lineJoin: .round))
          }
        }
      }
    }
  }

  /// The Select tool's preview tinted blue (apart from the mask's red), its points (green to
  /// include, red to leave out) and its box, over the image.
  private func selectionOverlay(image: CGImage, scale: Double) -> some View {
    let session = model.autoMask
    let preview = session.preview.flatMap { $0.image == ObjectIdentifier(image) ? $0.tint : nil }
    return ZStack {
      if let preview {
        Image(decorative: preview, scale: 1)
          .resizable()
          .interpolation(.none)
      }
      Canvas { context, _ in
        let box = selectDrag.map {
          CGRect(x: $0.start.x, y: $0.start.y, width: $0.end.x - $0.start.x, height: $0.end.y - $0.start.y).standardized
        } ?? session.box
        if let box {
          let rect = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
          context.stroke(Path(rect), with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
          context.stroke(Path(rect), with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: 1))
        }
        for point in session.points {
          let center = CGPoint(x: point.location.x * scale, y: point.location.y * scale)
          let dot = Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
          context.fill(dot, with: .color(point.positive ? .green : .red))
          context.stroke(dot, with: .color(.white), lineWidth: 2)
        }
      }
    }
  }

  private func updateMaskTint() {
    guard let image = model.image, let mask = model.canvasMask else { return maskTint = nil }
    maskTint = mask.tint(sourceSize: CGSize(width: image.width, height: image.height))
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
    Button("Show Image Full Size") { model.viewingCanvasImage = true }
      .disabled(model.image == nil)
    Divider()
    Button("Copy Image") { if let image = model.image { HistoryStore.copy(image) } }
      .disabled(model.image == nil)
    Button("Save Image…") { save() }
      .disabled(model.image == nil)
    Button("Save to Photos") { saveToPhotos() }
      .disabled(model.image == nil)
    Divider()
    Button("Upscale…") { model.upscalingCanvasImage = true }
      .disabled(!model.canUpscaleCanvasImage)
    Divider()
    CanvasContentItems(
      noun: "Image", addToMoodboardTitle: "Add to Moodboard",
      canLoadSettings: model.canvasImageSettings != nil,
      loadSettings: { model.loadCanvasImageSettings(undoManager: undoManager) },
      addToMoodboard: { model.addCanvasToMoodboard() })
    Divider()
    ZoomMenuItems(canvas: canvas)
  }

  /// Adds the image to Photos as a PNG carrying its settings, like Save Image.
  private func saveToPhotos() {
    guard let image = model.image else { return }
    let item = model.imageItem
    Task {
      do {
        let png: Data
        if let item {
          png = try await history.pngData(item)
        } else {
          guard let data = ImageTensor.png(image) else { throw ProjectError.badImage }
          png = data
        }
        try await PhotoLibrary.save([png])
      } catch {
        saveError = error.localizedDescription
      }
    }
  }

  /// Puts a dropped image on the canvas, or reads a dropped video and offers to upscale it. The
  /// video doesn't join the project.
  private func open(dropped provider: NSItemProvider) {
    Task {
      do {
        switch try await CanvasDrop.load(provider) {
        case .image(let image):
          model.setCanvasImage(image.image, metadata: image.metadata)
        case .video(let url, let name):
          droppedVideo = DroppedVideo(name: name, composition: try await TimelineComposition.make(file: url))
        case nil: break
        }
      } catch {
        videoError = error.localizedDescription
      }
    }
  }

  /// Asks where to save the dropped video upscaled, then queues the export.
  private func queueUpscaledExport(_ video: DroppedVideo, _ upscale: TimelineUpscale) {
    let create = model
    fileDialogs.save = FileDialogs.Save(
      // An empty file holds the place until the export replaces it.
      file: ExportedFile(type: .mpeg4Movie) { Data() }, name: "\(video.name) \(upscale.scale)x.mp4"
    ) { result in
      guard case .success(let url) = result else { return }
      create.queue(
        TimelineExportJob(
          composition: video.composition, upscale: upscale, title: video.name, destination: url))
    }
  }

  /// Saves as PNG; a finished image carries its settings like History's Export.
  private func save() {
    guard let image = model.image else { return }
    let item = model.imageItem
    let history = history
    fileDialogs.save = FileDialogs.Save(
      file: ExportedFile(type: .png) {
        if let item { return try await history.pngData(item) }
        guard let png = ImageTensor.png(image) else { throw ProjectError.badImage }
        return png
      },
      name: (item.map(history.fileName(for:)) ?? history.project.name) + ".png"
    ) { result in
      if case .failure(let error) = result { saveError = error.localizedDescription }
    }
  }
}

/// Shown while an image is loading onto the canvas. It waits a moment first, so the usual quick
/// load doesn't flash it.
private struct CanvasLoadingIndicator: View {
  @State private var isVisible = false

  var body: some View {
    ProgressView()
      .controlSize(.large)
      .padding(16)
      .background(.regularMaterial, in: .rect(cornerRadius: 16))
      .accessibilityLabel("Loading image")
      .opacity(isVisible ? 1 : 0)
      .task {
        try? await Task.sleep(for: .milliseconds(250))
        isVisible = true
      }
  }
}

/// What goes on the canvas and comes from it, the same for an image and a video so the two menus
/// keep their order.
struct CanvasContentItems: View {
  let noun: String
  let addToMoodboardTitle: String
  let canLoadSettings: Bool
  let loadSettings: () -> Void
  let addToMoodboard: () -> Void
  @Environment(CreateModel.self) private var model
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    Button("Open Image…") { model.imageImport = .canvas }
    Button("Open from Photos…") { model.photosImport = .canvas }
    Button("Paste Image") { model.pasteImage() }
    Button("Load Settings from \(noun)", action: loadSettings)
      .disabled(!canLoadSettings)
    Button(addToMoodboardTitle, action: addToMoodboard)
      .disabled(model.image == nil)
    Button("Match Size to \(noun)") { model.matchSizeToImage(undoManager: undoManager) }
      .disabled(model.image == nil)
    Button("Clear Canvas") { model.clearCanvas() }
      .disabled(model.image == nil)
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
      Button { canvas.zoomOut() } label: { Label("Zoom Out", systemImage: "minus").touchTarget() }
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
          .touchTarget()
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Zoom level. Pinch or use ⌘+ and ⌘− to zoom, drag to move, double-click to fit.")
      Button { canvas.zoomIn() } label: { Label("Zoom In", systemImage: "plus").touchTarget() }
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
  @Environment(ModelLibrary.self) private var library

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
        } else if let problem = model.runTargetMaskProblem {
          Label(problem, systemImage: "info.circle")
            .foregroundStyle(.secondary)
            .lineLimit(2)
        } else if let note = model.statusNote {
          Label(note, systemImage: "info.circle")
            .foregroundStyle(.secondary)
            .lineLimit(2)
        } else if model.lastSavedStep != nil {
          let took = model.imageItem.map { " in " + GenerationTime.text($0.sidecar.durationSeconds) } ?? ""
          Text("Saved to \(model.history.project.name)\(took)").foregroundStyle(.secondary)
          Button("Show in History") { navigation.section = .history }
            .linkButtonStyle()
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
      // A preset picked for a model that wasn't here: its download started from Create, so its
      // progress and Cancel are here too.
      ForEach(library.presetDownloads.values.map(\.model).sorted { $0.file < $1.file }, id: \.file) { download in
        Text("Downloading \(download.name)…").foregroundStyle(.secondary).lineLimit(1)
        ModelStatus(model: download, library: library).frame(maxWidth: 160)
      }
      QueueStatus()
      CanvasToolControls()
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
        Color.quaternaryLabel
        if let image = model.livePreview {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
          // Before the first step's preview arrives.
          Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      .frame(width: 24, height: 24)
      .clipShape(.rect(cornerRadius: 3))
      .contentShape(.rect)
      .touchTarget()
    }
    .buttonStyle(.plain)
    .help("The image being generated. Click to show it on the canvas.")
    .accessibilityLabel("The image being generated")
    .accessibilityHint("Shows it on the canvas")
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
      .rowResizePointer()
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
        .compactPickerSize()
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

  private func pickUp(_ item: HistoryItem) {
    if model.canUse(item) {
      model.use(item, restoreInput: false)
    } else {
      model.showWithPrompt(item, undoManager: undoManager)
    }
  }

  private func thumbnail(_ item: HistoryItem, isCurrent: Bool) -> some View {
    Thumbnail(item: item)
      .frame(width: 44, height: 44)
      .clipShape(.rect(cornerRadius: 4))
      .overlay(alignment: .topLeading) {
        if item.isVideo {
          Image(systemName: "film")
            .font(.system(size: 8, weight: .semibold))
            .padding(2)
            .background(.black.opacity(0.6), in: .rect(cornerRadius: 2))
            .foregroundStyle(.white)
            .padding(2)
            .help("Video")
        }
      }
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
      .onTapGesture { pickUp(item) }
      .accessibleButton(item.accessibilityDescription, isSelected: isCurrent) { pickUp(item) }
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
  /// The focused box while a style shows one per tag.
  @FocusState private var focusedTag: String?
  /// Too narrow for the buttons beside the prompt (a narrow iPad window): they go under it.
  @State private var narrow = false

  var body: some View {
    @Bindable var model = model
    let row = narrow
      ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))
    VStack(alignment: .leading, spacing: 6) {
      row {
        Group {
          if let style = model.style {
            tagFields(style)
          } else {
            promptField.focused($promptFocused)
          }
        }
        .promptBox(focused: promptFocused || focusedTag != nil)
        .help("Prompt. ⌘↩ generates. ⌘L focuses this field.")
        // Beside the prompt, as wide as the buttons at the bottom: the style, Layout and the mode
        // above them.
        ComposerColumn(spacing: 8) {
          // The rating of the image on the canvas, as in History.
          if let item = model.imageItem {
            StarRating(stars: model.history.rating(of: item)) {
              model.history.setRating($0, for: [item])
            }
            .imageScale(.large)
          }
          // Takes the column's width rather than setting it, so a long name is cut short.
          StyleControls()
            .layoutValue(key: ComposerColumn.FollowsWidth.self, value: true)
          HStack(spacing: 6) {
            if model.layoutFormat != nil {
              Toggle(
                isOn: Binding(get: { model.layout != nil }, set: { $0 ? model.openLayout() : model.closeLayout() })
              ) {
                Label("Layout", systemImage: "rectangle.3.group")
              }
              .toggleStyle(.button)
              .compactPickerSize()
              .fixedSize()
              .help("Draw boxes on the canvas and say what goes in each. The prompt is written in this model's layout format.")
            }
            modePicker
          }
          buttons
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
    .onChange(of: model.focusPromptRequest) {
      if model.style != nil { focusedTag = Style.subject } else { promptFocused = true }
    }
    #if os(iOS)
      .onGeometryChange(for: Bool.self) { $0.size.width < 480 } action: { narrow = $0 }
    #endif
  }

  /// Generate starts from the prompt; Edit also sends the canvas.
  private var modePicker: some View {
    Picker(
      "Mode", selection: Binding(get: { model.effectiveCanvasMode }, set: { model.canvasMode = $0 })
    ) {
      Text("Generate").tag(CreateModel.CanvasMode.generate)
      Text("Edit").tag(CreateModel.CanvasMode.edit)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .compactPickerSize()
    .frame(maxWidth: .infinity)
    .disabled(!model.canEdit)
    .help(
      model.canEdit
        ? "Generate starts from the prompt alone. Edit also sends the canvas: what's inside the frame is the input, and empty areas are filled in."
        : "This model doesn't take image inputs, so it always generates from the prompt. Lower Strength below 100% in the inspector to edit from the canvas.")
  }

  /// Stop, the image count and Generate.
  private var buttons: some View {
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

  /// Follows the window's corners, never tighter than a text field's.
  /// On the Mac a vertical text field doesn't scroll with the trackpad or mouse wheel, only by
  /// moving the caret, so there the prompt is a text editor sized to the same number of lines.
  /// With a style, one box per tag of its template in place of the prompt box, in the space the
  /// prompt box takes; `SUBJECT` is the prompt.
  private func tagFields(_ style: Style) -> some View {
    StyleTagFields(
      tags: style.tags, lines: promptLines, focus: $focusedTag, text: tagBinding, prompt: tagPrompt,
      submit: { model.generate() })
  }

  private func tagBinding(_ tag: String) -> Binding<String> {
    if tag == Style.subject {
      return Binding(get: { model.prompt }, set: { model.prompt = $0 })
    }
    return Binding(get: { model.styleValues[tag] ?? "" }, set: { model.styleValues[tag] = $0 })
  }

  /// A box's placeholder: the style's default for the tag, which an empty box uses.
  private func tagPrompt(_ tag: String) -> String {
    if let fallback = model.style?.defaults[tag] { return fallback }
    return tag == Style.subject ? "Describe the subject…" : "Optional: left out when empty"
  }

  @ViewBuilder private var promptField: some View {
    @Bindable var model = model
    #if os(macOS)
      Text(verbatim: " ")
        .lineLimit(promptLines, reservesSpace: true)
        .font(.body)
        .frame(maxWidth: .infinity)
        .hidden()
        .overlay {
          TextEditor(text: $model.prompt)
            .font(.body)
            .scrollContentBackground(.hidden)
            // The editor's own inset: line it up with where the field's text sat.
            .padding(.horizontal, -5)
        }
        .overlay(alignment: .topLeading) {
          if model.prompt.isEmpty {
            Text("Describe the image…")
              .font(.body)
              .foregroundStyle(.placeholder)
              .allowsHitTesting(false)
          }
        }
    #else
      TextField("Describe the image…", text: $model.prompt, axis: .vertical)
        .lineLimit(promptLines, reservesSpace: true)
        .textFieldStyle(.plain)
        .font(.body)
        .onSubmit { model.generate() }
    #endif
  }

  /// Follows the window's corners, never tighter than a text field's.
  static let fieldShape = ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true)
}

/// The controls beside the prompt, stacked and trailing-aligned: as wide as the widest at its own
/// size (the buttons, or Layout beside the mode switch), each given that width. A view marked
/// `FollowsWidth` doesn't count toward it.
struct ComposerColumn: Layout {
  var spacing: CGFloat

  struct FollowsWidth: LayoutValueKey {
    static let defaultValue = false
  }

  private func width(_ subviews: Subviews) -> CGFloat {
    subviews.filter { !$0[FollowsWidth.self] }.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
  }

  func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
    let width = width(subviews)
    let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0)))
  }

  func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
    let width = width(subviews)
    var y = bounds.minY
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      subview.place(
        at: CGPoint(x: bounds.maxX, y: y), anchor: .topTrailing, proposal: ProposedViewSize(width: width, height: size.height))
      y += size.height + spacing
    }
  }
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
      .linkButtonStyle()
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
        .accessibilityLabel("New random seed")
        Toggle("Random", isOn: Binding(get: { !model.seedLocked }, set: { model.seedLocked = !$0 }))
          .checkboxToggleStyle()
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
  @State private var choosing = false
  @State private var importingDrawThings = false
  @FocusState private var directoryFocused: Bool

  var body: some View {
    #if os(macOS)
      macBody
    #else
      Form {
        Section {
          FolderSetting(
            title: "Models folder", path: model.modelsDirectory,
            defaultPath: AppSettings.defaultModelsDirectory,
            choose: { url in
              FolderBookmarks.remember(url)
              if model.modelsDirectory != AppSettings.defaultModelsDirectory {
                FolderBookmarks.forget(model.modelsDirectory)
              }
              model.setModelsDirectory(url.path)
            },
            useDefault: { model.useDefaultModelsDirectory() })
        } footer: {
          Text("Models you download are saved here. The default is in Atelier's folder in Files.")
        }
        AdditionalModelFoldersSection()
        drawThingsSection
      }
      .settingsForm()
      .sheet(isPresented: $importingDrawThings) { DrawThingsImportSheet() }
    #endif
  }

  private var drawThingsSection: some View {
    Section {
      Button("Import from Draw Things…") { importingDrawThings = true }
    } header: {
      Text("Draw Things")
    } footer: {
      Text("Shares its models folder and brings over saved configurations and projects. You choose what, and nothing changes until you confirm.")
    }
  }

  private var macBody: some View {
    Form {
      Section {
        LabeledContent("Models directory") {
          HStack {
            TextField("Path", text: $directory)
              .labelsHidden()
              .focused($directoryFocused)
              .settingsFieldWidth()
            Button("Choose…") { choosing = true }
          }
        }
        HStack {
          Spacer()
          Button("Apply") { model.setModelsDirectory(directory) }
            .disabled(directory == model.modelsDirectory)
        }
      }
      AdditionalModelFoldersSection()
      drawThingsSection
    }
    .settingsForm()
    .sheet(isPresented: $importingDrawThings) { DrawThingsImportSheet() }
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result {
        FolderBookmarks.remember(url)
        directory = url.path
      }
    }
    .fileDialogDefaultDirectory(URL(fileURLWithPath: directory))
    .onAppear {
      directory = model.modelsDirectory
      // The window focuses the first field, which selects the whole path; start unfocused.
      Task { directoryFocused = false }
    }
  }
}

/// Settings ▸ Models: more folders models and LoRAs are read from. A file found in several
/// folders comes from the first (the models directory first, then this list in order).
private struct AdditionalModelFoldersSection: View {
  @Environment(CreateModel.self) private var model
  @State private var adding = false

  var body: some View {
    Section {
      ForEach(model.additionalModelsDirectories, id: \.self) { path in
        row(path)
      }
      Button("Add Folder…") { adding = true }
        .fileImporter(isPresented: $adding, allowedContentTypes: [.folder]) { result in
          guard case .success(let url) = result else { return }
          let path = url.path
          guard path != model.modelsDirectory, !model.additionalModelsDirectories.contains(path)
          else { return }
          FolderBookmarks.remember(url)
          model.setAdditionalModelsDirectories(model.additionalModelsDirectories + [path])
        }
    } header: {
      Text("Additional Model Folders")
    } footer: {
      Text(
        "Models and LoRAs in these folders can be picked in Create too. When a file is in more than one folder, the models folder comes first, then these in order. A folder on a disconnected drive is skipped until it's back."
      )
    }
  }

  private func row(_ path: String) -> some View {
    let available = model.availableModelsDirectories.contains(path)
    return HStack {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(displayName(path))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(path)
        if !available {
          Label("Not available", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .help("This folder can't be reached now. Its models are skipped until it's back.")
        }
      }
      Spacer()
      Button {
        FolderBookmarks.forget(path)
        model.setAdditionalModelsDirectories(model.additionalModelsDirectories.filter { $0 != path })
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Stop reading models from this folder. Its files stay where they are.")
      .accessibilityLabel("Remove \(displayName(path))")
    }
  }

  private func displayName(_ path: String) -> String {
    #if os(iOS)
      FolderSetting.location(of: path)
    #else
      (path as NSString).abbreviatingWithTildeInPath
    #endif
  }
}

#if os(iOS)
  /// A folder setting on iPad, where a typed path means nothing outside the app's own folders:
  /// where it is, as Files shows it, Choose… for any folder Files can reach, and Use Default for
  /// the folder in Atelier's Documents. Both buttons are always there; Use Default is disabled
  /// while the default is in use.
  struct FolderSetting: View {
    let title: String
    let path: String
    let defaultPath: String
    let choose: (URL) -> Void
    let useDefault: () -> Void
    @State private var choosing = false

    private var isDefault: Bool { path == defaultPath }

    var body: some View {
      // One Form row: the location, then the buttons under it.
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent(title) {
          VStack(alignment: .trailing, spacing: 2) {
            Text(Self.location(of: path) + (isDefault ? " (Default)" : ""))
              .lineLimit(2)
              .truncationMode(.middle)
              .multilineTextAlignment(.trailing)
            // The default is made when it's first used; a picked folder can go missing.
            if !isDefault, !FolderBookmarks.isReachable(path) {
              Label("Not available. Choose it again.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
        }
        ButtonRow {
          Button("Choose…") { choosing = true }
          Button("Use Default", action: useDefault)
            .disabled(isDefault)
        }
      }
      .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { choose(url) }
      }
    }

    /// The folder as Files names it: "On My iPad ▸ Atelier ▸ …" inside the app's Documents, else
    /// the picked folder's last two names.
    static func location(of path: String) -> String {
      let documents = URL.documentsDirectory.standardizedFileURL.pathComponents
      let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
      if components.starts(with: documents) {
        return (["On My iPad", "Atelier"] + components.dropFirst(documents.count)).joined(separator: " ▸ ")
      }
      let url = FolderBookmarks.open(path).url
      return url.pathComponents.suffix(2).map { FileManager.default.displayName(atPath: $0) }
        .joined(separator: " ▸ ")
    }
  }
#endif

/// Settings ▸ Images: what saved images carry, how videos are written, the output folder, and
/// notifications.
struct ImagesSettingsView: View {
  @AppStorage(AppSettings.embedsSettingsKey) private var embedsSettings = true
  @AppStorage(VideoCodec.key) private var videoCodec = VideoCodec.h264
  @AppStorage(AppSettings.savesToOutputFolderKey) private var savesToOutputFolder = false
  @AppStorage(AppSettings.outputFolderKey) private var outputFolder = AppSettings.defaultOutputFolder
  @AppStorage(AppSettings.notifiesKey) private var notifies = true
  @State private var choosingOutputFolder = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $embedsSettings) {
          Text("Include Generation Settings in Saved Images")
          Text(
            "Exported, saved and dragged images carry their prompt, model, seed and settings, in the format Draw Things reads. Videos carry them too."
          )
        }
        Picker(selection: $videoCodec) {
          ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
        } label: {
          Text("Video Format")
          Text("Videos are saved as MP4. H.264 plays everywhere; HEVC makes smaller files.")
        }
      }
      Section {
        Toggle(isOn: $savesToOutputFolder) {
          Text("Save Generated Images to Output Folder")
          Text(
            "Each new image is also written to this folder as a PNG, and each video as an MP4, named like an export. A project can use its own folder, or turn saving on or off for itself, from the project menu."
          )
        }
        #if os(macOS)
          LabeledContent("Output folder") {
            HStack {
              TextField("Path", text: $outputFolder, prompt: Text(AppSettings.defaultOutputFolder))
                .labelsHidden()
                .settingsFieldWidth()
              Button("Choose…") { choosingOutputFolder = true }
            }
          }
        #else
          FolderSetting(
            title: "Output folder", path: outputFolder, defaultPath: AppSettings.defaultOutputFolder,
            choose: { url in
              FolderBookmarks.remember(url)
              if outputFolder != AppSettings.defaultOutputFolder { FolderBookmarks.forget(outputFolder) }
              outputFolder = url.path
            },
            useDefault: {
              FolderBookmarks.forget(outputFolder)
              // Unsaved rather than saved as the default's path, which can change on iPad.
              UserDefaults.standard.removeObject(forKey: AppSettings.outputFolderKey)
            })
        #endif
      } header: {
        Text("Output Folder")
      }
      Section {
        Toggle(isOn: $notifies) {
          Text("Notify When Generations Finish")
          Text(
            "When an image or video finishes while Atelier is in the background, puts a count on the app's icon and posts a notification."
          )
        }
      } header: {
        Text("Notifications")
      }
      #if os(macOS)
        .fileImporter(isPresented: $choosingOutputFolder, allowedContentTypes: [.folder]) { result in
          if case .success(let url) = result {
            FolderBookmarks.remember(url)
            outputFolder = url.path
          }
        }
      #endif
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
    #if os(macOS)
      formStyle(.grouped)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    #else
      // A sheet on iPad: the form fills it.
      formStyle(.grouped)
    #endif
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
