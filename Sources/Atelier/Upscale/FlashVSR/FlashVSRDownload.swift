import Foundation
import Observation

/// Downloads a FlashVSR+ variant's files from Hugging Face into the models folder's "FlashVSR+",
/// one at a time, skipping ones already there. One download at a time for the app.
@MainActor
@Observable
final class FlashVSRDownload {
  static let shared = FlashVSRDownload()

  /// The variant downloading; nil when idle.
  private(set) var variant: FlashVSRFiles.Variant?
  private(set) var fraction: Double = 0
  private(set) var failure: String?
  private var task: Task<Void, Never>?

  /// Bytes left to download for `variant`.
  static func remainingBytes(_ variant: FlashVSRFiles.Variant) -> Int64 {
    FlashVSRFiles.required(variant).reduce(0) { sum, file in
      let size = (try? FileManager.default.attributesOfItem(
        atPath: FlashVSRFiles.folder.appending(path: file.path).path)[.size] as? Int64) ?? nil
      return sum + (size == file.bytes ? 0 : file.bytes)
    }
  }

  func start(_ variant: FlashVSRFiles.Variant) {
    guard task == nil else { return }
    self.variant = variant
    fraction = 0
    failure = nil
    task = Task {
      do {
        let files = FlashVSRFiles.required(variant)
        let total = Double(files.reduce(0) { $0 + $1.bytes })
        var done: Int64 = 0
        for file in files {
          let destination = FlashVSRFiles.folder.appending(path: file.path)
          let size =
            (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
          if size != file.bytes {
            let before = done
            try await Self.download(FlashVSRFiles.source(file.path), to: destination) { written in
              self.fraction = Double(before + written) / total
            }
          }
          done += file.bytes
          fraction = Double(done) / total
        }
      } catch {
        if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
          failure = "Couldn't download FlashVSR+: \(error.localizedDescription)"
        }
      }
      self.variant = nil
      task = nil
    }
  }

  func cancel() {
    task?.cancel()
  }

  /// Downloads `url` to `destination`, replacing what's there, reporting bytes written.
  private static func download(
    _ url: URL, to destination: URL, progress: @escaping @MainActor (Int64) -> Void
  ) async throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let delegate = Delegate(destination: destination, progress: progress)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let task = session.downloadTask(with: url)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        delegate.continuation = continuation
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @MainActor (Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    init(destination: URL, progress: @escaping @MainActor (Int64) -> Void) {
      self.destination = destination
      self.progress = progress
    }

    func urlSession(
      _: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
      totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64
    ) {
      let progress = progress
      Task { @MainActor in progress(totalBytesWritten) }
    }

    func urlSession(
      _: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
      // The file only lasts until this returns.
      do {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
          throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: location, to: destination)
      } catch {
        moveError = error
      }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
      if let error = error ?? moveError {
        continuation?.resume(throwing: error)
      } else {
        continuation?.resume()
      }
      continuation = nil
    }
  }
}
