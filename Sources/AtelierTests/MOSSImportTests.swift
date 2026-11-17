@testable import Atelier
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC
import Testing

/// Importing MOSS Image fine-tunes saved by ComfyUI: the ConvRot Hadamard matrix, INT8 + ConvRot
/// dequantization against a quantizer written the way comfy-kitchen's is, and a whole (tiny)
/// ComfyUI-layout checkpoint converted to a store: prefixed names, fused q/k/v split.
struct MOSSImportTests {
  /// A fixed sequence, so failures repeat.
  private struct Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state
    }
  }

  private struct Entry {
    var name: String
    var dtype: String
    var shape: [Int]
    var bytes: Data
  }

  private static func bf16(_ values: [Float]) -> Data {
    var data = Data()
    for value in values {
      withUnsafeBytes(of: UInt16(value.bitPattern >> 16).littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  private static func f32(_ values: [Float]) -> Data {
    var data = Data()
    for value in values {
      withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  /// A safetensors file of `entries` in a new temporary folder.
  private static func write(_ entries: [Entry]) throws -> URL {
    var header = [String: Any]()
    var body = Data()
    for entry in entries {
      header[entry.name] = ["dtype": entry.dtype, "shape": entry.shape, "data_offsets": [body.count, body.count + entry.bytes.count]]
      body.append(entry.bytes)
    }
    var json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    json.append(contentsOf: [UInt8](repeating: 0x20, count: (8 - json.count % 8) % 8))
    var file = Data()
    withUnsafeBytes(of: UInt64(json.count).littleEndian) { file.append(contentsOf: $0) }
    file.append(json)
    file.append(body)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MOSSImportTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("model.safetensors")
    try file.write(to: url)
    return url
  }

  /// `weight` (row-major [rows, columns]) rotated and quantized the way comfy-kitchen's
  /// `quantize_int8_convrot_weight` does: `W @ H.T` per block, then per-row absmax / 127 scales and
  /// round-to-nearest. The rotation is written out here, independent of `ConvRot.rotate`.
  private static func quantizeConvRot(_ weight: [Float], rows: Int, columns: Int, groupSize: Int) -> (q: [Int8], scale: [Float]) {
    let h = ConvRot.hadamard(groupSize)
    var rotated = [Float](repeating: 0, count: weight.count)
    for r in 0..<rows {
      for block in 0..<(columns / groupSize) {
        let base = r * columns + block * groupSize
        for j in 0..<groupSize {
          var sum: Float = 0
          for k in 0..<groupSize { sum += weight[base + k] * h[j * groupSize + k] }
          rotated[base + j] = sum
        }
      }
    }
    var q = [Int8](repeating: 0, count: weight.count)
    var scales = [Float]()
    for r in 0..<rows {
      let row = rotated[(r * columns)..<((r + 1) * columns)]
      let scale = max(row.map(abs).max()! / 127, 1e-30)
      scales.append(scale)
      for c in 0..<columns {
        q[r * columns + c] = Int8(max(-128, min(127, (rotated[r * columns + c] / scale).rounded())))
      }
    }
    return (q, scales)
  }

  private static func quantizedEntries(_ name: String, weight: [Float], rows: Int, columns: Int) -> [Entry] {
    let (q, scale) = quantizeConvRot(weight, rows: rows, columns: columns, groupSize: 256)
    let quant = Data(#"{"format":"int8_tensorwise","convrot":true,"convrot_groupsize":256}"#.utf8)
    return [
      Entry(name: name + ".weight", dtype: "I8", shape: [rows, columns], bytes: q.withUnsafeBytes { Data($0) }),
      Entry(name: name + ".weight_scale", dtype: "F32", shape: [rows, 1], bytes: f32(scale)),
      Entry(name: name + ".comfy_quant", dtype: "U8", shape: [quant.count], bytes: quant),
    ]
  }

  @Test func hadamardIsSymmetricOrthogonal() {
    for size in [4, 16, 64, 256] {
      let h = ConvRot.hadamard(size)
      let h4: [Float] = [1, 1, 1, -1, 1, 1, -1, 1, 1, -1, 1, 1, -1, 1, 1, 1]
      for i in 0..<size {
        for j in 0..<size {
          // A Kronecker power of H4: the product of H4 over the base-4 digits.
          var expected: Float = 1 / Float(size).squareRoot()
          var (a, b) = (i, j)
          for _ in 0..<Int(log2(Double(size)) / 2) {
            expected *= h4[(a % 4) * 4 + b % 4]
            (a, b) = (a / 4, b / 4)
          }
          #expect(h[i * size + j] == expected)
          #expect(h[i * size + j] == h[j * size + i])
          var dot: Float = 0
          for k in 0..<size { dot += h[i * size + k] * h[j * size + k] }
          #expect(abs(dot - (i == j ? 1 : 0)) < 1e-5)
        }
      }
    }
    #expect(!ConvRot.isValid(128))
    #expect(ConvRot.isValid(256))
  }

  @Test func int8ConvRotRoundTrip() throws {
    let rows = 6
    let columns = 512
    var generator = Generator(state: 7)
    let weight = (0..<(rows * columns)).map { _ in Float.random(in: -1...1, using: &generator) }
    let url = try Self.write(Self.quantizedEntries("blk.proj", weight: weight, rows: rows, columns: columns))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = try SafeTensorsReader(url: url)
    let tensor = try reader.weight("blk.proj.weight")
    #expect(Array(tensor.shape) == [rows, columns])
    var squared: Float = 0
    var worst: Float = 0
    for r in 0..<rows {
      for c in 0..<columns {
        let error = abs(tensor[r, c] - weight[r * columns + c])
        squared += error * error
        worst = max(worst, error)
      }
    }
    let rms = (squared / Float(rows * columns)).squareRoot()
    // Rounding error is at most half a step (≈ 0.01 here) per rotated value; un-rotating spreads it.
    #expect(rms < 0.01)
    #expect(worst < 0.05)
  }

  @Test func comfyUILayoutConverts() throws {
    let prefix = "model.diffusion_model."
    var generator = Generator(state: 3)
    var entries = [Entry]()
    // Rows tagged by index (r / 64, r % 64, exact in BF16) to follow them through the split.
    let qkv: [Float] = (0..<9_216).flatMap { r -> [Float] in [Float(r / 64), Float(r % 64), 0, 0] }
    let o = (0..<(8 * 256)).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
    for key in MOSSImporter.mapping(layers: 1, fusedQKV: true).keys {
      if key == "layers.0.proj.o.weight" {
        entries += Self.quantizedEntries(prefix + "layers.0.proj.o", weight: o, rows: 8, columns: 256)
        continue
      }
      let shape: [Int] =
        if key.contains("q_norm") || key.contains("k_norm") { [128] }
        else if key.hasSuffix("qkv.weight") { [9_216, 4] }
        else if key.hasSuffix("qkv.bias") { [9_216] }
        else if key.hasSuffix(".bias") || key.contains("norm") { [12] }
        else { [12, 4] }
      let values: [Float] =
        if key == "layers.0.proj.qkv.weight" { qkv }
        else { (0..<shape.reduce(1, *)).map { _ in Float.random(in: -1...1, using: &generator) } }
      entries.append(
        key.hasPrefix("time_embedding.2.")
          ? Entry(name: prefix + key, dtype: "F32", shape: shape, bytes: Self.f32(values))
          : Entry(name: prefix + key, dtype: "BF16", shape: shape, bytes: Self.bf16(values)))
    }
    let url = try Self.write(entries)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(MOSSImporter.isMOSS(url))
    let output = url.deletingLastPathComponent().appendingPathComponent("moss_f16.ckpt").path
    try MOSSImporter.convert(url, to: output, progress: { _ in })

    let graph = DynamicGraph()
    var tensors = [String: Tensor<Float>]()
    graph.openStore(output, flags: .readOnly) { store in
      for name in ["x_q", "x_k", "x_v", "x_o"] {
        if let tensor = store.read("__dit__[t-\(name)-0-0]") { tensors[name] = Tensor<Float>(from: tensor) }
      }
    }
    func tag(_ tensor: Tensor<Float>, _ row: Int) -> Int { Int(tensor[row, 0]) * 64 + Int(tensor[row, 1]) }
    let q = try #require(tensors["x_q"])
    let k = try #require(tensors["x_k"])
    let v = try #require(tensors["x_v"])
    #expect(Array(q.shape) == [3_072, 4])
    // q and k: the first and second thirds, each head's split halves interleaved for the engine's
    // rotary embedding (row h·128 + 2j + s came from h·128 + 64s + j); v: the last third as is.
    for head in 0..<24 {
      for j in 0..<64 {
        for s in 0..<2 {
          let row = head * 128 + 2 * j + s
          let source = head * 128 + 64 * s + j
          #expect(tag(q, row) == source)
          #expect(tag(k, row) == 3_072 + source)
        }
      }
    }
    #expect((0..<3_072).allSatisfy { tag(v, $0) == 6_144 + $0 })
    let x = try #require(tensors["x_o"])
    var worst: Float = 0
    for r in 0..<8 {
      for c in 0..<256 { worst = max(worst, abs(x[r, c] - o[r * 256 + c])) }
    }
    #expect(worst < 0.03)
  }

  @Test func otherQuantizationIsRefusedByName() throws {
    let quant = Data(#"{"format":"mxfp8"}"#.utf8)
    let url = try Self.write([
      Entry(name: "a.weight", dtype: "U8", shape: [4], bytes: Data([1, 2, 3, 4])),
      Entry(name: "a.comfy_quant", dtype: "U8", shape: [quant.count], bytes: quant),
      Entry(name: "b.weight", dtype: "I8", shape: [4], bytes: Data([1, 2, 3, 4])),
    ])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = try SafeTensorsReader(url: url)
    #expect(throws: SafeTensorsReader.Error.self) { try reader.weight("a.weight") }
    #expect(throws: SafeTensorsReader.Error.self) { try reader.weight("b.weight") }
  }

  /// A raw file: an 8-byte header length (`length`, or the header's real size), the header, `body`.
  private static func writeRaw(_ header: [String: Any], body: Data, length: UInt64? = nil) throws -> URL {
    let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    var file = Data()
    withUnsafeBytes(of: (length ?? UInt64(json.count)).littleEndian) { file.append(contentsOf: $0) }
    file.append(json)
    file.append(body)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MOSSImportTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("model.safetensors")
    try file.write(to: url)
    return url
  }

  @Test func malformedHeaderEntriesAreSkipped() throws {
    let header: [String: Any] = [
      "good": ["dtype": "F32", "shape": [2], "data_offsets": [0, 8]],
      "negativeOffset": ["dtype": "F32", "shape": [2], "data_offsets": [-8, 0]],
      "pastEnd": ["dtype": "F32", "shape": [2], "data_offsets": [0, Int.max]],
      "reversed": ["dtype": "F32", "shape": [2], "data_offsets": [8, 0]],
      "hugeDims": ["dtype": "F32", "shape": [Int.max / 2, 4], "data_offsets": [0, 8]],
      "hugeBytes": ["dtype": "F64", "shape": [Int.max / 4], "data_offsets": [0, 8]],
      "negativeDim": ["dtype": "F32", "shape": [-2, -1], "data_offsets": [0, 8]],
      "wrongSize": ["dtype": "F32", "shape": [3], "data_offsets": [0, 8]],
      "empty": ["dtype": "F32", "shape": [0, 4], "data_offsets": [8, 8]],
    ]
    let url = try Self.writeRaw(header, body: Self.f32([1, 2]))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = try SafeTensorsReader(url: url)
    #expect(Set(reader.entries.keys) == ["good", "empty"])
    #expect(try reader.floats(try #require(reader.entries["good"]), name: "good") == [1, 2])
    #expect(throws: SafeTensorsReader.Error.self) { try reader.weight("empty") }
    #expect(throws: SafeTensorsReader.Error.self) { try reader.weight("hugeDims") }

    for length in [UInt64.max, UInt64(Int.max), 1 << 40] {
      let bad = try Self.writeRaw(header, body: Data(), length: length)
      defer { try? FileManager.default.removeItem(at: bad.deletingLastPathComponent()) }
      #expect(throws: SafeTensorsReader.Error.self) { try SafeTensorsReader(url: bad) }
    }
  }
}
