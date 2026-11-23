import Foundation
import Observation
import SwiftUI

/// Downloads the depth model (`DepthMap.modelFile`) into the main models folder, where the engine
/// finds it, with the engine's resumable downloader checked against Draw Things' SHA-256
/// (`ModelLibrary.fetch`), as Add Folder fetches a file. One download at a time for the app, so
/// the sheet can close and open again while it runs.
@MainActor
@Observable
final class DepthModelDownload {
  static let shared = DepthModelDownload()

  private(set) var isDownloading = false
  private(set) var fraction: Double = 0
  /// Every byte is in and the file is being checked and moved into place.
  private(set) var isFinishing = false
  private(set) var failure: String?
  private var task: Task<Void, Never>?

  /// The folder it goes into: the main models folder when it's there and writable (or the
  /// default one, made on first use), never an additional one (`SAMFiles.downloadFolder`'s rules).
  /// Nil when it can't.
  static var destination: URL? {
    SAMFiles.downloadFolder(primary: AppSettings.modelsDirectory, additional: [])
  }

  /// Starts the download; `done` runs once the model is in.
  func start(then done: @escaping @MainActor () -> Void) {
    guard task == nil else { return }
    failure = nil
    fraction = 0
    isFinishing = false
    guard let folder = Self.destination else {
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
        if DepthMap.isModelInstalled {
          done()
        } else {
          failure = "The depth model downloaded, but the engine doesn't find it in the models folder."
        }
      } catch {
        if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
          failure = "Couldn't download the depth model: \(error.localizedDescription)"
        }
      }
      isDownloading = false
      isFinishing = false
      task = nil
    }
  }

  func cancel() {
    task?.cancel()
  }
}

/// Asks before Extract Depth Map downloads its model (`DepthModelDownload`), then queues the
/// depth map of `item` once it's in. Every control stays; ones that can't act are disabled.
struct DepthModelSheet: View {
  let item: HistoryItem
  @Environment(CreateModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  private var download = DepthModelDownload.shared

  init(item: HistoryItem) {
    self.item = item
  }

  var body: some View {
    let size = ByteCountFormatter.string(fromByteCount: DepthMap.modelBytes, countStyle: .file)
    VStack(alignment: .leading, spacing: 14) {
      Text("Download the Depth Model?")
        .font(.headline)
      Text(
        "Extract Depth Map uses Depth Anything v2 (\(size)), which isn't in your models folder yet. Atelier downloads it once into \(DepthModelDownload.destination?.path ?? "the models folder"), then makes the depth map."
      )
      .fixedSize(horizontal: false, vertical: true)
      ProgressView(value: download.fraction) {
        Text(
          download.isFinishing
            ? "Checking the download…"
            : download.isDownloading ? "Downloading… \(Int(download.fraction * 100))%" : "Not started")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .opacity(download.isDownloading ? 1 : 0.4)
      if let failure = download.failure {
        Text(failure)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button(download.isDownloading ? "Stop Download" : "Cancel", role: .cancel) {
          if download.isDownloading { download.cancel() } else { dismiss() }
        }
        .keyboardShortcut(.cancelAction)
        Button("Download and Extract") {
          let item = item
          download.start { [model] in
            do {
              try model.queueDepthMap(item)
            } catch {
              model.errorMessage = error.localizedDescription
            }
            model.depthModelSheetItem = nil
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(download.isDownloading || DepthModelDownload.destination == nil)
      }
    }
    .padding(20)
    .frame(width: 440)
  }
}
