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
/// This policy is the one the screen had: each new key cancels the render on its way and starts
/// again after `pause`, so a drag in progress doesn't start a render per frame.
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
  /// A render is under way (or waiting to start) for a key that isn't shown yet.
  private(set) var isBusy = false
  /// How many results have gone up, for the bench and tests.
  private(set) var deliveries = 0

  /// The wait before a render starts.
  @ObservationIgnored let pause: Duration
  @ObservationIgnored private var newest: Key?
  @ObservationIgnored private var running: (id: Int, key: Key, task: Task<Void, Never>)?
  @ObservationIgnored private var nextID = 0

  init(pause: Duration = .zero) {
    self.pause = pause
  }

  /// The newest key to show, with how to render it.
  func request(_ key: Key, settled _: Bool = true, render: @escaping Render) {
    guard key != newest else { return }
    newest = key
    running?.task.cancel()
    start(key, render)
  }

  /// A slider was let go: the newest key is final.
  func settle() {}

  /// Nothing to render (the pane went away, or shows something else): stops the render on its
  /// way and leaves the lane idle. What's shown stays.
  func cancel() {
    running?.task.cancel()
    running = nil
    newest = nil
    isBusy = false
  }

  private func start(_ key: Key, _ render: @escaping Render) {
    nextID += 1
    let id = nextID, pause = pause
    isBusy = true
    let task = Task { [weak self] in
      do {
        if pause > .zero { try await Task.sleep(for: pause) }
        let output = try await render()
        self?.finish(id, .success(output))
      } catch {
        self?.finish(id, .failure(error))
      }
    }
    running = (id, key, task)
  }

  private func finish(_ id: Int, _ result: Result<Output, any Error>) {
    // A render replaced or cancelled after its last check: its result is stale.
    guard let running, running.id == id, !running.task.isCancelled else { return }
    self.running = nil
    switch result {
    case .success(let output):
      shown = (running.key, output)
      failure = nil
      deliveries += 1
    case .failure(let error):
      if error is CancellationError { return }
      failure = error.localizedDescription
    }
    isBusy = false
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
/// in view.
@Observable
final class EditPaneRenders {
  typealias Loop = EditRenderLoop<EditRenderTarget, EditRenderLook, CGImage>
  typealias Request = (key: Loop.Key, render: Loop.Render)

  let fitted: Loop
  let window: Loop

  /// The pause before every render (a pane's two and the Slider's), so a drag in progress
  /// doesn't start a render per frame: each new value cancels the pause before the work starts.
  static let renderPause = Duration.milliseconds(30)

  /// A pane's lanes as the screen runs them (and the bench times them).
  static func forScreen() -> EditPaneRenders { EditPaneRenders(pause: renderPause) }

  /// The Slider comparison's one lane, as the screen runs it.
  static func sliderLoop() -> Loop { Loop(pause: renderPause) }

  init(pause: Duration = .zero) {
    fitted = Loop(pause: pause)
    window = Loop(pause: pause)
  }

  /// The newest keys, nil for a lane with nothing to render. `settled` is false while a slider
  /// is being dragged.
  func update(fitted fittedRequest: Request?, window windowRequest: Request?, settled: Bool) {
    if let windowRequest { window.request(windowRequest.key, settled: settled, render: windowRequest.render) } else { window.cancel() }
    if let fittedRequest { fitted.request(fittedRequest.key, settled: settled, render: fittedRequest.render) } else { fitted.cancel() }
  }

  func settle() {
    window.settle()
    fitted.settle()
  }

  func cancel() {
    window.cancel()
    fitted.cancel()
  }
}
