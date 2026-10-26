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
    .onDeleteCommand { remove(selection) }
  }

  private func row(_ job: JobQueue.Job) -> some View {
    QueueRow(job: job)
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
    let request = job.request
    let configuration = request.configuration
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
            "seed \(request.seed)", "\(configuration.steps) steps",
          ].joined(separator: " · ")
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
      Color(nsColor: .quaternaryLabelColor)
      if case .finished(let tensorId) = job.status, let item = create.history.item(tensorId: tensorId) {
        Thumbnail(item: item)
      } else if job.status == .running, let image = create.livePreview {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
      } else if let canvas = job.request.canvas {
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
    case .finished:
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
