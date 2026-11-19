@testable import Atelier
import Foundation
import Testing

/// 3D LUTs (`CubeLUT`, `Edit.LUTTable`): the table's Float16 storage, reading and writing
/// `.cube` files, and applying them.
struct LUTTests {
  @Test func tableKeepsItsValues() throws {
    let size = 2
    let values: [Float] = (0..<size * size * size * 3).map { Float($0) / 23 }
    let table = Edit.LUTTable(name: "ramp", size: size, values: values)
    #expect(table.data.count == values.count * 2)
    for (got, want) in zip(table.values, values) { #expect(abs(got - want) < 1e-3) }
    let decoded = try JSONDecoder().decode(Edit.LUTTable.self, from: JSONEncoder().encode(table))
    #expect(decoded == table && decoded.digest == table.digest)
  }

  /// Every level of each channel against a few of the others'.
  private func samplePlanes() -> EditPipeline.Planes {
    var r: [Float] = []
    var g: [Float] = []
    var b: [Float] = []
    for level in 0..<256 {
      for other in stride(from: 0, through: 255, by: 51) {
        r.append(Float(level))
        g.append(Float(other))
        b.append(Float((level * 3 + other) % 256))
      }
    }
    return EditPipeline.Planes(width: r.count, height: 1, r: r, g: g, b: b, alpha: [UInt8](repeating: 255, count: r.count))
  }

  private func worst(_ a: EditPipeline.Planes, _ b: EditPipeline.Planes) -> Float {
    var out: Float = 0
    for i in a.r.indices { out = max(out, abs(a.r[i] - b.r[i]), abs(a.g[i] - b.g[i]), abs(a.b[i] - b.b[i])) }
    return out
  }

  @Test(arguments: [17, 33]) func identityCubeIsANoOp(size: Int) throws {
    let source = samplePlanes()
    // Through the file, as a user's identity LUT would come.
    let table = try CubeLUT.parse(CubeLUT.text(of: CubeLUT.identity(size: size)), name: "id")
    #expect(table.size == size)
    var planes = source
    CubeLUT.apply(table, to: &planes)
    #expect(worst(planes, source) < 0.05)
  }

  @Test(arguments: [17, 33]) func exportThenImportIsWithinALevel(size: Int) throws {
    // A curve, a cross-channel mix and a grade, so the table isn't trivially linear.
    let baked = CubeLUT.bake(size: size, name: "Look") { planes in
      Grade.apply(EditOptions.Grade(temperature: 30, contrast: 0.3, saturation: 0.4), to: &planes)
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-lut-\(UUID().uuidString).cube")
    defer { try? FileManager.default.removeItem(at: url) }
    try CubeLUT.write(baked, to: url)
    let read = try CubeLUT.read(contentsOf: url)
    #expect(read.name == "Look" && read.size == size)
    for (a, b) in zip(read.values, baked.values) { #expect(abs(a - b) * 255 <= 1) }
    var first = samplePlanes()
    var second = first
    CubeLUT.apply(baked, to: &first)
    CubeLUT.apply(read, to: &second)
    #expect(worst(first, second) <= 1)
    // At a grid point the LUT gives the transform's own value, within a level.
    var exact = samplePlanes()
    let step = 255 / Float(size - 1)
    for i in exact.r.indices {
      exact.r[i] = (exact.r[i] / step).rounded() * step
      exact.g[i] = (exact.g[i] / step).rounded() * step
      exact.b[i] = (exact.b[i] / step).rounded() * step
    }
    var graded = exact
    Grade.apply(EditOptions.Grade(temperature: 30, contrast: 0.3, saturation: 0.4), to: &graded)
    for i in graded.r.indices {
      graded.r[i] = min(max(graded.r[i], 0), 255)
      graded.g[i] = min(max(graded.g[i], 0), 255)
      graded.b[i] = min(max(graded.b[i], 0), 255)
    }
    CubeLUT.apply(read, to: &exact)
    #expect(worst(exact, graded) <= 1)
  }

  @Test func redChangesFastestAndStrengthBlends() throws {
    // Swaps red and blue: entries are written r fastest, so line k's grid point is
    // (k % 2, k / 2 % 2, k / 4) and its output that with red and blue swapped.
    var text = "# swap\nTITLE \"Swap\"\nLUT_3D_SIZE 2\n\n"
    for k in 0..<8 { text += "\(k / 4) \(k / 2 % 2) \(k % 2)  # point \(k)\n" }
    let table = try CubeLUT.parse(text, name: "file")
    #expect(table.name == "Swap")
    var planes = EditPipeline.Planes(width: 1, height: 1, r: [255], g: [0], b: [64], alpha: [255])
    CubeLUT.apply(table, to: &planes)
    #expect(abs(planes.r[0] - 64) < 0.01 && planes.g[0] == 0 && abs(planes.b[0] - 255) < 0.01)
    var half = EditPipeline.Planes(width: 1, height: 1, r: [255], g: [0], b: [64], alpha: [255])
    CubeLUT.apply(table, to: &half, strength: 0.5)
    #expect(abs(half.r[0] - 159.5) < 0.01 && abs(half.b[0] - 159.5) < 0.01)
    var none = EditPipeline.Planes(width: 1, height: 1, r: [255], g: [0], b: [64], alpha: [255])
    CubeLUT.apply(table, to: &none, strength: 0)
    #expect(none.r == [255] && none.b == [64])
  }

  @Test func domainScalesTheInput() throws {
    // An identity on 0–2: input 1.0 (255) sits halfway up the grid, so comes out as 0.5.
    var text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n"
    for k in 0..<8 { text += "\(k % 2) \(k / 2 % 2) \(k / 4)\n" }
    let table = try CubeLUT.parse(text, name: "wide")
    #expect(table.name == "wide" && table.domainMin == [0, 0, 0] && table.domainMax == [2, 2, 2])
    var planes = EditPipeline.Planes(width: 2, height: 1, r: [255, 0], g: [127.5, 0], b: [0, 255], alpha: [255, 255])
    CubeLUT.apply(table, to: &planes)
    #expect(abs(planes.r[0] - 127.5) < 0.01 && abs(planes.g[0] - 63.75) < 0.01 && abs(planes.b[1] - 127.5) < 0.01)
    // The domain survives a round trip, and Resolve's input range reads as one.
    let again = try CubeLUT.parse(CubeLUT.text(of: table), name: "x")
    #expect(again.domainMax == [2, 2, 2])
    let resolve = try CubeLUT.parse(text.replacingOccurrences(of: "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2", with: "LUT_3D_INPUT_RANGE 0 2"), name: "r")
    #expect(resolve.domainMin == [0, 0, 0] && resolve.domainMax == [2, 2, 2])
  }

  @Test func malformedFilesThrow() {
    let points = (0..<8).map { "\($0 % 2) \($0 / 2 % 2) \($0 / 4)" }.joined(separator: "\n")
    #expect(throws: CubeLUT.ParseError.oneDimensional) { try CubeLUT.parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n", name: "x") }
    #expect(throws: CubeLUT.ParseError.missingSize) { try CubeLUT.parse(points, name: "x") }
    #expect(throws: CubeLUT.ParseError.badSize(1)) { try CubeLUT.parse("LUT_3D_SIZE 1\n0 0 0\n", name: "x") }
    #expect(throws: CubeLUT.ParseError.wrongCount(expected: 8, found: 7)) {
      try CubeLUT.parse("LUT_3D_SIZE 2\n" + points.split(separator: "\n").dropLast().joined(separator: "\n"), name: "x")
    }
    #expect(throws: CubeLUT.ParseError.self) { try CubeLUT.parse("LUT_3D_SIZE 2\n" + points.replacingOccurrences(of: "1 1 1", with: "1 one 1"), name: "x") }
    #expect(throws: CubeLUT.ParseError.self) { try CubeLUT.parse("LUT_3D_SIZE 2\n" + points.replacingOccurrences(of: "1 1 1", with: "1 1"), name: "x") }
    #expect(throws: CubeLUT.ParseError.badDomain) { try CubeLUT.parse("LUT_3D_SIZE 2\nDOMAIN_MIN 1 0 0\nDOMAIN_MAX 1 1 1\n" + points, name: "x") }
    #expect(throws: (any Error).self) { try CubeLUT.parse("", name: "x") }
  }
}
