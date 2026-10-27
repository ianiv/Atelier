import Diffusion
import Fickling
import Foundation
import NNC
import ZIPFoundation

/// FlashVSR+'s files, as the model page publishes them, in a "FlashVSR+" folder of the models
/// directory: `turbo/` and `base/` (each `dit.safetensors` and `lq_proj_in.safetensors`), the
/// tiny decoder `TCDecoder.ckpt` and the fixed prompt `posi_prompt.pth`. Read in place, without
/// converting anything.
///
/// The network follows vpipe's Metal port (github.com/tgo-app-dev/vpipe, Apache-2.0, T-Go LLC),
/// which follows the reference (github.com/OpenImagingLab/FlashVSR_Plus).
struct FlashVSRFiles {
  enum Variant: String, CaseIterable, Codable, Sendable {
    /// 25 of the 30 layers attend a small neighborhood and remember one step: fast.
    case turbo
    /// Every layer searches wide: slower, a little more detail.
    case base
  }

  static let folderName = "FlashVSR+"
  /// Where they're downloaded from.
  static let repository = "ruchangyao/FlashVSR_plus"
  static let promptRepository = "deAPI-ai/flashvsr-v1-1"

  let root: URL
  let variant: Variant

  var dit: URL { root.appending(path: "\(variant.rawValue)/dit.safetensors") }
  var sourceProjection: URL { root.appending(path: "\(variant.rawValue)/lq_proj_in.safetensors") }
  var tinyDecoder: URL { root.appending(path: "TCDecoder.ckpt") }
  var prompt: URL { root.appending(path: "posi_prompt.pth") }

  /// The files each variant needs, relative to the folder, with their sizes in bytes.
  static func required(_ variant: Variant) -> [(path: String, bytes: Int64)] {
    [
      ("\(variant.rawValue)/dit.safetensors", 5_676_070_392),
      ("\(variant.rawValue)/lq_proj_in.safetensors", 1_151_384_272),
      ("TCDecoder.ckpt", 189_018_333),
      ("posi_prompt.pth", 4_195_504),
    ]
  }

  /// In the models directory, when every file `variant` needs is there.
  static func installed(_ variant: Variant) -> FlashVSRFiles? {
    let root = URL(fileURLWithPath: AppSettings.modelsDirectory).appending(path: folderName)
    let manager = FileManager.default
    for file in required(variant) {
      guard manager.fileExists(atPath: root.appending(path: file.path).path) else { return nil }
    }
    return FlashVSRFiles(root: root, variant: variant)
  }
}

/// A checkpoint's tensors by name, as CPU tensors of float32.
final class FlashVSRCheckpoint {
  enum Failure: LocalizedError {
    case unreadable(String), missing(String)

    var errorDescription: String? {
      switch self {
      case .unreadable(let file): "Couldn't read \(file)."
      case .missing(let name): "The FlashVSR+ checkpoint has no \(name)."
      }
    }
  }

  private let archive: TensorArchive
  private let states: [String: TensorDescriptor]

  init(_ url: URL) throws {
    if url.pathExtension == "safetensors" {
      guard let safeTensors = SafeTensors(url: url) else {
        throw Failure.unreadable(url.lastPathComponent)
      }
      archive = safeTensors
      states = safeTensors.states
    } else {
      guard let zip = try? Archive(url: url, accessMode: .read) else {
        throw Failure.unreadable(url.lastPathComponent)
      }
      let root = try Interpreter.unpickle(zip: zip)
      let dictionary = root["state_dict"] as? Interpreter.Dictionary ?? root
      var states: [String: TensorDescriptor] = [:]
      dictionary.forEach { key, value in
        if let value = value as? TensorDescriptor { states[key] = value }
      }
      archive = zip
      self.states = states
    }
  }

  var names: [String] { Array(states.keys) }

  func contains(_ name: String) -> Bool { states[name] != nil }

  /// The tensor, float32 on the CPU, in its checkpoint shape.
  func tensor(_ name: String) throws -> Tensor<Float> {
    guard let descriptor = states[name] else { throw Failure.missing(name) }
    return try descriptor.inflate(from: archive, of: Float.self)
  }

  /// The tensor as `FloatType`, reshaped to `shape` (its element count unchanged).
  func tensor(_ name: String, shape: TensorShape) throws -> Tensor<FloatType> {
    Tensor<FloatType>(from: try tensor(name)).reshaped(format: .NCHW, shape: shape)
  }
}
