import Foundation
import Observation
import Synchronization

/// Downloads ReCaVSR's published files from Hugging Face into the models folder's "ReCaVSR",
/// one at a time, skipping ones already there at full size. One download at a time for the app.
/// Uses FlashVSR+'s downloader (`FlashVSRDownload.download`). Also makes the 8-bit copy, or
/// imports one.
@MainActor
@Observable
final class ReCaVSRDownload {
  static let shared = ReCaVSRDownload()

  private(set) var downloading = false
  /// Whether every published file is there, and whether the 8-bit copy is (made or imported,
  /// with or without the published transformer), as last looked (`refresh`).
  private(set) var isDownloaded = ReCaVSRFiles.downloaded
  private(set) var hasEightBitCopy = ReCaVSRFiles.hasEightBitCopy(in: ReCaVSRFiles.folder)

  /// Looks at the models folder again (it may have changed, or files been placed by hand).
  func refresh() {
    isDownloaded = ReCaVSRFiles.downloaded
    hasEightBitCopy = ReCaVSRFiles.hasEightBitCopy(in: ReCaVSRFiles.folder)
  }
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
    // An import fetches the prompt and the decoder itself; two writers would collide.
    guard task == nil, importing == nil else { return }
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
      refresh()
    }
  }

  func cancel() {
    task?.cancel()
  }

  // MARK: - 8-bit copy

  /// The 8-bit copy's progress, 0…1; nil when it isn't being written.
  private(set) var copying: Double?
  private(set) var copyFailure: String?
  private let stopCopy = StopFlag()

  private final nonisolated class StopFlag: Sendable {
    let value = Mutex(false)
  }

  /// The 8-bit copy's expected size, for the button.
  static let eightBitBytes: Int64 = 5_711_630_336

  /// Writes the 8-bit copy of the DiT beside it (`ReCaVSRQuantizer`), resuming one that was
  /// stopped.
  func makeEightBitCopy() {
    guard copying == nil, importing == nil, let files = ReCaVSRFiles.installed(.full) else { return }
    copying = 0
    copyFailure = nil
    stopCopy.value.withLock { $0 = false }
    let progress: @Sendable (Double) -> Void = { value in
      Task { @MainActor in
        guard ReCaVSRDownload.shared.copying != nil else { return }
        ReCaVSRDownload.shared.copying = value
      }
    }
    Task {
      do {
        let done = try await Self.quantize(files, progress: progress) { [stopCopy] in !stopCopy.value.withLock { $0 } }
        if done { refresh() }
      } catch {
        copyFailure = "Couldn't make ReCaVSR's 8-bit copy: \(error.localizedDescription)"
      }
      copying = nil
    }
  }

  /// Stops the copy; what's written is kept, and the next copy resumes it.
  func cancelEightBitCopy() {
    stopCopy.value.withLock { $0 = true }
  }

  @concurrent private nonisolated static func quantize(
    _ files: ReCaVSRFiles, progress: @escaping @Sendable (Double) -> Void,
    shouldContinue: @escaping @Sendable () -> Bool
  ) async throws -> Bool {
    try ReCaVSRQuantizer.quantize(files, progress: progress, shouldContinue: shouldContinue)
  }

  // MARK: - Importing an 8-bit copy

  /// An import's progress, 0…1; nil when nothing is being imported.
  private(set) var importing: Double?
  private(set) var importFailure: String?
  private var importTask: Task<Void, Never>?

  /// Brings in an 8-bit copy that's already somewhere else (`ReCaVSREightBitFile.importCopy`):
  /// checks it, copies it into the ReCaVSR folder and gets the prompt and the decoder if they're
  /// missing, so 8-bit runs work without downloading the published transformer. Not while the
  /// copy is being made or the files downloaded, which write the same files.
  func importEightBit(_ url: URL) {
    guard importing == nil, copying == nil, !downloading else { return }
    importing = 0
    importFailure = nil
    let folder = ReCaVSRFiles.folder
    let progress: @Sendable (Double) -> Void = { value in
      Task { @MainActor in
        guard ReCaVSRDownload.shared.importing != nil else { return }
        ReCaVSRDownload.shared.importing = value
      }
    }
    importTask = Task {
      do {
        try await ReCaVSREightBitFile.importCopy(of: url, into: folder, progress: progress)
      } catch let problem as ReCaVSREightBitFile.Problem {
        // These say what's wrong with the file by themselves.
        importFailure = problem.localizedDescription
      } catch {
        if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
          importFailure = "Couldn't import ReCaVSR's 8-bit copy: \(error.localizedDescription)"
        }
      }
      importing = nil
      importTask = nil
      refresh()
    }
  }

  /// Stops the import and removes what it copied so far.
  func cancelImport() {
    importTask?.cancel()
  }
}
