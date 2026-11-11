import SwiftUI

/// The Queue: the running job, the waiting ones (drag to reorder) and the recent ones.
struct QueueView: View {
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @State private var selection: Set<UUID> = []

  private var queue: JobQueue { create.queue }

  var body: some View {
    Group {
      if queue.isEmpty, queue.recent.isEmpty {
        ContentUnavailableView(
          "Nothing Queued", systemImage: "list.number",
          description: Text("Press Generate while an image is being made to queue the next one, or set ×N under Generate to make several."))
      } else {
        list
      }
    }
    .toolbar {
      ToolbarItem { PauseQueueButton() }
      ToolbarItem {
        Button("Cancel All", systemImage: "xmark.circle") { create.cancelAll() }
          .help("Remove every waiting job and stop the running one")
          .disabled(queue.isEmpty)
      }
      ToolbarItem {
        Button("Clear Finished", systemImage: "trash") { queue.clearRecent() }
          .help("Remove the finished, failed and cancelled jobs from this list (their images stay in History)")
          .disabled(queue.recent.isEmpty)
      }
    }
  }

  private var list: some View {
    List(selection: $selection) {
      if let running = queue.running {
        Section("Running") {
          row(running)
        }
      }
      if !queue.runningRemote.isEmpty {
        Section("Running on Servers") {
          ForEach(queue.runningRemote) { row($0) }
        }
      }
      if !queue.waiting.isEmpty {
        Section(queue.isPaused ? "Waiting (paused)" : "Waiting") {
          ForEach(queue.waiting) { row($0) }
            .onMove { queue.moveWaiting(fromOffsets: $0, toOffset: $1) }
        }
      }
      if !queue.recent.isEmpty {
        Section("Recent") {
          ForEach(queue.recent) { row($0) }
        }
      }
    }
    .deleteCommand { remove(selection) }
  }

  private func row(_ job: JobQueue.Job) -> some View {
    Group {
      if let export = job.export {
        ExportQueueRow(job: job, export: export)
      } else {
        QueueRow(job: job)
      }
    }
    .tag(job.id)
    .contextMenu { menu(for: job) }
  }

  @ViewBuilder
  private func menu(for job: JobQueue.Job) -> some View {
    switch job.status {
    case .waiting:
      Button("Run Next") { queue.runNext(job.id) }
        .disabled(queue.waiting.first?.id == job.id)
      Button("Cancel") { create.cancel(job.id) }
    case .running:
      Button("Stop") { create.cancel(job.id) }
    case .finished(let tensorId):
      Button("Show in History") {
        create.history.setCurrent(tensorId: tensorId)
        navigation.section = .history
      }
      // A colour match saves into its own project, which may not be the one open.
      .disabled(
        create.history.item(tensorId: tensorId) == nil
          || job.request?.colorMatch.map { $0.project != create.history.project.name } == true)
      Button("Run Again") { create.retry(job.id) }
      Button("Remove from List") { queue.removeRecent(job.id) }
    case .exported(let url):
      Button(Finder.showTitle) { Finder.reveal([url]) }
      Button("Export Again") { create.retry(job.id) }
      Button("Remove from List") { queue.removeRecent(job.id) }
    case .madeThumbnail, .ranForDevice:
      Button("Remove from List") { queue.removeRecent(job.id) }
    case .failed, .cancelled:
      // A thumbnail's result goes back to the Styles screen that queued it, and a paired device's to
      // that device, so they aren't rerun here.
      Button("Retry") { create.retry(job.id) }
        .disabled(job.styleThumbnail != nil || job.remoteDevice != nil)
      Button("Remove from List") { queue.removeRecent(job.id) }
    }
  }

  /// Delete: cancels waiting jobs and takes recent ones off the list; a running job keeps going.
  private func remove(_ ids: Set<UUID>) {
    for id in ids {
      if queue.waiting.contains(where: { $0.id == id }) {
        create.cancel(id)
      } else {
        queue.removeRecent(id)
      }
    }
    selection = []
  }
}

/// A job: its image (or input), prompt, and model, size, seed and steps.
struct QueueRow: View {
  @Environment(CreateModel.self) private var create
  var job: JobQueue.Job

  var body: some View {
    if let request = job.request { content(request) }
  }

  @ViewBuilder
  private func content(_ request: GenerationEngine.Request) -> some View {
    let configuration = request.configuration
    // Not the configuration's own model: on a server, that's only a blank to hold the settings.
    let video = VideoModel(model: request.model, loras: configuration.loras.compactMap(\.file))
    HStack(spacing: 10) {
      preview
        .frame(width: 48, height: 48)
        .clipShape(.rect(cornerRadius: 4))
      VStack(alignment: .leading, spacing: 2) {
        Text(title(request))
          .lineLimit(2)
        Text(caption(request, configuration: configuration, video: video))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let match = request.colorMatch, case .finished = job.status, let shift = match.record?.shift {
          Text(Self.shiftText(shift, luminance: match.luminance))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if case .failed(let message) = job.status {
          Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
        }
        if let timings = job.timings {
          Text(timings.lines.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .help(timings.lines.joined(separator: "\n"))
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: 0)
      if video != nil {
        Image(systemName: "film")
          .foregroundStyle(.secondary)
          .help(request.audio != nil ? "Video, with an audio file" : "Video")
          .accessibilityLabel(request.audio != nil ? "Video, with an audio file" : "Video")
      }
      if request.colorMatch != nil {
        Image(systemName: "eyedropper.halffull")
          .foregroundStyle(.secondary)
          .help("Match Colors to Original")
          .accessibilityLabel("Match Colors to Original")
      }
      if request.canvas != nil {
        Image(systemName: "photo")
          .foregroundStyle(.secondary)
          .help("Edit: starts from the canvas as it was when queued")
          .accessibilityLabel("Edit: starts from the canvas as it was when queued")
      }
      if job.fromAgent {
        Image(systemName: "network")
          .foregroundStyle(.secondary)
          .help("Queued by an agent")
          .accessibilityLabel("Queued by an agent")
      }
      if let device = job.remoteDevice {
        Image(systemName: "laptopcomputer.and.ipad")
          .foregroundStyle(.secondary)
          .help("Running for \(device)")
          .accessibilityLabel("Running for \(device)")
      }
      if let style = job.styleThumbnail {
        Image(systemName: "paintpalette")
          .foregroundStyle(.secondary)
          .help("Thumbnail for the style “\(style)”")
          .accessibilityLabel("Thumbnail for the style “\(style)”")
      }
      status
    }
    .padding(.vertical, 2)
  }

  private var preview: some View {
    ZStack {
      Color.quaternaryLabel
      if let match = job.request?.colorMatch {
        // Its steps are in its own project, which may not be the one open.
        let tensorId = if case .finished(let tensorId) = job.status { tensorId } else { match.sourceTensorId }
        if match.project == create.history.project.name, let item = create.history.item(tensorId: tensorId) {
          Thumbnail(item: item)
        } else {
          Image(systemName: "eyedropper.halffull").foregroundStyle(.secondary).accessibilityHidden(true)
        }
      } else if case .finished(let tensorId) = job.status, let item = create.history.item(tensorId: tensorId) {
        Thumbnail(item: item)
      } else if job.status == .running, let image = create.runProgress(of: job)?.preview {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
      } else if let canvas = job.request?.canvas {
        Image(decorative: canvas, scale: 1).resizable().aspectRatio(contentMode: .fill)
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    switch job.status {
    case .waiting:
      EmptyView()
    case .running:
      let progress = create.runProgress(of: job)
      if let transfer = progress?.transfer {
        // Moving a job's files to or from its server is a phase of its own.
        Text(transfer.title).font(.caption).foregroundStyle(.secondary)
        ProgressView(value: transfer.fraction)
          .frame(width: 80)
      } else if let progress, progress.totalSteps > 0 {
        ProgressView(value: Double(progress.step), total: Double(progress.totalSteps))
          .frame(width: 80)
      } else {
        ProgressView().controlSize(.small)
      }
    case .finished, .exported, .madeThumbnail, .ranForDevice:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Finished").accessibilityLabel("Finished")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Failed").accessibilityLabel("Failed")
    case .cancelled:
      Image(systemName: "xmark.circle").foregroundStyle(.secondary).help("Cancelled").accessibilityLabel("Cancelled")
    }
  }

  private func title(_ request: GenerationEngine.Request) -> String {
    if request.colorMatch != nil { return "Match colors to original" }
    if let upscale = request.imageUpscale {
      return upscale.scale == ImageUpscale.maxScale ? "Upscale to the largest size" : "Upscale \(upscale.scale)×"
    }
    return request.prompt.isEmpty ? "No prompt" : request.prompt
  }

  /// Where it runs, the size and how it's made, then how long it took. A colour match names no
  /// model, seed or steps: it uses none of them.
  private func caption(_ request: GenerationEngine.Request, configuration: PipelineConfiguration, video: VideoModel?) -> String {
    let took = job.elapsed.map { "took \(GenerationTime.text($0))" }
    let size = "\(configuration.width)×\(configuration.height)"
    if let match = request.colorMatch {
      var parts = [create.runLocationName(of: job), size, "strength \(Int((match.strength * 100).rounded()))%",
                   match.luminance ? "lightness matched" : "lightness kept"]
      // Its project, when it isn't the one open.
      if match.project != create.history.project.name { parts.insert("in “\(match.project)”", at: 1) }
      return (parts + [took]).compactMap(\.self).joined(separator: " · ")
    }
    return [
      create.runLocationName(of: job), modelName(request.model), size,
      video.map { length($0, configuration) }, "seed \(request.seed)",
      "\(configuration.steps) steps", took,
    ].compactMap(\.self).joined(separator: " · ")
  }

  /// "Δa −0.4, Δb +5.9 taken out".
  private static func shiftText(_ shift: ColorMatch.Shift, luminance: Bool) -> String {
    func signed(_ value: Double) -> String { String(format: "%+.1f", value) }
    let lightness = luminance ? "ΔL \(signed(shift.l)), " : ""
    return "\(lightness)Δa \(signed(shift.a)), Δb \(signed(shift.b)) taken out"
  }

  private func modelName(_ file: String) -> String {
    create.availableModels.first { $0.file == file }?.name ?? create.models.first { $0.file == file }?.name ?? file
  }

  /// "5.0 s, 121 frames".
  private func length(_ video: VideoModel, _ configuration: PipelineConfiguration) -> String {
    let frames = video.snapped(configuration.numFrames)
    return video.seconds(frames).formatted(.number.precision(.fractionLength(1))) + " s, \(frames) frames"
  }
}

/// An upscaled timeline export: the timeline, how it's upscaled, the size, frames and about how
/// long, and where it goes.
struct ExportQueueRow: View {
  @Environment(CreateModel.self) private var create
  var job: JobQueue.Job
  var export: TimelineExportJob

  var body: some View {
    let size = export.outputSize
    let upscale = export.upscale
    let method =
      upscale.method == .flashVSR ? "FlashVSR+ \(upscale.variant.title)" : "Apple Super Resolution"
    HStack(spacing: 10) {
      ZStack {
        Color.quaternaryLabel
        Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary).accessibilityHidden(true)
      }
      .frame(width: 48, height: 48)
      .clipShape(.rect(cornerRadius: 4))
      VStack(alignment: .leading, spacing: 2) {
        Text("Export “\(export.title)” upscaled")
          .lineLimit(1)
        Text(
          [
            method, "\(upscale.scale)×", "\(size.width)×\(size.height)",
            "\(export.composition.frameCount) frames", timing,
          ].compactMap(\.self).joined(separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        Text(export.destination.lastPathComponent)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if case .failed(let message) = job.status {
          Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      Image(systemName: "film.stack")
        .foregroundStyle(.secondary)
        .help("Timeline export")
        .accessibilityLabel("Timeline export")
      status
    }
    .padding(.vertical, 2)
  }

  /// About how long, while waiting or running; how long it took, once done.
  private var timing: String? {
    switch job.status {
    case .waiting, .running: "about \(Self.duration(export.estimatedSeconds))"
    default: job.elapsed.map { "took \(GenerationTime.text($0))" }
    }
  }

  @ViewBuilder
  private var status: some View {
    switch job.status {
    case .waiting:
      EmptyView()
    case .running:
      let progress = create.runProgress(of: job)
      ProgressView(value: Double(progress?.step ?? 0), total: Double(max(progress?.totalSteps ?? 1, 1)))
        .frame(width: 80)
    case .finished, .exported, .madeThumbnail, .ranForDevice:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Exported").accessibilityLabel("Exported")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Failed").accessibilityLabel("Failed")
    case .cancelled:
      Image(systemName: "xmark.circle").foregroundStyle(.secondary).help("Cancelled").accessibilityLabel("Cancelled")
    }
  }

  private static func duration(_ seconds: Double) -> String {
    Duration.seconds(max(seconds, 60).rounded(.up))
      .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
  }
}

/// Pausing lets the running image finish (or be stopped), then holds the waiting ones.
struct PauseQueueButton: View {
  @Environment(CreateModel.self) private var model

  var body: some View {
    let paused = model.queue.isPaused
    Button {
      model.setQueuePaused(!paused)
    } label: {
      Label(paused ? "Resume Queue" : "Pause Queue", systemImage: paused ? "play.fill" : "pause.fill")
    }
    .labelStyle(.iconOnly)
    .help(
      paused
        ? "Resume: run the waiting images"
        : "Pause after the current image finishes or is stopped")
  }
}
