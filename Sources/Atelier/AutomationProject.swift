import AppKit
import _MediaGenerationKit

extension Automation {
  /// Checks the Draw Things project format end to end on a scratch project, as PASS/FAIL lines:
  /// append, list, settings round trip, image round trip, thumbnails, delete and renumbering.
  ///
  ///   Atelier --project-check [--keep DIR] [--quit]
  ///
  /// With `--keep DIR` the scratch project is left at DIR/Check.sqlite3 for other readers
  /// (DTDB Browser, sqlite3).
  static func projectCheck(_ model: CreateModel) {
    let args = CommandLine.arguments
    let keep = args.firstIndex(of: "--keep").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    Task { @MainActor in
      var failures = 0
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      while model.settings == nil || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let base = model.settings, let modelFile = model.selectedModel else { return }

      let directory = keep.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "atelier-project-check-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("Check.sqlite3")
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
      let project = Project(url: url)

      // Three steps with different settings.
      var variants: [PipelineConfiguration] = [base]
      var second = base
      second.steps = base.steps + 3
      second.shift = base.shift + 0.5
      second.hiresFix = !base.hiresFix
      second.width = 768
      second.height = 512
      variants.append(second)
      var third = base
      third.guidanceScale = base.guidanceScale + 1
      third.loras = [LoRA(file: "example_lora_f16.ckpt", weight: 0.75, mode: .all)]
      third.tiledDecoding = true
      variants.append(third)

      guard let original = gradient(width: 320, height: 192),
        let tensor = ImageTensor.tensor(from: original)
      else {
        check(false, "couldn't build a test image")
        return
      }
      var appended: [HistoryItem] = []
      for (index, settings) in variants.enumerated() {
        var settings = settings
        settings.seed = UInt32(1000 + index)
        do {
          let item = try await project.append(
            tensor: tensor, model: modelFile, prompt: "check prompt \(index) “quoted” ✓",
            negativePrompt: index == 1 ? "blurry" : "", seed: settings.seed,
            settings: JSONValue.fields(of: settings), createdAt: Date(), duration: 1.5 + Double(index))
          appended.append(item)
        } catch {
          check(false, "append \(index): \(error.localizedDescription)")
        }
      }
      check(appended.map(\.id.logicalTime) == [0, 1, 2], "appended steps 0, 1, 2 on lineage 0")

      let items = project.items()
      check(items.map(\.id.logicalTime) == [2, 1, 0], "items lists the main line newest first")
      for (index, settings) in variants.enumerated() {
        guard let item = items.first(where: { $0.id.logicalTime == Int64(index) }) else { continue }
        var expected = JSONValue.fields(of: settings)
        expected["seed"] = .number(Double(1000 + index))
        let read = item.sidecar.configuration
        let differing = Set(expected.keys).union(read.keys).filter { expected[$0] != read[$0] }
          .sorted()
        check(differing.isEmpty, "step \(index): every configuration field round-trips \(differing.map { "\($0): \(expected[$0].map { "\($0)" } ?? "missing") → \(read[$0].map { "\($0)" } ?? "missing")" })")
        var restored = base
        SettingsRegistry.apply(dump: read, to: &restored)
        let registry = SettingsRegistry.all.filter { $0.get(restored) != $0.get(settings) }.map(\.id)
        check(registry.isEmpty, "step \(index): Use settings restores all registry fields \(registry)")
        check(
          item.sidecar.prompt == "check prompt \(index) “quoted” ✓"
            && item.sidecar.negativePrompt == (index == 1 ? "blurry" : "")
            && item.sidecar.seed == UInt32(1000 + index) && item.sidecar.model == modelFile,
          "step \(index): prompt, negative prompt, seed and model")
      }

      if let item = items.first, let image = project.image(for: item),
        let difference = pixelDifference(original, image)
      {
        check(difference.maxDelta == 0, "image round trip is exact (max channel delta \(difference.maxDelta))")
      } else {
        check(false, "image round trip: couldn't read the image back")
      }
      if let item = items.first {
        let full = project.thumbnail(previewId: item.previewId, half: false)
        let half = project.thumbnail(previewId: item.previewId, half: true)
        check(
          full?.width == 320 && half.map { $0.width < 320 } == true,
          "thumbnails: full \(full?.width ?? 0)×\(full?.height ?? 0), half \(half?.width ?? 0)×\(half?.height ?? 0)")
      }

      // Delete the middle step: the last one moves down to step 1.
      let middle = items.first { $0.id.logicalTime == 1 }
      if let middle {
        do {
          try await project.delete(middle.id)
          let after = project.items()
          check(after.map(\.id.logicalTime) == [1, 0], "deleting step 1 renumbers step 2 to 1")
          check(
            after.first?.sidecar.seed == 1002 && after.first.flatMap { project.image(for: $0) } != nil,
            "the moved step keeps its settings and image")
          check(
            project.thumbnail(previewId: middle.previewId, half: false) == nil
              && project.tensor(id: middle.tensorId) == nil,
            "the deleted step's thumbnail and tensor are gone")
        } catch {
          check(false, "delete: \(error.localizedDescription)")
        }
      }

      await project.close()
      let reopened = Project(url: url)
      check(reopened.items().count == 2, "a reopened project lists the same steps")
      await reopened.close()
      if keep == nil {
        try? FileManager.default.removeItem(at: directory)
      } else {
        print("kept \(url.path)")
      }
      print(failures == 0 ? "project check: all passed" : "project check: \(failures) failed")
      fflush(stdout)
      if args.contains("--quit") { NSApp.terminate(nil) }
    }
  }

  /// A test image with distinct values in every channel.
  private static func gradient(width: Int, height: Int) -> CGImage? {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        bytes[i] = UInt8(x * 255 / (width - 1))
        bytes[i + 1] = UInt8(y * 255 / (height - 1))
        bytes[i + 2] = UInt8((x * 7 + y * 13) % 256)
      }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}
