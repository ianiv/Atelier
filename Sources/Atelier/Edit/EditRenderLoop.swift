import CoreGraphics
import Foundation

/// One render lane of an Edit preview pane (its fitted preview, its zoomed window, or the
/// Slider's preview): what decides when a render starts, which result goes up, and whether the
/// lane is busy. A type of its own rather than `.task(id:)` modifiers on the pane, so the
/// scheduling can be unit tested with a fake renderer and timed by `--edit-render-bench`
/// through the same code the screen runs.
///
/// A key is a `Target` (what the render is of: the source, its size, the window) and a `Look`
/// (the options and the context they render with). The pane asks for the newest key with
/// `request`; the result is `shown`.
///
/// Latest wins. A new look doesn't stop the render on its way: a slider ticks every 16 ms and a
/// render of a 10 MP preview takes 100–300 ms, so cancelling on every change (as the screen
/// first did, after a pause) showed nothing at all until the slider was let go. Instead the
/// render finishes and goes up, and if the newest key differs by then that's rendered next,
/// at once; the values in between are skipped, never queued. The lane is idle once it has
/// caught up. A render is stopped only when its result can't be used (another source, size or
/// window: a new `Target`), when the lane has nothing to render (`cancel`), or when the look is
/// final (`request(settled: true)` or `settle`, a slider let go, a toggle or picker changed),
/// so the final look starts now rather than after a stale one.
@Observable
final class EditRenderLoop<Target: Hashable, Look: Hashable, Output: Sendable> {
  nonisolated struct Key: Hashable {
    var target: Target
    var look: Look
  }

  typealias Render = @Sendable () async throws -> Output

  /// The last render that finished, and what it was of.
  private(set) var shown: (key: Key, output: Output)?
  /// The last render that finished, as `shown` is but for a partial result (`showPartial`), which
  /// is drawn over it: a zoomed view's partial has holes where its tiles are still rendering.
  private(set) var complete: (key: Key, output: Output)?
  /// When `shown` and `complete` went up, in the order of every lane's (`EditRenderCounts.serial`),
  /// so a pane can tell which of two lanes' results is newer.
  private(set) var shownSerial = 0
  private(set) var completeSerial = 0
  /// What went wrong with the last render, nil once one succeeds.
  private(set) var failure: String?
  /// A render is under way, or waiting to start (`canStart`), for a key that isn't shown yet.
  /// It stays true from one render to the next, so the pane's spinner doesn't flicker between
  /// them.
  private(set) var isBusy = false
  /// How many results have gone up, for the bench and tests.
  private(set) var deliveries = 0

  /// Whether a render may start now. The fitted preview's lane waits while the zoomed window's
  /// is busy (`EditPaneRenders`); `resume` tries again.
  @ObservationIgnored var canStart: () -> Bool = { true }
  /// Called whenever the lane goes idle, so a lane waiting on this one can start.
  @ObservationIgnored var onIdle: () -> Void = {}

  @ObservationIgnored private var newest: (key: Key, render: Render)?
  @ObservationIgnored private var running: (id: Int, key: Key, task: Task<Void, Never>)?
  /// The key of the last render that finished (shown, or failed), so asking for it again
  /// renders nothing.
  @ObservationIgnored private var finished: Key?
  @ObservationIgnored private var nextID = 0

  init() {}

  /// The newest key to show, with how to render it. `settled` is false while a slider is being
  /// dragged: then a render of an older look on its way finishes first. Otherwise (a slider let
  /// go, a toggle, a typed value) a stale render is stopped and this one starts at once.
  func request(_ key: Key, settled: Bool = true, render: @escaping Render) {
    newest = (key, render)
    if let running {
      if running.key == key { return }
      // A render of another source, size or window can't be shown: stop it. One of an older
      // look can, unless this look is final.
      guard running.key.target != key.target || settled else { return }
      stop()
    }
    startNewest()
  }

  /// A slider was let go: the newest key is final, so a render of an older look on its way is
  /// stopped and the newest starts now.
  func settle() {
    guard let running, let newest, running.key != newest.key else { return }
    stop()
    startNewest()
  }

  /// Puts up part of the render of `key` on its way (a zoomed view whose kept tiles are in and
  /// whose others are still rendering), if that's still the one running; the lane stays busy
  /// until the render finishes. Counted in `partials`, not `deliveries`.
  func showPartial(_ output: Output, of key: Key) {
    guard let running, running.key == key else { return }
    shown = (key, output)
    EditRenderCounts.serial += 1
    shownSerial = EditRenderCounts.serial
    partials += 1
  }

  /// How many partial results have gone up (`showPartial`).
  private(set) var partials = 0

  /// Tries again to start a render that was waiting on `canStart`.
  func resume() {
    if running == nil { startNewest() }
  }

  /// Nothing to render (the pane went away, or shows something else): stops the render on its
  /// way and leaves the lane idle. What's shown stays.
  func cancel() {
    stop()
    newest = nil
    goIdle()
  }

  private func stop() {
    guard let running else { return }
    running.task.cancel()
    self.running = nil
    EditRenderCounts.stopped += 1
  }

  private func startNewest() {
    guard let newest, newest.key != finished else { return goIdle() }
    guard canStart() else {
      if !isBusy { isBusy = true }
      return
    }
    nextID += 1
    let id = nextID, render = newest.render
    if !isBusy { isBusy = true }
    let task = Task { [weak self] in
      do {
        let output = try await render()
        self?.finish(id, .success(output))
      } catch {
        self?.finish(id, .failure(error))
      }
    }
    running = (id, newest.key, task)
    EditRenderCounts.started += 1
  }

  private func finish(_ id: Int, _ result: Result<Output, any Error>) {
    // A render stopped after its last check: its result is stale, and the lane has moved on.
    guard let running, running.id == id else { return }
    self.running = nil
    finished = running.key
    switch result {
    case .success(let output):
      shown = (running.key, output)
      complete = (running.key, output)
      EditRenderCounts.serial += 1
      shownSerial = EditRenderCounts.serial
      completeSerial = shownSerial
      failure = nil
      deliveries += 1
    case .failure(let error):
      if !(error is CancellationError) { failure = error.localizedDescription }
    }
    // Straight on to the newest look if it changed meanwhile; idle if caught up.
    startNewest()
  }

  private func goIdle() {
    if isBusy { isBusy = false }
    onIdle()
  }
}

/// Renders every Edit lane has started, and stopped on their way (a new target, or a cancel),
/// since launch: for `--edit-render-bench` and `--edit-ui-bench`, which count what a pinch or
/// pan sets off.
@MainActor
enum EditRenderCounts {
  static var started = 0
  static var stopped = 0
  /// Counts results going up in any lane (`EditRenderLoop.shownSerial`).
  static var serial = 0
}

/// What an Edit preview render is of: a change to any of it means a render on its way can't
/// be used.
nonisolated struct EditRenderTarget: Hashable, Sendable {
  var source: ObjectIdentifier
  var width = 0
  var height = 0
  var window: EditPipeline.Window?
  /// A zoomed view (`EditRenderer.zoomed`), the edit's window lane.
  var zoomed: EditPipeline.Zoomed?
  /// The size of the image it's of (0 when not given): a fitted render of one image can stand in
  /// for the next of the same size (`stands(for:width:height:)`).
  var sourceWidth = 0
  var sourceHeight = 0

  /// Whether a fitted render of this target can stay up for the image `source`, `width` ×
  /// `height`, until that one's render lands: one of it, or of the working image it replaced when
  /// the size is the same (a Heal stroke: the picture barely changes). A new size (a crop) can't:
  /// drawn in the new frame it would be stretched. Panes are made anew for a new source, so this
  /// never shows another image's render.
  func stands(for source: ObjectIdentifier, width: Int, height: Int) -> Bool {
    self.source == source || (sourceWidth > 0 && sourceWidth == width && sourceHeight == height)
  }
}

/// The look an Edit preview render shows: the options and the context version they render with.
nonisolated struct EditRenderLook: Hashable, Sendable {
  var options: EditOptions
  var context: Int
}

/// A preview pane's two render lanes: the whole image fitted, and zoomed past that the window
/// in view. Zoomed in, the window is what the user is looking at, so it goes first: the fitted
/// lane starts a render only while the window's lane is idle (one already on its way finishes),
/// rather than the two sharing the CPU and both arriving late.
@Observable
final class EditPaneRenders {
  typealias Loop = EditRenderLoop<EditRenderTarget, EditRenderLook, CGImage>
  typealias Request = (key: Loop.Key, render: Loop.Render)

  let fitted = Loop()
  let window = Loop()

  init() {
    fitted.canStart = { [weak window] in !(window?.isBusy ?? false) }
    window.onIdle = { [weak fitted] in fitted?.resume() }
  }

  /// A pane's lanes as the screen runs them (and the bench times them).
  static func forScreen() -> EditPaneRenders { EditPaneRenders() }

  /// The Slider comparison's one lane, as the screen runs it.
  static func sliderLoop() -> Loop { Loop() }

  /// The newest keys, nil for a lane with nothing to render. `settled` is false while a slider
  /// is being dragged (`EditRenderLoop.request`).
  /// `holdingWindow`: a pinch or pan is moving the view, so the window lane is left as it is (a
  /// render on its way finishes, none starts, what's shown stays up, drawn where the view puts
  /// it) until the gesture ends and the pane asks again.
  func update(fitted fittedRequest: Request?, window windowRequest: Request?, settled: Bool, holdingWindow: Bool = false) {
    if holdingWindow {
      request(fittedRequest, settled: settled)
    } else if let windowRequest {
      // The window first, so the fitted lane sees it busy.
      window.request(windowRequest.key, settled: settled, render: windowRequest.render)
      request(fittedRequest, settled: settled)
    } else {
      // The fitted lane's newest first, so the window going idle starts that one.
      request(fittedRequest, settled: settled)
      window.cancel()
    }
  }

  private func request(_ fittedRequest: Request?, settled: Bool) {
    if let fittedRequest { fitted.request(fittedRequest.key, settled: settled, render: fittedRequest.render) } else { fitted.cancel() }
  }

  /// What a pane's two lanes are to render for `viewport`, nil for nothing: the targets its
  /// size and zoom make, which go with the look when the pane schedules (`schedule`). The pane's
  /// body works out only these, never reading the look, so a slider moving doesn't work out the
  /// pane again; only a render landing does.
  struct Targets: Hashable {
    var fitted: EditRenderTarget?
    var window: EditRenderTarget?
  }

  /// The edit's targets for `image` in `viewport`.
  static func targets(_ image: CGImage, _ viewport: EditViewport) -> Targets {
    let fit = viewport.fitPixels
    return Targets(
      fitted: .init(source: ObjectIdentifier(image), width: fit.width, height: fit.height, sourceWidth: image.width, sourceHeight: image.height),
      window: viewport.zoomed.map { .init(source: ObjectIdentifier(image), zoomed: $0) })
  }

  /// Hands the lanes the newest keys: `targets` with `look`, each with a render of it, as
  /// `EditPane` asks them (and the benches, through the same code). `moving`: a pinch or drag is
  /// moving the view.
  func schedule(
    _ targets: Targets, image: CGImage, renderer: EditRenderer, context: EditPipeline.Context, look: EditRenderLook, settled: Bool,
    moving: Bool = false
  ) {
    if moving, let target = targets.window {
      showKept(target, image: image, renderer: renderer, look: look)
    } else {
      endKept()
    }
    update(
      fitted: targets.fitted.map { target -> Request in
        (Loop.Key(target: target, look: look), { try await renderer.preview(source: image, options: look.options, context: context, fitting: target.width, height: target.height) })
      },
      window: targets.window.flatMap { target in
        target.zoomed.map { zoomed -> Request in
          let lane = window
          return (Loop.Key(target: target, look: look), {
            try await renderer.zoomed(source: image, options: look.options, context: context, contextID: look.context, zoomed: zoomed) { part in
              await lane.showPartial(part, of: .init(target: target, look: look))
            }
          })
        }
      },
      settled: settled, holdingWindow: moving)
  }

  @ObservationIgnored private var keptPass: (target: EditRenderTarget, task: Task<Void, Never>)?

  /// Kept tiles put up while a pan or pinch moves the view (`showKept`), each a strip that came
  /// into view, drawn over the window lane's last render; one that went up before the window
  /// lane's last complete render (`EditRenderLoop.completeSerial`) is done with.
  struct Overlay {
    var target: EditRenderTarget
    var look: EditRenderLook
    var image: CGImage
    var serial: Int
    var tiles: Set<EditRenderer.Tile>
  }

  private(set) var overlays: [Overlay] = []
  /// The tiles `overlays` hold, and the scale and look they're of.
  @ObservationIgnored private var overlaid: (scale: Double, look: EditRenderLook, tiles: Set<EditRenderer.Tile>)?

  /// While a pan or pinch moves the view: the kept tiles in view that neither the window lane's
  /// last complete render nor an overlay already shows (`EditRenderer.keptView`), put up as one
  /// more overlay, so tiles already rendered show as they come into view. Nothing renders; asked
  /// again only when the tiles in view change, and only for the new strip, since the main thread
  /// puts up each image.
  func showKept(_ target: EditRenderTarget, image: CGImage, renderer: EditRenderer, look: EditRenderLook) {
    guard let zoomed = target.zoomed else { return }
    let side = renderer.tileSide, region = zoomed.region
    let x = region.x / side * side, y = region.y / side * side
    let aligned = EditRenderTarget(
      source: target.source,
      zoomed: .init(
        scale: zoomed.scale,
        region: .init(x: x, y: y, width: (region.x + region.width + side - 1) / side * side - x, height: (region.y + region.height + side - 1) / side * side - y)))
    guard keptPass?.target != aligned else { return }
    keptPass?.task.cancel()
    pruneOverlays()
    if let overlaid, overlaid.scale != zoomed.scale || overlaid.look != look {
      overlays = []
      self.overlaid = nil
    }
    // Strips a long or back-and-forth pan left behind: out of view, so dropped (their tiles can
    // go up again when they're back).
    let view = aligned.zoomed!.region
    func inView(_ overlay: Overlay) -> Bool {
      guard let region = overlay.target.zoomed?.region else { return false }
      return region.x < view.x + view.width && view.x < region.x + region.width && region.y < view.y + view.height && view.y < region.y + region.height
    }
    if overlays.contains(where: { !inView($0) }) {
      overlays.removeAll { !inView($0) }
      overlaid = overlays.isEmpty ? nil : overlaid.map { ($0.scale, $0.look, overlays.reduce(into: Set()) { $0.formUnion($1.tiles) }) }
    }
    let lane = window
    // Only what the last complete render up doesn't already show.
    let excluding = lane.complete.flatMap { complete in
      complete.key.target.source == target.source && complete.key.look == look ? complete.key.target.zoomed : nil
    }.flatMap { $0.scale == zoomed.scale ? $0.region : nil }
    let skipping = overlaid?.tiles ?? []
    let task = Task {
      guard let kept = await renderer.keptView(
              source: image, options: look.options, contextID: look.context, zoomed: aligned.zoomed!, excluding: excluding, skipping: skipping),
        !Task.isCancelled
      else { return }
      EditRenderCounts.serial += 1
      overlays.append(Overlay(target: EditRenderTarget(source: target.source, zoomed: kept.zoomed), look: look, image: kept.image, serial: EditRenderCounts.serial, tiles: kept.tiles))
      overlaid = (zoomed.scale, look, (overlaid?.tiles ?? []).union(kept.tiles))
    }
    keptPass = (aligned, task)
  }

  /// The gesture ended: no more kept-tile passes (the overlays up stay until the window's render
  /// lands).
  func endKept() {
    keptPass?.task.cancel()
    keptPass = nil
    pruneOverlays()
  }

  private func pruneOverlays() {
    guard overlays.contains(where: { $0.serial < window.completeSerial }) else { return }
    overlays.removeAll { $0.serial < window.completeSerial }
    if overlays.isEmpty { overlaid = nil }
  }

  /// A slider was let go.
  func settle() {
    window.settle()
    fitted.settle()
  }

  /// The pane went away.
  func cancel() {
    endKept()
    overlays = []
    overlaid = nil
    fitted.cancel()
    window.cancel()
  }
}
