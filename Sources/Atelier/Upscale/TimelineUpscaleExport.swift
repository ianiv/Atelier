import AVFoundation
import CoreGraphics
import CoreVideo
import DataModels
import Diffusion
import Foundation
import NNC

/// How Export Upscaled… makes a timeline larger.
struct TimelineUpscale: Sendable, Hashable {
  var method: ClipUpscale.Method
  var scale: Int
  /// The SeedVR2 checkpoint, for Quality.
  var seedVR2: String

  /// The export's size for a `width`×`height` timeline.
  func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
    ClipUpscale.outputSize(width: width, height: height, scale: scale, method: method)
  }

  /// A rough time for `frames` frames of `width`×`height`, in seconds, from an M5 Max: SeedVR2
  /// takes about 2.6 s per output megapixel, Apple Super Resolution with encoding about 0.04 s.
  func estimatedSeconds(frames: Int, width: Int, height: Int) -> Double {
    let size = outputSize(width: width, height: height)
    let megapixels = Double(size.width * size.height) / 1_000_000
    switch method {
    case .seedVR2: return Double(frames) * megapixels * 2.6
    case .system: return Double(frames) * (0.02 + megapixels * 0.04)
    }
  }
}

extension TimelineComposition {
  /// Writes it as Export does, but upscaled: the composed frames (after trims and crossfades)
  /// go through Apple Super Resolution one by one, or through SeedVR2 a run between hard cuts at
  /// a time, straight into the MP4, so no more than a few upscaled frames are held at once. The
  /// soundtrack is mixed as Export mixes it and put in unchanged. Runs in the engine's turn, so
  /// not alongside a generation. Cancelling the task stops it.
  func exportUpscaled(
    to url: URL, codec: VideoCodec, title: String, upscale: TimelineUpscale,
    engine: GenerationEngine, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let folder = URL.temporaryDirectory.appending(path: "upscale-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = folder.appending(path: "video.mp4")
    // Frames are most of the work; the sound and putting the two together, the rest.
    let frames = Double(max(frameCount, 1))
    try await engine.inTurn {
      switch upscale.method {
      case .system:
        try await writeWithSystemSuperResolution(
          to: video, codec: codec, scale: upscale.scale
        ) { progress(0.95 * Double($0) / frames) }
      case .seedVR2:
        let composition = self
        try await engine.onEngineQueue { shouldContinue in
          try composition.writeWithSeedVR2(
            to: video, codec: codec, upscale: upscale, shouldContinue: shouldContinue
          ) { progress(0.95 * Double($0) / frames) }
        }
      }
    }
    try Task.checkCancellation()
    let sound = folder.appending(path: "sound.m4a")
    let hasSound = try await writeSound(to: sound)
    try await combine(video: video, sound: hasSound ? sound : nil, to: url, title: title)
    progress(1)
  }

  // MARK: - Frames

  /// Apple Super Resolution, frame by frame in order, each with the one before.
  private func writeWithSystemSuperResolution(
    to url: URL, codec: VideoCodec, scale: Int, written: (Int) -> Void
  ) async throws {
    let scaler = try await SystemSuperResolution.Scaler(width: width, height: height, scale: scale)
    let reader = try ComposedFrames(self)
    let writer = try UpscaledVideoWriter(
      url: url, codec: codec, width: scaler.outputWidth, height: scaler.outputHeight)
    var count = 0
    do {
      while let (frame, time) = reader.next() {
        try Task.checkCancellation()
        let result = try await scaler.next(frame)
        let buffer = try writer.buffer()
        try scaler.copy(result, into: buffer)
        try writer.append(buffer, at: time)
        count += 1
        written(count)
      }
      try reader.finish()
      try writer.finish()
    } catch {
      writer.cancel()
      throw error
    }
  }

  /// SeedVR2, one run between hard cuts at a time, so a cut doesn't blur into the next shot.
  /// Runs on the engine's queue.
  private func writeWithSeedVR2(
    to url: URL, codec: VideoCodec, upscale: TimelineUpscale, shouldContinue: @escaping () -> Bool,
    written: (Int) -> Void
  ) throws {
    let size = upscale.outputSize(width: width, height: height)
    let reader = try ComposedFrames(self)
    let writer = try UpscaledVideoWriter(url: url, codec: codec, width: size.width, height: size.height)
    // The frame last read, which the restorer may ask for again (a chunk starts on the frame the
    // one before ended on); past the end, the last frame repeats.
    var last: (index: Int, image: CGImage)?
    func frame(_ index: Int) -> CGImage? {
      while (last?.index ?? -1) < index, let (buffer, _) = reader.next() {
        guard let image = Self.image(buffer) else { return nil }
        last = ((last?.index ?? -1) + 1, image)
      }
      return last?.image
    }
    var count = 0
    do {
      for run in Self.restorableRuns(runs) {
        let restorer = SeedVR2Restorer(
          model: upscale.seedVR2, width: size.width, height: size.height, seed: 0)
        try restorer.run(
          count: run.count, frame: { frame(run.lowerBound + $0) }, progress: { _, _, _ in },
          shouldContinue: shouldContinue
        ) { tensor in
          let buffer = try writer.buffer()
          Self.fill(buffer, with: tensor)
          try writer.append(buffer, at: Self.frameTime(count, framesPerSecond))
          count += 1
          written(count)
        }
      }
      try reader.finish()
      try writer.finish()
    } catch {
      writer.cancel()
      throw error
    }
  }

  /// `runs`, with ones too short for SeedVR2 (under 5 frames) joined to a neighbor.
  static func restorableRuns(_ runs: [Range<Int>]) -> [Range<Int>] {
    var joined: [Range<Int>] = []
    for run in runs {
      if let previous = joined.last, run.count < 5 || previous.count < 5 {
        joined[joined.count - 1] = previous.lowerBound..<run.upperBound
      } else {
        joined.append(run)
      }
    }
    return joined
  }

  /// A composed frame as an image of its own (the reader reuses its buffers).
  private static func image(_ buffer: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer),
      let provider = CGDataProvider(data: Data(bytes: base, count: bytesPerRow * height) as CFData)
    else { return nil }
    return CGImage(
      width: CVPixelBufferGetWidth(buffer), height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  /// Writes a `[1, height, width, 3]` tensor in [-1, 1] into a BGRA buffer of its size.
  private static func fill(_ buffer: CVPixelBuffer, with tensor: Tensor<FloatType>) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let width = min(CVPixelBufferGetWidth(buffer), tensor.shape[2])
    let height = min(CVPixelBufferGetHeight(buffer), tensor.shape[1])
    let tensorWidth = tensor.shape[2]
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    func byte(_ value: FloatType) -> UInt8 {
      let scaled: Float = (Float(value) + 1) * 127.5
      return UInt8(max(0, min(255, scaled.rounded())))
    }
    tensor.withUnsafeBytes { raw in
      let values = raw.bindMemory(to: FloatType.self)
      for y in 0..<height {
        let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
          let source = (y * tensorWidth + x) * 3
          row[x * 4] = byte(values[source + 2])
          row[x * 4 + 1] = byte(values[source + 1])
          row[x * 4 + 2] = byte(values[source])
          row[x * 4 + 3] = 255
        }
      }
    }
  }

  // MARK: - Sound and putting it together

  /// The soundtrack, mixed as Export mixes it; false when there's none.
  private func writeSound(to url: URL) async throws -> Bool {
    guard try await !composition.loadTracks(withMediaType: .audio).isEmpty,
      let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else { return false }
    session.audioMix = audioMix
    try await session.export(to: url, as: .m4a)
    return true
  }

  /// The upscaled video with the soundtrack, without encoding either again.
  private func combine(video: URL, sound: URL?, to url: URL, title: String) async throws {
    let combined = AVMutableComposition()
    let videoAsset = AVURLAsset(url: video)
    guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
      let track = combined.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { throw ClipVideoError.noFrames }
    let videoRange = try await videoTrack.load(.timeRange)
    try track.insertTimeRange(videoRange, of: videoTrack, at: .zero)
    if let sound {
      let soundAsset = AVURLAsset(url: sound)
      if let soundTrack = try await soundAsset.loadTracks(withMediaType: .audio).first,
        let track = combined.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      {
        let range = try await soundTrack.load(.timeRange).intersection(videoRange)
        try track.insertTimeRange(range, of: soundTrack, at: .zero)
      }
    }
    guard
      let session = AVAssetExportSession(asset: combined, presetName: AVAssetExportPresetPassthrough)
    else { throw ClipVideoError.cantWrite }
    let name = AVMutableMetadataItem()
    name.identifier = .iTunesMetadataSongName
    name.value = title as NSString
    session.metadata = [name]
    try? FileManager.default.removeItem(at: url)
    try await session.export(to: url, as: .mp4)
  }
}

/// The timeline's frames as it plays them, in order, as BGRA at its size.
private final class ComposedFrames {
  private let reader: AVAssetReader
  private let output: AVAssetReaderVideoCompositionOutput

  init(_ timeline: TimelineComposition) throws {
    reader = try AVAssetReader(asset: timeline.composition)
    let tracks = timeline.composition.tracks(withMediaType: .video)
    output = AVAssetReaderVideoCompositionOutput(
      videoTracks: tracks,
      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
    output.videoComposition = timeline.videoComposition
    guard reader.canAdd(output) else { throw ClipVideoError.cantWrite }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? ClipVideoError.cantWrite }
  }

  /// The next frame and when it plays; nil at the end.
  func next() -> (CVPixelBuffer, CMTime)? {
    guard let sample = output.copyNextSampleBuffer(), let buffer = sample.imageBuffer else {
      return nil
    }
    return (buffer, sample.presentationTimeStamp)
  }

  func finish() throws {
    if reader.status == .failed { throw reader.error ?? ClipVideoError.cantWrite }
  }
}

/// A silent MP4 at the upscaled size, written a frame at a time.
private final class UpscaledVideoWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor

  init(url: URL, codec: VideoCodec, width: Int, height: Int) throws {
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: ClipVideo.videoSettings(codec, width: width, height: height))
    input.expectsMediaDataInRealTime = false
    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      ])
    guard writer.canAdd(input) else { throw ClipVideoError.cantWrite }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? ClipVideoError.cantWrite }
    writer.startSession(atSourceTime: .zero)
  }

  /// A BGRA buffer to fill with the next frame.
  func buffer() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    guard let pool = adaptor.pixelBufferPool,
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer
    else { throw writer.error ?? ClipVideoError.cantWrite }
    return buffer
  }

  /// Appends a frame, waiting for the encoder to take it.
  func append(_ buffer: CVPixelBuffer, at time: CMTime) throws {
    while !input.isReadyForMoreMediaData {
      guard writer.status == .writing else { throw writer.error ?? ClipVideoError.cantWrite }
      usleep(2_000)
    }
    guard adaptor.append(buffer, withPresentationTime: time) else {
      throw writer.error ?? ClipVideoError.cantWrite
    }
  }

  func finish() throws {
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? ClipVideoError.cantWrite }
  }

  func cancel() {
    writer.cancelWriting()
  }
}
