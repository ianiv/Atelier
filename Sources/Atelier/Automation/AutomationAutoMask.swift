#if os(macOS)
import SwiftUI

extension Automation {
  /// Auto masking through `CreateModel`'s entry points, on an image placed on the canvas (use a
  /// scratch `--project`; nothing is generated or saved):
  ///   Vision (`--subject`, or without `--sam`): the subject under the first point (else the
  ///     image's center) and every subject: the mask isn't empty and holds the click.
  ///   SAM 2.1 (`--sam`, downloading `--size` through the app's own download when it's missing):
  ///     the mask holds the positive point; the same prompt again skips the encoder; a negative
  ///     point inside the selection (a second `--point`, else pixels deep inside it, far from
  ///     the first in each of eight directions, until one does) takes at least a fifth of it away; Subtract after Add gives back the mask before;
  ///     Replace is one undo step; `--box` selects inside the box; and the Select tool's own
  ///     history: commit a selection, change a setting, add two points, then undo ×3 and redo ×3
  ///     through them in order (each undo of a point selecting again, its preview the same as a
  ///     fresh selection of those points), and undoing the commit brings back both the mask and
  ///     its points. Prints encoder and decoder timing.
  /// Points and box are in the input's pixels. `--snapshot-dir` saves the mask over the image
  /// after each part. Prints PASS/FAIL lines.
  ///
  /// `--model` picks an image model first when the selected one is a video model (masks are for
  /// image models).
  ///
  ///   Atelier --automask-check --project NAME --input FILE [--point x,y]… [--box x,y,w,h]
  ///           [--subject] [--sam] [--size tiny|small|large] [--model M] [--snapshot-dir DIR] [--quit]
  static func autoMaskCheck(_ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    func numbers(_ text: String) -> [Double] { text.split(separator: ",").compactMap { Double($0) } }
    let points = args.indices.filter { args[$0] == "--point" && $0 + 1 < args.count }
      .map { numbers(args[$0 + 1]) }.filter { $0.count == 2 }.map { CGPoint(x: $0[0], y: $0[1]) }
    let box = value("--box").map(numbers).flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
    let usesSAM = args.contains("--sam")
    let usesSubject = args.contains("--subject") || !usesSAM
    let size = value("--size").flatMap(SAMFiles.Size.init(rawValue:)) ?? .small
    let snapshots = value("--snapshot-dir").map { URL(fileURLWithPath: $0) }
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      func note(_ message: String) {
        print(message)
        fflush(stdout)
      }
      @MainActor func finish() {
        print(failures == 0 ? "automask check: all passed" : "automask check: \(failures) failed")
        fflush(stdout)
        if args.contains("--quit") { AppLifecycle.quit() }
      }
      func ms(_ duration: Duration?) -> String {
        guard let duration else { return "skipped" }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.0f ms", seconds * 1000)
      }
      @MainActor func painted(at point: CGPoint) -> Bool {
        guard let image = model.image, let mask = model.canvasMask else { return false }
        let x = Int(point.x), y = Int(point.y)
        guard (0..<image.width).contains(x), (0..<image.height).contains(y) else { return false }
        // One row is enough: the coverage is drawn for the whole image, then read at the point.
        return mask.coverage(width: image.width, height: image.height)[y * image.width + x] != 0
      }
      @MainActor func paintedPixels() -> Int { model.canvasMaskStats?.paintedPixels ?? 0 }
      @MainActor func snapshot(_ name: String) {
        guard let snapshots, let overlay = model.canvasMaskOverlay(), let png = ImageTensor.png(overlay) else { return }
        try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try? png.write(to: snapshots.appending(path: "automask-\(name).png"))
      }

      while !model.history.isLoaded || model.models.isEmpty || model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let path = value("--input"), let input = ImageLoader.image(at: URL(fileURLWithPath: path)) else {
        check(false, "--input FILE is required and must be readable")
        return finish()
      }
      if let file = value("--model") {
        model.selectedModel = file
        try? await Task.sleep(for: .milliseconds(200))
        while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
      }
      model.layout = nil
      model.placeOnCanvas(input)
      model.canvasTool = .select
      guard model.canPaintMask else {
        check(false, "the mask can be painted (Edit mode, an image model on this device; model \(model.selectedModel ?? "none"))")
        return finish()
      }
      let center = CGPoint(x: Double(input.width) / 2, y: Double(input.height) / 2)
      let click = points.first ?? center
      note("input \(input.width)×\(input.height), click \(Int(click.x)),\(Int(click.y))")

      if usesSubject {
        model.clearMask(undoManager: nil)
        do {
          let outcome = try await model.autoMaskSubject(at: click, mode: .replace, undoManager: nil)
          check(outcome.selectedPixels > 0 && paintedPixels() > 0, "subject: the mask isn't empty (\(paintedPixels()) px) in \(ms(outcome.decodeTime))")
          check(painted(at: click), "subject: the mask holds the click")
          snapshot("subject")
        } catch {
          check(false, "subject under the click: \(error.localizedDescription)")
        }
        do {
          model.clearMask(undoManager: nil)
          let outcome = try await model.autoMaskSubject(mode: .add, undoManager: nil)
          check(outcome.selectedPixels > 0, "subject: every subject selects something (\(outcome.selectedPixels) px)")
        } catch {
          check(false, "every subject: \(error.localizedDescription)")
        }
      }

      if usesSAM {
        if SAMFiles.installed(size) == nil {
          guard let folder = SAMFiles.downloadFolder else {
            check(false, "SAM 2.1 \(size.title) isn't installed and no models folder can take a download")
            return finish()
          }
          note("downloading SAM 2.1 \(size.title) into \(SAMFiles.folder(size, in: folder).path)…")
          let progress = Task { @MainActor in
            var last = -1
            while !Task.isCancelled {
              let percent = Int(SAMDownload.shared.fraction * 100)
              if percent / 10 != last / 10 {
                note("  \(percent)%")
                last = percent
              }
              try? await Task.sleep(for: .milliseconds(500))
            }
          }
          do {
            try await SAMDownload.shared.download(size)
          } catch {
            progress.cancel()
            check(false, "SAM 2.1 \(size.title) downloads: \(error.localizedDescription)")
            return finish()
          }
          progress.cancel()
        }
        check(SAMFiles.installed(size) != nil, "SAM 2.1 \(size.title) is installed")
        model.autoMask.size = size
        model.clearMask(undoManager: nil)
        let positive = SAMSegmenter.Point(location: click, positive: true)
        do {
          let first = try await model.autoMask(points: [positive], mode: .replace, undoManager: nil)
          let whole = paintedPixels()
          check(whole > 0 && painted(at: click), "sam: the mask holds the positive point (\(whole) px, score \(String(format: "%.2f", first.score ?? 0)))")
          note("sam timing, first click: encoder \(ms(first.encodeTime)), decoder \(ms(first.decodeTime)) (first runs warm up the GPU; loading not counted)")
          snapshot("sam-point")
          let again = try await model.autoMask(points: [positive], mode: .replace, undoManager: nil)
          check(again.encodeTime == nil && paintedPixels() == whole, "sam: the same image again skips the encoder (decoder \(ms(again.decodeTime)))")

          // A negative point inside the selection takes a clear part of it away. With a second
          // --point: both points selected, then the second marked to leave out instead (SAM keeps
          // a box's whole content however it's marked inside, so the box isn't used here).
          // Without: the click's selection, then left out a pixel deep inside it (a third of the
          // deepest's distance from the edge or more), as far from the click as it goes: the
          // farthest in each of eight directions, tried nearest-last until one carves a part away.
          // A pixel farthest from the click alone lands on a thin tip (a teapot's spout), and one
          // in the middle of a single part takes nothing away, so neither proves anything.
          var base = [positive]
          let second = points.dropFirst().first
          if let second { base.append(SAMSegmenter.Point(location: second, positive: true)) }
          _ = try await model.autoMask(points: base, mode: .replace, undoManager: nil)
          if second != nil { base.removeLast() }
          let selected = paintedPixels()
          var candidates = second.map { [$0] } ?? []
          if second == nil, let selection = model.canvasMask?.coverage(width: input.width, height: input.height) {
            let edge = Self.edgeDistance(selection, width: input.width, height: input.height)
            let depth = (edge.max() ?? 0) / 3
            var farthest = [(distance: Double, point: CGPoint)?](repeating: nil, count: 8)
            for y in stride(from: 0, to: input.height, by: 2) {
              for x in stride(from: 0, to: input.width, by: 2) where depth > 0 && edge[y * input.width + x] >= depth {
                let dx = Double(x) - click.x, dy = Double(y) - click.y
                let distance = hypot(dx, dy)
                let sector = (Int(((atan2(dy, dx) + .pi) / (2 * .pi) * 8).rounded(.down)) % 8 + 8) % 8
                if distance > farthest[sector]?.distance ?? 0 { farthest[sector] = (distance, CGPoint(x: x, y: y)) }
              }
            }
            candidates = farthest.compactMap(\.self).sorted { $0.distance > $1.distance }.map(\.point)
          }
          var report = "no point deep inside the selection"
          var carved = false
          for (index, negative) in candidates.enumerated() {
            let wasSelected = painted(at: negative)
            let shrunk = try await model.autoMask(
              points: base + [SAMSegmenter.Point(location: negative, positive: false)], mode: .replace, undoManager: nil)
            let after = paintedPixels()
            carved = wasSelected && !painted(at: negative) && Double(after) < Double(selected) * 0.8
            report =
              "at \(Int(negative.x)),\(Int(negative.y)) (try \(index + 1) of \(candidates.count)): \(selected) → \(after) px, \(Int((1 - Double(after) / Double(max(selected, 1))) * 100))% less, decoder \(ms(shrunk.decodeTime))"
            if carved { break }
          }
          check(carved, "sam: a negative point inside the selection takes at least a fifth of it away (\(report))")
          snapshot("sam-negative")

          // Subtract after Add gives back what was there: a rectangle away from the selection.
          model.clearMask(undoManager: nil)
          _ = try await model.autoMask(points: [positive], mode: .replace, undoManager: nil)
          let selectionBounds = model.canvasMaskStats?.bounds ?? .zero
          let side = Double(min(input.width, input.height)) / 8
          let corners = [
            CGRect(x: 0, y: 0, width: side, height: side),
            CGRect(x: Double(input.width) - side, y: 0, width: side, height: side),
            CGRect(x: 0, y: Double(input.height) - side, width: side, height: side),
            CGRect(x: Double(input.width) - side, y: Double(input.height) - side, width: side, height: side),
          ]
          if let corner = corners.first(where: { !$0.intersects(selectionBounds) }) {
            model.clearMask(undoManager: nil)
            model.addMaskStrokes([.rect(corner)], undoManager: nil)
            let before = model.canvasMask?.coverage(width: input.width, height: input.height)
            _ = try await model.autoMask(points: [positive], mode: .add, undoManager: nil)
            let added = paintedPixels()
            _ = try await model.autoMask(points: [positive], mode: .subtract, undoManager: nil)
            let after = model.canvasMask?.coverage(width: input.width, height: input.height)
            check(after == before && added > paintedPixels(), "sam: Subtract after Add gives back the mask before (\(added) → \(paintedPixels()) px)")
          } else {
            note("sam: the selection reaches every corner; Subtract after Add not checked")
          }

          // Replace is one undo step.
          let undo = UndoManager()
          undo.groupsByEvent = false
          model.clearMask(undoManager: nil)
          model.addMaskStrokes([.rect(corners[0])], undoManager: nil)
          let previous = model.canvasMask
          undo.beginUndoGrouping()
          _ = try await model.autoMask(points: [positive], mode: .replace, undoManager: undo)
          undo.endUndoGrouping()
          let replaced = model.canvasMask
          undo.undo()
          check(replaced != previous && model.canvasMask == previous, "sam: Replace undoes in one step")

          // The Select tool's steps in the one history, among a setting's.
          do {
            model.clearMask(undoManager: nil)
            model.autoMask.clearPoints(model: model, undoManager: nil)
            let history = UndoManager()
            history.groupsByEvent = false
            /// One user action: its own undo group, as an event gives it.
            @MainActor func act(_ body: () -> Void) async {
              history.beginUndoGrouping()
              body()
              history.endUndoGrouping()
              try? await Task.sleep(for: .milliseconds(20))
              while model.autoMask.isBusy { try? await Task.sleep(for: .milliseconds(50)) }
            }
            @MainActor func step(_ body: () -> Void) async {
              body()
              try? await Task.sleep(for: .milliseconds(20))
              while model.autoMask.isBusy { try? await Task.sleep(for: .milliseconds(50)) }
            }
            /// The preview is SAM's selection of the points shown (no older run's).
            @MainActor func previewMatches() async -> Bool {
              let session = model.autoMask
              guard !session.points.isEmpty else { return session.preview == nil }
              guard let preview = session.preview,
                    let fresh = try? await model.samSelection(SAMSegmenter.Prompt(points: session.points, box: session.box), size: size)
              else { return false }
              return preview.coverage == fresh.selection.coverage
            }
            let p2 = SAMSegmenter.Point(location: CGPoint(x: click.x + 6, y: click.y + 6), positive: true)
            let p3 = SAMSegmenter.Point(location: CGPoint(x: click.x - 6, y: click.y - 6), positive: false)
            await act { model.autoMask.addPoint(click, positive: true, model: model, undoManager: history) }
            check(history.undoActionName == "Add Point" && model.autoMask.preview != nil, "history: a click is an “Add Point” step (\(history.undoActionName))")
            await act { model.commitAutoMaskPreview(mode: .add, undoManager: history) }
            let committed = model.canvasMask
            check(
              committed != nil && model.autoMask.points.isEmpty && history.undoActionName == "Add Selection",
              "history: Add commits the selection and clears the points, one “Add Selection” step")
            let stepsBefore = model.settings?.steps ?? 0
            await act {
              if let steps = SettingsRegistry.byID["steps"] { model.set(steps, to: .number(Double(stepsBefore + 3)), undoManager: history) }
            }
            check(model.settings?.steps == stepsBefore + 3, "history: a setting changes (\(history.undoActionName))")
            await act { model.autoMask.addPoint(p2.location, positive: true, model: model, undoManager: history) }
            // The second point right after the first, before its preview comes: the newer run wins.
            history.beginUndoGrouping()
            model.autoMask.addPoint(p3.location, positive: false, model: model, undoManager: history)
            history.endUndoGrouping()
            await step {}
            var matches = await previewMatches()
            check(
              model.autoMask.points == [p2, p3] && history.undoActionName == "Exclude Point" && matches,
              "history: two more points, the second an “Exclude Point” step; the preview is theirs")
            await step { history.undo() }
            matches = await previewMatches()
            check(model.autoMask.points == [p2] && matches, "history: undo 1 takes the second point away and selects again")
            await step { history.undo() }
            check(model.autoMask.points.isEmpty && model.autoMask.preview == nil && model.canvasMask == committed, "history: undo 2 takes the first point away")
            await step { history.undo() }
            check(model.settings?.steps == stepsBefore && model.canvasMask == committed, "history: undo 3 puts the setting back, the mask unchanged")
            await step { history.redo() }
            check(model.settings?.steps == stepsBefore + 3, "history: redo 1 changes the setting again")
            await step { history.redo() }
            matches = await previewMatches()
            check(model.autoMask.points == [p2] && matches, "history: redo 2 adds the first point again")
            await step { history.redo() }
            matches = await previewMatches()
            check(model.autoMask.points == [p2, p3] && matches && !history.canRedo, "history: redo 3 adds the second, and that's the end")
            // Back past the setting to the commit: undoing it brings back the mask and its points.
            for _ in 0..<3 { await step { history.undo() } }
            check(history.undoActionName == "Add Selection", "history: next to undo is the commit (\(history.undoActionName))")
            await step { history.undo() }
            matches = await previewMatches()
            check(
              model.canvasMask == nil && model.autoMask.points == [SAMSegmenter.Point(location: click, positive: true)] && matches,
              "history: undoing the commit takes the selection out of the mask and puts its point back")
            await step { history.redo() }
            check(model.canvasMask == committed && model.autoMask.points.isEmpty, "history: redoing it commits it again")
            // Another SAM size starts the selection over, as one step that puts both back.
            let otherSize: SAMFiles.Size = size == .tiny ? .small : .tiny
            await act { model.autoMask.addPoint(click, positive: true, model: model, undoManager: history) }
            await act { model.autoMask.setSize(otherSize, model: model, undoManager: history) }
            check(
              model.autoMask.size == otherSize && model.autoMask.points.isEmpty && history.undoActionName == "Change SAM Size",
              "history: a size change clears the points, one “Change SAM Size” step")
            await step { history.undo() }
            matches = await previewMatches()
            check(model.autoMask.size == size && model.autoMask.points.count == 1 && matches, "history: undoing it brings back the size and the point, selected again")
            await step { history.redo() }
            check(model.autoMask.size == otherSize && model.autoMask.points.isEmpty, "history: redoing it changes the size again")
            await step { history.undo() }
            check(model.autoMask.size == size && model.autoMask.points.count == 1, "history: and undoing again puts it back")
            // Generate with a selection not yet in the mask adds it first, as Add does. Then,
            // under that run's preview, undoing the add brings the points back and the selection
            // waits for the image (no error), rather than failing.
            if var settings = model.settings {
              settings.steps = 2
              settings.width = 512
              settings.height = 512
              model.settings = settings
              model.canvasMode = .edit
              @MainActor func runningMask() -> Bool { model.queue.running?.request?.mask != nil }
              // A selection still being worked out is waited for.
              model.clearMask(undoManager: nil)
              model.autoMask.clearPoints(model: model, undoManager: nil)
              history.beginUndoGrouping()
              model.autoMask.addPoint(click, positive: true, model: model, undoManager: history)
              history.endUndoGrouping()
              let decoding = model.autoMask.isBusy
              model.generate(undoManager: history)
              let addedAtOnce = model.canvasMask != nil
              for _ in 0..<1500 where model.canvasMask == nil || !model.isBusy {
                try? await Task.sleep(for: .milliseconds(20))
              }
              check(
                decoding && !addedAtOnce && model.canvasMask != nil && runningMask() && history.undoActionName == "Add Selection"
                  && model.autoMask.points.isEmpty,
                "generate: a selection still decoding is awaited, then added to the mask (“\(history.undoActionName)”), and the run carries it")
              while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
              check(model.canEditMask && model.canvasUndoImage === model.image, "generate: once the result lands, it's the image mask steps go on")

              // A selection ready: added at once, the run carries the mask.
              let second = SAMSegmenter.Point(location: CGPoint(x: click.x + 6, y: click.y + 6), positive: true)
              model.clearMask(undoManager: nil)
              model.autoMask.clearPoints(model: model, undoManager: nil)
              await act { model.autoMask.addPoint(click, positive: true, model: model, undoManager: history) }
              await act { model.autoMask.addPoint(second.location, positive: true, model: model, undoManager: history) }
              let request = model.screenRequest()
              check(request?.mask == nil, "generate: before it, the selection isn't in the mask a run would take")
              model.generate(undoManager: history)
              check(
                model.canvasMask != nil && history.undoActionName == "Add Selection" && model.autoMask.points.isEmpty
                  && (runningMask() || model.queue.waiting.last?.request?.mask != nil),
                "generate: a ready selection is added first, one “Add Selection” step, and the queued run carries the mask")
              var covered = false
              for _ in 0..<3000 where model.isBusy {
                if !model.canvasShowsImage, model.canvasUndoImage != nil {
                  covered = true
                  break
                }
                try? await Task.sleep(for: .milliseconds(5))
              }
              if covered, !model.canvasShowsImage, model.isBusy {
                history.undo()
                let session = model.autoMask
                check(
                  session.points == [SAMSegmenter.Point(location: click, positive: true), second] && session.selectionWaits
                    && session.failure == nil && session.preview == nil && model.canvasMask == nil,
                  "history: undoing the add under the run's preview takes it out and brings the points back, selecting once the image shows (points \(session.points.count), waits \(session.selectionWaits), failure \(session.failure ?? "none"))")
              } else {
                print("SKIP history: no run preview covered the canvas to undo under")
              }
              while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            }
            // A step on an image that's gone leaves the history and never reaches another image.
            await act { model.autoMask.addPoint(click, positive: true, model: model, undoManager: history) }
            await act { model.addMaskStrokes([.rect(corners[0])], actionName: "Brush Stroke", undoManager: history) }
            let other = CanvasMask(rects: [corners[3]])
            // Another image (a copy: placing the very same image object again would be the same
            // image to the Select tool).
            if let copy = input.copy() { model.placeOnCanvas(copy) }
            // The Select tool follows the canvas image as the view updates.
            model.autoMask.follow(model.image)
            model.setMask(other, actionName: "Brush Stroke", undoManager: nil)
            let undoable = history.canUndo
            await step { if history.canUndo { history.undo() } }
            check(
              !undoable && model.canvasMask == other && model.autoMask.points.isEmpty,
              "history: after another image goes on the canvas, the old image's steps are gone, so ⌘Z can't reach the new one (undoable \(undoable), mask \(model.canvasMask == other ? "kept" : "changed"), points \(model.autoMask.points.count))")
            model.clearMask(undoManager: nil)
          }

          if let box {
            model.clearMask(undoManager: nil)
            let boxed = try await model.autoMask(points: [], box: box, mode: .replace, undoManager: nil)
            let bounds = model.canvasMaskStats?.bounds
            check(
              boxed.selectedPixels > 0 && bounds.map { box.insetBy(dx: -16, dy: -16).contains($0) } == true,
              "sam: a box selects inside it (bounds \(bounds.map { "\($0)" } ?? "none"), decoder \(ms(boxed.decodeTime)))")
            snapshot("sam-box")
          }
        } catch {
          check(false, "sam: \(error.localizedDescription)")
        }
      }
      model.clearMask(undoManager: nil)
      // The Select tool as it looks with a preview, for the eye.
      if let snapshots {
        navigation.section = .create
        ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
        if usesSAM {
          model.autoMask.addPoint(click, positive: true, model: model)
        } else {
          model.autoMask.selectSubject(at: click, model: model)
        }
        while model.autoMask.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(500))
        Automation.snapshot(to: snapshots.appending(path: "automask-window.png"))
        note("window snapshot: \(FileManager.default.fileExists(atPath: snapshots.appending(path: "automask-window.png").path) ? "saved" : "no window (window \(AutomationWindows.mainWindowNumber))")")
        model.autoMask.clearPoints(model: model, undoManager: nil)
      }
      finish()
    }
  }

  /// Each pixel's distance in pixels to the nearest unselected one (or the image's edge), by a
  /// two-pass chamfer transform (3-4 weights, divided by 3): 0 outside the selection.
  static func edgeDistance(_ selection: [UInt8], width: Int, height: Int) -> [Double] {
    let far = Int.max / 4
    var d = selection.map { $0 != 0 ? far : 0 }
    func at(_ x: Int, _ y: Int) -> Int { x < 0 || y < 0 || x >= width || y >= height ? 0 : d[y * width + x] }
    for y in 0..<height {
      for x in 0..<width where d[y * width + x] != 0 {
        d[y * width + x] = min(d[y * width + x], at(x - 1, y) + 3, at(x, y - 1) + 3, at(x - 1, y - 1) + 4, at(x + 1, y - 1) + 4)
      }
    }
    for y in stride(from: height - 1, through: 0, by: -1) {
      for x in stride(from: width - 1, through: 0, by: -1) where d[y * width + x] != 0 {
        d[y * width + x] = min(d[y * width + x], at(x + 1, y) + 3, at(x, y + 1) + 3, at(x + 1, y + 1) + 4, at(x - 1, y + 1) + 4)
      }
    }
    return d.map { Double($0) / 3 }
  }
}
#endif
