import CoreGraphics
@preconcurrency import Diffusion
import Foundation
@preconcurrency import ModelZoo
@preconcurrency import NNC

/// Extract Depth Map: turns an image into a depth map with the engine's Depth Anything v2
/// (`ImageGeneratorUtils.extractDepthMap`, the estimator Draw Things runs for depth control) and
/// saves it as a new step after the image. Grey, near white and far black, as Draw Things' depth
/// hint is (`LocalImageGenerator`'s `.depth` control: `0.5 * (depth + 1)` copied into R, G and B),
/// so the result goes straight back in as a depth ControlNet or depth model's input.
///
/// The job runs in `CreateModel.runDepthMap(_:request:job:)`; the estimate in
/// `GenerationEngine.depthMap(image:)`.
nonisolated enum DepthMap {
  /// The model file, as Draw Things names it (`EverythingZoo`). The engine finds it by name in
  /// the models folders (`EverythingZoo.filePathForModelDownloaded`, which is
  /// `ModelZoo.filePathForModelDownloaded`: every folder Atelier hands MGK), so a copy Draw Things
  /// downloaded into a folder Atelier reads counts.
  static let modelFile = "depth_anything_v2.0_f16.ckpt"
  /// Its size, for the download sheet before the server says (static.libnnc.org's copy).
  static let modelBytes: Int64 = 669_720_576
  static let modelURL = URL(string: "https://static.libnnc.org/\(modelFile)")!
  /// The checksum Draw Things checks its download against.
  static var modelSHA256: String? { EverythingZoo.fileSHA256ForModelDownloaded(modelFile) }
  /// The menu command's and Queue row's symbol.
  static let symbol = "square.3.layers.3d.down.right"

  /// Whether the model is in a models folder the engine reads (`ImageGeneratorUtils.isDepthModelAvailable`).
  static var isModelInstalled: Bool { EverythingZoo.isModelDownloaded(modelFile) }

  /// A queued Extract Depth Map (`GenerationEngine.Request.depthMap`): which image, in which
  /// project. It names its project, as `ColorMatch.Job` does, because it reads from and saves into
  /// that one whichever project is open when it runs.
  struct Job: Codable, Hashable, Sendable {
    var project: String
    /// The step whose image it reads (an Imported entry's too), by the key History lists it by,
    /// which stays the same when steps are renumbered.
    var sourceTensorId: Int64

    /// What the saved step records.
    var record: Record { Record(model: DepthMap.modelFile) }

    /// The same image in the same project: its depth map would be the same, so it's never queued twice.
    func isSameJob(as other: Job) -> Bool {
      project == other.project && sourceTensorId == other.sourceTensorId
    }
  }

  /// What a step Extract Depth Map made keeps in its `profile_data` (`depth_map`), so History,
  /// agents and Use Settings know what it is. Only the model's name: the image it was made from is
  /// the step's input (`input_tensor_id`), as for Match Colors.
  struct Record: Codable, Hashable, Sendable {
    var model: String

    init(model: String) { self.model = model }

    /// A name from a project file is untrusted: kept only when it's a plain file name of sane length.
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil
      self.model = model.flatMap { $0.count <= 255 && !$0.contains("/") ? $0 : nil } ?? DepthMap.modelFile
    }

    private enum CodingKeys: String, CodingKey { case model }
  }

  /// The image tensor (`[1, H, W, 3]` in [-1, 1], as `ImageTensor` keeps images) of a depth
  /// estimate: `depth` is `[1, H, W, 1]` with near large, as `ImageGeneratorUtils.extractDepthMap`
  /// returns it, min-max scaled to [-1, 1]. Each value goes into R, G and B, so near is white and
  /// far black once the tensor is an image (`ImageTensor.cgImage`, `(v + 1) * 127.5`), which is
  /// Draw Things' `0.5 * (depth + 1)` in its [0, 1] hint space. Values are clamped to [-1, 1] and a
  /// non-finite one counts as far: a flat image leaves the estimate unscaled, and a bad weight
  /// could give NaN. Nil for a tensor of another shape.
  static func rgb(depth: Tensor<FloatType>) -> Tensor<FloatType>? {
    let shape = depth.shape
    guard shape.count == 4, shape[0] >= 1, shape[1] > 0, shape[2] > 0, shape[3] >= 1 else { return nil }
    let height = shape[1], width = shape[2], channels = shape[3]
    var result = Tensor<FloatType>(.CPU, .NHWC(1, height, width, 3))
    depth.withUnsafeBytes { raw in
      let values = raw.bindMemory(to: FloatType.self)
      result.withUnsafeMutableBytes { out in
        let rgb = out.bindMemory(to: FloatType.self)
        for pixel in 0..<(width * height) {
          let value = FloatType(clamped(Float(values[pixel * channels])))
          rgb[pixel * 3] = value
          rgb[pixel * 3 + 1] = value
          rgb[pixel * 3 + 2] = value
        }
      }
    }
    return result
  }

  /// `value` in [-1, 1]; a non-finite one is -1 (far).
  static func clamped(_ value: Float) -> Float {
    guard value.isFinite else { return -1 }
    return min(max(value, -1), 1)
  }

  nonisolated enum Failure: LocalizedError {
    case modelMissing, video, unreadable, noSettings, projectMissing(String), stepMissing(String), failed(String)

    var errorDescription: String? {
      switch self {
      case .modelMissing:
        "The depth model (Depth Anything v2, \(DepthMap.modelFile)) isn't in a models folder. Choose Extract Depth Map in the canvas menu once to download it."
      case .video: "Extract Depth Map works on images, not videos."
      case .unreadable: "The image couldn't be read."
      case .noSettings: "There are no settings to save the result with yet: wait for the model list to load."
      case .projectMissing(let name): "The project “\(name)” the image was in is no longer there."
      case .stepMissing(let name): "The image is no longer in the project “\(name)”."
      case .failed(let message): message
      }
    }
  }
}
