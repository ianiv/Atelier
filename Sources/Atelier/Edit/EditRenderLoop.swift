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
    running?.task.cancel()
    running = nil
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
  }

  private func finish(_ id: Int, _ result: Result<Output, any Error>) {
    // A render stopped after its last check: its result is stale, and the lane has moved on.
    guard let running, running.id == id else { return }
    self.running = nil
    finished = running.key
    switch result {
    case .success(let output):
      shown = (running.key, output)
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

/// What an Edit preview render is of: a change to any of it means a render on its way can't
/// be used.
nonisolated struct EditRenderTarget: Hashable, Sendable {
  var source: ObjectIdentifier
  var width = 0
  var height = 0
  var window: EditPipeline.Window?
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
  func update(fitted fittedRequest: Request?, window windowRequest: Request?, settled: Bool) {
    if let windowRequest {
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

  /// A slider was let go.
  func settle() {
    window.settle()
    fitted.settle()
  }

  /// The pane went away.
  func cancel() {
    fitted.cancel()
    window.cancel()
  }
}
