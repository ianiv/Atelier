@testable import Atelier
import Foundation
import Testing

/// Heal strokes as a step keeps them (`Edit.HealStrokes`, `Edit.StoredHeal`): the binary
/// encoding, its digest and its size.
@Suite(.tags(.smoke))
struct HealStrokesTests {
  private static func strokes(_ count: Int, points: Int) -> Edit.HealStrokes {
    Edit.HealStrokes(strokes: (0..<count).map { index in
      Edit.HealStroke(
        points: (0..<points).map { SIMD2(Float(index) * 3.25 + Float($0), Float($0) * 0.5 - 7) },
        radius: 8 + Float(index % 5), offset: SIMD2(Float(index) - 40.5, 12.25), feather: 0.25 + Float(index % 3) / 10,
        band: UInt8(index % 2))
    })
  }

  @Test func encodingRoundTrips() throws {
    let original = Self.strokes(7, points: 5)
    let decoded = try #require(Edit.HealStrokes(encoded: original.encoded))
    #expect(decoded == original)
    #expect(Edit.HealStrokes(encoded: Edit.HealStrokes.empty.encoded) == .empty)
    // Odd values survive bit for bit.
    let odd = Edit.HealStrokes(strokes: [Edit.HealStroke(points: [SIMD2(-0.0, .ulpOfOne)], radius: .leastNonzeroMagnitude, offset: SIMD2(1e30, -3))])
    #expect(Edit.HealStrokes(encoded: odd.encoded)?.strokes[0].points[0].x.sign == .minus)
    #expect(Edit.HealStrokes(encoded: odd.encoded) == odd)
  }

  @Test func encodingIsLittleEndianAndVersioned() {
    let data = Edit.HealStrokes(strokes: [Edit.HealStroke(points: [SIMD2(1, 2)], radius: 4, offset: SIMD2(5, 6))]).encoded
    #expect(Array(data.prefix(6)) == [1, 0, 1, 0, 0, 0])
    // Header 6, stroke header 21, one point 8.
    #expect(data.count == 35)
    #expect(data[26] == 0)
  }

  @Test func jsonCarriesTheEncoding() throws {
    let original = Self.strokes(3, points: 4)
    let json = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(Edit.HealStrokes.self, from: json) == original)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Edit.HealStrokes.self, from: Data("\"AAAA\"".utf8)) }
  }

  @Test func digestIsStable() {
    let a = Self.strokes(4, points: 3)
    #expect(a.digest == Self.strokes(4, points: 3).digest)
    #expect(a.digest.count == 64)
    var b = a
    b.strokes[2].offset.x += 1
    #expect(a.digest != b.digest)
    let stored = Edit.StoredHeal(a)
    #expect(stored.digest == a.digest && stored.count == 4 && stored.version == 1)
    #expect(stored.tensorName == nil)
    var saved = stored
    saved.id = Edit.blobId(forDigest: stored.digest)
    #expect(saved.tensorName == "edit_heal_\(saved.id!)")
  }

  @Test func unreadableDataIsRefused() {
    var data = Self.strokes(2, points: 3).encoded
    var otherVersion = data
    otherVersion[0] = 2
    #expect(Edit.HealStrokes(encoded: otherVersion) == nil)
    #expect(Edit.HealStrokes(encoded: data.dropLast()) == nil)
    #expect(Edit.HealStrokes(encoded: Data()) == nil)
    data.append(0)
    #expect(Edit.HealStrokes(encoded: data) == nil)
    // A point count running past the end isn't trusted.
    var huge = Edit.HealStrokes(strokes: [Edit.HealStroke(points: [SIMD2(1, 1)], radius: 2, offset: .zero)]).encoded
    huge.replaceSubrange(6..<10, with: [0xFF, 0xFF, 0xFF, 0x7F])
    #expect(Edit.HealStrokes(encoded: huge) == nil)
  }

  @Test func twoHundredStrokesStaySmall() {
    let strokes = Self.strokes(200, points: 30)
    let data = strokes.encoded
    #expect(data.count == 6 + 200 * (21 + 30 * 8))
    #expect(data.count < 64 * 1024)
    #expect(Edit.HealStrokes(encoded: data) == strokes)
  }
}
