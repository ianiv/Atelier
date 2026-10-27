import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import NNC

/// The codec clips are written with (Settings ▸ General).
enum VideoCodec: String, CaseIterable, Identifiable {
  case h264, hevc

  var id: String { rawValue }

  var title: String {
    switch self {
    case .h264: "H.264"
    case .hevc: "HEVC"
    }
  }

  static let key = "videoCodec"
  static var current: VideoCodec {
    UserDefaults.standard.string(forKey: key).flatMap(VideoCodec.init(rawValue:)) ?? .h264
  }
}

/// Writes a clip as an MP4: its frames, its soundtrack as AAC, and its settings as metadata in
/// the iTunes tags MP4 files carry (QuickTime's own keys are only kept in .mov). After the engine
/// CLI's `writeVideo` (Apps/DrawThingsCLI).
enum ClipVideo {

  struct Metadata {
    /// Draw Things' summary of the prompt and settings, as an image's description.
    var description: String
    /// The history sidecar as JSON, in the comment tag (like the `Atelier` chunk in PNGs).
    var settings: String?
  }

  /// Writes `count` frames, each from `frame(i)` (all one size), at `framesPerSecond`, with
  /// `audio` (PCM in [channels, samples] order) at `audioSampleRate`.
  static func write(
    to url: URL, count: Int, frame: @escaping @Sendable (Int) -> CGImage?, framesPerSecond: Double,
    audio: Tensor<Float>?, audioSampleRate: Int, codec: VideoCodec, metadata: Metadata?
  ) async throws {
    guard count > 0, let first = frame(0) else { throw ClipVideoError.noFrames }
    let width = first.width, height = first.height
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    if let metadata { writer.metadata = items(for: metadata) }
    let video = AVAssetWriterInput(
      mediaType: .video, outputSettings: videoSettings(codec, width: width, height: height))
    video.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: video,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.canAdd(video) else { throw ClipVideoError.cantWrite }
    writer.add(video)
    let samples = audio.flatMap { $0.shape.count == 2 && $0.shape[1] > 0 ? $0 : nil }
    var sound: AVAssetWriterInput?
    if samples != nil, audioSampleRate > 0 {
      let input = AVAssetWriterInput(
        mediaType: .audio, outputSettings: audioSettings(sampleRate: Double(audioSampleRate)))
      input.expectsMediaDataInRealTime = false
      if writer.canAdd(input) {
        writer.add(input)
        sound = input
      }
    }
    guard writer.startWriting() else { throw writer.error ?? ClipVideoError.cantWrite }
    writer.startSession(atSourceTime: .zero)

    let frameDuration = Self.frameDuration(framesPerSecond)
    let queue = DispatchQueue(label: "Atelier.ClipVideo")
    let state = WriteState()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      state.onDone = { error in
        if let error {
          writer.cancelWriting()
          continuation.resume(throwing: error)
        } else {
          writer.finishWriting {
            if writer.status == .completed {
              continuation.resume()
            } else {
              continuation.resume(throwing: writer.error ?? ClipVideoError.cantWrite)
            }
          }
        }
      }
      state.pending = sound == nil ? 1 : 2
      var index = 0
      video.requestMediaDataWhenReady(on: queue) {
        while video.isReadyForMoreMediaData, !state.isDone {
          guard index < count else {
            video.markAsFinished()
            state.finishOne()
            return
          }
          guard let pool = adaptor.pixelBufferPool, let image = index == 0 ? first : frame(index),
            let buffer = pixelBuffer(image, pool: pool),
            adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index)))
          else {
            state.fail(writer.error ?? ClipVideoError.cantWrite)
            return
          }
          index += 1
        }
      }
      if let sound, let samples {
        let total = samples.shape[1]
        var offset = 0
        sound.requestMediaDataWhenReady(on: queue) {
          while sound.isReadyForMoreMediaData, !state.isDone {
            guard offset < total else {
              sound.markAsFinished()
              state.finishOne()
              return
            }
            let chunk = min(1024, total - offset)
            guard
              let buffer = sampleBuffer(
                samples, offset: offset, count: chunk, sampleRate: Double(audioSampleRate)),
              sound.append(buffer)
            else {
              state.fail(writer.error ?? ClipVideoError.cantWrite)
              return
            }
            offset += chunk
          }
        }
      }
    }
  }

  /// The settings an Atelier video carries (its comment, when that's a sidecar), read off the
  /// main actor.
  static func settings(at url: URL) async -> String? {
    let asset = AVURLAsset(url: url)
    guard let items = try? await asset.load(.metadata) else { return nil }
    for item in items where item.identifier == .iTunesMetadataUserComment {
      if let value = try? await item.load(.stringValue), value.hasPrefix("{") { return value }
    }
    return nil
  }

  /// A video's first frame.
  static func firstFrame(at url: URL) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    return try? await generator.image(at: .zero).image
  }

  // MARK: - Writing

  private static func items(for metadata: Metadata) -> [AVMetadataItem] {
    func item(_ identifier: AVMetadataIdentifier?, _ value: String) -> AVMetadataItem {
      let item = AVMutableMetadataItem()
      item.identifier = identifier
      item.value = value as NSString
      item.dataType = kCMMetadataBaseDataType_UTF8 as String
      return item
    }
    var items = [
      item(.iTunesMetadataDescription, metadata.description),
      item(.iTunesMetadataEncodingTool, "Atelier"),
    ]
    if let settings = metadata.settings { items.append(item(.iTunesMetadataUserComment, settings)) }
    return items
  }

  private static func videoSettings(_ codec: VideoCodec, width: Int, height: Int) -> [String: Any] {
    switch codec {
    case .h264:
      [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: max(9_500_000, width * height * 5),
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoMaxKeyFrameIntervalKey: 30,
        ],
      ]
    case .hevc:
      [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: max(7_500_000, width * height * 4),
          AVVideoMaxKeyFrameIntervalKey: 30,
        ],
      ]
    }
  }

  /// AAC at the nearest standard rate at or above the model's (encoders take only those).
  private static func audioSettings(sampleRate: Double) -> [String: Any] {
    let rates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
    let rate = rates.first { $0 >= sampleRate } ?? 48_000
    return [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: 2,
      // AAC caps the bit rate per sample rate: stereo at 24 kHz takes up to 128 kbps, not 6× the
      // rate, and fails to encode past it.
      AVEncoderBitRateKey: min(192_000, Int(rate) * 16 / 3),
    ]
  }

  private static func frameDuration(_ framesPerSecond: Double) -> CMTime {
    guard framesPerSecond > 0 else { return CMTime(value: 1, timescale: 30) }
    if abs(framesPerSecond - framesPerSecond.rounded()) < 1e-9 {
      return CMTime(value: 1, timescale: Int32(framesPerSecond.rounded()))
    }
    return CMTime(value: Int64((60_000 / framesPerSecond).rounded()), timescale: 60_000)
  }

  private static func pixelBuffer(_ image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer
    else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }

  /// Interleaved stereo float PCM; mono plays on both channels.
  private static func sampleBuffer(
    _ audio: Tensor<Float>, offset: Int, count: Int, sampleRate: Double
  ) -> CMSampleBuffer? {
    let channels = audio.shape[0]
    var interleaved = [Float32](repeating: 0, count: count * 2)
    for i in 0..<count {
      interleaved[i * 2] = max(-1, min(1, audio[0, offset + i]))
      interleaved[i * 2 + 1] = max(-1, min(1, audio[min(1, channels - 1), offset + i]))
    }
    let byteCount = interleaved.count * MemoryLayout<Float32>.size
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: byteCount, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
      let block,
      interleaved.withUnsafeBytes({
        CMBlockBufferReplaceDataBytes(
          with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
      }) == kCMBlockBufferNoErr
    else { return nil }
    var format = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
      mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
      mReserved: 0)
    var description: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &description) == noErr,
      let description
    else { return nil }
    var buffer: CMSampleBuffer?
    guard
      CMAudioSampleBufferCreateWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
        sampleCount: count,
        presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)),
        packetDescriptions: nil, sampleBufferOut: &buffer) == noErr
    else { return nil }
    return buffer
  }
}

/// Tracks the video and audio inputs finishing, on the writer's queue.
private final class WriteState: @unchecked Sendable {
  var pending = 0
  var isDone = false
  var onDone: ((Error?) -> Void)?

  func finishOne() {
    pending -= 1
    if pending == 0, !isDone {
      isDone = true
      onDone?(nil)
    }
  }

  func fail(_ error: Error) {
    guard !isDone else { return }
    isDone = true
    onDone?(error)
  }
}

enum ClipVideoError: LocalizedError {
  case noFrames
  case cantWrite

  var errorDescription: String? {
    switch self {
    case .noFrames: "The clip has no frames."
    case .cantWrite: "The video couldn't be written."
    }
  }
}
