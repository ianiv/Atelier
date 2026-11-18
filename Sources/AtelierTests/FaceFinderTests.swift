@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// Vision's coordinates (0…1 from the bottom left) into image pixels from the top left
/// (`FaceFinder`), for a whole image and for a part of it that was searched on its own.
@Suite(.tags(.smoke))
struct FaceFinderTests {
  private static let size = CGSize(width: 400, height: 200)

  @Test func rectsFlipToCountDown() {
    // A quarter up from the bottom in Vision is a quarter down from the top here.
    let rect = FaceFinder.imageRect(normalized: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), imageSize: Self.size)
    #expect(rect == CGRect(x: 100, y: 50, width: 200, height: 50))
    #expect(FaceFinder.imageRect(normalized: CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: Self.size) == CGRect(origin: .zero, size: Self.size))
    #expect(FaceFinder.imageRect(normalized: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), imageSize: Self.size) == CGRect(x: 0, y: 100, width: 200, height: 100))
  }

  @Test func pointsFlipToCountDown() {
    #expect(FaceFinder.imagePoint(normalized: CGPoint(x: 0.5, y: 0.25), imageSize: Self.size) == CGPoint(x: 200, y: 150))
    #expect(FaceFinder.imagePoint(normalized: CGPoint(x: 0, y: 1), imageSize: Self.size) == .zero)
    // A landmark's point is within its face's rectangle: (0, 0) its bottom left, (1, 1) its top right.
    let box = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
    #expect(FaceFinder.imagePoint(normalized: .zero, in: box, imageSize: Self.size) == CGPoint(x: 100, y: 100))
    #expect(FaceFinder.imagePoint(normalized: CGPoint(x: 1, y: 1), in: box, imageSize: Self.size) == CGPoint(x: 300, y: 50))
    #expect(FaceFinder.imagePoint(normalized: CGPoint(x: 0.5, y: 0.5), in: box, imageSize: Self.size) == CGPoint(x: 200, y: 75))
  }

  @Test func aSearchedRegionMovesBackIntoTheImage() {
    // The part searched was 400×200 with its top left at (1000, 300) of the whole image.
    let origin = CGPoint(x: 1000, y: 300)
    let box = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
    #expect(FaceFinder.imageRect(normalized: box, imageSize: Self.size, origin: origin) == CGRect(x: 1100, y: 350, width: 200, height: 50))
    #expect(FaceFinder.imagePoint(normalized: .zero, in: box, imageSize: Self.size, origin: origin) == CGPoint(x: 1100, y: 400))
    // The points stay inside their face's box.
    let rect = FaceFinder.imageRect(normalized: box, imageSize: Self.size, origin: origin)
    let point = FaceFinder.imagePoint(normalized: CGPoint(x: 0.3, y: 0.9), in: box, imageSize: Self.size, origin: origin)
    #expect(rect.contains(point))
  }

  @Test func aRegionOutsideTheImageHasNoFaces() throws {
    let image = try #require(CreateModel.blankImage(width: 64, height: 64))
    #expect(try FaceFinder.faces(in: image, region: CGRect(x: 100, y: 100, width: 50, height: 50)).isEmpty)
  }
}
