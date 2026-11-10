import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Select Subject: Apple Vision's foreground instance mask (`VNGenerateForegroundInstanceMaskRequest`,
/// the subject lifting Photos uses), which ships with the system, so it needs no download. It
/// finds each separate subject; with a point, only the one under it.
nonisolated enum SubjectMask {
  enum Failure: LocalizedError {
    case noSubject, nothingAtPoint

    var errorDescription: String? {
      switch self {
      case .noSubject: "No subject found in the image."
      case .nothingAtPoint: "No subject there."
      }
    }
  }

  /// The subjects in `image` (or the one under `point`, image pixels from the top left), one byte
  /// per image pixel, top row first: 255 selected, 0 not.
  static func coverage(_ image: CGImage, at point: CGPoint? = nil) throws -> [UInt8] {
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.noSubject }
    var instances = observation.allInstances
    if let point {
      // The instance map is smaller than the image, labelled 0 for the background.
      let labels = observation.instanceMask
      guard let label = instanceLabel(labels, at: point, sourceSize: CGSize(width: image.width, height: image.height)),
            label != 0
      else { throw Failure.nothingAtPoint }
      instances = IndexSet(integer: label)
    }
    let mask = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
    return try coverage(of: mask, width: image.width, height: image.height)
  }

  /// The instance label at an image point, in Vision's one-byte instance map.
  private static func instanceLabel(_ buffer: CVPixelBuffer, at point: CGPoint, sourceSize: CGSize) -> Int? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer), width > 0, height > 0 else { return nil }
    let x = Int(point.x / sourceSize.width * Double(width)), y = Int(point.y / sourceSize.height * Double(height))
    guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
    let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
    return Int(row[x])
  }

  /// Vision's scaled mask (one float per pixel, 0…1, top row first) as bytes at the image's size
  /// (sampled nearest, should Vision's size differ), selected from half covered up.
  private static func coverage(of buffer: CVPixelBuffer, width: Int, height: Int) throws -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let maskWidth = CVPixelBufferGetWidth(buffer), maskHeight = CVPixelBufferGetHeight(buffer)
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
          maskWidth > 0, maskHeight > 0, let base = CVPixelBufferGetBaseAddress(buffer)
    else { throw Failure.noSubject }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let columns = (0..<width).map { min($0 * maskWidth / width, maskWidth - 1) }
    var coverage = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
      let row = base.advanced(by: min(y * maskHeight / height, maskHeight - 1) * bytesPerRow).assumingMemoryBound(to: Float.self)
      for x in 0..<width where row[columns[x]] >= 0.5 {
        coverage[y * width + x] = 255
      }
    }
    return coverage
  }
}
