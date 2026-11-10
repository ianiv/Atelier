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
  ///     Replace is one undo step; `--box` selects inside the box. Prints encoder and decoder
  ///     timing.
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
          note("downloading SAM 2.1 \(size.title) into \(SAMFiles.folder(size).path)…")
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
        model.autoMask.clearPoints()
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
