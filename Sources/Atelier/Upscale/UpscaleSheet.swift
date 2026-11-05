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
      variant: $variant, server: create.runTargetUpscalers)
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
    .sheetPadding()
    .sheetFrame(width: 440, height: 360)
  }
}

/// Upscale… on the canvas image: pick an upscaler model and a scale, then queue it. The result is
/// a new image in History.
struct ImageUpscaleSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  let width: Int
  let height: Int
  @AppStorage("imageUpscaler") private var chosen = ""
  @AppStorage("imageUpscaleScale") private var scale = 4
  private let upscalers = ImageUpscale.installed

  /// The one last picked while it's there, else the first.
  private var file: String? {
    upscalers.contains { $0.file == chosen } ? chosen : upscalers.first?.file
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Upscale Image").font(.headline)
      if upscalers.isEmpty {
        Text("There's no upscaler model in your models folder. Add one, such as Real-ESRGAN X4+ or 4x UltraSharp.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Picker("Upscaler", selection: Binding(get: { file ?? "" }, set: { chosen = $0 })) {
          ForEach(upscalers, id: \.file) { Text($0.name).tag($0.file) }
        }
        Picker("Scale", selection: $scale) {
          ForEach(ImageUpscale.scales, id: \.self) { Text("\($0)×").tag($0) }
        }
        .pickerStyle(.segmented)
        LabeledContent("Size", value: "\(width) × \(height) → \(width * scale) × \(height * scale)")
      }
      Spacer(minLength: 0)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Upscale") {
          if let file { create.upscaleCanvasImage(ImageUpscale(file: file, scale: scale)) }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(file == nil)
      }
    }
    .sheetPadding()
    .sheetFrame(width: 440, height: 220)
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
  /// A video from outside the project, which is only here to be upscaled: there's no None, and
  /// the sheet names it.
  var name: String?
  /// Called with how to upscale, or nil to export as it is.
  let export: (TimelineUpscale?) -> Void
  @Environment(CreateModel.self) private var create
  /// "none" or a `ClipUpscale.Method`.
  @AppStorage("exportUpscale") private var upscaleChoice = "none"
  @AppStorage("exportUpscaleScale") private var scale = 2
  @AppStorage("upscaleFlashVSRVariant") private var variant = FlashVSRFiles.Variant.turbo

  private var method: ClipUpscale.Method? {
    // Without None, a saved None falls to the method that needs no download.
    ClipUpscale.Method(rawValue: upscaleChoice) ?? (name == nil ? nil : .system)
  }

  var body: some View {
    let controls = UpscaleControls(
      width: width, height: height,
      method: Binding(get: { method }, set: { upscaleChoice = $0?.rawValue ?? "none" }),
      scale: $scale, variant: $variant, offersNone: name == nil, server: create.runTargetUpscalers)
    let upscale = method.map { TimelineUpscale(method: $0, scale: scale, variant: variant) }
    let problem = controls.problem
    VStack(alignment: .leading, spacing: 12) {
      Text(name.map { "Upscale “\($0)”" } ?? "Export Video").font(.headline)
        .lineLimit(1).truncationMode(.middle)
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
    .sheetPadding()
    .sheetFrame(width: 440, height: 430)
  }

  private static func duration(_ seconds: Double) -> String {
    Duration.seconds(max(seconds, 60).rounded(.up))
      .formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
  }
}

/// A video dropped on the canvas, ready for `VideoExportSheet`.
struct DroppedVideo: Identifiable {
  let id = UUID()
  /// The file's name, without its extension.
  let name: String
  let composition: TimelineComposition
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
  /// Where it would run, when that's a server: what it has decides, not what's on this device.
  let server: (name: String, upscalers: RemoteUpscalers)?
  private var download = FlashVSRDownload.shared

  init(
    width: Int, height: Int, method: Binding<ClipUpscale.Method?>, scale: Binding<Int>,
    variant: Binding<FlashVSRFiles.Variant>, offersNone: Bool = false,
    server: (name: String, upscalers: RemoteUpscalers)? = nil
  ) {
    self.server = server
    self.width = width
    self.height = height
    _method = method
    _scale = scale
    _variant = variant
    self.offersNone = offersNone
  }

  /// The scales the chosen method can do at this size.
  private var scales: [Int] {
    // What Apple's model offers depends on the device and the size. A server's isn't asked; this
    // device's is the best guess, and a server that differs fails the job saying so.
    if server != nil, method == .system {
      let here = ClipUpscale.offeredScales(width: width, height: height, method: .system)
      return here.isEmpty ? ClipUpscale.scales : here
    }
    return method.map { ClipUpscale.offeredScales(width: width, height: height, method: $0) } ?? []
  }

  /// Why it can't upscale with these choices; nil when it can (or isn't upscaling).
  var problem: String? {
    guard let method else { return nil }
    if let server {
      switch method {
      case .flashVSR:
        guard server.upscalers.flashVSR.contains(variant) else {
          return "\(server.name) doesn't have FlashVSR+ \(variant.title). Download it there."
        }
        return scales.contains(scale) ? nil : "That's too large for FlashVSR+."
      case .system:
        return server.upscalers.superResolution ? nil : "\(server.name) doesn't support Apple Super Resolution."
      }
    }
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
          .disabled(method != .flashVSR || !missing || downloading != nil || server != nil)
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
