import Diffusion
import Foundation
import NNC

/// FlashVSR's source projection: reads the source, already resized to the output size, in
/// pixels and turns each four frames into one frame of rows on the denoiser's token grid, which
/// the denoiser adds to its input. Two causal 3D convolutions (4×3×3, stride 2 in time) carry the
/// last two frames each reads from one call to the next, so the clip streams through without
/// restarting.
///
/// The first call takes frame 0 alone and makes no rows (it fills the carries as the reference
/// pads the start with that frame); every later call takes 4 frames and makes one row frame.
final class FlashVSRSourceProjection {
  /// The token grid: the output size over 16.
  let gridHeight: Int
  let gridWidth: Int
  private let stage1: Model
  private let stage2: Model
  private let graph: DynamicGraph
  /// The last 2 frames conv1 read (unshuffled), and the last 2 conv2 read (after norm1 and SiLU).
  private var carry1: DynamicGraph.Tensor<FloatType>?
  private var carry2: DynamicGraph.Tensor<FloatType>?

  init(graph: DynamicGraph, checkpoint: FlashVSRCheckpoint, gridHeight: Int, gridWidth: Int) throws {
    self.graph = graph
    self.gridHeight = gridHeight
    self.gridWidth = gridWidth
    let (conv1, norm1, stage1) = Self.stage(
      depth: 6, height: gridHeight, width: gridWidth, inChannels: 768, outChannels: 2048, name: "1")
    let (conv2, norm2, stage2) = Self.stage(
      depth: 4, height: gridHeight, width: gridWidth, inChannels: 2048, outChannels: 3072, name: "2")
    let input2 = Input()
    let linear = Dense(count: 1536, name: "linear")
    let rows = linear(stage2(input2).reshaped([gridHeight * gridWidth, 3072]))
    self.stage1 = stage1
    self.stage2 = Model([input2], [rows])
    stage1.compile(
      inputs: graph.variable(.GPU(0), .NHWC(6, gridHeight, gridWidth, 768), of: FloatType.self))
    self.stage2.compile(
      inputs: graph.variable(.GPU(0), .NHWC(4, gridHeight, gridWidth, 2048), of: FloatType.self))
    let normName = checkpoint.contains("norm1.weight") ? "weight" : "gamma"
    conv1.weight.copy(
      from: Self.im2colWeights(try checkpoint.tensor("conv1.weight"), out: 2048, in: 768))
    conv1.bias.copy(from: try checkpoint.tensor("conv1.bias", shape: [2048]))
    norm1.weight.copy(
      from: try checkpoint.tensor("norm1.\(normName)").reshaped(format: .NCHW, shape: [2048]))
    conv2.weight.copy(
      from: Self.im2colWeights(try checkpoint.tensor("conv2.weight"), out: 3072, in: 2048))
    conv2.bias.copy(from: try checkpoint.tensor("conv2.bias", shape: [3072]))
    norm2.weight.copy(
      from: try checkpoint.tensor("norm2.\(normName)").reshaped(format: .NCHW, shape: [3072]))
    linear.weight.copy(from: try checkpoint.tensor("linear_layers.0.weight", shape: [1536, 3072]))
    linear.bias.copy(from: try checkpoint.tensor("linear_layers.0.bias", shape: [1536]))
  }

  /// Causal conv3d (4×3×3, stride (2,1,1), spatial padding replicating the edge), then the
  /// reference's RMS norm (`F.normalize * sqrt(C) * gamma`) and SiLU. Takes `depth` frames
  /// `[depth, h, w, C]` (the carry first) and gives `(depth - 2) / 2` frames. The convolution
  /// runs as one matrix multiply over its 36 shifted views (im2col), which is far faster than
  /// a 3D convolution here; its weights are reordered to match (`im2colWeights`).
  private static func stage(
    depth: Int, height: Int, width: Int, inChannels: Int, outChannels: Int, name: String
  ) -> (Dense, RMSNorm, Model) {
    let x = Input()
    let frames = (depth - 4) / 2 + 1
    let padded = x.padded(.replicate, begin: [0, 1, 1, 0], end: [0, 1, 1, 0])
    let rowStride = (width + 2) * inChannels
    let frameStride = (height + 2) * rowStride
    var columns: [Model.IO] = []
    for o in 0..<frames {
      var views: [Model.IO] = []
      for kt in 0..<4 {
        for ky in 0..<3 {
          for kx in 0..<3 {
            views.append(
              padded.reshaped(
                [1, height, width, inChannels], offset: [2 * o + kt, ky, kx, 0],
                strides: [frameStride, rowStride, inChannels, 1]))
          }
        }
      }
      columns.append(Concat(axis: 3)(views).reshaped([height * width, 36 * inChannels]))
    }
    let patches = frames == 1 ? columns[0] : Concat(axis: 0)(columns)
    let conv = Dense(count: outChannels, name: "conv\(name)")
    var out = conv(patches).reshaped([frames, height, width, outChannels])
    let norm = RMSNorm(epsilon: 1e-12 / Float(outChannels), axis: [3], name: "norm\(name)")
    out = norm(out.to(.Float32)).swish().to(.Float16)
    return (conv, norm, Model([x], [out]))
  }

  /// A conv3d weight `[out, in, 4, 3, 3]` as the im2col matrix `[out, (t, y, x, in)]`.
  private static func im2colWeights(_ weight: Tensor<Float>, out: Int, in inChannels: Int)
    -> Tensor<FloatType>
  {
    var result = Tensor<FloatType>(.CPU, .WC(out, 36 * inChannels))
    weight.withUnsafeBytes { source in
      let w = source.bindMemory(to: Float.self)
      result.withUnsafeMutableBytes { target in
        let r = target.bindMemory(to: FloatType.self)
        for o in 0..<out {
          for i in 0..<inChannels {
            let base = (o * inChannels + i) * 36
            for tap in 0..<36 {
              r[o * 36 * inChannels + tap * inChannels + i] = FloatType(w[base + tap])
            }
          }
        }
      }
    }
    return result
  }

  /// Back to the start of a clip.
  func reset() {
    carry1 = nil
    carry2 = nil
  }

  /// Opens the stream with frame 0 (`[h, w, 768]`, unshuffled). Makes no rows.
  func open(_ frame: DynamicGraph.Tensor<FloatType>) {
    // conv1 reads frame 0 six times: the reference prepends three copies and the causal padding
    // two more.
    let input = concatenated(Array(repeating: frame, count: 6))
    carry1 = Functional.concat(axis: 0, frame, frame)
    carry2 = stage1(inputs: input)[0].as(of: FloatType.self)
  }

  /// The next row frame (`[h * w, 1536]`) from the next 4 frames (`[4, h, w, 768]`).
  func next(_ frames: DynamicGraph.Tensor<FloatType>) -> DynamicGraph.Tensor<FloatType> {
    guard let carry1, let carry2 else { preconditionFailure("open the stream first") }
    let h = gridHeight, w = gridWidth
    let input1 = Functional.concat(axis: 0, carry1, frames)
    self.carry1 = frames[2..<4, 0..<h, 0..<w, 0..<768].copied()
    let a = stage1(inputs: input1)[0].as(of: FloatType.self)
    let input2 = Functional.concat(axis: 0, carry2, a)
    self.carry2 = a
    return stage2(inputs: input2)[0].as(of: FloatType.self)
  }

  /// A frame of `rgb` (interleaved u8 RGB, `height`×`width`, multiples of 16) as the
  /// projection reads it: [-1, 1] (`u / 255 * 2 - 1`), 16×16 pixel-unshuffled to
  /// `[height / 16, width / 16, 768]` with channel `c * 256 + y * 16 + x`.
  static func unshuffled(_ rgb: [UInt8], width: Int, height: Int) -> Tensor<FloatType> {
    let h = height / 16, w = width / 16
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, h, w, 768))
    tensor.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: FloatType.self)
      rgb.withUnsafeBufferPointer { pixels in
        for oy in 0..<h {
          for ox in 0..<w {
            let base = (oy * w + ox) * 768
            for ky in 0..<16 {
              let row = ((oy * 16 + ky) * width + ox * 16) * 3
              for kx in 0..<16 {
                let pixel = row + kx * 3
                for c in 0..<3 {
                  let value = Float(pixels[pixel + c]) / 255 * 2 - 1
                  out[base + c * 256 + ky * 16 + kx] = FloatType(value)
                }
              }
            }
          }
        }
      }
    }
    return tensor
  }
}
