import Accelerate
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// A safetensors file read by Atelier itself, for the checkpoints the engine's reader can't take:
/// `SafeTensors.init` (SwiftDiffusion/Sources/Archive/SafeTensors.swift) skips every entry whose
/// dtype isn't F16, F32, F64, BF16 or F8, so the INT8 weights of a ComfyUI quantized checkpoint
/// simply aren't there. This reads every entry from the header and decodes tensors from the mapped
/// file one at a time, so a conversion holds one tensor in memory, not the checkpoint.
///
/// `weight(_:)` also undoes ComfyUI's quantization (`comfy_quant` / `weight_scale` sidecar
/// tensors, the layout documented in ComfyUI's QUANTIZATION.md).
final nonisolated class SafeTensorsReader {
  struct Entry {
    var dtype: String
    var shape: [Int]
    /// Byte range in the file (the header's `data_offsets` moved past the header).
    var range: Range<Int>

    var count: Int { shape.reduce(1, *) }
  }

  enum Error: LocalizedError {
    case unreadable
    case unsupportedType(String, String)
    case unsupportedQuantization(String, String)
    case missingScale(String)
    case badScale(String)
    case badRotation(String)

    var errorDescription: String? {
      switch self {
      case .unreadable: "Not a safetensors file."
      case .unsupportedType(let name, let dtype): "\(name) is stored as \(dtype), which the importer can't read."
      case .unsupportedQuantization(let name, let format): "\(name) is quantized as \(format), which the importer can't read."
      case .missingScale(let name): "\(name) is INT8 but has no weight_scale to dequantize it with."
      case .badScale(let name): "\(name)'s weight_scale doesn't match its shape."
      case .badRotation(let name): "\(name)'s ConvRot group size doesn't fit the tensor."
      }
    }
  }

  let data: Data
  let entries: [String: Entry]

  init(url: URL) throws {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 8 else {
      throw Error.unreadable
    }
    let headerSize = data.withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
    guard headerSize > 0, headerSize <= data.count - 8, headerSize < 100_000_000,
          let header = try? JSONSerialization.jsonObject(with: data[8..<(8 + headerSize)]) as? [String: Any]
    else { throw Error.unreadable }
    let start = 8 + headerSize
    var entries = [String: Entry]()
    for (key, value) in header {
      guard let value = value as? [String: Any], let dtype = value["dtype"] as? String,
            let shape = value["shape"] as? [Int], let offsets = value["data_offsets"] as? [Int],
            offsets.count == 2, offsets[0] <= offsets[1], start + offsets[1] <= data.count
      else { continue }
      entries[key] = Entry(dtype: dtype.uppercased(), shape: shape, range: (start + offsets[0])..<(start + offsets[1]))
    }
    self.data = data
    self.entries = entries
  }

  /// The raw bytes of `entry`.
  func bytes(_ entry: Entry) -> Data { data.subdata(in: entry.range) }

  /// `entry` decoded to Float, row-major.
  func floats(_ entry: Entry, name: String) throws -> [Float] {
    let count = entry.count
    let size: Int
    switch entry.dtype {
    case "F32": size = 4
    case "F64": size = 8
    case "F16", "BF16": size = 2
    case "I8", "U8", "F8_E4M3", "F8_E5M2": size = 1
    default: throw Error.unsupportedType(name, entry.dtype)
    }
    guard entry.range.count == count * size else { throw Error.unreadable }
    return [Float](unsafeUninitializedCapacity: count) { out, initialized in
      data.withUnsafeBytes { raw in
        let base = raw.baseAddress! + entry.range.lowerBound
        switch entry.dtype {
        case "F32":
          for i in 0..<count { out[i] = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))) }
        case "F64":
          for i in 0..<count { out[i] = Float(Double(bitPattern: UInt64(littleEndian: base.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)))) }
        case "F16":
          for i in 0..<count { out[i] = Float(Float16(bitPattern: UInt16(littleEndian: base.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))) }
        case "BF16":
          for i in 0..<count { out[i] = Float(bitPattern: UInt32(UInt16(littleEndian: base.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))) << 16) }
        case "I8":
          let p = base.assumingMemoryBound(to: Int8.self)
          for i in 0..<count { out[i] = Float(p[i]) }
        case "U8":
          let p = base.assumingMemoryBound(to: UInt8.self)
          for i in 0..<count { out[i] = Float(p[i]) }
        case "F8_E4M3":
          let p = base.assumingMemoryBound(to: UInt8.self)
          for i in 0..<count { out[i] = F8_E4M3[Int(p[i])] }
        default: // F8_E5M2
          let p = base.assumingMemoryBound(to: UInt8.self)
          for i in 0..<count { out[i] = F8_E5M2[Int(p[i])] }
        }
      }
      initialized = count
    }
  }

  /// The weight at `name`, dequantized when ComfyUI quantized it. A quantized linear keeps its
  /// scale in `<module>.weight_scale` and its format in `<module>.comfy_quant` (UTF-8 JSON, e.g.
  /// `{"format":"int8_tensorwise","convrot":true,"convrot_groupsize":256}`). Dequantizing follows
  /// comfy-kitchen's eager backend (`dequantize_int8_simple`: `q.float() * scale`, the scale a
  /// scalar or one per row; `dequantize_int8_convrot_weight`: that, then un-rotated, see
  /// `ConvRot`). FP8 weights with a `weight_scale` are scaled the same way.
  func weight(_ name: String) throws -> Tensor<Float> {
    guard let entry = entries[name] else { throw Error.unreadable }
    var values = try floats(entry, name: name)
    let module = name.hasSuffix(".weight") ? String(name.dropLast(".weight".count)) : name
    var convRotGroupSize: Int?
    if let quant = entries[module + ".comfy_quant"] {
      let object = (try? JSONSerialization.jsonObject(with: bytes(quant))) as? [String: Any] ?? [:]
      let format = object["format"] as? String ?? "unknown"
      let readable = ["int8_tensorwise", "float8_e4m3fn", "float8_e5m2"]
      guard readable.contains(format) else { throw Error.unsupportedQuantization(name, format) }
      if object["convrot"] as? Bool == true {
        convRotGroupSize = (object["convrot_groupsize"] as? NSNumber)?.intValue ?? 256
      }
    }
    let scaleEntry = entries[module + ".weight_scale"] ?? entries[module + ".scale_weight"]
    if entry.dtype == "I8", scaleEntry == nil { throw Error.missingScale(name) }
    if let scaleEntry, entry.dtype == "I8" || entry.dtype.hasPrefix("F8") {
      let scale = try floats(scaleEntry, name: module + ".weight_scale")
      let rows = entry.shape.first ?? 1
      if scale.count == 1 {
        var s = scale[0]
        values.withUnsafeMutableBufferPointer { buffer in
          vDSP_vsmul(buffer.baseAddress!, 1, &s, buffer.baseAddress!, 1, vDSP_Length(buffer.count))
        }
      } else if scale.count == rows, rows > 0 {
        let columns = values.count / rows
        values.withUnsafeMutableBufferPointer { buffer in
          for r in 0..<rows {
            var s = scale[r]
            let row = buffer.baseAddress! + r * columns
            vDSP_vsmul(row, 1, &s, row, 1, vDSP_Length(columns))
          }
        }
      } else {
        throw Error.badScale(name)
      }
    }
    if let groupSize = convRotGroupSize {
      guard entry.shape.count == 2, ConvRot.isValid(groupSize), entry.shape[1] % groupSize == 0 else {
        throw Error.badRotation(name)
      }
      values = ConvRot.unrotate(values, groupSize: groupSize)
    }
    let shape = entry.shape.isEmpty ? [1] : entry.shape
    var tensor = Tensor<Float>(.CPU, format: .NCHW, shape: TensorShape(shape))
    tensor.withUnsafeMutableBytes { raw in
      values.withUnsafeBytes { raw.copyMemory(from: $0) }
    }
    return tensor
  }
}

/// ComfyUI's ConvRot: before row-wise INT8 quantization, each row of a linear weight is rotated in
/// blocks of `groupSize` input columns by a normalized regular Hadamard matrix, which spreads
/// outliers so they quantize better. Followed from comfy-kitchen
/// (github.com/Comfy-Org/comfy-kitchen, comfy_kitchen/tensor/int8_utils.py at bada696):
/// `_build_hadamard` makes H = H4 ⊗ H4 ⊗ … (Kronecker powers of the regular H4 below, so the size
/// must be a power of 4) divided by √size, which is symmetric and orthogonal; `_rotate_weight`
/// computes `W_rot = W_block @ H.T` per block; and `dequantize_int8_convrot_weight` undoes it by
/// rotating the dequantized weight the same way again (H·Hᵀ = I as H is symmetric orthogonal).
nonisolated enum ConvRot {
  static func isValid(_ size: Int) -> Bool {
    var n = size
    guard n >= 4 else { return false }
    while n % 4 == 0 { n /= 4 }
    return n == 1
  }

  /// The normalized `size`×`size` regular Hadamard matrix, row-major.
  static func hadamard(_ size: Int) -> [Float] {
    precondition(isValid(size))
    let h4: [Float] = [1, 1, 1, -1, 1, 1, -1, 1, 1, -1, 1, 1, -1, 1, 1, 1]
    var h = h4
    var n = 4
    // torch.kron(h, h4): entry (i·4 + k, j·4 + l) = h[i, j] · h4[k, l].
    while n < size {
      let m = n * 4
      var next = [Float](repeating: 0, count: m * m)
      for i in 0..<n {
        for j in 0..<n {
          let a = h[i * n + j]
          for k in 0..<4 {
            for l in 0..<4 { next[(i * 4 + k) * m + j * 4 + l] = a * h4[k * 4 + l] }
          }
        }
      }
      h = next
      n = m
    }
    let norm = 1 / Float(size).squareRoot()
    return h.map { $0 * norm }
  }

  /// `_rotate_weight`: each `groupSize` block of every row times Hᵀ.
  static func rotate(_ values: [Float], groupSize: Int) -> [Float] {
    let h = hadamard(groupSize)
    var transposed = [Float](repeating: 0, count: h.count)
    vDSP_mtrans(h, 1, &transposed, 1, vDSP_Length(groupSize), vDSP_Length(groupSize))
    var out = [Float](repeating: 0, count: values.count)
    // Rows × blocks of a row-major [rows, columns] matrix are contiguous [rows·blocks, groupSize].
    vDSP_mmul(
      values, 1, transposed, 1, &out, 1, vDSP_Length(values.count / groupSize), vDSP_Length(groupSize),
      vDSP_Length(groupSize))
    return out
  }

  /// The inverse, which comfy-kitchen computes with the same rotation.
  static func unrotate(_ values: [Float], groupSize: Int) -> [Float] {
    rotate(values, groupSize: groupSize)
  }
}
