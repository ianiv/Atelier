import Foundation
import Observation
import SwiftUI

/// Downloads the depth model (`DepthMap.modelFile`) into the main models folder, where the engine
/// finds it, with the engine's resumable downloader checked against Draw Things' SHA-256
/// (`ModelLibrary.fetch`), as Add Folder fetches a file. One download at a time for the app.
@MainActor
@Observable
final class DepthModelDownload {
  static let shared = DepthModelDownload()

  private(set) var isDownloading = false
  private(set) var fraction: Double = 0
  /// Every byte is in and the file is being checked and moved into place. A Stop then lets that
  /// finish (`ModelLibrary.fetch`), so there's nothing to stop.
  private(set) var isFinishing = false
  private(set) var failure: String?
  /// Whether the model is in a models folder, as last looked (`refresh`).
  private(set) var isInstalled = false
  /// The folder a download goes into, as last looked (`refresh`): the main models folder when
  /// it's there and writable (or the default one, made on first use), never an additional one
  /// (`SAMFiles.downloadFolder`'s rules). Nil when it can't.
  private(set) var destination: URL?
  private var task: Task<Void, Never>?
  /// Stop was pressed for the download under way.
  private var stopped = false

  init() { refresh() }

  /// Looks at the folders again: when the sheet opens and when a download starts or ends.
  func refresh() {
    isInstalled = DepthMap.isModelInstalled
    destination = SAMFiles.downloadFolder(primary: AppSettings.modelsDirectory, additional: [])
  }

  /// What a finished download does about the depth map it was started for (`DepthModelSheet`).
  nonisolated enum Outcome: Equatable {
    /// Queue it: the model is in, nothing was stopped, the sheet still shows that image and its
    /// project is still the open one.
    case queue
    /// Nothing: stopped, or the sheet now shows another image (or none).
    case nothing
    /// Leave the sheet open with a note: the project it was for isn't the open one now, and its
    /// step ids would name steps of another project.
    case projectChanged
  }

  /// The decision the sheet makes once the download has ended.
  nonisolated static func outcome(
    stopped: Bool, installed: Bool, sheetTensorId: Int64?, tensorId: Int64, openProject: String, project: String
  ) -> Outcome {
    guard !stopped, installed, sheetTensorId == tensorId else { return .nothing }
    return openProject == project ? .queue : .projectChanged
  }

  /// Starts the download; `done` runs once it has ended with the model in, with whether Stop was
  /// pressed (it can still end that way: once every byte is in, the file is checked and moved
  /// anyway).
  func start(then done: @escaping @MainActor (_ stopped: Bool) -> Void) {
    guard task == nil else { return }
    refresh()
    failure = nil
    fraction = 0
    isFinishing = false
    stopped = false
    guard let folder = destination else {
      failure = "Couldn't download the depth model: the models folder isn't there. Connect its drive, or choose another in Settings ▸ Models."
      return
    }
    isDownloading = true
    task = Task {
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await ModelLibrary.fetch(
          url: DepthMap.modelURL, to: folder.appending(path: DepthMap.modelFile), sha256: DepthMap.modelSHA256,
          progress: { written, expected in
            let total = expected > 0 ? expected : DepthMap.modelBytes
            Task { @MainActor in self.fraction = min(Double(written) / Double(max(total, 1)), 1) }
          },
          finishing: { _ in Task { @MainActor in self.isFinishing = true } })
        refresh()
        if !isInstalled {
          failure = "The depth model downloaded, but the engine doesn't find it in the models folder."
        }
      } catch {
        refresh()
        if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
          failure = "Couldn't download the depth model: \(error.localizedDescription)"
        }
      }
      isDownloading = false
      isFinishing = false
      task = nil
      if isInstalled { done(stopped || Task.isCancelled) }
    }
  }

  func cancel() {
    stopped = true
    task?.cancel()
  }
}

/// Asks before Extract Depth Map downloads its model (`DepthModelDownload`), then queues the
/// depth map of `item`, a step of `project`, once it's in. Every control stays; ones that can't act
/// are disabled. It can't be swiped away while downloading, so the download ends in the sheet it
/// started from.
struct DepthModelSheet: View {
  let item: HistoryItem
  @Environment(CreateModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  private var download = DepthModelDownload.shared
  /// The project the sheet opened in, which `item` is a step of.
  @State private var project: String
  /// Why the depth map wasn't queued after the download, when it wasn't.
  @State private var note: String?

  init(item: HistoryItem, project: String) {
    self.item = item
    _project = State(initialValue: project)
  }

  var body: some View {
    let size = ByteCountFormatter.string(fromByteCount: DepthMap.modelBytes, countStyle: .file)
    let folder = download.destination?.path ?? "the models folder"
    VStack(alignment: .leading, spacing: 14) {
      Text(download.isInstalled ? "Depth Model Ready" : "Download the Depth Model?")
        .font(.headline)
      Text(
        download.isInstalled
          ? "Depth Anything v2 is in your models folders now: Extract makes the depth map."
          : "Extract Depth Map uses Depth Anything v2 (\(size)), which isn't in your models folders yet. Atelier downloads it once into \(folder), then makes the depth map."
      )
      .fixedSize(horizontal: false, vertical: true)
      ProgressView(value: download.isInstalled ? 1 : download.fraction) {
        Text(
          download.isFinishing
            ? "Checking the download…"
            : download.isDownloading ? "Downloading… \(Int(download.fraction * 100))%" : download.isInstalled ? "Downloaded" : "Not started")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .opacity(download.isDownloading || download.isInstalled ? 1 : 0.4)
      if let message = note ?? download.failure {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button(download.isFinishing ? "Checking…" : download.isDownloading ? "Stop Download" : "Cancel", role: .cancel) {
          if download.isDownloading { download.cancel() } else { dismiss() }
        }
        .keyboardShortcut(.cancelAction)
        // Once every byte is in, the check and move finish anyway: Stop can't stop them.
        .disabled(download.isFinishing)
        Button(download.isInstalled ? "Extract" : "Download and Extract") {
          note = nil
          if download.isInstalled { return finished(stopped: false) }
          download.start { stopped in finished(stopped: stopped) }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(download.isDownloading || (!download.isInstalled && download.destination == nil))
      }
    }
    .padding(20)
    .frame(width: 440)
    .interactiveDismissDisabled(download.isDownloading)
    .onAppear { download.refresh() }
  }

  /// Queues the depth map once the model is in, unless the download was stopped, the sheet moved
  /// on to another image, or the open project isn't the image's any more (its step ids would name
  /// another project's steps).
  private func finished(stopped: Bool) {
    switch DepthModelDownload.outcome(
      stopped: stopped, installed: download.isInstalled, sheetTensorId: model.depthModelSheetItem?.tensorId,
      tensorId: item.tensorId, openProject: model.history.project.name, project: project)
    {
    case .queue:
      do {
        try model.queueDepthMap(item)
      } catch {
        model.errorMessage = error.localizedDescription
      }
      model.depthModelSheetItem = nil
    case .projectChanged:
      note = "Another project is open now, so the depth map wasn't made. The model is in: choose Extract Depth Map again."
    case .nothing:
      break
    }
  }
}
