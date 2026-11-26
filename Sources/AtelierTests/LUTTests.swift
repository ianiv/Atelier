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
      Grade.apply(EditOptions.Grade(brightness: 0.3, highlights: -0.4, shadows: 0.3, temperature: 30, contrast: 0.3, saturation: 0.4), to: &planes)
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
    Grade.apply(EditOptions.Grade(brightness: 0.3, highlights: -0.4, shadows: 0.3, temperature: 30, contrast: 0.3, saturation: 0.4), to: &graded)
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

  /// A file as other tools write them: a byte order mark, CRLF line ends, a comment, a title
  /// with a "#" in its quotes, tabs between numbers, scientific notation, size 65.
  @Test func readsOtherToolsFiles() throws {
    let size = 65
    var lines = ["\u{FEFF}# Made by another tool", "TITLE \"Film #3\"  # the third", "LUT_3D_SIZE\t65", "DOMAIN_MIN 0 0 0", ""]
    for index in 0..<size * size * size {
      let r = Double(index % size) / Double(size - 1)
      let g = Double(index / size % size) / Double(size - 1)
      let b = Double(index / (size * size)) / Double(size - 1)
      lines.append(String(format: "%.6e\t%.6e \t%.6e", r, g, b))
    }
    let text = lines.joined(separator: "\r\n") + "\r\n"
    let table = try CubeLUT.parse(text, name: "file")
    #expect(table.name == "Film #3" && table.size == size)
    var planes = EditPipeline.Planes(
      width: 4, height: 1, r: [0, 64, 200, 255], g: [10, 128, 30, 255], b: [255, 3, 90, 0], alpha: [255, 255, 255, 255])
    let before = planes
    CubeLUT.apply(table, to: &planes)
    for i in 0..<4 {
      #expect(abs(planes.r[i] - before.r[i]) < 0.6 && abs(planes.g[i] - before.g[i]) < 0.6 && abs(planes.b[i] - before.b[i]) < 0.6)
    }
    // Unquoted titles stop at a comment; sizes past 129 are refused.
    #expect(try CubeLUT.parse("TITLE Plain # note\nLUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8), name: "x").name == "Plain")
    #expect(throws: CubeLUT.ParseError.badSize(256)) { try CubeLUT.parse("LUT_3D_SIZE 256\n", name: "x") }
  }

  /// Values that aren't numbers, and a stored table whose domain is empty, don't trap.
  @Test func applyingSurvivesBadInput() {
    var planes = EditPipeline.Planes(
      width: 3, height: 1, r: [.nan, .infinity, -.infinity], g: [.nan, 5, 7], b: [1, .nan, 3], alpha: [255, 255, 255])
    CubeLUT.apply(CubeLUT.identity(size: 5), to: &planes)
    // No trap; finite channels of those pixels come out finite.
    #expect(planes.g[1].isFinite && planes.g[2].isFinite && planes.b[2].isFinite)
    let flat = Edit.LUTTable(name: "flat", size: 2, values: [Float](repeating: 0.5, count: 24), domainMin: [0.5, 0, 0], domainMax: [0.5, 1, 1])
    var same = EditPipeline.Planes(width: 1, height: 1, r: [10], g: [20], b: [30], alpha: [255])
    CubeLUT.apply(flat, to: &same)
    #expect(same.r == [10] && same.g == [20] && same.b == [30])
  }

  // MARK: Built-in looks

  /// Grid points (of 33) the built-ins are checked at: black, white, grey and some colours.
  private static let builtInPoints = [(0, 0, 0), (32, 32, 32), (16, 16, 16), (5, 20, 30), (28, 10, 3), (12, 25, 8), (31, 2, 17), (20, 24, 6), (8, 9, 27)]

  /// make_luts.py's output (after its clip to 0–1) at the grid points below, from numpy.
  private static let expected: [String: [[Double]]] = [
    "Warm Film": [[0.01506286, 0.02970118, 0.04067992], [1.00000000, 0.99865749, 0.96467725], [0.50958127, 0.50928900, 0.50838103], [0.18171948, 0.63777726, 0.90827166], [0.85646262, 0.31664500, 0.12522455], [0.46514293, 0.73719299, 0.37520459], [0.91760708, 0.09673879, 0.53469654], [0.65943284, 0.76359120, 0.24955385], [0.24361962, 0.27812428, 0.82790993]],
    "Teal and Orange": [[0.00000000, 0.01080280, 0.04320280], [1.00000000, 1.00000000, 0.95338970], [0.50010111, 0.50047842, 0.49997534], [0.08459905, 0.66193541, 0.99321485], [0.95972960, 0.26729139, 0.02550079], [0.33637598, 0.84355100, 0.16623431], [1.00000000, 0.01485375, 0.56111045], [0.66490238, 0.80504977, 0.08581530], [0.18421269, 0.24092137, 0.94903819]],
    "Faded Matte": [[0.08094055, 0.08535277, 0.08976500], [0.94919096, 0.94617961, 0.94015691], [0.51114450, 0.51110682, 0.51096335], [0.27836290, 0.60294303, 0.81048688], [0.75787800, 0.37073023, 0.22465838], [0.44411248, 0.72599920, 0.35607153], [0.80368389, 0.19221647, 0.51242097], [0.63079145, 0.71581229, 0.32410787], [0.30441086, 0.32702728, 0.71700214]],
    "Punchy Slide": [[0.00000000, 0.00000000, 0.00000000], [1.00000000, 1.00000000, 1.00000000], [0.50000000, 0.50000000, 0.50000000], [0.00000000, 0.69602870, 1.00000000], [1.00000000, 0.20718909, 0.00000000], [0.27128670, 0.89904610, 0.08876326], [1.00000000, 0.00000000, 0.57845301], [0.66553610, 0.84661995, 0.00000000], [0.15476336, 0.20440843, 1.00000000]],
    "Bleach Bypass": [[0.01000000, 0.01000000, 0.01000000], [1.00000000, 1.00000000, 1.00000000], [0.50500000, 0.50500000, 0.50500000], [0.25719002, 0.61606854, 0.83585052], [0.76095803, 0.33169877, 0.18135147], [0.47042716, 0.77703227, 0.37313809], [0.78624647, 0.13067398, 0.45668515], [0.69517726, 0.78310754, 0.35626656], [0.21850717, 0.23940258, 0.66774971]],
    "Sodium Night": [[0.00000000, 0.01688660, 0.01868660], [1.00000000, 1.00000000, 0.94828400], [0.49119177, 0.49172625, 0.49065094], [0.15156795, 0.63045848, 0.91138529], [0.85708781, 0.28718073, 0.09531276], [0.37761111, 0.79895808, 0.23103709], [0.91471229, 0.06982206, 0.51782551], [0.66380218, 0.77890047, 0.17270852], [0.20267296, 0.24781058, 0.82798396]],
    "Cool Phone Night": [[0.01534301, 0.01624825, 0.01751771], [0.95504104, 1.00000000, 1.00000000], [0.48053807, 0.51139099, 0.55454644], [0.10697035, 0.65564384, 1.00000000], [0.89243230, 0.29715562, 0.06912944], [0.33052266, 0.82443578, 0.23163976], [0.98786739, 0.03700205, 0.60611562], [0.60565945, 0.78530655, 0.15271350], [0.22253948, 0.27265268, 0.97815909]],
    "Golden Hour": [[0.01185955, 0.00000000, 0.00000000], [1.00000000, 1.00000000, 0.87539075], [0.53626006, 0.50016039, 0.42825532], [0.12478533, 0.64625953, 0.86429238], [0.96675000, 0.28396877, 0.04639330], [0.37826270, 0.81692478, 0.17119491], [1.00000000, 0.03280594, 0.46503663], [0.68810376, 0.78170600, 0.10878737], [0.24440011, 0.25644521, 0.78444852]],
    "Tri-X Mono": [[0.02000000, 0.02000000, 0.02000000], [0.99000000, 0.99000000, 0.99000000], [0.50500000, 0.50500000, 0.50500000], [0.43622944, 0.43622944, 0.43622944], [0.56007128, 0.56007128, 0.56007128], [0.56203077, 0.56203077, 0.56203077], [0.52666753, 0.52666753, 0.52666753], [0.67536155, 0.67536155, 0.67536155], [0.28876159, 0.28876159, 0.28876159]],
    "Cross Process": [[0.00000000, 0.00963650, 0.10413650], [1.00000000, 1.00000000, 0.81114550], [0.49964100, 0.52064100, 0.45764100], [0.08149028, 0.67323039, 0.78827922], [0.94673263, 0.29560446, 0.15217794], [0.32561414, 0.84688364, 0.26277820], [1.00000000, 0.04177285, 0.48743325], [0.65836700, 0.80907481, 0.21195294], [0.18858919, 0.26845469, 0.72802669]],
  ]

  /// Each built-in's formula gives the original script's values, and its baked table holds them
  /// (to the table's Float16 storage).
  @MainActor @Test func builtInLooksMatchTheirScript() throws {
    #expect(Set(Self.expected.keys) == Set(BuiltInLUTs.names))
    for name in BuiltInLUTs.names {
      let look = try #require(BuiltInLUTs.look(name))
      let table = try #require(BuiltInLUTs.table(name))
      #expect(table.size == 33 && table.name == name)
      let values = table.values
      for (point, want) in zip(Self.builtInPoints, try #require(Self.expected[name])) {
        let out = look(BuiltInLUTs.RGB(Double(point.0) / 32, Double(point.1) / 32, Double(point.2) / 32))
        let got = [out.r, out.g, out.b].map { min(max($0, 0), 1) }
        for channel in 0..<3 {
          #expect(abs(got[channel] - want[channel]) < 1e-4, "\(name) at \(point) channel \(channel): \(got[channel]) vs \(want[channel])")
          let index = ((point.2 * 33 + point.1) * 33 + point.0) * 3 + channel
          #expect(abs(Double(values[index]) - want[channel]) < 1e-3, "\(name)'s table at \(point) channel \(channel)")
        }
      }
      #expect(BuiltInLUTs.name(of: table) == name)
    }
    #expect(BuiltInLUTs.look("Not a Look") == nil && BuiltInLUTs.table("Not a Look") == nil)
  }
}
