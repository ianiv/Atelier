import SwiftUI

/// Upscale… on a clip in History: pick FlashVSR+ (Quality), ReCaVSR or Apple Super Resolution
/// (Fast) and a scale, then queue it. The result is a new clip after the source.
struct UpscaleSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  var item: HistoryItem
  @AppStorage("upscaleMethod") private var method = ClipUpscale.Method.flashVSR
  @AppStorage("upscaleScale") private var scale = 2
  @AppStorage("upscaleFlashVSRVariant") private var variant = FlashVSRFiles.Variant.turbo
  @AppStorage("upscaleReCaVSRWeights") private var weights = ReCaVSRFiles.Weights.full

  var body: some View {
    let sidecar = item.sidecar
    let controls = UpscaleControls(
      width: sidecar.width, height: sidecar.height,
      method: Binding(get: { method }, set: { if let new = $0 { method = new } }), scale: $scale,
      variant: $variant, weights: $weights, server: create.runTargetUpscalers)
    VStack(alignment: .leading, spacing: 12) {
      Text("Upscale Video").font(.headline)
      controls
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Upscale") {
          let item = item, method = method, scale = scale, variant = variant, weights = weights
          Task { await create.upscale(item, method: method, scale: scale, variant: variant, weights: weights) }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(controls.problem != nil)
      }
    }
    .sheetPadding()
    .sheetFrame(width: 500, height: 440)
  }
}

/// Upscale… on the canvas image: any upscaler, named for its model, and a scale, then queue it.
/// The result is a new image in History. A FlashVSR+ version that isn't here yet is still offered,
/// and the main button downloads it first.
struct ImageUpscaleSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  let width: Int
  let height: Int
  /// An option's tag.
  @AppStorage("imageUpscaler") private var chosen = ""
  @AppStorage("imageUpscaleScale") private var scale = 4
  private let models = ImageUpscale.installed
  private var download = FlashVSRDownload.shared

  init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

  private var seedVR2: [(file: String, name: String)] { ImageUpscale.seedVR2Models(in: create.modelFiles) }

  private var tags: [String] {
    models.map { "model:\($0.file)" }
      + FlashVSRFiles.Variant.allCases.map { "flashVSR:\($0.rawValue)" } + ["system"]
      + seedVR2.map { "seedVR2:\($0.file)" }
  }

  /// The one last picked while it's there, else the first.
  private var selection: String { tags.contains(chosen) ? chosen : tags[0] }

  private var upscaler: ImageUpscale.Upscaler {
    if selection == "system" { return .video(.system, nil) }
    if selection.hasPrefix("flashVSR:") { return .video(.flashVSR, variant ?? .turbo) }
    if selection.hasPrefix("seedVR2:") { return .seedVR2(String(selection.dropFirst("seedVR2:".count))) }
    return .model(String(selection.dropFirst("model:".count)))
  }

  /// The FlashVSR+ version selected.
  private var variant: FlashVSRFiles.Variant? {
    guard selection.hasPrefix("flashVSR:") else { return nil }
    return FlashVSRFiles.Variant(rawValue: String(selection.dropFirst("flashVSR:".count)))
  }

  private var upscale: ImageUpscale {
    ImageUpscale(upscaler: upscaler, scale: scale).resolved(width: width, height: height)
  }

  private var caption: String {
    switch upscaler {
    case .model: "Sharpens the image, without a diffusion model."
    case .video(.flashVSR, _): "Restores detail with a video model. It uses a lot of memory at large sizes."
    case .video(.system, _): "Runs on the Neural Engine in seconds. macOS downloads its model the first time."
    case .video(.recaVSR, _): "ReCaVSR upscales videos, not images."
    case .seedVR2: "Restores detail with a diffusion model in one step, and can invent texture."
    }
  }

  var body: some View {
    let upscale = self.upscale
    let size = upscale.outputSize(width: width, height: height)
    let offered = upscale.scales(width: width, height: height)
    let missing = variant.flatMap { FlashVSRFiles.installed($0) == nil ? $0 : nil }
    let downloading = download.variant
    let problem = upscale.problem(width: width, height: height)
    let note: String? =
      downloading.map { "Downloading FlashVSR+ \($0.title)… \(Int(download.fraction * 100))%" }
        ?? download.failure ?? problem
    VStack(alignment: .leading, spacing: 14) {
      Text("Upscale Image").font(.headline)
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Upscaler").gridColumnAlignment(.trailing)
          VStack(alignment: .leading, spacing: 6) {
            picker
            // Room for two lines always, so the sheet doesn't move between upscalers.
            Text(caption).font(.caption).foregroundStyle(.secondary)
              .lineLimit(2, reservesSpace: true)
          }
        }
        GridRow {
          Text("Scale")
          // SwiftUI can't grey one segment, so a scale this upscaler can't do stays choosable and
          // the note says why. Max only comes when it makes a size of its own.
          Picker("Scale", selection: Binding(get: { upscale.scale }, set: { scale = $0 })) {
            ForEach(ImageUpscale.scales + (upscale.offersMax(width: width, height: height) ? [ImageUpscale.maxScale] : []), id: \.self) {
              Text($0 == ImageUpscale.maxScale ? "Max" : "\($0)×").tag($0)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .disabled(offered.isEmpty)
        }
        GridRow {
          Text("Size")
          VStack(alignment: .leading, spacing: 6) {
            Text("\(width) × \(height) → " + (problem != nil ? "—" : "\(size.width) × \(size.height)"))
              .monospacedDigit()
            Text(note ?? " ").font(.caption).foregroundStyle(.secondary)
              .lineLimit(2, reservesSpace: true)
          }
        }
      }
      Spacer(minLength: 0)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          if downloading != nil { download.cancel() } else { dismiss() }
        }
        .keyboardShortcut(.cancelAction)
        Button(missing.map { "Download \(Self.bytes(FlashVSRDownload.remainingBytes($0)))" } ?? "Upscale") {
          if let missing {
            download.start(missing)
          } else {
            create.upscaleCanvasImage(upscale)
            dismiss()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(downloading != nil || (missing == nil && problem != nil))
      }
    }
    .sheetPadding()
    .sheetFrame(width: 460, height: 270)
  }

  private var picker: some View {
    Picker("Upscaler", selection: Binding(get: { selection }, set: { chosen = $0 })) {
      ForEach(models, id: \.file) { Text($0.name).tag("model:\($0.file)") }
      if !models.isEmpty { Divider() }
      ForEach(FlashVSRFiles.Variant.allCases, id: \.self) { variant in
        Text(
          "FlashVSR+ \(variant.title)" + (FlashVSRFiles.installed(variant) == nil ? " (not downloaded)" : "")
        ).tag("flashVSR:\(variant.rawValue)")
      }
      Text("Apple Super Resolution").tag("system")
      if !seedVR2.isEmpty { Divider() }
      ForEach(seedVR2, id: \.file) { Text($0.name).tag("seedVR2:\($0.file)") }
    }
    .labelsHidden()
  }

  private static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
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
  @AppStorage("upscaleReCaVSRWeights") private var weights = ReCaVSRFiles.Weights.full

  private var method: ClipUpscale.Method? {
    // Without None, a saved None falls to the method that needs no download.
    ClipUpscale.Method(rawValue: upscaleChoice) ?? (name == nil ? nil : .system)
  }

  var body: some View {
    let controls = UpscaleControls(
      width: width, height: height,
      method: Binding(get: { method }, set: { upscaleChoice = $0?.rawValue ?? "none" }),
      scale: $scale, variant: $variant, weights: $weights, offersNone: name == nil, server: create.runTargetUpscalers)
    let upscale = method.map { TimelineUpscale(method: $0, scale: scale, variant: variant, weights: weights) }
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
    .sheetFrame(width: 500, height: 520)
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

/// Method, FlashVSR+ variant, ReCaVSR weights and scale for upscaling a `width`×`height` video,
/// with the size it makes, a Download button for the chosen model when it isn't there yet,
/// ReCaVSR's Make 8-bit Copy, and why it can't, if it can't. Every control stays; ones that
/// don't apply are disabled.
struct UpscaleControls: View {
  let width: Int
  let height: Int
  /// nil: not upscaling (only when `offersNone`).
  @Binding var method: ClipUpscale.Method?
  @Binding var scale: Int
  @Binding var variant: FlashVSRFiles.Variant
  @Binding var weights: ReCaVSRFiles.Weights
  /// A None choice before Quality and Fast, for exporting as it is.
  let offersNone: Bool
  /// Where it would run, when that's a server: what it has decides, not what's on this device.
  let server: (name: String, upscalers: RemoteUpscalers)?
  private var download = FlashVSRDownload.shared
  private var recaVSR = ReCaVSRDownload.shared

  init(
    width: Int, height: Int, method: Binding<ClipUpscale.Method?>, scale: Binding<Int>,
    variant: Binding<FlashVSRFiles.Variant>, weights: Binding<ReCaVSRFiles.Weights>, offersNone: Bool = false,
    server: (name: String, upscalers: RemoteUpscalers)? = nil
  ) {
    self.server = server
    self.width = width
    self.height = height
    _method = method
    _scale = scale
    _variant = variant
    _weights = weights
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
      case .recaVSR:
        guard (server.upscalers.recaVSR ?? []).contains(weights) else {
          return "\(server.name) doesn't have ReCaVSR \(weights.title). Set it up there."
        }
        return scales.contains(scale) ? nil : "That's too large for ReCaVSR."
      }
    }
    return ClipUpscale.problem(
      width: width, height: height, scale: scale, method: method, variant: variant, weights: weights)
  }

  var body: some View {
    let size =
      method.map { ClipUpscale.outputSize(width: width, height: height, scale: scale, method: $0) }
        ?? (width: width, height: height)
    // Read while they change, so the controls follow the downloads and the copy.
    let downloading = download.variant
    let missing = FlashVSRFiles.installed(variant) == nil
    let recaVSRDownloaded = recaVSR.copies >= 0 && !recaVSR.downloading && ReCaVSRFiles.downloaded
    let hasEightBit = ReCaVSRFiles.installed(.eightBit) != nil
    Group {
      Picker(offersNone ? "Upscale" : "Method", selection: $method) {
        if offersNone { Text("None").tag(ClipUpscale.Method?.none) }
        Text("Quality").tag(ClipUpscale.Method?.some(.flashVSR))
        Text("ReCaVSR").tag(ClipUpscale.Method?.some(.recaVSR))
        Text("Fast").tag(ClipUpscale.Method?.some(.system))
      }
      .pickerStyle(.segmented)
      Text(
        method == .flashVSR
          ? "FlashVSR+ restores detail as one stream, steady from frame to frame. It takes a few seconds a frame."
          : method == .recaVSR
          ? "ReCaVSR restores detail with a large video model, reusing what it made for the frames before. About a second a frame at 1080p."
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
      Picker("Weights", selection: $weights) {
        ForEach(ReCaVSRFiles.Weights.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .disabled(method != .recaVSR || !ClipUpscale.recaVSRFullAllowed)
      .help("8-bit uses about 4.5 GB less memory and looks nearly the same; it needs the 8-bit copy")
      HStack {
        if method == .recaVSR {
          if recaVSR.downloading {
            ProgressView(value: recaVSR.fraction) { Text("Downloading ReCaVSR…").font(.caption) }
            Button("Cancel") { recaVSR.cancel() }
          } else {
            Button("Download ReCaVSR (\(Self.bytes(ReCaVSRDownload.remainingBytes)))") { recaVSR.start() }
              .disabled(recaVSRDownloaded || server != nil)
              .help("Downloads it into \(ReCaVSRFiles.folderName) in the models folder, from Hugging Face")
          }
        } else if let downloading, downloading == variant {
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
      HStack {
        if let copying = recaVSR.copying {
          ProgressView(value: copying) { Text("Making ReCaVSR's 8-bit copy…").font(.caption) }
          Button("Stop") { recaVSR.cancelEightBitCopy() }
        } else {
          Button("Make 8-bit Copy (\(Self.bytes(ReCaVSRDownload.eightBitBytes)))") { recaVSR.makeEightBitCopy() }
            .disabled(method != .recaVSR || !recaVSRDownloaded || hasEightBit || server != nil)
            .help("Writes an 8-bit copy of ReCaVSR beside it in the models folder, for the 8-bit weights")
        }
      }
      if let failure = recaVSR.failure ?? recaVSR.copyFailure, method == .recaVSR {
        Text(failure).font(.caption).foregroundStyle(.red)
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
    .onAppear {
      offerScale()
      offerWeights()
    }
    .onChange(of: method) { offerScale() }
  }

  /// Keeps the weights to what this device runs: 8-bit only on an iPad.
  private func offerWeights() {
    if !ClipUpscale.recaVSRFullAllowed, weights == .full { weights = .eightBit }
  }

  /// Keeps the scale to one the method offers at this size.
  private func offerScale() {
    if let first = scales.first, !scales.contains(scale) { scale = first }
  }

  private static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}
