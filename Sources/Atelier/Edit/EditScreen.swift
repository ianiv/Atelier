import SwiftUI
import UniformTypeIdentifiers

/// The Edit screen (sidebar "Edit"): grain and colour grading of one image, previewed live and
/// saved to History as a new step after it, or exported. The preview takes the room the
/// inspector leaves; the bottom bar holds the comparison, zoom and what to do with the result.
struct EditScreen: View {
  @Environment(EditModel.self) private var edit
  @Environment(HistoryStore.self) private var history
  @Environment(FileDialogs.self) private var fileDialogs
  /// Hold for Original is pressed (or, with VoiceOver, turned on).
  @State private var holding = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      EditPreview(holding: holding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      bottomBar
    }
    .toolbar {
      ToolbarItemGroup {
        Button("Open Image…", systemImage: "folder") { EditFiles.openImage(edit, fileDialogs) }
          .help("Open an image file to edit")
        Button("Open from Photos…", systemImage: "photo.on.rectangle") { EditFiles.openPhoto(edit, fileDialogs) }
          .help("Open a photo from the library to edit")
        Button("Use Canvas Image", systemImage: "paintbrush") { Task { await edit.openCanvasImage() } }
          .disabled(!edit.canUseCanvasImage)
          .help("Edit the image on the Create screen's canvas")
      }
      HelpToolbarItem(section: .edit)
    }
    .detailInspector(selection: 0, isEmpty: false, clearSelection: {}) {
      EditInspector()
        .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
    }
    .navigationTitle("Edit")
    // The step open at the last quit, once its project has loaded.
    .task(id: history.isLoaded ? history.project.name : nil) {
      guard history.isLoaded else { return }
      await edit.restoreSession()
    }
    .alert(
      "Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
      actions: { Button("OK") { error = nil } }, message: { Text(error ?? "") })
  }

  private var bottomBar: some View {
    @Bindable var edit = edit
    return HStack(spacing: 12) {
      // The Hold segment is itself what's held: a stock segmented Picker can't say when one
      // segment is pressed and let go, so this is drawn as one.
      EditCompareControl(mode: $edit.compareMode, holding: $holding, canHold: edit.hasSource)
      EditZoomControls(canvas: edit.canvas)
        .disabled(!edit.hasSource || edit.compareMode == .slider)
      Spacer(minLength: 8)
      Group {
        if edit.isExporting {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Exporting…")
          }
        } else {
          let status = edit.note ?? (edit.hasSource ? edit.saveProblem : nil) ?? edit.sourceTitle
          Text(status)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(status)
        }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      Button("Reset") { edit.reset() }
        .disabled(!edit.hasSource)
        .help("Back to the default look, with no profile, reference or LUT")
      Button("Add to History") {
        Task {
          do {
            try await edit.addToHistory()
          } catch is CancellationError {
            // Another image opened meanwhile: the entry is in History, nothing was queued.
          } catch {
            self.error = error.localizedDescription
          }
        }
      }
      .disabled(!edit.isFromFile || !history.isLoaded || edit.isAdding)
      .help("Put the opened image in the current project and save the edit after it")
      Button("Save to History") {
        do { try edit.save() } catch { self.error = error.localizedDescription }
      }
      .disabled(edit.saveProblem != nil)
      .help("Render the edit at full size and save it as a new step after the image")
      Button("Export…") { EditFiles.exportPNG(edit, fileDialogs) { self.error = $0 } }
        .disabled(!edit.hasSource || edit.isExporting)
        .help("Save the edit at full size as a PNG")
    }
    .padding(.horizontal, 12)
    .frame(height: 40)
  }
}

/// The comparison choice, drawn as a segmented control so that its Hold for Original segment
/// can be pressed and held: pressing it chooses Hold and shows the original until it's let go,
/// so a plain click just chooses Hold. With VoiceOver, each segment is a button marked selected
/// as a picker's are, and the Hold segment's action turns the original on and off once Hold is
/// chosen, since VoiceOver can't press and hold.
private struct EditCompareControl: View {
  @Binding var mode: Compare.Mode
  @Binding var holding: Bool
  /// There's an image whose original can show.
  let canHold: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isEnabled) private var isEnabled
  /// The Hold segment is down.
  @State private var pressed = false

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Compare.Mode.allCases, id: \.self) { segment($0) }
    }
    .padding(2)
    .background(.fill.tertiary, in: .capsule)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Comparison")
    .onChange(of: canHold) { if !canHold { holding = false } }
    .onChange(of: mode) { if mode != .hold { holding = false } }
  }

  @ViewBuilder private func segment(_ option: Compare.Mode) -> some View {
    let selected = mode == option
    let label = Text(option.title)
      .lineLimit(1)
      .padding(.horizontal, Self.horizontalPadding)
      .padding(.vertical, Self.verticalPadding)
      .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      .background { if selected { selection(down: option == .hold && pressed) } }
      .contentShape(.capsule)
    if option == .hold {
      label
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { _ in
              guard !pressed else { return }
              pressed = true
              mode = .hold
              holding = canHold
            }
            .onEnded { _ in
              pressed = false
              holding = false
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(selected && canHold ? (holding ? "Showing the original" : "Showing the edit") : "")
        // VoiceOver can't press and hold: once Hold is chosen, its action turns the original on and off.
        .accessibilityAction {
          if mode != .hold { mode = .hold } else if canHold { holding.toggle() }
        }
        .help("Press and hold to see the original in place of the edit")
    } else {
      label
        .onTapGesture { mode = option }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { mode = option }
        .help(option == .sideBySide ? "Show the original and the edit next to each other" : "Show one picture with a divider you drag across it to compare")
    }
  }

  /// The selected segment's raised capsule, as the system draws it: white over the grey track in
  /// light mode, a lighter grey in dark mode, and tinted while Hold is held down.
  private func selection(down: Bool) -> some View {
    Capsule()
      .fill(down ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(colorScheme == .dark ? Color.white.opacity(0.22) : Color.white))
      .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.12), radius: 1, y: 0.5)
  }

  #if os(macOS)
  private static let horizontalPadding: CGFloat = 10
  private static let verticalPadding: CGFloat = 3
  #else
  private static let horizontalPadding: CGFloat = 12
  private static let verticalPadding: CGFloat = 6
  #endif
}

/// − / zoom level / +, as the Create screen's status bar has them.
private struct EditZoomControls: View {
  let canvas: CanvasState

  var body: some View {
    HStack(spacing: 2) {
      Button { canvas.zoomOut() } label: { Label("Zoom Out", systemImage: "minus").touchTarget() }
        .help("Zoom Out (⌘−)")
      Menu {
        Button("Zoom to Fit") { canvas.zoomToFit() }
        Button("Zoom to Fill") { canvas.zoomToFill() }
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
      .help("Zoom level. Pinch or use ⌘+ and ⌘− to zoom, drag to move, double-click for actual size or to fit.")
      Button { canvas.zoomIn() } label: { Label("Zoom In", systemImage: "plus").touchTarget() }
        .help("Zoom In (⌘+)")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
  }
}

/// The Open and Save panels the screen and its inspector ask for.
@MainActor
enum EditFiles {
  static func openImage(_ edit: EditModel, _ dialogs: FileDialogs) {
    dialogs.open = FileDialogs.Open(types: [.image]) { urls in
      if let url = urls.first { Task { await edit.open(url: url) } }
    }
  }

  static func openPhoto(_ edit: EditModel, _ dialogs: FileDialogs) {
    dialogs.photos = FileDialogs.Photos { photos, _ in
      if let data = photos.first { Task { await edit.open(photo: data) } } else { edit.note = "The photo couldn't be loaded." }
    }
  }

  static func exportPNG(_ edit: EditModel, _ dialogs: FileDialogs, failed: @escaping @MainActor (String) -> Void) {
    dialogs.save = FileDialogs.Save(
      file: ExportedFile(type: .png) { try await edit.exportPNG() }, name: edit.exportName + ".png"
    ) { result in
      if case .failure(let error) = result { failed(error.localizedDescription) }
    }
  }
}

// MARK: - Preview

/// Where the image sits in a pane, worked out from the zoom: what the preview renders (the whole
/// image fitted, or zoomed past that only the part in view) and where it's drawn. `scale` is
/// screen pixels per image pixel, so 100% is the image's own pixels on the screen's; `offset`
/// moves the image's centre from the pane's, in points.
nonisolated struct EditViewport: Equatable {
  var imageWidth: Int
  var imageHeight: Int
  var viewSize: CGSize
  var displayScale: Double
  var scale: Double?
  var offset: CGSize = .zero

  /// Screen pixels per image pixel that fit the image in the pane.
  var fitScale: Double {
    guard imageWidth > 0, imageHeight > 0 else { return 1 }
    return max(1e-3, min(viewSize.width * displayScale / Double(imageWidth), viewSize.height * displayScale / Double(imageHeight)))
  }

  /// Screen pixels per image pixel that cover the pane.
  var fillScale: Double {
    guard imageWidth > 0, imageHeight > 0 else { return 1 }
    return max(1e-3, max(viewSize.width * displayScale / Double(imageWidth), viewSize.height * displayScale / Double(imageHeight)))
  }

  var zoom: Double { scale ?? fitScale }
  var pointsPerPixel: Double { zoom / max(displayScale, 1e-3) }

  /// The whole image's rectangle in the pane, in points.
  var imageFrame: CGRect {
    let width = Double(imageWidth) * pointsPerPixel, height = Double(imageHeight) * pointsPerPixel
    return CGRect(
      x: viewSize.width / 2 + offset.width - width / 2, y: viewSize.height / 2 + offset.height - height / 2,
      width: width, height: height)
  }

  /// The fitted preview's size in pixels: the image at the fit scale, never above its own size.
  var fitPixels: (width: Int, height: Int) {
    let scale = min(1, fitScale)
    return (max(1, Int((Double(imageWidth) * scale).rounded())), max(1, Int((Double(imageHeight) * scale).rounded())))
  }

  /// The part of the image to render on its own when the zoom is closer than the fitted preview
  /// shows: the part in view plus a margin, on a 64 px grid (so a small move reuses the render),
  /// at the zoom up to 1:1. Nil when the fitted preview is enough.
  var window: EditPipeline.Window? {
    guard imageWidth > 0, imageHeight > 0, zoom > min(1, fitScale) * 1.01 else { return nil }
    let frame = imageFrame
    let ppp = pointsPerPixel
    let x0 = max(0, -frame.minX / ppp), y0 = max(0, -frame.minY / ppp)
    let x1 = min(Double(imageWidth), (viewSize.width - frame.minX) / ppp)
    let y1 = min(Double(imageHeight), (viewSize.height - frame.minY) / ppp)
    guard x1 > x0, y1 > y0 else { return nil }
    let grid = 64.0
    let left = max(0, ((x0 - grid / 2) / grid).rounded(.down) * grid)
    let top = max(0, ((y0 - grid / 2) / grid).rounded(.down) * grid)
    let right = min(Double(imageWidth), ((x1 + grid / 2) / grid).rounded(.up) * grid)
    let bottom = min(Double(imageHeight), ((y1 + grid / 2) / grid).rounded(.up) * grid)
    guard right > left, bottom > top else { return nil }
    return EditPipeline.Window(
      x: Int(left), y: Int(top), width: Int(right - left), height: Int(bottom - top), scale: min(1, zoom))
  }

  /// Where a window's render is drawn, in points.
  func frame(of window: EditPipeline.Window) -> CGRect {
    let frame = imageFrame
    let ppp = pointsPerPixel
    return CGRect(
      x: frame.minX + Double(window.x) * ppp, y: frame.minY + Double(window.y) * ppp,
      width: Double(window.width) * ppp, height: Double(window.height) * ppp)
  }
}

/// The preview, arranged as the comparison mode says: the edit (the original while Hold is
/// pressed), the two side by side, or the slider.
private struct EditPreview: View {
  @Environment(EditModel.self) private var edit
  @Environment(FileDialogs.self) private var fileDialogs
  let holding: Bool
  @State private var isTargeted = false

  var body: some View {
    Group {
      if let image = edit.image {
        Group {
          switch edit.compareMode {
          case .hold:
            EditPane(image: image, showsOriginal: holding)
          case .sideBySide:
            HStack(spacing: 1) {
              EditPane(image: image, showsOriginal: true, title: "Original")
              EditPane(image: image, showsOriginal: false, title: "Edited")
            }
          case .slider:
            EditSliderPane(image: image)
              .padding(16)
          }
        }
        // New panes for a new source: their renders are of the old one, and drawn in the new
        // one's frame they'd show the old image stretched until the first render lands.
        .id(ObjectIdentifier(image))
      } else {
        ContentUnavailableView {
          Label(edit.isLoading ? "Opening…" : "No image to edit", systemImage: Edit.symbol)
        } description: {
          Text("Open an image, take the one on the Create canvas, or drop an image here. Open in Edit, in History's and the canvas's menus, brings a step here.")
        } actions: {
          Button("Open Image…") { EditFiles.openImage(edit, fileDialogs) }
          Button("Use Canvas Image") { Task { await edit.openCanvasImage() } }
            .disabled(!edit.canUseCanvasImage)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.underPageBackground)
    .overlay {
      if isTargeted { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) }
    }
    // What the canvas takes (`CanvasDrop`): image files and image data, which Photos and
    // browsers drag rather than a file.
    .onDrop(of: CanvasDrop.types, isTargeted: $isTargeted) { providers in
      guard let provider = providers.first else { return false }
      Task { await edit.open(dropped: provider) }
      return true
    }
  }
}

/// One pane of the preview: the edit rendered for what's in view, or the original, zoomed and
/// moved with the screen's `CanvasState` (both panes of Side by Side share it).
///
/// The edit is drawn in two layers: the whole image fitted to the pane (rendered once per look
/// and pane size), and, zoomed past that, the part in view rendered at the zoom (up to 1:1),
/// laid over it where it belongs. Each is a lane of `EditPaneRenders`, which decides when its
/// renders start and which result goes up; the last one stays up until the next arrives, with
/// the pane's spinner in its corner once a render takes a while (`EditRenderingIndicator`).
private struct EditPane: View {
  @Environment(EditModel.self) private var edit
  @Environment(\.displayScale) private var displayScale
  let image: CGImage
  let showsOriginal: Bool
  var title: String?
  /// This pane's render lanes (`EditModel.RenderLane`).
  @State private var paneID = UUID()
  @State private var renders = EditPaneRenders.forScreen()
  @State private var gestureStart: (scale: Double, offset: CGSize)?

  /// What the pane's two lanes are to show, nil for nothing.
  private struct RenderKeys: Hashable {
    var fitted: EditPaneRenders.Loop.Key?
    var window: EditPaneRenders.Loop.Key?
  }

  private var fitted: CGImage? { renders.fitted.shown?.output }
  private var failure: String? { renders.fitted.failure }

  var body: some View {
    GeometryReader { geometry in
      let canvas = edit.canvas
      let viewport = EditViewport(
        imageWidth: image.width, imageHeight: image.height, viewSize: geometry.size, displayScale: displayScale,
        scale: canvas.scale, offset: canvas.offset)
      let frame = viewport.imageFrame
      let fit = viewport.fitPixels
      let window = showsOriginal ? nil : viewport.window
      let look = EditRenderLook(options: edit.options, context: edit.contextVersion)
      let keys = RenderKeys(
        fitted: showsOriginal ? nil : .init(target: .init(source: ObjectIdentifier(image), width: fit.width, height: fit.height), look: look),
        window: window.map { .init(target: .init(source: ObjectIdentifier(image), window: $0), look: look) })
      ZStack(alignment: .topLeading) {
        if showsOriginal {
          // The source itself zoomed in; the fitted copy zoomed out, which draws smoother.
          let picture = viewport.zoom > viewport.fitScale * 1.01 ? image : (edit.originalPreview ?? image)
          Image(decorative: picture, scale: 1)
            .resizable()
            .interpolation(viewport.pointsPerPixel > 2 ? .none : .high)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
        } else {
          if let fitted {
            Image(decorative: fitted, scale: 1)
              .resizable()
              .interpolation(.high)
              .frame(width: frame.width, height: frame.height)
              .offset(x: frame.minX, y: frame.minY)
          }
          if window != nil, let windowed = renders.window.shown, let shownWindow = windowed.key.target.window {
            let rect = viewport.frame(of: shownWindow)
            Image(decorative: windowed.output, scale: 1)
              .resizable()
              .interpolation(viewport.pointsPerPixel > 2 ? .none : .high)
              .frame(width: rect.width, height: rect.height)
              .offset(x: rect.minX, y: rect.minY)
          }
          if fitted == nil {
            ProgressView().frame(width: geometry.size.width, height: geometry.size.height)
          }
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .clipped()
      .overlay(alignment: .topLeading) {
        if let title {
          Text(title).font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .padding(8)
        }
      }
      .overlay(alignment: .bottom) {
        if let failure, !showsOriginal {
          Text(failure).font(.caption).foregroundStyle(.red).padding(8)
        }
      }
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            let start = gestureStart ?? (canvas.effectiveScale, canvas.offset)
            gestureStart = start
            canvas.scale = start.scale
            canvas.offset = CGSize(width: start.offset.width + value.translation.width, height: start.offset.height + value.translation.height)
          }
          .onEnded { _ in gestureStart = nil }
          .simultaneously(
            with: MagnifyGesture()
              .onChanged { value in
                let start = gestureStart ?? (canvas.effectiveScale, canvas.offset)
                gestureStart = start
                let anchor = CGPoint(
                  x: value.startLocation.x - geometry.size.width / 2, y: value.startLocation.y - geometry.size.height / 2)
                canvas.offset = start.offset
                canvas.scale = start.scale
                canvas.zoom(to: start.scale * value.magnification, around: anchor)
              }
              .onEnded { _ in gestureStart = nil }))
      .onTapGesture(count: 2) {
        if canvas.scale == nil { canvas.zoom(to: 1) } else { canvas.zoomToFit() }
      }
      .onChange(of: viewport.fitScale, initial: true) { canvas.fitScale = viewport.fitScale }
      .onChange(of: viewport.fillScale, initial: true) { canvas.fillScale = viewport.fillScale }
      .onChange(of: keys, initial: true) { _, keys in schedule(keys) }
    }
    .accessibilityElement()
    .accessibilityLabel(showsOriginal ? "Original image" : "Edited image")
    .accessibilityAddTraits(.isImage)
    // Outside the pane's accessibility element, so VoiceOver can find it.
    .overlay(alignment: .topTrailing) { EditRenderingIndicator(pane: paneID, hidden: fitted == nil) }
    // A slider let go: its last value is final, so a render of an older one stops for it.
    .onChange(of: edit.isAdjusting) { _, adjusting in if !adjusting { renders.settle() } }
    .onChange(of: renders.fitted.isBusy, initial: true) { _, busy in mark(.fitted, busy) }
    .onChange(of: renders.window.isBusy, initial: true) { _, busy in mark(.window, busy) }
    .onDisappear {
      renders.cancel()
      edit.endRenders(pane: paneID)
    }
  }

  /// Hands the lanes the newest keys, each with a render of it made from the look as it is now.
  private func schedule(_ keys: RenderKeys) {
    let renderer = edit.renderer, context = edit.context, image = image
    renders.update(
      fitted: keys.fitted.map { key in
        (key, { try await renderer.preview(source: image, options: key.look.options, context: context, fitting: key.target.width, height: key.target.height) })
      },
      window: keys.window.flatMap { key in
        key.target.window.map { window in (key, { try await renderer.window(source: image, options: key.look.options, context: context, window: window) }) }
      },
      settled: !edit.isAdjusting)
  }

  /// The pane's lanes as the model keeps them, for its spinner.
  private func mark(_ kind: EditModel.RenderLane.Kind, _ busy: Bool) {
    let lane = EditModel.RenderLane(pane: paneID, kind: kind)
    if busy { edit.beginRender(lane) } else { edit.endRender(lane) }
  }
}

/// A pane's busy spinner, in its top trailing corner: always in the layout, shown (by opacity)
/// once one of the pane's renders has been under way for `delay`, while the last preview stays
/// up as it is. `hidden` while the pane's own first-render spinner shows instead.
private struct EditRenderingIndicator: View {
  @Environment(EditModel.self) private var edit
  let pane: UUID
  var hidden = false
  @State private var shown = false

  static let delay = Duration.milliseconds(300)
  /// The spinner's square: a small ProgressView's size.
  #if os(macOS)
  private static let side: CGFloat = 16
  #else
  private static let side: CGFloat = 20
  #endif

  var body: some View {
    let rendering = edit.isRendering(pane: pane)
    let visible = shown && !hidden
    // Not shown, a clear square of the spinner's size holds its place: an indeterminate
    // ProgressView keeps animating at opacity 0.
    Group {
      if visible {
        ProgressView().controlSize(.small)
      } else {
        Color.clear
      }
    }
    .frame(width: Self.side, height: Self.side)
    .padding(6)
    .glassEffect(.regular, in: .circle)
    .padding(8)
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(false)
    .accessibilityLabel("Rendering")
    .accessibilityHidden(!visible)
    .task(id: rendering) {
      guard rendering else {
        shown = false
        return
      }
      try? await Task.sleep(for: Self.delay)
      if !Task.isCancelled { shown = true }
    }
  }
}

/// The Slider comparison: the fitted edit and the original, as Match Colors… compares them.
private struct EditSliderPane: View {
  @Environment(EditModel.self) private var edit
  @Environment(\.displayScale) private var displayScale
  let image: CGImage
  @State private var paneID = UUID()
  @State private var loop = EditPaneRenders.sliderLoop()

  var body: some View {
    GeometryReader { geometry in
      let viewport = EditViewport(
        imageWidth: image.width, imageHeight: image.height,
        viewSize: CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 22)), displayScale: displayScale)
      let fit = viewport.fitPixels
      SliderComparison(
        matched: loop.shown?.output, original: edit.originalPreview ?? image, matchedNote: "Rendering…",
        shape: CGSize(width: image.width, height: image.height), matchedTitle: "Edited")
        .onChange(of: EditPaneRenders.Loop.Key(
          target: .init(source: ObjectIdentifier(image), width: fit.width, height: fit.height),
          look: .init(options: edit.options, context: edit.contextVersion)), initial: true)
        { _, key in schedule(key) }
    }
    .overlay(alignment: .topTrailing) { EditRenderingIndicator(pane: paneID, hidden: loop.shown == nil) }
    .onChange(of: edit.isAdjusting) { _, adjusting in if !adjusting { loop.settle() } }
    .onChange(of: loop.isBusy, initial: true) { _, busy in
      let lane = EditModel.RenderLane(pane: paneID, kind: .slider)
      if busy { edit.beginRender(lane) } else { edit.endRender(lane) }
    }
    .onDisappear {
      loop.cancel()
      edit.endRenders(pane: paneID)
    }
  }

  private func schedule(_ key: EditPaneRenders.Loop.Key) {
    let renderer = edit.renderer, context = edit.context, image = image
    loop.request(key, settled: !edit.isAdjusting) {
      try await renderer.preview(source: image, options: key.look.options, context: context, fitting: key.target.width, height: key.target.height)
    }
  }
}
