#if os(macOS)
import CoreGraphics
import Foundation

extension Automation {
  /// Checks the Edit screen end to end (Slice J fills it).
  ///
  ///   Atelier --edit-screen-check --show edit --project NAME [--snapshot-dir DIR] [--quit]
  ///
  /// For now only `--snapshot-dir`: opens a made-up test image on the Edit screen and saves the
  /// window in each comparison mode (`edit-<mode>.png`), for checking the layout by eye.
  static func editScreenCheck(_: CreateModel) {
    let args = CommandLine.arguments
    let snapshotDir = args.firstIndex(of: "--snapshot-dir").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    Task { @MainActor in
      if let snapshotDir, let edit = editModel, let image = testImage(width: 1600, height: 1200) {
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        snapshot(to: snapshotDir.appendingPathComponent("edit-empty.png"))
        edit.open(image: image, name: "Test Image")
        var look = EditOptions.grainDefaults
        look.grade.temperature = 30
        look.vignette.amount = 0.4
        edit.options = look
        for mode in Compare.Mode.allCases {
          edit.compareMode = mode
          try? await Task.sleep(for: .seconds(2))
          snapshot(to: snapshotDir.appendingPathComponent("edit-\(mode.rawValue).png"))
        }
        edit.compareMode = .hold
        edit.canvas.zoom(to: 2)
        try? await Task.sleep(for: .seconds(2))
        snapshot(to: snapshotDir.appendingPathComponent("edit-zoom200.png"))
        print("snapshots in \(snapshotDir.path)")
        // Add to History and Save, then open the saved step again.
        let model = edit.create
        var waited = 0
        while model?.settings == nil || model?.history.isLoaded != true, waited < 600 {
          try? await Task.sleep(for: .milliseconds(100))
          waited += 1
        }
        if let model {
          do {
            let id = try await edit.addToHistory()
            while model.queue.recent.first(where: { $0.id == id }) == nil { try? await Task.sleep(for: .milliseconds(100)) }
            let job = model.queue.recent.first { $0.id == id }
            print("save job: \(String(describing: job?.status))")
            if case .finished(let tensorId)? = job?.status, let saved = model.history.item(tensorId: tensorId) {
              print("saved step has record: \(saved.sidecar.edit != nil), size \(saved.sidecar.width)x\(saved.sidecar.height)")
              let source = edit.item?.tensorId
              edit.reset()
              await edit.open(saved)
              print("reopened as source: \(edit.item?.tensorId == source), options back: \(edit.options == look.snapped)")
              print("same edit refused: \(edit.saveProblem ?? "nil")")
              let png = try await edit.exportPNG()
              print("export PNG bytes: \(png.count)")
            }
          } catch {
            print("save failed: \(error.localizedDescription)")
          }
        }
      }
      print("FAIL --edit-screen-check is not implemented yet")
      fflush(stdout)
      if args.contains("--quit") { AppLifecycle.quit() }
    }
  }

  /// A test image with gradients and edges, so grain, colour and zoom all show.
  static func testImage(width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let colors = [CGColor(red: 0.15, green: 0.3, blue: 0.6, alpha: 1), CGColor(red: 0.95, green: 0.75, blue: 0.5, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
      context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 0.95, alpha: 1))
    context.fillEllipse(in: CGRect(x: width / 2, y: height / 2, width: width / 5, height: width / 5))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: width / 8, y: height / 6, width: width / 4, height: height / 3))
    return context.makeImage()
  }
}
#endif
