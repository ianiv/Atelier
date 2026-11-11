import Foundation
@preconcurrency import NNC

/// ReCaVSR's files, as the model page (huggingface.co/kopper/ReCaVSR, Apache-2.0) publishes
/// them, in a "ReCaVSR" folder of the models directory: the DiT `transformer.safetensors`
/// (Wan2.2-TI2V-5B fine-tuned, BF16, with its source and recycle projections), the fixed prompt
/// `prompt.safetensors` and the FlashDecoder-S `flashdecoder.safetensors`. Read in place; the
/// optional 8-bit copy of the DiT is written beside them. The Wan VAE the page also lists isn't
/// needed: FlashDecoder replaces its decoder.
///
/// The network follows the reference inference code (github.com/kopperx/ReCaVSR,
/// `recavsr_infer/`).
nonisolated struct ReCaVSRFiles {
  /// Which copy of the DiT a job reads.
  enum Weights: String, CaseIterable, Codable, Sendable {
    /// The published BF16 weights, run in half precision.
    case full
    /// The local 8-bit copy: about half the memory.
    case eightBit

    var title: String {
      switch self {
      case .full: "Full"
      case .eightBit: "8-bit"
      }
    }
  }

  enum Failure: LocalizedError {
    case missing

    var errorDescription: String? { "ReCaVSR isn't downloaded." }
  }

  static let folderName = "ReCaVSR"
  /// Where they're downloaded from.
  static let repository = "kopper/ReCaVSR"

  let root: URL
  let weights: Weights

  var transformer: URL { root.appending(path: "transformer.safetensors") }
  var eightBitTransformer: URL { root.appending(path: Self.eightBitName) }
  var prompt: URL { root.appending(path: "prompt.safetensors") }
  var decoder: URL { root.appending(path: "flashdecoder.safetensors") }

  /// The 8-bit copy of the DiT, written by `ReCaVSRQuantizer`.
  static let eightBitName = "transformer_i8x.ckpt"

  /// The published files, relative to the folder, with their sizes in bytes.
  static let required: [(path: String, bytes: Int64)] = [
    ("transformer.safetensors", 10_603_673_624),
    ("prompt.safetensors", 4_194_392),
    ("flashdecoder.safetensors", 228_723_776),
  ]

  /// The folder in the models directory.
  static var folder: URL { URL(fileURLWithPath: AppSettings.modelsDirectory).appending(path: folderName) }

  /// Where a required file downloads from.
  static func source(_ path: String) -> URL {
    URL(string: "https://huggingface.co/\(repository)/resolve/main/\(path)")!
  }

  /// Whether every published file is there at its full size.
  static var downloaded: Bool {
    let root = folder
    return required.allSatisfy { file in
      let size = (try? FileManager.default.attributesOfItem(
        atPath: root.appending(path: file.path).path)[.size] as? Int64) ?? nil
      return size == file.bytes
    }
  }

  /// In the models directory, when the files `weights` reads are there: the published ones, and
  /// for `.eightBit` the finished 8-bit copy too.
  static func installed(_ weights: Weights) -> ReCaVSRFiles? {
    guard downloaded else { return nil }
    let files = ReCaVSRFiles(root: folder, weights: weights)
    if weights == .eightBit, !FileManager.default.fileExists(atPath: files.eightBitTransformer.path) {
      return nil
    }
    return files
  }
}

/// The released checkpoint's fixed configuration, from `checkpoints/model_config.json`,
/// `checkpoints/vae_config.json` and `runtime/constants.py`.
nonisolated enum ReCaVSRConfig {
  /// DiT width, heads and depth (model_config.json).
  static let hidden = 3072
  static let heads = 24
  static let headDimension = 128
  static let layers = 30
  static let feedForward = 14336
  /// Latent channels (the Wan2.2 VAE's z_dim).
  static let latentChannels = 48
  /// RGB pixels per latent and per DiT token (constants.py:11-12).
  static let latentStride = 16
  static let tokenStride = 32
  /// RGB frames and latent frames in the first block and each later one (constants.py:5-9).
  static let prefixFrames = 21
  static let prefixLatents = 6
  static let bodyFrames = 8
  static let bodyLatents = 2
  /// The temporal RoPE's training interval, in latents (constants.py:13).
  static let ropeWindow = 22
  /// The DiT's spatial attention window, in tokens (rows, columns) (constants.py:14).
  static let window = (height: 22, width: 40)
  /// The fixed timestep (constants.py:13).
  static let timestep = 1000.0

  /// The Wan2.2 VAE's per-channel latent statistics (vae_config.json `latents_mean`,
  /// `latents_std`): FlashDecoder reads `x0 * std + mean` (runtime/flashdecoder.py:61-66).
  static let latentMean: [Float] = [
    -0.2289, -0.0052, -0.1323, -0.2339, -0.2799, 0.0174, 0.1838, 0.1557, -0.1382, 0.0542, 0.2813,
    0.0891, 0.157, -0.0098, 0.0375, -0.1825, -0.2246, -0.1207, -0.0698, 0.5109, 0.2665, -0.2108,
    -0.2158, 0.2502, -0.2055, -0.0322, 0.1109, 0.1567, -0.0729, 0.0899, -0.2799, -0.123, -0.0313,
    -0.1649, 0.0117, 0.0723, -0.2839, -0.2083, -0.052, 0.3748, 0.0152, 0.1957, 0.1433, -0.2944,
    0.3573, -0.0548, -0.1681, -0.0667,
  ]
  static let latentStd: [Float] = [
    0.4765, 1.0364, 0.4514, 1.1677, 0.5313, 0.499, 0.4818, 0.5013, 0.8158, 1.0344, 0.5894, 1.0901,
    0.6885, 0.6165, 0.8454, 0.4978, 0.5759, 0.3523, 0.7135, 0.6804, 0.5833, 1.4146, 0.8986, 0.5659,
    0.7069, 0.5338, 0.4889, 0.4917, 0.4069, 0.4999, 0.6866, 0.4093, 0.5709, 0.6065, 0.6415, 0.4944,
    0.5726, 1.2042, 0.5458, 1.6887, 0.3971, 1.06, 0.3943, 0.5537, 0.5444, 0.4089, 0.7468, 0.7744,
  ]

  /// Runs `body` with MFA attention's Neural Accelerator path off (when `enabled`). On an M5 Max
  /// (2026-11) that path returned all zeros for some of the DiT's half-precision calls and wrong
  /// values for every one of FlashDecoder's float32 calls; the plain MFA kernels match the
  /// reference (`--recavsr-check`). Process-wide, so it's restored after.
  static func withAttentionWorkaround<R>(_ enabled: Bool = true, _ body: () throws -> R) rethrows -> R {
    guard enabled, !DynamicGraph.flags.contains(.disableMFANeuralAccelerators) else { return try body() }
    DynamicGraph.flags.insert(.disableMFANeuralAccelerators)
    defer { DynamicGraph.flags.remove(.disableMFANeuralAccelerators) }
    return try body()
  }
}

/// A safetensors file read a tensor at a time (`FileHandle`), so a checkpoint never sits in
/// memory whole. `Data(contentsOf:options: .mappedIfSafe)`, which `SafeTensors` uses, reads the
/// file in full when it's on an external volume, as models folders often are: 10.6 GB for
/// ReCaVSR's DiT, held while the weights it fills are on the GPU too.
final nonisolated class ReCaVSRCheckpoint {
  enum Failure: LocalizedError {
    case unreadable(String), missing(String)

    var errorDescription: String? {
      switch self {
      case .unreadable(let file): "Couldn't read \(file)."
      case .missing(let name): "The ReCaVSR checkpoint has no \(name)."
      }
    }
  }

  private struct Entry {
    var dtype: String
    var shape: [Int]
    var start: UInt64
    var end: UInt64
  }

  private let handle: FileHandle
  private let file: String
  private let entries: [String: Entry]

  init(_ url: URL) throws {
    file = url.lastPathComponent
    guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable(file) }
    self.handle = handle
    guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else { throw Failure.unreadable(file) }
    let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    guard length < 100_000_000, let header = try handle.read(upToCount: Int(length)),
          let json = try JSONSerialization.jsonObject(with: header) as? [String: Any]
    else { throw Failure.unreadable(file) }
    var entries: [String: Entry] = [:]
    for (name, value) in json {
      guard let value = value as? [String: Any], let dtype = value["dtype"] as? String,
            let shape = value["shape"] as? [Int], let offsets = value["data_offsets"] as? [Int], offsets.count == 2
      else { continue }
      entries[name] = Entry(
        dtype: dtype, shape: shape.isEmpty ? [1] : shape, start: 8 + length + UInt64(offsets[0]),
        end: 8 + length + UInt64(offsets[1]))
    }
    self.entries = entries
  }

  func contains(_ name: String) -> Bool { entries[name] != nil }

  /// The tensor, float32 on the CPU, in its checkpoint shape (BF16, F16 and F32 files).
  func tensor(_ name: String) throws -> Tensor<Float> {
    // The read's buffer is autoreleased; on a queue with no pool of its own it would stay until
    // the whole load ends, as much again as the weights.
    try autoreleasepool { try read(name) }
  }

  private func read(_ name: String) throws -> Tensor<Float> {
    guard let entry = entries[name] else { throw Failure.missing(name) }
    try handle.seek(toOffset: entry.start)
    guard let data = try handle.read(upToCount: Int(entry.end - entry.start)) else { throw Failure.unreadable(file) }
    let count = entry.shape.reduce(1, *)
    var tensor = Tensor<Float>(.CPU, format: .NCHW, shape: TensorShape(entry.shape))
    try tensor.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: Float.self)
      try data.withUnsafeBytes { source in
        switch entry.dtype {
        case "BF16":
          guard source.count == count * 2 else { throw Failure.unreadable(file) }
          let bits = source.bindMemory(to: UInt16.self)
          for i in 0..<count { out[i] = Float(bitPattern: UInt32(bits[i]) << 16) }
        case "F16":
          guard source.count == count * 2 else { throw Failure.unreadable(file) }
          let halves = source.bindMemory(to: Float16.self)
          for i in 0..<count { out[i] = Float(halves[i]) }
        case "F32":
          guard source.count == count * 4 else { throw Failure.unreadable(file) }
          _ = memcpy(out.baseAddress!, source.baseAddress!, count * 4)
        default:
          throw Failure.unreadable("\(file) (\(name) is \(entry.dtype))")
        }
      }
    }
    return tensor
  }
}
