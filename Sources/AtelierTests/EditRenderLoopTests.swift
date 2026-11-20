@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// The Edit preview's render scheduling (`EditRenderLoop`, `EditPaneRenders`) with a fake
/// renderer whose renders finish only when a test says so.
@Suite(.tags(.smoke))
struct EditRenderLoopTests {
  typealias Loop = EditRenderLoop<String, Int, String>

  /// Renders that wait for `finish`, recording which looks started and which were cancelled.
  @MainActor final class FakeRenderer {
    private(set) var started: [String] = []
    private(set) var cancelled: [String] = []
    private var waiting: [String: CheckedContinuation<String, any Error>] = [:]

    /// A render of `name`, finishing with "`name` done".
    func render(_ name: String) -> @Sendable () async throws -> String {
      { [self] in try await self.run(name) }
    }

    private func run(_ name: String) async throws -> String {
      started.append(name)
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          if Task.isCancelled {
            cancelled.append(name)
            continuation.resume(throwing: CancellationError())
          } else {
            waiting[name] = continuation
          }
        }
      } onCancel: {
        Task { @MainActor in self.cancel(name) }
      }
    }

    private func cancel(_ name: String) {
      guard let continuation = waiting.removeValue(forKey: name) else { return }
      cancelled.append(name)
      continuation.resume(throwing: CancellationError())
    }

    func finish(_ name: String) {
      waiting.removeValue(forKey: name)?.resume(returning: "\(name) done")
    }

    func fail(_ name: String) {
      waiting.removeValue(forKey: name)?.resume(throwing: CocoaError(.fileReadCorruptFile))
    }

    var inFlight: Set<String> { Set(waiting.keys) }
  }

  /// Waits (up to two seconds) for `condition`, which the loop's tasks make true on the main actor.
  @MainActor private func until(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
  }

  @MainActor private func key(_ target: String, _ look: Int) -> Loop.Key { .init(target: target, look: look) }

  /// Asks `loop` for look `look` of `target`, rendered as "target/look".
  @MainActor private func ask(_ loop: Loop, _ fake: FakeRenderer, _ target: String, _ look: Int, settled: Bool = false) {
    loop.request(key(target, look), settled: settled, render: fake.render("\(target)/\(look)"))
  }

  @Test @MainActor func aDragLetsTheRenderOnItsWayFinishAndSkipsToTheNewest() async {
    let loop = Loop(), fake = FakeRenderer()
    ask(loop, fake, "a", 0)
    await until { fake.started == ["a/0"] }
    #expect(loop.isBusy)
    // Newer looks while it renders: nothing is cancelled and nothing else starts.
    for look in 1...5 { ask(loop, fake, "a", look) }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(fake.cancelled.isEmpty && fake.started == ["a/0"])
    // It goes up, then the newest renders at once, the ones between skipped.
    fake.finish("a/0")
    await until { fake.started.count == 2 }
    #expect(loop.shown?.output == "a/0 done" && loop.shown?.key == key("a", 0))
    #expect(fake.started == ["a/0", "a/5"])
    #expect(loop.isBusy)
    fake.finish("a/5")
    await until { !loop.isBusy }
    #expect(loop.shown?.key == key("a", 5) && loop.deliveries == 2 && fake.cancelled.isEmpty)
  }

  @Test @MainActor func asOftenAsItRendersTheFinalLookIsAlwaysRendered() async {
    let loop = Loop(), fake = FakeRenderer()
    var rendered: [String] = []
    for look in 0..<30 {
      ask(loop, fake, "a", look)
      // Every third change, the render on its way finishes.
      if look % 3 == 2, let name = fake.inFlight.first {
        fake.finish(name)
        rendered.append(name)
        await until { fake.inFlight.count == 1 || !loop.isBusy }
      }
    }
    while loop.isBusy {
      await until { !fake.inFlight.isEmpty || !loop.isBusy }
      if let name = fake.inFlight.first { fake.finish(name) }
      await until { fake.inFlight.isEmpty }
    }
    #expect(loop.shown?.key == key("a", 29))
    #expect(fake.cancelled.isEmpty)
    // Never more renders than results (nothing queued up behind the newest).
    #expect(fake.started.count == loop.deliveries)
    // And asking for what's shown renders nothing.
    ask(loop, fake, "a", 29)
    #expect(!loop.isBusy && fake.started.count == loop.deliveries)
  }

  @Test @MainActor func releaseStopsAStaleRenderForTheFinalLook() async {
    let loop = Loop(), fake = FakeRenderer()
    ask(loop, fake, "a", 0)
    await until { fake.started == ["a/0"] }
    ask(loop, fake, "a", 1)
    ask(loop, fake, "a", 2)
    loop.settle()
    await until { fake.cancelled == ["a/0"] && fake.started.count == 2 }
    #expect(fake.started == ["a/0", "a/2"])
    #expect(loop.isBusy)
    fake.finish("a/2")
    await until { !loop.isBusy }
    #expect(loop.shown?.key == key("a", 2) && loop.deliveries == 1)

    // Let go on the look that's rendering: nothing to stop.
    ask(loop, fake, "a", 3)
    await until { fake.started.count == 3 }
    loop.settle()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(fake.cancelled == ["a/0"])
    fake.finish("a/3")
    await until { !loop.isBusy }

    // A settled change (a toggle, a typed value) is a release of its own.
    ask(loop, fake, "a", 4)
    await until { fake.started.count == 4 }
    ask(loop, fake, "a", 5, settled: true)
    await until { fake.cancelled.contains("a/4") && fake.started.last == "a/5" }
    fake.finish("a/5")
    await until { !loop.isBusy }
    #expect(loop.shown?.key == key("a", 5))
  }

  @Test @MainActor func aNewTargetStopsARenderItCantUse() async {
    let loop = Loop(), fake = FakeRenderer()
    ask(loop, fake, "small", 0)
    await until { fake.started == ["small/0"] }
    // Another size (or source, or window) mid-drag: the old render can't be shown.
    ask(loop, fake, "large", 0)
    await until { fake.cancelled == ["small/0"] && fake.started.count == 2 }
    #expect(fake.started == ["small/0", "large/0"])
    // Its result, should it arrive after the cancel, doesn't go up.
    fake.finish("small/0")
    fake.finish("large/0")
    await until { !loop.isBusy }
    #expect(loop.shown?.key == key("large", 0) && loop.deliveries == 1)
  }

  @Test @MainActor func cancelLeavesTheLaneIdleAndKeepsWhatsShown() async {
    let loop = Loop(), fake = FakeRenderer()
    ask(loop, fake, "a", 0)
    await until { !fake.inFlight.isEmpty }
    fake.finish("a/0")
    await until { !loop.isBusy }
    ask(loop, fake, "a", 1)
    await until { fake.inFlight == ["a/1"] }
    loop.cancel()
    #expect(!loop.isBusy)
    await until { fake.cancelled == ["a/1"] }
    #expect(loop.shown?.key == key("a", 0))
    // Asked again for what's shown (the pane shows the edit again): nothing to render.
    ask(loop, fake, "a", 0)
    #expect(!loop.isBusy && fake.started.count == 2)
  }

  @Test @MainActor func aFailureIsReportedAndTheLaneMovesOn() async {
    let loop = Loop(), fake = FakeRenderer()
    ask(loop, fake, "a", 0)
    await until { !fake.inFlight.isEmpty }
    ask(loop, fake, "a", 1)
    fake.fail("a/0")
    await until { fake.started.count == 2 }
    #expect(loop.failure != nil && loop.shown == nil && loop.isBusy)
    fake.finish("a/1")
    await until { !loop.isBusy }
    #expect(loop.failure == nil && loop.shown?.key == key("a", 1))
  }

  @Test @MainActor func busyStaysOnBetweenBackToBackRenders() async throws {
    let loop = Loop(), fake = FakeRenderer()
    var changes: [Bool] = []
    var last = loop.isBusy
    func watch() {
      if loop.isBusy != last {
        last = loop.isBusy
        changes.append(last)
      }
    }
    ask(loop, fake, "a", 0)
    watch()
    for look in 1...3 {
      await until { !fake.inFlight.isEmpty }
      ask(loop, fake, "a", look)
      watch()
      fake.finish(try #require(fake.inFlight.first))
      await until { fake.started.count == look + 1 }
      watch()
    }
    await until { !fake.inFlight.isEmpty }
    fake.finish(try #require(fake.inFlight.first))
    await until { !loop.isBusy }
    watch()
    #expect(changes == [true, false])
  }

  // MARK: - What's final

  @Test @MainActor func slidersCountAndTheirChangesArentFinal() {
    let edit = EditModel()
    // Two sliders dragged at once (iPad): adjusting until both are let go.
    edit.adjusting(true)
    edit.adjusting(true)
    edit.adjusting(false)
    #expect(edit.isAdjusting)
    edit.adjusting(false)
    edit.adjusting(false)
    #expect(!edit.isAdjusting && edit.adjustingCount == 0)
    // A slider's change (dragged or by arrow key) isn't final; a toggle's or typed one is.
    edit.sliderChange { edit.options.halation.amount = 0.37 }
    #expect(!edit.lastChangeIsFinal)
    edit.options.vignette.amount = 0.21
    #expect(edit.lastChangeIsFinal)
    // A slider change that snaps to no change leaves the next change as it is.
    edit.sliderChange { edit.options.halation.amount = 0.37 }
    edit.options.vignette.amount = 0.33
    #expect(edit.lastChangeIsFinal)
  }

  // MARK: - A pane's two lanes

  @MainActor private func paneKey(_ window: EditPipeline.Window?, _ look: Int) -> EditPaneRenders.Loop.Key {
    var options = EditOptions.grainDefaults
    options.grain.seed = look
    return .init(target: .init(source: ObjectIdentifier(NSObject.self), width: window == nil ? 100 : 0, height: 100, window: window), look: .init(options: options, context: 0))
  }

  /// Renders that wait for `finish(name)`, giving 1×1 images.
  @MainActor final class FakeImages {
    private(set) var started: [String] = []
    private var waiting: [String: CheckedContinuation<CGImage, any Error>] = [:]
    var inFlight: Set<String> { Set(waiting.keys) }

    func render(_ name: String) -> EditPaneRenders.Loop.Render {
      { [self] in try await self.run(name) }
    }

    private func run(_ name: String) async throws -> CGImage {
      started.append(name)
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { waiting[name] = $0 }
      } onCancel: {
        Task { @MainActor in self.waiting.removeValue(forKey: name)?.resume(throwing: CancellationError()) }
      }
    }

    func finish(_ name: String) {
      let image = ColorMatch.cgImage(rgba: [0, 0, 0, 255], width: 1, height: 1)!
      waiting.removeValue(forKey: name)?.resume(returning: image)
    }
  }

  @Test @MainActor func zoomedInTheWindowGoesFirst() async {
    let renders = EditPaneRenders(), fake = FakeImages()
    let window = EditPipeline.Window(x: 0, y: 0, width: 50, height: 50, scale: 1)
    func update(_ look: Int, zoomed: Bool = true, settled: Bool = false) {
      renders.update(
        fitted: (paneKey(nil, look), fake.render("fitted/\(look)")),
        window: zoomed ? (paneKey(window, look), fake.render("window/\(look)")) : nil, settled: settled)
    }
    update(0)
    await until { !fake.inFlight.isEmpty }
    // The fitted preview waits while the window renders, busy all the same.
    #expect(fake.started == ["window/0"] && renders.fitted.isBusy && renders.window.isBusy)
    update(1)
    fake.finish("window/0")
    // The window catches up before the fitted preview starts.
    await until { fake.started.count == 2 }
    #expect(fake.started == ["window/0", "window/1"])
    fake.finish("window/1")
    await until { fake.started.count == 3 }
    #expect(fake.started.last == "fitted/1" && !renders.window.isBusy)
    // A new look while the fitted preview renders: the window starts at once beside it; the
    // fitted lane waits for the window again before the newest.
    update(2)
    await until { fake.started.count == 4 }
    #expect(fake.started.last == "window/2")
    fake.finish("fitted/1")
    try? await Task.sleep(for: .milliseconds(20))
    #expect(fake.started.count == 4 && renders.fitted.isBusy)
    fake.finish("window/2")
    await until { fake.started.count == 5 }
    #expect(fake.started.last == "fitted/2")
    // Zoomed out: the window lane stops, the fitted one goes on.
    update(2, zoomed: false)
    #expect(!renders.window.isBusy)
    fake.finish("fitted/2")
    await until { !renders.fitted.isBusy }
    #expect(renders.fitted.shown?.key == paneKey(nil, 2) && renders.window.shown?.key == paneKey(window, 2))
    // The pane going away leaves both lanes idle.
    update(3)
    await until { !fake.inFlight.isEmpty }
    renders.cancel()
    #expect(!renders.fitted.isBusy && !renders.window.isBusy)
  }

  @Test @MainActor func aMovedWindowStopsTheOldWindowsRender() async {
    let renders = EditPaneRenders(), fake = FakeImages()
    let left = EditPipeline.Window(x: 0, y: 0, width: 50, height: 50, scale: 1)
    let right = EditPipeline.Window(x: 64, y: 0, width: 50, height: 50, scale: 1)
    renders.update(fitted: (paneKey(nil, 0), fake.render("fitted")), window: (paneKey(left, 0), fake.render("left")), settled: false)
    await until { fake.inFlight == ["left"] }
    renders.update(fitted: (paneKey(nil, 0), fake.render("fitted")), window: (paneKey(right, 0), fake.render("right")), settled: false)
    await until { fake.inFlight == ["right"] }
    #expect(fake.started == ["left", "right"])
    fake.finish("right")
    await until { fake.inFlight == ["fitted"] }
    fake.finish("fitted")
    await until { !renders.fitted.isBusy && !renders.window.isBusy }
    #expect(renders.window.shown?.key.target.window == right && renders.window.deliveries == 1)
  }
}
