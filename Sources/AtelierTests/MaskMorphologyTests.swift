@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// Growing and shrinking a mask (`MaskMorphology`): a round element, exact distances, and an
/// image edge that a shrinking mask doesn't draw back from.
@Suite(.tags(.smoke))
struct MaskMorphologyTests {
  /// A `width` × `height` grid painted (with `value`) inside `rect`.
  private static func grid(width: Int, height: Int, rect: CGRect, value: UInt8 = 255) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height)
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) { bytes[y * width + x] = value }
    }
    return bytes
  }

  private static func count(_ bytes: [UInt8]) -> Int { bytes.count { $0 != 0 } }

  @Test func zeroIsTheSameMask() {
    let square = Self.grid(width: 16, height: 12, rect: CGRect(x: 3, y: 2, width: 5, height: 4), value: 7)
    let same = MaskMorphology.grown(square, width: 16, height: 12, by: 0)
    // Painted is anything but 0 going in, 255 coming out.
    #expect(same == Self.grid(width: 16, height: 12, rect: CGRect(x: 3, y: 2, width: 5, height: 4)))
    #expect(MaskMorphology.grown([UInt8](repeating: 0, count: 64), width: 8, height: 8, by: 3) == [UInt8](repeating: 0, count: 64))
    #expect(MaskMorphology.grown([], width: 0, height: 0, by: 3).isEmpty)
  }

  @Test func aGrownSquareHasRoundCorners() {
    let width = 80, height = 80, radius = 8
    let square = Self.grid(width: width, height: height, rect: CGRect(x: 30, y: 30, width: 20, height: 20))
    let grown = MaskMorphology.grown(square, width: width, height: height, by: radius)
    func painted(_ x: Int, _ y: Int) -> Bool { grown[y * width + x] != 0 }
    // Straight out from a side: exactly the radius.
    #expect(painted(22, 40) && !painted(21, 40) && painted(57, 40) && !painted(58, 40))
    #expect(painted(40, 22) && !painted(40, 21) && painted(40, 57) && !painted(40, 58))
    // Round the corner pixel (30, 30): within 8 of it, not the square a box element would give.
    #expect(painted(25, 24) && !painted(24, 24) && !painted(22, 22))
    // The square, a band along each side and a quarter disc at each corner: the 41 pixels (i, j),
    // both from 1, with i² + j² ≤ 64 (a square corner would have 64).
    #expect(Self.count(grown) == 20 * 20 + 4 * 20 * radius + 4 * 41)
    // Growing stops at the image's edge.
    let corner = Self.grid(width: 20, height: 20, rect: CGRect(x: 0, y: 0, width: 4, height: 4))
    let spread = MaskMorphology.grown(corner, width: 20, height: 20, by: 3)
    #expect(spread[0] == 255 && spread[6] == 255 && spread[7] == 0 && spread[6 * 20] == 255 && spread[7 * 20] == 0)
  }

  @Test func shrinkingUndoesGrowing() {
    let width = 120, height = 100
    let square = Self.grid(width: width, height: height, rect: CGRect(x: 40, y: 30, width: 35, height: 28))
    for radius in [1, 5, 12] {
      let grown = MaskMorphology.grown(square, width: width, height: height, by: radius)
      #expect(Self.count(grown) > Self.count(square))
      #expect(MaskMorphology.grown(grown, width: width, height: height, by: -radius) == square)
    }
    // One pixel off every side.
    let shrunk = MaskMorphology.grown(square, width: width, height: height, by: -1)
    #expect(shrunk == Self.grid(width: width, height: height, rect: CGRect(x: 41, y: 31, width: 33, height: 26)))
  }

  @Test func shrinkingCanLeaveNothing() throws {
    let square = Self.grid(width: 40, height: 40, rect: CGRect(x: 10, y: 10, width: 10, height: 10))
    #expect(Self.count(MaskMorphology.grown(square, width: 40, height: 40, by: -4)) == 4)
    #expect(Self.count(MaskMorphology.grown(square, width: 40, height: 40, by: -5)) == 0)
    let mask = CanvasMask(rects: [CGRect(x: 10, y: 10, width: 10, height: 10)])
    #expect(mask.grown(by: -5, width: 40, height: 40) == nil)
    #expect(CanvasMask().grown(by: 5, width: 40, height: 40) == nil)
    // What's left is one bitmap stroke painting the same pixels.
    let grown = try #require(mask.grown(by: 3, width: 40, height: 40))
    #expect(grown.mask.strokes.count == 1 && grown.mask.strokes[0].kind == .bitmap)
    #expect(grown.mask.coverage(width: 40, height: 40) == MaskMorphology.grown(square, width: 40, height: 40, by: 3))
    // It comes with the pixels it paints, and takes the mask's own when the caller has them.
    #expect(grown.coverage == MaskMorphology.grown(square, width: 40, height: 40, by: 3))
    #expect(mask.grown(by: 3, width: 40, height: 40, from: square)?.coverage == grown.coverage)
  }

  @Test func aMaskAtTheEdgeKeepsToIt() {
    // Outside the image counts as painted: only the sides inside it draw back.
    let width = 40, height = 60
    let band = Self.grid(width: width, height: height, rect: CGRect(x: 0, y: 20, width: 10, height: 20))
    let shrunk = MaskMorphology.grown(band, width: width, height: height, by: -3)
    #expect(shrunk == Self.grid(width: width, height: height, rect: CGRect(x: 0, y: 23, width: 7, height: 14)))
    // A mask of the whole image has no edge to shrink from.
    let whole = [UInt8](repeating: 255, count: width * height)
    #expect(MaskMorphology.grown(whole, width: width, height: height, by: -10) == whole)
  }
}
