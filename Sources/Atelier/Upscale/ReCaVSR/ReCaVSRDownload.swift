import Foundation
import Observation

/// Downloads ReCaVSR's published files from Hugging Face into the models folder's "ReCaVSR",
/// one at a time, skipping ones already there at full size. One download at a time for the app.
/// Uses FlashVSR+'s downloader (`FlashVSRDownload.download`).
@MainActor
@Observable
final class ReCaVSRDownload {
  static let shared = ReCaVSRDownload()

  private(set) var downloading = false
  private(set) var fraction: Double = 0
  private(set) var failure: String?
  private var task: Task<Void, Never>?

  /// Bytes left to download.
  static var remainingBytes: Int64 {
    ReCaVSRFiles.required.reduce(0) { sum, file in
      let size = (try? FileManager.default.attributesOfItem(
        atPath: ReCaVSRFiles.folder.appending(path: file.path).path)[.size] as? Int64) ?? nil
      return sum + (size == file.bytes ? 0 : file.bytes)
    }
  }

  func start() {
    guard task == nil else { return }
    downloading = true
    fraction = 0
    failure = nil
    task = Task {
      do {
        let files = ReCaVSRFiles.required
        let total = Double(files.reduce(0) { $0 + $1.bytes })
        var done: Int64 = 0
        for file in files {
          let destination = ReCaVSRFiles.folder.appending(path: file.path)
          let size =
            (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
          if size != file.bytes {
            let before = done
            try await FlashVSRDownload.download(ReCaVSRFiles.source(file.path), to: destination) { written in
              self.fraction = Double(before + written) / total
            }
          }
          done += file.bytes
          fraction = Double(done) / total
        }
      } catch {
        if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
          failure = "Couldn't download ReCaVSR: \(error.localizedDescription)"
        }
      }
      downloading = false
      task = nil
    }
  }

  func cancel() {
    task?.cancel()
  }
}
