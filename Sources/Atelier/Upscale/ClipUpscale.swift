import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import ModelZoo
@preconcurrency import NNC

/// A queued job that upscales an image instead of generating: the request's canvas is the image,
/// and its size the result's. It always runs on this device, whose models these are.
nonisolated struct ImageUpscale: Codable, Sendable, Hashable {
  enum Upscaler: Codable, Sendable, Hashable {
    /// One of the engine's ESRGAN models, by file.
    case model(String)
    /// A video upscaler, with the image as a clip of one frame.
    case video(ClipUpscale.Method, FlashVSRFiles.Variant?)
    /// A SeedVR2 model, by file: a one-step run of the engine on the image stretched to size.
    case seedVR2(String)
  }

  var upscaler: Upscaler
  /// 2 or 4. A model scales its result to fit, whatever its own scale is (`RealESRGANer`'s forced
  /// scale factor).
  var scale: Int

  /// The result's size for a `width`×`height` image.
  func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
    switch upscaler {
    case .model: return (width * scale, height * scale)
    case .video(let method, _):
      return ClipUpscale.outputSize(width: width, height: height, scale: scale, method: method)
    case .seedVR2:
      // The engine generates in multiples of 64.
      func snapped(_ side: Int) -> Int { max(Int((Double(side * scale) / 64).rounded()), 1) * 64 }
      return (snapped(width), snapped(height))
    }
  }

  /// `image` stretched to exactly `width`×`height`: SeedVR2 restores what it's given at its size.
  static func stretched(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  /// The SeedVR2 models among `files`, which are the model folder's.
  static func seedVR2Models(in files: [String]) -> [(file: String, name: String)] {
    files.filter { $0.hasPrefix("seedvr2_") && !$0.contains("_vae") }.sorted()
      .map { ($0, ModelZoo.humanReadableNameForModel($0)) }
  }

  static let scales = [4, 2]

  /// The upscaler models in the models folder. Not the settings' file-name match: that also finds
  /// LTX's spatial upscalers, which aren't for images.
  static var installed: [(file: String, name: String)] {
    UpscalerZoo.availableSpecifications
      .filter { UpscalerZoo.isModelDownloaded($0.file) }
      .map { ($0.file, $0.name) }
  }
}

/// A queued job that upscales a clip instead of generating: the request's size and seed are
/// the result's (its model stays the source's), and the frames come from the source clip when
/// the job runs.
nonisolated struct ClipUpscale: Codable, Sendable, Hashable {
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
