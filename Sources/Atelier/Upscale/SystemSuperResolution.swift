import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Upscales a clip with the system's video super resolution model (VideoToolbox's
/// `VTSuperResolutionScaler`), the Fast method. It runs on the Neural Engine and takes each frame
/// with the one before it and that frame's result, so detail stays steady from frame to frame.
/// macOS downloads the model the first time it's used.
enum SystemSuperResolution {
  enum Failure: LocalizedError {
    case unsupported, scale(Int), tooLarge(Int, Int), noBuffer

    var errorDescription: String? {
      switch self {
      case .unsupported: "This device doesn't support Apple Super Resolution."
      case .scale(let scale): "Apple Super Resolution can't scale by \(scale)×."
      case .tooLarge(let width, let height):
        "Apple Super Resolution takes clips up to \(width)×\(height)."
      case .noBuffer: "Couldn't prepare a frame for Apple Super Resolution."
      }
    }
  }

  /// The largest input frame the model takes for video.
  static var maximumInput: (width: Int, height: Int) {
    #if os(macOS)
      (1920, 1080)
    #else
      (1440, 1080)
    #endif
  }

  static var isSupported: Bool { VTSuperResolutionScalerConfiguration.isSupported }

  /// Scale factors the model offers for a `width`×`height` input; empty when it can't take it.
  static func scaleFactors(width: Int, height: Int) -> [Int] {
    guard isSupported, fits(width: width, height: height) else { return [] }
    return VTSuperResolutionScalerConfiguration.supportedScaleFactors
  }

  static func fits(width: Int, height: Int) -> Bool {
    let limit = maximumInput
    // Either orientation.
    return (width <= limit.width && height <= limit.height)
      || (width <= limit.height && height <= limit.width)
  }

  /// Upscales `count` frames of `width`×`height`, each read with `frame(i)`, by `scale`.
  /// `progress(done, total, image)` follows each frame (`done` 0 while the model downloads).
  static func run(
    count: Int, width: Int, height: Int, scale: Int, frame: (Int) -> CGImage?,
    progress: @escaping (Int, Int, CGImage?) -> Void
  ) async throws -> [CGImage] {
    let scaler = try await Scaler(width: width, height: height, scale: scale) {
      progress(0, count, nil)
    }
    var results: [CGImage] = []
    for index in 0..<count {
      try Task.checkCancellation()
      guard let image = frame(index) else { throw ProjectError.badImage }
      let result = try await scaler.next(image)
      results.append(result)
      progress(index + 1, count, result)
    }
    return results
  }

  /// Upscales frames one at a time, in order: each goes in with the frame before it and that
  /// frame's result, so detail stays steady. Holds only those two besides the one in hand.
  final class Scaler {
    let outputWidth: Int
    let outputHeight: Int
    private let processor = VTFrameProcessor()
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    private let transfer: VTPixelTransferSession
    private var previous: VTFrameProcessorFrame?
    private var previousOutput: VTFrameProcessorFrame?
    private var index = 0

    /// `downloading` is called before macOS downloads the model, the first time it's used.
    init(width: Int, height: Int, scale: Int, downloading: () -> Void = {}) async throws {
      guard SystemSuperResolution.isSupported else { throw Failure.unsupported }
      guard SystemSuperResolution.fits(width: width, height: height) else {
        throw Failure.tooLarge(maximumInput.width, maximumInput.height)
      }
      guard VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(scale) else {
        throw Failure.scale(scale)
      }
      guard
        let configuration = VTSuperResolutionScalerConfiguration(
          frameWidth: width, frameHeight: height, scaleFactor: scale, inputType: .video,
          usePrecomputedFlow: false, qualityPrioritization: .normal,
          revision: VTSuperResolutionScalerConfiguration.defaultRevision)
      else { throw Failure.unsupported }
      if configuration.configurationModelStatus != .ready {
        downloading()
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          configuration.downloadConfigurationModel { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
          }
        }
      }
      outputWidth = width * scale
      outputHeight = height * scale
      sourcePool = try pool(configuration.sourcePixelBufferAttributes, width: width, height: height)
      destinationPool = try pool(
        configuration.destinationPixelBufferAttributes, width: outputWidth, height: outputHeight)
      transfer = try transferSession()
      try processor.startSession(configuration: configuration)
    }

    deinit { processor.endSession() }

    /// The next frame's result, in the model's pixel format. `frame` is any format the system
    /// converts from (the model's size); its alpha comes out NaN.
    func next(_ frame: CVPixelBuffer) async throws -> CVPixelBuffer {
      let source = try buffer(from: sourcePool)
      guard VTPixelTransferSessionTransferImage(transfer, from: frame, to: source) == noErr else {
        throw Failure.noBuffer
      }
      return try await process(source)
    }

    /// The next frame's result as an image.
    func next(_ image: CGImage) async throws -> CGImage {
      let source = try buffer(from: sourcePool)
      try draw(image, into: source, transfer: transfer)
      let destination = try await process(source)
      guard let result = try cgImage(from: destination, transfer: transfer) else {
        throw Failure.noBuffer
      }
      return result
    }

    /// Converts a result into `buffer` (BGRA for a video writer, say).
    func copy(_ result: CVPixelBuffer, into buffer: CVPixelBuffer) throws {
      guard VTPixelTransferSessionTransferImage(transfer, from: result, to: buffer) == noErr else {
        throw Failure.noBuffer
      }
    }

    private func process(_ source: CVPixelBuffer) async throws -> CVPixelBuffer {
      let time = CMTime(value: CMTimeValue(index), timescale: 30)
      index += 1
      let destination = try buffer(from: destinationPool)
      guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time),
            let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: time),
            let parameters = VTSuperResolutionScalerParameters(
              sourceFrame: sourceFrame, previousFrame: previous, previousOutputFrame: previousOutput,
              opticalFlow: nil, submissionMode: previous == nil ? .random : .sequential,
              destinationFrame: destinationFrame)
      else { throw Failure.noBuffer }
      try await processor.process(parameters: parameters)
      previous = sourceFrame
      previousOutput = destinationFrame
      return destination
    }
  }

  // MARK: - Pixel buffers

  private static func pool(_ attributes: [String: Any], width: Int, height: Int) throws
    -> CVPixelBufferPool
  {
    var attributes = attributes
    attributes[kCVPixelBufferWidthKey as String] = width
    attributes[kCVPixelBufferHeightKey as String] = height
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    guard let pool else { throw Failure.noBuffer }
    return pool
  }

  private static func buffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else { throw Failure.noBuffer }
    return buffer
  }

  private static func transferSession() throws -> VTPixelTransferSession {
    var session: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
    guard let session else { throw Failure.noBuffer }
    return session
  }

  private static func bgraBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    CVPixelBufferCreate(
      nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    guard let buffer else { throw Failure.noBuffer }
    return buffer
  }

  /// Draws `image` into a BGRA buffer, then converts it into `buffer`'s format and size.
  private static func draw(
    _ image: CGImage, into buffer: CVPixelBuffer, transfer: VTPixelTransferSession
  ) throws {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bgra = try bgraBuffer(width: width, height: height)
    CVPixelBufferLockBaseAddress(bgra, [])
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(bgra), width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    context?.interpolationQuality = .high
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    CVPixelBufferUnlockBaseAddress(bgra, [])
    guard context != nil, VTPixelTransferSessionTransferImage(transfer, from: bgra, to: buffer) == noErr
    else { throw Failure.noBuffer }
  }

  private static func cgImage(from buffer: CVPixelBuffer, transfer: VTPixelTransferSession) throws
    -> CGImage?
  {
    let bgra = try bgraBuffer(
      width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    guard VTPixelTransferSessionTransferImage(transfer, from: buffer, to: bgra) == noErr else {
      throw Failure.noBuffer
    }
    // The video model leaves alpha NaN (it comes out 0 in BGRA), so read the buffer as opaque.
    // Copied out: an image drawn from the buffer's memory goes blank once the buffer is reused.
    CVPixelBufferLockBaseAddress(bgra, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
    let width = CVPixelBufferGetWidth(bgra)
    let height = CVPixelBufferGetHeight(bgra)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(bgra)
    guard let base = CVPixelBufferGetBaseAddress(bgra),
          let provider = CGDataProvider(data: Data(bytes: base, count: bytesPerRow * height) as CFData)
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
