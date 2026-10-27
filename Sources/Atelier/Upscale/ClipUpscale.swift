import AVFoundation
import Foundation
import NNC

/// A queued job that upscales a clip instead of generating: the request's size and seed are
/// the result's (its model stays the source's), and the frames come from the source clip when
/// the job runs.
struct ClipUpscale: Codable, Sendable, Hashable {
  enum Method: String, Codable, Sendable, CaseIterable {
    /// FlashVSR+, restoring the clip as one stream (`FlashVSRUpscaler`).
    case flashVSR
    /// Apple's video super resolution (`SystemSuperResolution`).
    case system
  }

  var method: Method
  var scale: Int
  /// The source clip (its first frame's image tensor).
  var sourceTensorId: Int64
  /// Only the source's first frames, for scripted checks; nil for the whole clip.
  var frameLimit: Int?
  /// FlashVSR+'s variant; nil for Turbo.
  var variant: FlashVSRFiles.Variant?

  static let scales = [2, 4]
  /// FlashVSR+'s largest output, in pixels per frame: 1920×1152. Its wide layers' attention grows
  /// with the square of the size, so past this it takes minutes a frame.
  static let flashVSRPixelLimit = 1920 * 1152

  /// The result's size for a `width`×`height` clip. FlashVSR+ works on a 128-pixel grid.
  static func outputSize(width: Int, height: Int, scale: Int, method: Method) -> (width: Int, height: Int) {
    switch method {
    case .system: (width * scale, height * scale)
    case .flashVSR: FlashVSRUpscaler.outputSize(width: width, height: height, scale: scale)
    }
  }

  /// The scales `method` can upscale a `width`×`height` clip by: what Apple's model supports on
  /// this device, or FlashVSR+'s that fit its output limit.
  static func offeredScales(width: Int, height: Int, method: Method) -> [Int] {
    switch method {
    case .system:
      SystemSuperResolution.scaleFactors(width: width, height: height)
    case .flashVSR:
      scales.filter { scale in
        let size = outputSize(width: width, height: height, scale: scale, method: method)
        return size.width * size.height <= flashVSRPixelLimit
      }
    }
  }

  /// Why `method` can't upscale a `width`×`height` clip by `scale`; nil when it can.
  static func problem(
    width: Int, height: Int, scale: Int, method: Method, variant: FlashVSRFiles.Variant = .turbo
  ) -> String? {
    switch method {
    case .system:
      guard SystemSuperResolution.isSupported else { return "This device doesn't support Apple Super Resolution." }
      guard SystemSuperResolution.fits(width: width, height: height) else {
        let limit = SystemSuperResolution.maximumInput
        return "Apple Super Resolution takes clips up to \(limit.width)×\(limit.height)."
      }
      guard SystemSuperResolution.scaleFactors(width: width, height: height).contains(scale) else {
        return "Apple Super Resolution can't scale by \(scale)×."
      }
    case .flashVSR:
      guard FlashVSRFiles.installed(variant) != nil else {
        return "Download FlashVSR+ \(variant.title) to use Quality."
      }
      let size = outputSize(width: width, height: height, scale: scale, method: method)
      guard size.width * size.height <= flashVSRPixelLimit else {
        return offeredScales(width: width, height: height, method: method).isEmpty
          ? "FlashVSR+ makes videos up to 1920×1152, so this one is too large to upscale."
          : "FlashVSR+ makes videos up to 1920×1152; pick a smaller scale."
      }
    }
    return nil
  }

  /// `samples` ([channels, samples] PCM) at `target` Hz instead of `source`.
  static func resample(_ samples: Tensor<Float>, from source: Int, to target: Int) -> Tensor<Float> {
    let channels = samples.shape[0]
    let count = samples.shape[1]
    guard source != target, source > 0, target > 0, channels > 0, count > 0,
      let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(source),
        channels: AVAudioChannelCount(channels), interleaved: false),
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(target),
        channels: AVAudioChannelCount(channels), interleaved: false),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
      let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)),
      let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: AVAudioFrameCount(count * target / source + 1024)),
      let inputData = input.floatChannelData
    else { return samples }
    input.frameLength = AVAudioFrameCount(count)
    for channel in 0..<channels {
      for i in 0..<count { inputData[channel][i] = samples[channel, i] }
    }
    nonisolated(unsafe) var fed = false
    nonisolated(unsafe) let source = input
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if fed {
        status.pointee = .endOfStream
        return nil
      }
      fed = true
      status.pointee = .haveData
      return source
    }
    guard error == nil, let outputData = output.floatChannelData else { return samples }
    let length = Int(output.frameLength)
    var result = Tensor<Float>(.CPU, .WC(channels, length))
    for channel in 0..<channels {
      for i in 0..<length { result[channel, i] = outputData[channel][i] }
    }
    return result
  }
}
