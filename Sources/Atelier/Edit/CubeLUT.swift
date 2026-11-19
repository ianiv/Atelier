import Foundation

/// Pipeline step 7, and the Edit screen's LUT files: reading and writing Adobe/Resolve `.cube`
/// 3D LUTs (`Edit.LUTTable`), applying one with a strength, and baking one from a transform
/// (Export LUT… bakes steps 3–7).
///
/// The format, as the Adobe Cube LUT Specification 1.0 has it: `#` comments, `TITLE "…"`,
/// `LUT_3D_SIZE n` (2–256), optional `DOMAIN_MIN r g b` / `DOMAIN_MAX r g b` (Resolve's
/// `LUT_3D_INPUT_RANGE min max` too), then n³ lines of `r g b` output values with red changing
/// fastest, then green, then blue. 1D LUTs (`LUT_1D_SIZE`) are refused: the Edit screen's
/// looks are 3D. Unknown keywords are skipped, as most readers skip them.
///
/// Applying maps each 0–255 value to 0–1, then from the domain to the table's 0…n−1 grid
/// (clamped), and interpolates the eight surrounding entries trilinearly; the output is the
/// table's 0–1 times 255, blended with the input by strength.
nonisolated enum CubeLUT {
  enum ParseError: LocalizedError, Equatable {
    case oneDimensional
    case missingSize
    case badSize(Int)
    case badLine(Int, String)
    case wrongCount(expected: Int, found: Int)
    case badDomain

    var errorDescription: String? {
      switch self {
      case .oneDimensional: "This is a 1D LUT. Only 3D LUTs (LUT_3D_SIZE) can be used."
      case .missingSize: "The file has no LUT_3D_SIZE line, so it isn't a 3D .cube LUT."
      case .badSize(let size): "The LUT size \(size) isn't one a .cube file can have (2 to 256)."
      case .badLine(let line, let text): "Line \(line) of the LUT can't be read: \(text)"
      case .wrongCount(let expected, let found): "The LUT should have \(expected) entries but has \(found)."
      case .badDomain: "The LUT's DOMAIN_MIN isn't below its DOMAIN_MAX."
      }
    }
  }

  static let sizeRange = 2...256

  // MARK: Reading

  /// The table in a `.cube` file, named by its TITLE or else the file's name.
  static func read(contentsOf url: URL) throws -> Edit.LUTTable {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try parse(text, name: url.deletingPathExtension().lastPathComponent)
  }

  /// The table in `.cube` text, named by its TITLE or else `name`.
  static func parse(_ text: String, name: String) throws -> Edit.LUTTable {
    var title: String?
    var size: Int?
    var domainMin: [Double] = [0, 0, 0]
    var domainMax: [Double] = [1, 1, 1]
    var values: [Float] = []
    func numbers(_ fields: ArraySlice<Substring>, count: Int, line: Int, text: Substring) throws -> [Double] {
      let parsed = fields.compactMap { Double($0) }
      guard fields.count == count, parsed.count == count, parsed.allSatisfy(\.isFinite) else {
        throw ParseError.badLine(line, String(text))
      }
      return parsed
    }
    for (offset, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
      let lineNumber = offset + 1
      var line = raw
      if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
      line = line.drop(while: \.isWhitespace)
      guard let first = line.first else { continue }
      let fields = line.split(whereSeparator: \.isWhitespace)
      if first.isLetter {
        let keyword = fields[0].uppercased()
        switch keyword {
        case "TITLE":
          let rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
          title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
          throw ParseError.oneDimensional
        case "LUT_3D_SIZE":
          let value = try numbers(fields.dropFirst(), count: 1, line: lineNumber, text: line)[0]
          guard value == value.rounded(), let n = Int(exactly: value) else { throw ParseError.badLine(lineNumber, String(line)) }
          guard sizeRange.contains(n) else { throw ParseError.badSize(n) }
          size = n
          values.reserveCapacity(n * n * n * 3)
        case "DOMAIN_MIN":
          domainMin = try numbers(fields.dropFirst(), count: 3, line: lineNumber, text: line)
        case "DOMAIN_MAX":
          domainMax = try numbers(fields.dropFirst(), count: 3, line: lineNumber, text: line)
        case "LUT_3D_INPUT_RANGE":
          let range = try numbers(fields.dropFirst(), count: 2, line: lineNumber, text: line)
          domainMin = [range[0], range[0], range[0]]
          domainMax = [range[1], range[1], range[1]]
        default:
          // Other keywords (LUT_IN_VIDEO_RANGE and such) change nothing here.
          continue
        }
        continue
      }
      guard size != nil else { throw ParseError.missingSize }
      for value in try numbers(fields[...], count: 3, line: lineNumber, text: line) { values.append(Float(value)) }
    }
    guard let size else { throw ParseError.missingSize }
    let expected = size * size * size
    guard values.count == expected * 3 else { throw ParseError.wrongCount(expected: expected, found: values.count / 3) }
    guard zip(domainMin, domainMax).allSatisfy({ $0 < $1 }) else { throw ParseError.badDomain }
    let named = title.flatMap { $0.isEmpty ? nil : $0 } ?? name
    return Edit.LUTTable(name: named, size: size, values: values, domainMin: domainMin, domainMax: domainMax)
  }

  // MARK: Writing

  /// `table` as `.cube` text: its name as TITLE, its size, its domain when it isn't 0–1, and
  /// its entries to six decimals.
  static func text(of table: Edit.LUTTable) -> String {
    var out = "# Made by Atelier\n"
    let title = table.name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
    out += "TITLE \"\(title)\"\n"
    out += "LUT_3D_SIZE \(table.size)\n"
    if table.domainMin != [0, 0, 0] || table.domainMax != [1, 1, 1] {
      out += "DOMAIN_MIN \(table.domainMin.map { format($0) }.joined(separator: " "))\n"
      out += "DOMAIN_MAX \(table.domainMax.map { format($0) }.joined(separator: " "))\n"
    }
    let values = table.values
    out.reserveCapacity(out.utf8.count + values.count / 3 * 27)
    for index in stride(from: 0, to: values.count, by: 3) {
      out += "\(format(Double(values[index]))) \(format(Double(values[index + 1]))) \(format(Double(values[index + 2])))\n"
    }
    return out
  }

  /// `text(of:)` written to `url`.
  static func write(_ table: Edit.LUTTable, to url: URL) throws {
    try Data(text(of: table).utf8).write(to: url, options: .atomic)
  }

  private static func format(_ value: Double) -> String { String(format: "%.6f", value) }

  // MARK: Baking

  /// A `size`³ table whose entries are `transform` of each grid point, red fastest. `transform`
  /// takes the planes of every grid point at once (`size`² × `size` pixels, values 0–255, opaque)
  /// and changes them in place, as the pipeline's steps do; its output is clipped to 0–255 and
  /// stored as 0–1.
  static func bake(size: Int = 33, name: String, transform: (inout EditPipeline.Planes) -> Void) -> Edit.LUTTable {
    let size = min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
    let count = size * size * size
    var r = [Float](repeating: 0, count: count)
    var g = r
    var b = r
    let step = 255 / Float(size - 1)
    for index in 0..<count {
      r[index] = Float(index % size) * step
      g[index] = Float(index / size % size) * step
      b[index] = Float(index / (size * size)) * step
    }
    var planes = EditPipeline.Planes(
      width: size * size, height: size, r: r, g: g, b: b, alpha: [UInt8](repeating: 255, count: count))
    transform(&planes)
    var values = [Float](repeating: 0, count: count * 3)
    func unit(_ value: Float) -> Float { value.isNaN ? 0 : min(max(value, 0), 255) / 255 }
    for index in 0..<count {
      values[index * 3] = unit(planes.r[index])
      values[index * 3 + 1] = unit(planes.g[index])
      values[index * 3 + 2] = unit(planes.b[index])
    }
    return Edit.LUTTable(name: name, size: size, values: values)
  }

  /// `bake` from a transform of one color, RGB in 0–1 to RGB in 0–1.
  static func bake(size: Int = 33, name: String, color transform: ([Float]) -> [Float]) -> Edit.LUTTable {
    bake(size: size, name: name) { planes in
      for index in 0..<planes.r.count {
        let out = transform([planes.r[index] / 255, planes.g[index] / 255, planes.b[index] / 255])
        guard out.count >= 3 else { continue }
        planes.r[index] = out[0] * 255
        planes.g[index] = out[1] * 255
        planes.b[index] = out[2] * 255
      }
    }
  }

  /// A table that changes nothing, for tests and as a starting point.
  static func identity(size: Int = 33, name: String = "Identity") -> Edit.LUTTable {
    bake(size: size, name: name) { _ in }
  }

  // MARK: Applying

  /// `planes` through `table`, blended with themselves by `strength` (0 leaves them, 1 is the
  /// LUT's output). Nothing happens at strength 0 or with a table whose data is the wrong size.
  static func apply(_ table: Edit.LUTTable, to planes: inout EditPipeline.Planes, strength: Double = 1) {
    let strength = Float(min(max(strength, 0), 1))
    let n = table.size
    let values = table.values
    guard strength > 0, n >= 2, values.count == n * n * n * 3, table.domainMin.count == 3, table.domainMax.count == 3 else { return }
    let top = Float(n - 1)
    // Input level → grid coordinate: (v/255 − min) / (max − min) × (n − 1).
    let scale = (0..<3).map { top / 255 / Float(table.domainMax[$0] - table.domainMin[$0]) }
    let offset = (0..<3).map { -Float(table.domainMin[$0]) * top / Float(table.domainMax[$0] - table.domainMin[$0]) }
    let (sr, sg, sb) = (scale[0], scale[1], scale[2])
    let (or, og, ob) = (offset[0], offset[1], offset[2])
    let rowStride = n * 3
    let planeStride = n * n * 3
    values.withUnsafeBufferPointer { lut in
      let lut = lut.baseAddress!
      planes.withPixelBands { range, r, g, b in
        for i in range {
          let x = min(max(r[i] * sr + or, 0), top)
          let y = min(max(g[i] * sg + og, 0), top)
          let z = min(max(b[i] * sb + ob, 0), top)
          let x0 = min(Int(x), n - 2)
          let y0 = min(Int(y), n - 2)
          let z0 = min(Int(z), n - 2)
          let fx = x - Float(x0)
          let fy = y - Float(y0)
          let fz = z - Float(z0)
          let base = z0 * planeStride + y0 * rowStride + x0 * 3
          var out = SIMD3<Float>()
          for channel in 0..<3 {
            let p = lut + base + channel
            let c00 = p[0] + fx * (p[3] - p[0])
            let c10 = p[rowStride] + fx * (p[rowStride + 3] - p[rowStride])
            let c01 = p[planeStride] + fx * (p[planeStride + 3] - p[planeStride])
            let c11 = p[planeStride + rowStride] + fx * (p[planeStride + rowStride + 3] - p[planeStride + rowStride])
            let c0 = c00 + fy * (c10 - c00)
            let c1 = c01 + fy * (c11 - c01)
            out[channel] = (c0 + fz * (c1 - c0)) * 255
          }
          r[i] += strength * (out.x - r[i])
          g[i] += strength * (out.y - g[i])
          b[i] += strength * (out.z - b[i])
        }
      }
    }
  }
}
