import SwiftUI

/// The Queue: the running job, the waiting ones (drag to reorder) and the recent ones.
struct QueueView: View {
  @Environment(CreateModel.self) private var create
  @Environment(Navigation.self) private var navigation
  @State private var selection: Set<UUID> = []

  private var queue: JobQueue { create.queue }

  var body: some View {
    Group {
      if queue.isEmpty && queue.recent.isEmpty {
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

  @ViewBuilder
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
      .disabled(create.history.item(tensorId: tensorId) == nil)
      Button("Run Again") { create.retry(job.id) }
      Button("Remove from List") { queue.removeRecent(job.id) }
    case .exported(let url):
      Button(Finder.showTitle) { Finder.reveal([url]) }
      Button("Export Again") { create.retry(job.id) }
      Button("Remove from List") { queue.removeRecent(job.id) }
    case .failed, .cancelled:
      Button("Retry") { create.retry(job.id) }
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
    let video = configuration.videoModel
    HStack(spacing: 10) {
      preview
        .frame(width: 48, height: 48)
        .clipShape(.rect(cornerRadius: 4))
      VStack(alignment: .leading, spacing: 2) {
        Text(request.prompt.isEmpty ? "No prompt" : request.prompt)
          .lineLimit(2)
        Text(
          [
            modelName(request.model), "\(configuration.width)×\(configuration.height)",
            video.map { length($0, configuration) }, "seed \(request.seed)",
            "\(configuration.steps) steps", job.elapsed.map { "took \(GenerationTime.text($0))" },
          ].compactMap { $0 }.joined(separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        if case .failed(let message) = job.status {
          Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      if video != nil {
        Image(systemName: "film")
          .foregroundStyle(.secondary)
          .help(request.audio != nil ? "Video, with an audio file" : "Video")
      }
      if request.canvas != nil {
        Image(systemName: "photo")
          .foregroundStyle(.secondary)
          .help("Edit: starts from the canvas as it was when queued")
      }
      if job.fromAgent {
        Image(systemName: "network")
          .foregroundStyle(.secondary)
          .help("Queued by an agent")
      }
      status
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var preview: some View {
    ZStack {
      Color.quaternaryLabel
      if case .finished(let tensorId) = job.status, let item = create.history.item(tensorId: tensorId) {
        Thumbnail(item: item)
      } else if job.status == .running, let image = create.livePreview {
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
      if create.totalSteps > 0 {
        ProgressView(value: Double(create.step), total: Double(create.totalSteps))
          .frame(width: 80)
      } else {
        ProgressView().controlSize(.small)
      }
    case .finished, .exported:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Finished")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Failed")
    case .cancelled:
      Image(systemName: "xmark.circle").foregroundStyle(.secondary).help("Cancelled")
    }
  }

  private func modelName(_ file: String) -> String {
    create.models.first { $0.file == file }?.name ?? file
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
        Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
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
          ].compactMap { $0 }.joined(separator: " · ")
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
      ProgressView(value: Double(create.step), total: Double(max(create.totalSteps, 1)))
        .frame(width: 80)
    case .finished, .exported:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Exported")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Failed")
    case .cancelled:
      Image(systemName: "xmark.circle").foregroundStyle(.secondary).help("Cancelled")
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
