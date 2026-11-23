#if os(macOS)
import CoreGraphics
import Foundation

extension Automation {
  /// --edit-ui-bench: times the main thread while the real Edit screen is driven, with no model
  /// and nothing written, and prints a line per phase:
  ///
  ///   Atelier --edit-ui-bench [--size WxH | --input FILE] [--ticks N] [--keep-window] [--quit]
  ///
  /// The window fills its screen (a full-screen window's size; `--keep-window` leaves it), the
  /// Edit screen opens the made-up image (`testImage`, `--size` defaults to 6000x4000) or
  /// `--input FILE` as Open Image… does, then another image and the first again (new panes with
  /// the inspector already enabled), and then: Halation (amount), Grade (exposure) and Grain
  /// (strength) are dragged as a slider drags them (a change every 16 ms for N ticks, default
  /// 90, between the slider saying it's pressed and let go) with the preview fitted; Side by Side
  /// is chosen and zoomed to 100% (the first frame zoomed draws the original's side); Halation is
  /// dragged again there; then, in one pane, pinches from fit to
  /// 37%, 50%, 71% and 100% (those past fit) and 1 s of pan at 100% and back, marked as moving as
  /// the pane's gestures mark them; then Heal: a source set and ten strokes (32 px brush, a short
  /// drag each) a second apart, timed from each stroke to its pixels healed in and to the fitted
  /// preview's render done (a line of their own, "heal strokes"), then Clear Heal.
  /// Each line gives the main thread's stalls over 12 ms (how many, their
  /// total and the worst, from a background thread timing a hop to the main queue every
  /// couple of milliseconds, `MainStallMonitor`), how long the phase took to go idle, the renders started and stopped
  /// on their way (`EditRenderCounts`), and the screen's views' body evaluations
  /// (`EditViewCounts`), per tick for a drag. The screen's look, comparison and zoom are put back.
  static func editUIBench(navigation: Navigation) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let size = value("--size").map { $0.lowercased().split(separator: "x").compactMap { Int($0) } }
    let madeWidth = size?.count == 2 ? max(size![0], 16) : 6000
    let madeHeight = size?.count == 2 ? max(size![1], 16) : 4000
    let ticks = max(value("--ticks").flatMap(Int.init) ?? 90, 2)
    let input = value("--input")
    Task { @MainActor in
      func log(_ message: String) {
        print(message)
        fflush(stdout)
      }
      @MainActor func finish() { if args.contains("--quit") { AppLifecycle.quit() } }
      guard let edit = editModel else {
        log("FAIL edit ui bench: the app has no Edit screen model")
        return finish()
      }
      let made = input.map { ImageLoader.image(at: URL(fileURLWithPath: $0)) } ?? testImage(width: madeWidth, height: madeHeight)
      guard let image = made else {
        log("FAIL edit ui bench: " + (input.map { "couldn't read an image at \($0)" } ?? "the test image couldn't be made"))
        return finish()
      }
      let optionsBefore = edit.options, compareBefore = edit.compareMode, sectionBefore = navigation.section
      let frameBefore = AutomationWindows.windowFrame
      navigation.section = .edit
      edit.compareMode = .hold
      var base = EditOptions.grainDefaults
      base.halation.amount = 0.4
      edit.options = base
      try? await Task.sleep(for: .seconds(1))
      let window = args.contains("--keep-window") ? AutomationWindows.setWindowFrame(frameBefore) : AutomationWindows.setWindowFrame(nil)
      guard let window else {
        log("FAIL edit ui bench: no visible window (screen locked?)")
        return finish()
      }
      log("edit ui bench: window \(Int(window.content.width))x\(Int(window.content.height)) pt at \(window.scale)x, "
        + "source \(image.width)x\(image.height)\(input.map { " (\(($0 as NSString).lastPathComponent))" } ?? "")")
      try? await Task.sleep(for: .seconds(1))

      let monitor = MainStallMonitor()
      monitor.start()
      let clock = ContinuousClock()
      func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
      }
      /// Until no pane has rendered for 150 ms (the panes start theirs a frame after a change).
      @MainActor func idle() async {
        let start = clock.now
        var quietSince = clock.now
        try? await Task.sleep(for: .milliseconds(50))
        while clock.now - start < .seconds(30) {
          if edit.isRendering { quietSince = clock.now } else if clock.now - quietSince > .milliseconds(150) { break }
          try? await Task.sleep(for: .milliseconds(5))
        }
      }
      @MainActor func phase(_ name: String, ticks: Int? = nil, _ body: () async -> Void) async {
        await idle()
        _ = monitor.take()
        EditViewCounts.reset()
        EditViewCounts.isOn = true
        let renders = (EditRenderCounts.started, EditRenderCounts.stopped)
        let start = clock.now
        await body()
        await idle()
        let took = milliseconds(clock.now - start) - 150
        EditViewCounts.isOn = false
        let stalls = monitor.take().filter { $0 > 12 }
        let counts = EditViewCounts.counts.sorted { $0.key < $1.key }.map { name, count in
          ticks.map { "\(name) \(String(format: "%.1f", Double(count) / Double($0)))/tick" } ?? "\(name) \(count)"
        }
        let turns = EditViewCounts.turns.sorted { $0.key < $1.key }.map { name, times in
          "\(name) \(times.count)× " + String(format: "avg %.1f ms, worst %.1f ms", times.reduce(0, +) / Double(max(times.count, 1)), times.max() ?? 0)
        }
        log("  \(name.padding(toLength: 26, withPad: " ", startingAt: 0)) stalls>12ms \(stalls.count), "
          + String(format: "total %4.0f ms, worst %4.0f ms; idle after %5.0f ms", stalls.reduce(0, +), stalls.max() ?? 0, took)
          + "; renders \(EditRenderCounts.started - renders.0) started, \(EditRenderCounts.stopped - renders.1) stopped"
          + (counts.isEmpty ? "" : "; bodies: " + counts.joined(separator: ", "))
          + (turns.isEmpty ? "" : "; to the next turn: " + turns.joined(separator: ", ")))
      }
      /// A slider drag: pressed, a change every 16 ms, let go.
      @MainActor func drag(_ vary: (inout EditOptions, Double) -> Void) async {
        edit.adjusting(true)
        let start = clock.now
        for index in 1...ticks {
          try? await Task.sleep(until: start + .milliseconds(16) * index, clock: clock)
          var options = edit.options
          vary(&options, Double(index) / Double(ticks))
          edit.sliderChange { edit.options = options }
        }
        edit.adjusting(false)
      }
      let halation: (inout EditOptions, Double) -> Void = { $0.halation.amount = 0.05 + 0.9 * $1 }

      await phase("open") { edit.open(image: image, name: "Edit UI bench") }
      // Another image with one already open: new panes, but the inspector stays as it is.
      if let another = testImage(width: image.width, height: image.height) {
        await phase("open another") { edit.open(image: another, name: "Edit UI bench 2") }
        await phase("open the first again") { edit.open(image: image, name: "Edit UI bench") }
      }
      await phase("fit Halation drag", ticks: ticks) { await drag(halation) }
      await phase("fit Grade drag", ticks: ticks) { await drag { $0.grade.exposure = -1 + 2 * $1 } }
      await phase("fit Grain drag", ticks: ticks) { await drag { $0.grain.lum = 2 + 28 * $1 } }
      await phase("side by side") { edit.compareMode = .sideBySide }
      await phase("side by side zoom 100%") { edit.canvas.zoom(to: 1) }
      await phase("side by side pan", ticks: 30) {
        let start = clock.now
        for index in 1...30 {
          try? await Task.sleep(until: start + .milliseconds(16) * index, clock: clock)
          edit.canvas.offset.width -= 20
        }
      }
      await phase("side by side 100% Halation", ticks: ticks) { await drag(halation) }
      await phase("fit") { edit.canvas.zoomToFit() }
      // Pinches and a pan in one pane, as the pane's gestures move the view (marked as moving
      // until the gesture ends): fit to 37%, 50%, 71% and 100% (the levels past fit), 12 ticks
      // each, then 1 s of pan at 100%. "idle after" counts from the first tick, so it holds the
      // gesture's 0.2 s (pinch) or 1 s (pan).
      await phase("hold") { edit.compareMode = .hold }
      @MainActor func moving(_ ticks: Int, _ move: (Int) -> Void) async {
        edit.isMovingView = true
        let start = clock.now
        for index in 1...ticks {
          try? await Task.sleep(until: start + .milliseconds(16) * index, clock: clock)
          move(index)
        }
        edit.isMovingView = false
      }
      var from = edit.canvas.fitScale
      for level in [0.37, 0.5, 0.71, 1.0] where level > edit.canvas.fitScale * 1.01 {
        let start = from
        await phase("pinch \(Int((start * 100).rounded()))→\(Int((level * 100).rounded()))%", ticks: 12) {
          await moving(12) { edit.canvas.zoom(to: start * pow(level / start, Double($0) / 12)) }
        }
        from = level
      }
      await phase("pan 1 s at 100%", ticks: 62) { await moving(62) { _ in edit.canvas.offset.width -= 20 } }
      await phase("pan back", ticks: 62) { await moving(62) { _ in edit.canvas.offset.width += 20 } }
      await phase("fit again") { edit.canvas.zoomToFit() }

      // Heal strokes as the pane adds them when a drag ends, on the fitted preview.
      let healBrushBefore = edit.healBrushSize
      edit.tool = .heal
      edit.healBrushSize = 32
      edit.setHealSource(at: CGPoint(x: Double(image.width) * 0.1, y: Double(image.height) * 0.1))
      var healed: [Double] = [], shown: [Double] = []
      await phase("heal 10 strokes", ticks: 10) {
        for index in 0..<10 {
          let x = Double(image.width) * (0.3 + 0.05 * Double(index)), y = Double(image.height) * 0.5
          let start = clock.now
          edit.addHealStroke(points: (0..<5).map { CGPoint(x: x + Double($0) * 10, y: y) }, undoManager: nil)
          await edit.settleHeal()
          healed.append(milliseconds(clock.now - start))
          await idle()
          shown.append(milliseconds(clock.now - start) - 150)
        }
      }
      func summary(_ times: [Double]) -> String {
        String(format: "avg %.0f ms, worst %.0f ms", times.reduce(0, +) / Double(max(times.count, 1)), times.max() ?? 0)
      }
      log("  heal strokes: healed in \(summary(healed)); fitted preview rendered \(summary(shown))")
      await phase("clear heal") { edit.clearHeal(undoManager: nil) }
      edit.tool = .move
      edit.healBrushSize = healBrushBefore
      monitor.stop()

      edit.options = optionsBefore
      edit.compareMode = compareBefore
      edit.canvas.zoomToFit()
      navigation.section = sectionBefore
      if !args.contains("--keep-window") { AutomationWindows.setWindowFrame(frameBefore) }
      log("edit ui bench: done")
      finish()
    }
  }
}

#endif
