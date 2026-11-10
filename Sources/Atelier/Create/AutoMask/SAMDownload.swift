import Foundation
import Observation

/// Downloads a SAM 2.1 size's three Core ML packages from Hugging Face into the models folder's
/// "SAM 2.1/<size>", as `FlashVSRDownload` does FlashVSR+: the repository's file listing first
/// (each package is a folder of files), then each file in turn, skipping ones already there at
/// their size. The listing is written last, which is what makes the size count as installed. One
/// download at a time for the app.
@MainActor
@Observable
final class SAMDownload {
  static let shared = SAMDownload()

  /// The size downloading; nil when idle.
  private(set) var size: SAMFiles.Size?
  private(set) var fraction: Double = 0
  private(set) var failure: String?
  /// Bumped when a download finishes, so views that ask `SAMFiles.installed` look again.
  private(set) var finished = 0
  private var task: Task<Void, Never>?

  /// Bytes left to download for `size` (all of it until it's installed: the listing isn't known
  /// before the download starts).
  static func remainingBytes(_ size: SAMFiles.Size) -> Int64 {
    SAMFiles.installed(size) == nil ? size.bytes : 0
  }

  func start(_ size: SAMFiles.Size) {
    guard task == nil else { return }
    self.size = size
    fraction = 0
    failure = nil
    task = Task {
      do {
        try await Self.download(size) { self.fraction = $0 }
        finished += 1
      } catch {
        if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
          failure = "Couldn't download SAM 2.1: \(error.localizedDescription)"
        }
      }
      self.size = nil
      task = nil
    }
  }

  /// Downloads `size` and waits for it, for callers without a view (scripted checks). Throws what
  /// stopped it.
  func download(_ size: SAMFiles.Size) async throws {
    if SAMFiles.installed(size) != nil { return }
    start(size)
    while let task {
      await task.value
    }
    if let failure { throw DownloadFailure(message: failure) }
    if SAMFiles.installed(size) == nil { throw SAMFiles.Failure.missing }
  }

  struct DownloadFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
  }

  func cancel() {
    task?.cancel()
  }

  private static func download(_ size: SAMFiles.Size, progress: @escaping @MainActor (Double) -> Void) async throws {
    let (listing, response) = try await URLSession.shared.data(from: SAMFiles.listingURL(size))
    if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw URLError(.badServerResponse) }
    let files = try SAMFiles.packageFiles(inListing: listing)
    // All three packages, each with its spec and weights.
    guard SAMFiles.Part.allCases.allSatisfy({ part in
      files.contains { $0.path.hasSuffix("\(part.rawValue)FLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel") }
    }) else { throw URLError(.cannotParseResponse) }
    let root = SAMFiles.folder(size)
    let manager = FileManager.default
    // A listing from an earlier download no longer holds once files change under it.
    try? manager.removeItem(at: root.appending(path: SAMFiles.listingName))
    let total = Double(max(files.reduce(0) { $0 + $1.size }, 1))
    var done: Int64 = 0
    for file in files {
      try Task.checkCancellation()
      let destination = root.appending(path: file.path)
      let existing = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
      if existing != file.size {
        let before = done
        try await FlashVSRDownload.download(SAMFiles.source(size, path: file.path), to: destination) { written in
          progress(Double(before + written) / total)
        }
        let written = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
        guard written == file.size else { throw URLError(.cannotDecodeContentData) }
      }
      done += file.size
      progress(Double(done) / total)
    }
    try JSONEncoder().encode(files).write(to: root.appending(path: SAMFiles.listingName), options: .atomic)
  }
}
