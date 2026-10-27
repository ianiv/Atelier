import AVFoundation
import Foundation
import ModelZoo
import NNC

/// A queued job that upscales a clip instead of generating: the request's model, size and seed
/// are the result's, and the frames come from the source clip when the job runs.
struct ClipUpscale: Codable, Sendable, Hashable {
  enum Method: String, Codable, Sendable, CaseIterable {
    /// SeedVR2, restoring many frames at once (`SeedVR2Restorer`).
    case seedVR2
    /// Apple's video super resolution (`SystemSuperResolution`).
    case system
  }

  var method: Method
  var scale: Int
  /// The source clip (its first frame's image tensor).
  var sourceTensorId: Int64
  /// Only the source's first frames, for scripted checks; nil for the whole clip.
  var frameLimit: Int?

  static let scales = [2, 4]
  /// SeedVR2's largest output, in pixels per frame: 1920×1088. Its encoder can't tile, and past
  /// this its full-size features (7 padded frames of 128 channels) overflow NNC's 32-bit sizes.
  static let seedVR2PixelLimit = 1920 * 1088

  static func isSeedVR2(_ model: String) -> Bool {
    let version = ModelZoo.versionForModel(model)
    return version == .seedvr2_3b || version == .seedvr2_7b
  }

  /// The result's size for a `width`×`height` clip. SeedVR2 works in 16-pixel blocks.
  static func outputSize(width: Int, height: Int, scale: Int, method: Method) -> (width: Int, height: Int) {
    switch method {
    case .system: (width * scale, height * scale)
    case .seedVR2: (width * scale / 16 * 16, height * scale / 16 * 16)
    }
  }

  /// The scales `method` can upscale a `width`×`height` clip by: what Apple's model supports on
  /// this device, or SeedVR2's that fit its output limit.
  static func offeredScales(width: Int, height: Int, method: Method) -> [Int] {
    switch method {
    case .system:
      SystemSuperResolution.scaleFactors(width: width, height: height)
    case .seedVR2:
      scales.filter { scale in
        let size = outputSize(width: width, height: height, scale: scale, method: method)
        return size.width * size.height <= seedVR2PixelLimit
      }
    }
  }

  /// Why `method` can't upscale a `width`×`height` clip by `scale`; nil when it can.
  static func problem(width: Int, height: Int, scale: Int, method: Method) -> String? {
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
    case .seedVR2:
      let size = outputSize(width: width, height: height, scale: scale, method: method)
      guard size.width * size.height <= seedVR2PixelLimit else {
        return offeredScales(width: width, height: height, method: method).isEmpty
          ? "SeedVR2 makes clips up to 1920×1088, so this one is too large to upscale."
          : "SeedVR2 makes clips up to 1920×1088; pick a smaller scale."
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
