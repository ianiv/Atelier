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
