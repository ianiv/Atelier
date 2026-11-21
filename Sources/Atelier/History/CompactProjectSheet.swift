import SwiftUI

/// Compact Project…: rewrites the current project's file without its unused space
/// (`ProjectCompaction.compact`, through `CreateModel.compactProject`). While it runs the sheet
/// can't be dismissed, which keeps the window's edits away from a file `VACUUM` has to itself; a
/// large file takes minutes, so it shows a spinner and the time so far, then the sizes before and
/// after.
struct CompactProjectSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(HistoryStore.self) private var history
  @Environment(\.dismiss) private var dismiss
  @State private var phase = Phase.measuring

  enum Phase {
    case measuring
    case ready(Measure)
    case running(since: Date)
    case done(ProjectCompaction.Outcome)
    case failed(String)
  }

  struct Measure {
    var fileBytes: Int64
    var stats: ProjectCompaction.Stats?
    var needed: Int64
    var available: Int64?
    var hasRoom: Bool { available.map { $0 >= needed } ?? true }
  }

  private var isRunning: Bool {
    if case .running = phase { true } else { false }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Compact “\(history.project.name)”").font(.headline)
      content
      HStack {
        Spacer()
        switch phase {
        case .done, .failed:
          Button("Done") { dismiss() }
            .keyboardShortcut(.defaultAction)
        case .measuring, .ready, .running:
          Button("Cancel", role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
            .disabled(isRunning)
          Button("Compact", action: compact)
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        }
      }
    }
    .sheetPadding()
    .sheetFrame(width: 440)
    .interactiveDismissDisabled(isRunning)
    .task { await measure() }
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .measuring:
      ProgressView().controlSize(.small)
    case .ready(let measure):
      VStack(alignment: .leading, spacing: 8) {
        Text(summary(measure))
          .fixedSize(horizontal: false, vertical: true)
        Text("The project can't be used while it's compacted. A large file takes a few minutes.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if !measure.hasRoom, let available = measure.available {
          Label(
            ProjectCompaction.Failure.notEnoughSpace(needed: measure.needed, available: available).errorDescription ?? "",
            systemImage: "exclamationmark.triangle")
            .fixedSize(horizontal: false, vertical: true)
        } else if !create.canCompactProject {
          Label(CreateModel.CompactError.busy.errorDescription ?? "", systemImage: "info.circle")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    case .running(let since):
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        TimelineView(.periodic(from: since, by: 1)) { context in
          Text("Compacting… \(GenerationTime.clock(context.date.timeIntervalSince(since)))")
            .monospacedDigit()
        }
      }
    case .done(let outcome):
      Label(
        "\(ProjectCompaction.format(outcome.bytesBefore)) → \(ProjectCompaction.format(outcome.bytesAfter))",
        systemImage: "checkmark.circle")
      if outcome.mode != .incremental {
        Text("The file didn't switch to giving back space by itself; compacting again may help.")
          .foregroundStyle(.secondary)
      }
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var canStart: Bool {
    guard case .ready(let measure) = phase else { return false }
    return measure.hasRoom && create.canCompactProject
  }

  private func summary(_ measure: Measure) -> String {
    let size = ProjectCompaction.format(measure.fileBytes)
    guard let stats = measure.stats else { return "The project file is \(size)." }
    let free = ProjectCompaction.format(stats.freeBytes)
    let percent = Int((stats.freeFraction * 100).rounded())
    var text = "The project file is \(size), \(free) of it (\(percent)%) unused space left by deleted images."
    if stats.mode != .incremental {
      text += " Compacting also lets it give back space from later deletes by itself."
    }
    return text
  }

  private func measure() async {
    let url = history.project.url
    let measure = await Task.detached {
      Measure(
        fileBytes: ProjectCompaction.fileBytes(url), stats: ProjectCompaction.stats(at: url),
        needed: ProjectCompaction.spaceNeeded(for: url), available: ProjectCompaction.availableSpace(for: url))
    }.value
    if case .measuring = phase { phase = .ready(measure) }
  }

  private func compact() {
    phase = .running(since: .now)
    Task {
      do {
        phase = try await .done(create.compactProject())
      } catch {
        phase = .failed(error.localizedDescription)
      }
    }
  }
}

/// The offer to compact a project that opened with a lot of unused space
/// (`HistoryStore.compactionOffer`), along the bottom of the window: it doesn't stop anything.
/// Turning it down is kept in the project (`HistoryStore.declineCompaction`).
struct CompactionOfferBar: View {
  let offer: HistoryStore.CompactionOffer
  @Environment(CreateModel.self) private var create
  @Environment(HistoryStore.self) private var history

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "externaldrive.badge.minus")
        .foregroundStyle(.secondary)
      Text("“\(offer.project)” has \(ProjectCompaction.format(offer.stats.freeBytes)) of unused space (\(Int((offer.stats.freeFraction * 100).rounded()))% of the file).")
        .lineLimit(2)
      Spacer()
      Button("Don't Ask for This Project") { history.declineCompaction() }
      Button("Compact…") { create.showsCompactProject = true }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)
  }
}
