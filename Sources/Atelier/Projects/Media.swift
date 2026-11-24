import AVFoundation
import CoreGraphics
import Foundation

/// Videos brought into a project from outside (dropped, Open Video…, Photos), kept as their own
/// files beside the project: `<Name>.sqlite3-media/<UUID>.<ext>`, moved and deleted with it. Copied
/// with `FileManager.copyItem`, which on APFS clones the file (no extra space until either copy
/// changes) and copies it across volumes. The project gets one step for the video, its first
/// frame as the image (an Imported step, listed like a generated one), with a `media` record in
/// its `profile_data` naming the file; Draw Things sees an imported image. Frames are decoded
/// from the file when they're needed (playback, a frame as input, a reference video).
nonisolated enum Media {
  /// What a step's `profile_data` keeps about its file.
  struct Record: Codable, Hashable, Sendable {
    /// The file's name in the media folder: `<UUID>.<ext>`.
    var file: String
    var bytes: Int64
    /// The name it came in under (without its extension), for History and exports.
    var name: String
    /// Upright (the track's transform applied), in pixels.
    var width: Int
    var height: Int
    var framesPerSecond: Double
    var frameCount: Int
    /// Seconds.
    var duration: Double
    var hasAudio: Bool

    /// Whether `file` is a name this app writes, so a damaged or hostile project can't point
    /// outside its media folder.
    var isSafeFileName: Bool { Media.isSafeFileName(file) }

    /// Whether it can stand for a video: a name this app writes, a size, a positive finite rate
    /// and length, at least one frame. A project file is untrusted; one that isn't is ignored
    /// (`ProjectMapping.Profile`).
    var isValid: Bool {
      isSafeFileName && width > 0 && height > 0 && frameCount >= 1 && bytes >= 0 && framesPerSecond.isFinite
        && framesPerSecond > 0 && duration.isFinite && duration >= 0
    }
  }

  /// A project's media folder.
  static func folder(forProject url: URL) -> URL {
    URL(fileURLWithPath: url.path + suffix, isDirectory: true)
  }

  /// What's added to the project file's path, as `-wal` and `-shm` are.
  static let suffix = "-media"

  /// The file a record names in the project at `projectURL`; nil for a name that isn't one this
  /// app writes.
  static func url(of record: Record, inProject projectURL: URL) -> URL? {
    guard record.isSafeFileName else { return nil }
    return folder(forProject: projectURL).appending(path: record.file, directoryHint: .notDirectory)
  }

  /// `<UUID>.<ext>`, the extension letters and digits only.
  static func isSafeFileName(_ name: String) -> Bool {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, (1...8).contains(parts[1].count) else { return false }
    return parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }

  /// A file still being copied in: renamed to its own name once whole.
  static let partialExtension = "partial"

  enum Failure: LocalizedError {
    /// The file is gone from the media folder, or isn't the file the record describes.
    case missing
    /// Not a video AVFoundation can read.
    case invalidVideo

    var errorDescription: String? {
      switch self {
      case .missing: "The video's file is missing from the project's media folder."
      case .invalidVideo: "The video couldn't be read."
      }
    }
  }

  /// What a video file is: its upright size, frame rate, length and sound.
  struct Inspection: Sendable, Equatable {
    var width: Int
    var height: Int
    var framesPerSecond: Double
    var frameCount: Int
    var duration: Double
    var hasAudio: Bool
  }

  @concurrent static func inspect(_ url: URL) async throws -> Inspection {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { throw Failure.invalidVideo }
    let (natural, turn, range, nominal) = try await track.load(.naturalSize, .preferredTransform, .timeRange, .nominalFrameRate)
    let box = CGRect(origin: .zero, size: natural).applying(turn)
    let width = Int(box.width.rounded()), height = Int(box.height.rounded())
    let duration = range.duration.seconds
    guard width > 0, height > 0, duration.isFinite, duration > 0 else { throw Failure.invalidVideo }
    // As `TimelineComposition.make(file:)`: a file with no nominal rate plays at 30.
    let rate = nominal.isFinite && nominal > 0 ? Double(nominal) : 30
    let frames = max(Int(min((duration * rate).rounded(), Double(Int32.max))), 1)
    let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
    return Inspection(width: width, height: height, framesPerSecond: rate, frameCount: frames, duration: duration, hasAudio: hasAudio)
  }

  /// A generator for `url`'s frames as the engine's CLI reads a video (`loadInputVideoTensor`):
  /// upright, at the exact time asked for, in SDR.
  static func generator(for url: URL) -> AVAssetImageGenerator {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.dynamicRangePolicy = .forceSDR
    return generator
  }

  /// The time frame `index` starts at, at `framesPerSecond`, on the CLI's 6000 timescale.
  static func time(ofFrame index: Int, framesPerSecond: Double) -> CMTime {
    CMTime(seconds: Double(index) / (framesPerSecond > 0 ? framesPerSecond : 30), preferredTimescale: 6_000)
  }

  /// Frame `index` of the video at `url`, upright, at its own size.
  @concurrent static func frame(_ index: Int, of url: URL, framesPerSecond: Double) async throws -> CGImage {
    do {
      return try await generator(for: url).image(at: time(ofFrame: index, framesPerSecond: framesPerSecond)).image
    } catch {
      throw FileManager.default.fileExists(atPath: url.path) ? Failure.invalidVideo : Failure.missing
    }
  }

  /// The files of deleted steps to remove: those no remaining step names (`named`), and only names
  /// this app writes.
  static func unnamed(deleted: Set<String>, named: Set<String>) -> [String] {
    deleted.subtracting(named).filter(isSafeFileName).sorted()
  }

  /// The media files no step names, and copies left half done, to remove: everything in the
  /// folder (`files`, names) that isn't `referenced`, except what's being copied in now
  /// (`inFlight`, final names, whose `.partial` copies stay too).
  static func orphans(files: [String], referenced: Set<String>, inFlight: Set<String>) -> [String] {
    files.filter { name in
      if name.hasPrefix(".") { return false }
      if name.hasSuffix("." + partialExtension) {
        return !inFlight.contains(String(name.dropLast(partialExtension.count + 1)))
      }
      return !referenced.contains(name) && !inFlight.contains(name)
    }
  }
}
