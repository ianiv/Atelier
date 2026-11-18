import CoreGraphics
import Foundation
import Vision

/// Finding faces with Apple Vision's landmark detector (`VNDetectFaceLandmarksRequest`), which
/// ships with the system like Select Subject's model (`SubjectMask`), so it needs no download.
/// For callers that fix a face without a person pointing at it: the box says where to put the
/// frame and the mask.
nonisolated enum FaceFinder {
  /// One face, in image pixels from the top left.
  struct Face: Sendable {
    /// Vision's face rectangle: about brow to chin, so the whole head needs padding around it.
    var box: CGRect
    var confidence: Float
    /// The head's tilt and turn in radians, when Vision gives them.
    var roll: Double?
    var yaw: Double?
    /// The outlines Vision found, by name: `left_eye`, `right_eye`, `nose`, `outer_lips`,
    /// `face_contour`. Left and right are the image's, as Vision names them.
    var landmarks: [String: [CGPoint]]
  }

  /// The faces in `image`, largest first. With `region` (image pixels from the top left) only that
  /// part is searched, at its own resolution, and the results are moved back into the whole
  /// image's pixels: Vision can miss a face that is a few percent of a large image.
  static func faces(in image: CGImage, region: CGRect? = nil) throws -> [Face] {
    var searched = image
    var origin = CGPoint.zero
    if let region {
      let crop = region.standardized.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard !crop.isNull, crop.width >= 1, crop.height >= 1, let cropped = image.cropping(to: crop) else { return [] }
      searched = cropped
      origin = crop.origin
    }
    let request = VNDetectFaceLandmarksRequest()
    try VNImageRequestHandler(cgImage: searched, options: [:]).perform([request])
    let size = CGSize(width: searched.width, height: searched.height)
    let faces = (request.results ?? []).map { observation in
      var landmarks: [String: [CGPoint]] = [:]
      let regions: [(String, VNFaceLandmarkRegion2D?)] = [
        ("left_eye", observation.landmarks?.leftEye), ("right_eye", observation.landmarks?.rightEye),
        ("nose", observation.landmarks?.nose), ("outer_lips", observation.landmarks?.outerLips),
        ("face_contour", observation.landmarks?.faceContour),
      ]
      for (name, region) in regions {
        guard let region, region.pointCount > 0 else { continue }
        // A landmark's points are normalized to its face's rectangle.
        landmarks[name] = region.normalizedPoints.map {
          imagePoint(normalized: $0, in: observation.boundingBox, imageSize: size, origin: origin)
        }
      }
      return Face(
        box: imageRect(normalized: observation.boundingBox, imageSize: size, origin: origin),
        confidence: observation.confidence, roll: observation.roll?.doubleValue, yaw: observation.yaw?.doubleValue,
        landmarks: landmarks)
    }
    return faces.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
  }

  /// A rectangle Vision gives (0…1 of the image searched, from its bottom left) in image pixels
  /// from the top left. `origin` is the searched part's top left in the whole image, when a
  /// region of it was searched.
  static func imageRect(normalized: CGRect, imageSize: CGSize, origin: CGPoint = .zero) -> CGRect {
    CGRect(
      x: normalized.minX * imageSize.width + origin.x, y: (1 - normalized.maxY) * imageSize.height + origin.y,
      width: normalized.width * imageSize.width, height: normalized.height * imageSize.height)
  }

  /// A point Vision gives, 0…1 of `box` from its bottom left (`box` itself normalized to the image
  /// searched, as a face's `boundingBox` is; by default the whole image), in image pixels from the
  /// top left. `origin` as for `imageRect`.
  static func imagePoint(
    normalized: CGPoint, in box: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: CGSize, origin: CGPoint = .zero
  ) -> CGPoint {
    let x = box.minX + normalized.x * box.width, y = box.minY + normalized.y * box.height
    return CGPoint(x: x * imageSize.width + origin.x, y: (1 - y) * imageSize.height + origin.y)
  }
}
