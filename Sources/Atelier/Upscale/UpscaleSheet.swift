import SwiftUI

/// Upscale… on a clip in History: pick FlashVSR+ (Quality) or Apple Super Resolution (Fast) and
/// a scale, then queue it. The result is a new clip after the source.
struct UpscaleSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  var item: HistoryItem
  @AppStorage("upscaleMethod") private var method = ClipUpscale.Method.flashVSR
  @AppStorage("upscaleScale") private var scale = 2
  @AppStorage("upscaleFlashVSRVariant") private var variant = FlashVSRFiles.Variant.turbo

  var body: some View {
    let sidecar = item.sidecar
    let controls = UpscaleControls(
      width: sidecar.width, height: sidecar.height,
      method: Binding(get: { method }, set: { if let new = $0 { method = new } }), scale: $scale,
      variant: $variant)
    VStack(alignment: .leading, spacing: 12) {
      Text("Upscale Video").font(.headline)
      controls
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Upscale") {
          let item = item, method = method, scale = scale, variant = variant
          Task { await create.upscale(item, method: method, scale: scale, variant: variant) }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(controls.problem != nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 360)
  }
}

/// Export Video… for a timeline or a video in History: as it is, or upscaled (Fast or Quality,
/// at a scale), with the size it makes and, when upscaling, about how long it takes. As it is
/// exports right away; upscaled, it's a Queue job.
struct VideoExportSheet: View {
  @Environment(\.dismiss) private var dismiss
  let width: Int
  let height: Int
  let frameCount: Int
  /// Called with how to upscale, or nil to export as it is.
  let export: (TimelineUpscale?) -> Void
  /// "none" or a `ClipUpscale.Method`.
  @AppStorage("exportUpscale") private var upscaleChoice = "none"
  @AppStorage("exportUpscaleScale") private var scale = 2
  @AppStorage("upscaleFlashVSRVariant") private var variant = FlashVSRFiles.Variant.turbo

  private var method: ClipUpscale.Method? { ClipUpscale.Method(rawValue: upscaleChoice) }

  var body: some View {
    let controls = UpscaleControls(
      width: width, height: height,
      method: Binding(get: { method }, set: { upscaleChoice = $0?.rawValue ?? "none" }),
      scale: $scale, variant: $variant, offersNone: true)
    let upscale = method.map { TimelineUpscale(method: $0, scale: scale, variant: variant) }
    let problem = controls.problem
    VStack(alignment: .leading, spacing: 12) {
      Text("Export Video").font(.headline)
      controls
      LabeledContent(
        "Takes about",
        value: upscale.map { problem == nil ? Self.duration($0.estimatedSeconds(frames: frameCount, width: width, height: height)) : "—" }
          ?? "Seconds")
      Text(
        upscale == nil
          ? "Exports right away."
          : "Upscaled exports run in the Queue, after what's queued; you choose where the file goes first."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Export…") {
          dismiss()
          export(upscale)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(problem != nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 430)
  }

  private static func duration(_ seconds: Double) -> String {
    Duration.seconds(max(seconds, 60).rounded(.up))
      .formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
  }
}

/// Method, FlashVSR+ variant and scale for upscaling a `width`×`height` video, with the size it
/// makes, a Download button when FlashVSR+ isn't there yet, and why it can't, if it can't.
/// Every control stays; ones that don't apply are disabled.
struct UpscaleControls: View {
  let width: Int
  let height: Int
  /// nil: not upscaling (only when `offersNone`).
  @Binding var method: ClipUpscale.Method?
  @Binding var scale: Int
  @Binding var variant: FlashVSRFiles.Variant
  /// A None choice before Quality and Fast, for exporting as it is.
  let offersNone: Bool
  private var download = FlashVSRDownload.shared

  init(
    width: Int, height: Int, method: Binding<ClipUpscale.Method?>, scale: Binding<Int>,
    variant: Binding<FlashVSRFiles.Variant>, offersNone: Bool = false
  ) {
    self.width = width
    self.height = height
    _method = method
    _scale = scale
    _variant = variant
    self.offersNone = offersNone
  }

  /// The scales the chosen method can do at this size.
  private var scales: [Int] {
    method.map { ClipUpscale.offeredScales(width: width, height: height, method: $0) } ?? []
  }

  /// Why it can't upscale with these choices; nil when it can (or isn't upscaling).
  var problem: String? {
    guard let method else { return nil }
    return ClipUpscale.problem(
      width: width, height: height, scale: scale, method: method, variant: variant)
  }

  var body: some View {
    let size =
      method.map { ClipUpscale.outputSize(width: width, height: height, scale: scale, method: $0) }
      ?? (width: width, height: height)
    // Read while it changes, so the controls follow the download.
    let downloading = download.variant
    let missing = FlashVSRFiles.installed(variant) == nil
    Group {
      Picker(offersNone ? "Upscale" : "Method", selection: $method) {
        if offersNone { Text("None").tag(ClipUpscale.Method?.none) }
        Text("Quality").tag(ClipUpscale.Method?.some(.flashVSR))
        Text("Fast").tag(ClipUpscale.Method?.some(.system))
      }
      .pickerStyle(.segmented)
      Text(
        method == .flashVSR
          ? "FlashVSR+ restores detail as one stream, steady from frame to frame. It takes a few seconds a frame."
          : method == .system
            ? "Apple Super Resolution runs on the Neural Engine in seconds. macOS downloads its model the first time."
            : "At its own size."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Picker("Version", selection: $variant) {
        ForEach(FlashVSRFiles.Variant.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .disabled(method != .flashVSR)
      .help("Turbo is fast; Base searches wider for a little more detail")
      HStack {
        if let downloading, downloading == variant {
          ProgressView(value: download.fraction) {
            Text("Downloading FlashVSR+ \(variant.title)…").font(.caption)
          }
          Button("Cancel") { download.cancel() }
        } else {
          Button(
            "Download FlashVSR+ \(variant.title) (\(Self.bytes(FlashVSRDownload.remainingBytes(variant))))"
          ) {
            download.start(variant)
          }
          .disabled(method != .flashVSR || !missing || downloading != nil)
          .help("Downloads it into \(FlashVSRFiles.folderName) in the models folder, from Hugging Face")
        }
      }
      if let failure = download.failure {
        Text(failure).font(.caption).foregroundStyle(.red)
      }
      Picker("Scale", selection: $scale) {
        ForEach(scales.isEmpty ? ClipUpscale.scales : scales, id: \.self) {
          Text("\($0)×").tag($0)
        }
      }
      .pickerStyle(.segmented)
      .disabled(method == nil || scales.isEmpty)
      LabeledContent("Size", value: "\(width) × \(height) → \(size.width) × \(size.height)")
      if let problem {
        Text(problem).font(.caption).foregroundStyle(.secondary)
      }
    }
    // On each control, which is harmless: the first sets things right.
    .onAppear { offerScale() }
    .onChange(of: method) { offerScale() }
  }

  /// Keeps the scale to one the method offers at this size.
  private func offerScale() {
    if let first = scales.first, !scales.contains(scale) { scale = first }
  }

  private static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}
