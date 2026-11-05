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
  /// 2 or 4, or `maxScale`. A model scales its result to fit, whatever its own scale is
  /// (`RealESRGANer`'s forced scale factor).
  var scale: Int

  /// The largest size the upscaler allows at the image's shape, for those with a limit.
  static let maxScale = 0

  /// The result's size for a `width`×`height` image.
  func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
    if scale == Self.maxScale, let limit = sizeLimit {
      return Self.fitted(width: width, height: height, pixels: limit.pixels, grid: limit.grid)
    }
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

  /// SeedVR2's largest result, in pixels: 5888×5888 passed 76 GB of memory on a real run.
  static let seedVR2PixelLimit = 2944 * 2944

  /// The upscaler's limit on its result and the grid its sizes keep to; nil when it has no limit
  /// or, for Apple's, only takes fixed scales.
  var sizeLimit: (pixels: Int, grid: Int, description: String)? {
    switch upscaler {
    case .seedVR2: (Self.seedVR2PixelLimit, 64, "SeedVR2 goes up to 2944 × 2944")
    case .video(.flashVSR, _): (ClipUpscale.flashVSRPixelLimit, 128, "FlashVSR+ goes up to 1920 × 1152")
    case .model, .video(.system, _): nil
    }
  }

  /// The scales to offer for a `width`×`height` image, Max last.
  func scales(width: Int, height: Int) -> [Int] {
    if case .video(.system, _) = upscaler {
      return ClipUpscale.offeredScales(width: width, height: height, method: .system)
    }
    return Self.scales + (sizeLimit == nil ? [] : [Self.maxScale])
  }

  /// The largest size of `width`×`height`'s shape within `pixels`, in multiples of `grid`.
  static func fitted(width: Int, height: Int, pixels: Int, grid: Int) -> (width: Int, height: Int) {
    let fit = (Double(pixels) / Double(max(width * height, 1))).squareRoot()
    func side(_ value: Int) -> Int { max(Int(Double(value) * fit / Double(grid)), 1) * grid }
    return (side(width), side(height))
  }

  /// Why this can't upscale a `width`×`height` image; nil when it can.
  func problem(width: Int, height: Int) -> String? {
    if case .video(let method, let variant) = upscaler {
      if method == .flashVSR, FlashVSRFiles.installed(variant ?? .turbo) == nil {
        return "Download FlashVSR+ \((variant ?? .turbo).title) to use it."
      }
      if method == .system {
        return ClipUpscale.problem(width: width, height: height, scale: scale, method: method)
      }
    }
    guard let limit = sizeLimit else { return nil }
    let size = outputSize(width: width, height: height)
    if scale == Self.maxScale {
      return size.width * size.height > width * height ? nil : "This image is already at \(limit.description)'s limit."
    }
    return size.width * size.height > limit.pixels ? "\(limit.description). Choose Max for the largest it can make." : nil
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
