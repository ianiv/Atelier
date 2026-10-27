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

  private var seedVR2Models: [(file: String, name: String)] {
    create.models.filter { ClipUpscale.isSeedVR2($0.file) }.map { ($0.file, $0.name) }
  }

  /// The scales the chosen method can do for this clip.
  private var scales: [Int] {
    ClipUpscale.offeredScales(
      width: item.sidecar.width, height: item.sidecar.height, method: method)
  }

  private var problem: String? {
    let sidecar = item.sidecar
    if method == .seedVR2, seedVR2Models.isEmpty {
      return "Download a SeedVR2 model in Models to use Quality."
    }
    return ClipUpscale.problem(
      width: sidecar.width, height: sidecar.height, scale: scale, method: method)
  }

  var body: some View {
    let sidecar = item.sidecar
    let size = ClipUpscale.outputSize(
      width: sidecar.width, height: sidecar.height, scale: scale, method: method)
    VStack(alignment: .leading, spacing: 12) {
      Text("Upscale Video").font(.headline)
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
      LabeledContent("Size", value: "\(sidecar.width) × \(sidecar.height) → \(size.width) × \(size.height)")
      if let problem {
        Text(problem).font(.caption).foregroundStyle(.secondary)
      }
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
        .disabled(problem != nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 320)
    .onAppear {
      // The model last used, or the largest SeedVR2 downloaded (7B sorts after 3B).
      if !seedVR2Models.contains(where: { $0.file == seedVR2 }) {
        seedVR2 = seedVR2Models.map(\.file).sorted().last ?? ""
      }
      offerScale()
    }
    .onChange(of: method) { offerScale() }
  }

  /// Keeps the scale to one the method offers for this clip.
  private func offerScale() {
    if let first = scales.first, !scales.contains(scale) { scale = first }
  }
}
