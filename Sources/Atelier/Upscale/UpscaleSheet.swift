import SwiftUI

/// Upscale… on a clip in History: pick SeedVR2 (Quality) or Apple Super Resolution (Fast) and a
/// scale, then queue it. The result is a new clip after the source.
struct UpscaleSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  var item: HistoryItem
  @AppStorage("upscaleMethod") private var method = ClipUpscale.Method.seedVR2
  @AppStorage("upscaleScale") private var scale = 2
  @AppStorage("upscaleSeedVR2Model") private var seedVR2 = ""

  var body: some View {
    let sidecar = item.sidecar
    let controls = UpscaleControls(
      width: sidecar.width, height: sidecar.height, method: $method, scale: $scale,
      seedVR2: $seedVR2)
    VStack(alignment: .leading, spacing: 12) {
      Text("Upscale Video").font(.headline)
      controls
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Upscale") {
          let item = item, method = method, scale = scale, seedVR2 = seedVR2
          Task { await create.upscale(item, method: method, scale: scale, seedVR2: seedVR2) }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(controls.problem(models: create.models.map(\.file)) != nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 320)
  }
}

/// Export Upscaled Video… on a timeline: the same choices, for the whole timeline at its size,
/// with roughly how long it will take.
struct TimelineUpscaleSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  let width: Int
  let height: Int
  let frameCount: Int
  let export: (TimelineUpscale) -> Void
  @AppStorage("timelineUpscaleMethod") private var method = ClipUpscale.Method.system
  @AppStorage("timelineUpscaleScale") private var scale = 4
  @AppStorage("upscaleSeedVR2Model") private var seedVR2 = ""

  var body: some View {
    let controls = UpscaleControls(
      width: width, height: height, method: $method, scale: $scale, seedVR2: $seedVR2)
    let upscale = TimelineUpscale(method: method, scale: scale, seedVR2: seedVR2)
    let problem = controls.problem(models: create.models.map(\.file))
    VStack(alignment: .leading, spacing: 12) {
      Text("Export Upscaled Video").font(.headline)
      controls
      LabeledContent(
        "Takes about",
        value: problem == nil
          ? Self.duration(upscale.estimatedSeconds(frames: frameCount, width: width, height: height))
          : "—")
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Export") {
          dismiss()
          export(upscale)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(problem != nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 350)
  }

  private static func duration(_ seconds: Double) -> String {
    Duration.seconds(max(seconds, 60).rounded(.up))
      .formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
  }
}

/// Method, SeedVR2 model and scale for upscaling a `width`×`height` video, with the size it
/// makes and why it can't, if it can't. Every control stays; ones that don't apply are disabled.
struct UpscaleControls: View {
  @Environment(CreateModel.self) private var create
  let width: Int
  let height: Int
  @Binding var method: ClipUpscale.Method
  @Binding var scale: Int
  @Binding var seedVR2: String

  private var seedVR2Models: [(file: String, name: String)] {
    create.models.filter { ClipUpscale.isSeedVR2($0.file) }.map { ($0.file, $0.name) }
  }

  /// The scales the chosen method can do at this size.
  private var scales: [Int] {
    ClipUpscale.offeredScales(width: width, height: height, method: method)
  }

  /// Why it can't upscale with these choices (and the `models` downloaded); nil when it can.
  func problem(models: [String]) -> String? {
    if method == .seedVR2, !models.contains(where: ClipUpscale.isSeedVR2) {
      return "Download a SeedVR2 model in Models to use Quality."
    }
    return ClipUpscale.problem(width: width, height: height, scale: scale, method: method)
  }

  var body: some View {
    let size = ClipUpscale.outputSize(width: width, height: height, scale: scale, method: method)
    Group {
      Picker("Method", selection: $method) {
        Text("Quality").tag(ClipUpscale.Method.seedVR2)
        Text("Fast").tag(ClipUpscale.Method.system)
      }
      .pickerStyle(.segmented)
      Text(
        method == .seedVR2
          ? "SeedVR2 restores detail across many frames at once. It takes a while and a lot of memory."
          : "Apple Super Resolution runs on the Neural Engine in seconds. macOS downloads its model the first time."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Picker("Model", selection: $seedVR2) {
        ForEach(seedVR2Models, id: \.file) { Text($0.name).tag($0.file) }
      }
      .disabled(method != .seedVR2 || seedVR2Models.isEmpty)
      Picker("Scale", selection: $scale) {
        ForEach(scales.isEmpty ? ClipUpscale.scales : scales, id: \.self) {
          Text("\($0)×").tag($0)
        }
      }
      .pickerStyle(.segmented)
      .disabled(scales.isEmpty)
      LabeledContent("Size", value: "\(width) × \(height) → \(size.width) × \(size.height)")
      if let problem = problem(models: create.models.map(\.file)) {
        Text(problem).font(.caption).foregroundStyle(.secondary)
      }
    }
    // On each control, which is harmless: the first sets things right.
    .onAppear {
      // The model last used, or the largest SeedVR2 downloaded (7B sorts after 3B).
      if !seedVR2Models.contains(where: { $0.file == seedVR2 }) {
        seedVR2 = seedVR2Models.map(\.file).sorted().last ?? ""
      }
      offerScale()
    }
    .onChange(of: method) { offerScale() }
  }

  /// Keeps the scale to one the method offers at this size.
  private func offerScale() {
    if let first = scales.first, !scales.contains(scale) { scale = first }
  }
}
