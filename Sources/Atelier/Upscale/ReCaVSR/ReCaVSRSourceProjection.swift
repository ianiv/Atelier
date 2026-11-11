@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

/// ReCaVSR's source projection (`LQ4xProj`, models/lq_proj.py): reads the source, already
/// stretched to the output size, in [-1, 1], and turns it into rows on the DiT's token grid,
/// one latent frame per four source frames. A 16×16 pixel unshuffle, then two causal 3D
/// convolutions (4×3×3, stride 2 in time; the second stride 2 in space too, zero-padded), each
/// with a channel RMS norm and SiLU, then a linear layer.
///
/// Each convolution's 4 temporal taps run as one 2D convolution over the 4 frames stacked on
/// channels (tap-major), its weight `[O, C, 4, 3, 3]` reordered to `[O, 4C, 3, 3]`. The stream
/// carries the last two frames each convolution read, as `forward_streaming` keeps its history
/// (lq_proj.py:75-139): the first block pads its start with three copies of frame 0, so its 21
/// frames make 11 and then 6 outputs; each later 8 make 4 and then 2.
final nonisolated class ReCaVSRSourceProjection {
  /// The source grid (the padded output over 16) and the token grid (over 32).
  let height: Int
  let width: Int
  private let graph: DynamicGraph
  private let stage1: Model
  private let stage2: Model
  /// out_proj, over rows (t, h, w).
  private let output: Model
  /// The last 2 unshuffled frames conv1 read, and the last 2 outputs of stage 1.
  private var carry1: DynamicGraph.Tensor<FloatType>?
  private var carry2: DynamicGraph.Tensor<FloatType>?

  /// For a padded output of `height`×`width` pixels (multiples of 32).
  init(graph: DynamicGraph, checkpoint: ReCaVSRCheckpoint, height: Int, width: Int) throws {
    self.graph = graph
    self.height = height / 16
    self.width = width / 16
    let h = self.height, w = self.width
    func stage(_: Int, _ outChannels: Int, stride: Int, name: String) -> (Convolution, RMSNorm, Model) {
      let x = Input()
      let conv = Convolution(
        groups: 1, filters: outChannels, filterSize: [3, 3],
        hint: Hint(stride: [stride, stride], border: Hint.Border(begin: [1, 1], end: [1, 1])),
        format: .OIHW, name: "conv\(name)")
      let norm = RMSNorm(epsilon: 1e-6, axis: [3], name: "norm\(name)")
      return (conv, norm, Model([x], [norm(conv(x).to(.Float32)).swish().to(.Float16)]))
    }
    let (conv1, norm1, stage1) = stage(4 * 768, 2048, stride: 1, name: "1")
    let (conv2, norm2, stage2) = stage(4 * 2048, 3072, stride: 2, name: "2")
    let rows = Input()
    let linear = Dense(count: 3072, name: "out_proj")
    output = Model([rows], [linear(rows)])
    self.stage1 = stage1
    self.stage2 = stage2
    stage1.compile(inputs: graph.variable(.GPU(0), .NHWC(11, h, w, 4 * 768), of: FloatType.self))
    stage2.compile(inputs: graph.variable(.GPU(0), .NHWC(6, h, w, 4 * 2048), of: FloatType.self))
    output.compile(inputs: graph.variable(.GPU(0), .WC(6 * (h / 2) * (w / 2), 3072), of: FloatType.self))
    conv1.weight.copy(from: try Self.tapMajor(checkpoint.tensor("lq_proj.conv1.weight"), out: 2048, in: 768, graph: graph))
    conv1.bias.copy(from: Tensor<FloatType>(from: try checkpoint.tensor("lq_proj.conv1.bias").reshaped(format: .NCHW, shape: [2048])))
    norm1.weight.copy(from: try checkpoint.tensor("lq_proj.norm1.weight").reshaped(format: .NCHW, shape: [2048]))
    conv2.weight.copy(from: try Self.tapMajor(checkpoint.tensor("lq_proj.conv2.weight"), out: 3072, in: 2048, graph: graph))
    conv2.bias.copy(from: Tensor<FloatType>(from: try checkpoint.tensor("lq_proj.conv2.bias").reshaped(format: .NCHW, shape: [3072])))
    norm2.weight.copy(from: try checkpoint.tensor("lq_proj.norm2.weight").reshaped(format: .NCHW, shape: [3072]))
    linear.weight.copy(from: Tensor<FloatType>(from: try checkpoint.tensor("lq_proj.out_proj.weight").reshaped(format: .NCHW, shape: [3072, 3072])))
    linear.bias.copy(from: Tensor<FloatType>(from: try checkpoint.tensor("lq_proj.out_proj.bias").reshaped(format: .NCHW, shape: [3072])))
  }

  /// A conv3d weight `[O, C, 4, 3, 3]` as the 2D weight `[O, 4C, 3, 3]` over tap-major stacked
  /// channels (input channel t * C + c), reordered on the GPU.
  private static func tapMajor(_ weight: Tensor<Float>, out: Int, in channels: Int, graph: DynamicGraph)
    -> Tensor<FloatType>
  {
    let variable = graph.variable(Tensor<FloatType>(from: weight).toGPU(0))
      .reshaped(format: .NCHW, shape: [out, channels, 4, 9])
    return variable.permuted(0, 2, 1, 3).copied().reshaped(format: .NCHW, shape: [out, 4 * channels, 3, 3])
      .rawValue.toCPU()
  }

  /// Back to the start of a clip.
  func reset() {
    carry1 = nil
    carry2 = nil
  }

  /// Frames `[n, 16h, 16w, 3]` in [-1, 1] unshuffled to `[n, h, w, 768]`, channel
  /// `c * 256 + y * 16 + x` (lq_proj.py:278-284).
  func unshuffled(_ frames: DynamicGraph.Tensor<FloatType>) -> DynamicGraph.Tensor<FloatType> {
    let n = frames.shape[0]
    return frames.reshaped(format: .NHWC, shape: [n, height, 16, width, 16, 3]).permuted(0, 1, 3, 5, 2, 4)
      .copied().reshaped(.NHWC(n, height, width, 768))
  }

  /// The causal convolution's outputs over `frames` (`[n, h, w, C]`): output j stacks frames
  /// 2j … 2j + 3.
  private static func stacked(_ frames: DynamicGraph.Tensor<FloatType>) -> DynamicGraph.Tensor<FloatType> {
    let shape = frames.shape
    let n = shape[0], h = shape[1], w = shape[2], c = shape[3]
    let outputs = (n - 4) / 2 + 1
    var rows: [DynamicGraph.Tensor<FloatType>] = []
    for j in 0..<outputs {
      let taps = (0..<4).map { t in frames[(2 * j + t)..<(2 * j + t + 1), 0..<h, 0..<w, 0..<c] }
      rows.append(Functional.concat(axis: 3, taps[0], taps[1], taps[2], taps[3]))
    }
    return concatenated(rows)
  }

  /// The rows for the next block of source frames (`[n, h, w, 768]` unshuffled; 21 for the
  /// first block, 8 after): `[latents * tokens, 3072]`, latents 6 then 2.
  func next(_ frames: DynamicGraph.Tensor<FloatType>) -> DynamicGraph.Tensor<FloatType> {
    let h = height, w = width
    func last2(_ x: DynamicGraph.Tensor<FloatType>) -> DynamicGraph.Tensor<FloatType> {
      let s = x.shape
      return x[(s[0] - 2)..<s[0], 0..<s[1], 0..<s[2], 0..<s[3]].copied()
    }
    let input1: DynamicGraph.Tensor<FloatType>
    if let carry1 {
      input1 = Functional.concat(axis: 0, carry1, frames)
    } else {
      let first = frames[0..<1, 0..<h, 0..<w, 0..<768]
      input1 = Functional.concat(axis: 0, first, first, first, frames)
    }
    carry1 = last2(frames)
    let a = stage1(inputs: Self.stacked(input1))[0].as(of: FloatType.self)
    let input2: DynamicGraph.Tensor<FloatType>
    if let carry2 {
      input2 = Functional.concat(axis: 0, carry2, a)
    } else {
      let first = a[0..<1, 0..<h, 0..<w, 0..<2048]
      input2 = Functional.concat(axis: 0, first, first, first, a)
    }
    carry2 = last2(a)
    let b = stage2(inputs: Self.stacked(input2))[0].as(of: FloatType.self)
    let s = b.shape
    return output(inputs: b.reshaped(.WC(s[0] * s[1] * s[2], 3072)))[0].as(of: FloatType.self)
  }
}
