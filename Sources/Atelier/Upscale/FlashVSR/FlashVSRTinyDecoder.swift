import Diffusion
import Foundation
import NNC

/// FlashVSR's tiny conditional decoder (`TCDecoder.ckpt`, a TAEHV-style decoder): turns each
/// latent frame into 4 frames at 8× its size, reading the source (resized to the output size)
/// beside the latent. Its MemBlocks read their own previous input too, which it carries from one
/// latent frame to the next, so a clip decodes in pieces exactly as in one pass.
///
/// A stream's first latent frame makes 1 frame (its first 3 are dropped); each later one makes 4.
final class FlashVSRTinyDecoder {
  let latentHeight: Int
  let latentWidth: Int
  /// Latent frames 1×: conv, conv, MemBlocks 5–7, then ×2, TGrow (stride 1), conv, MemBlocks 11–13,
  /// then ×2 and TGrow (stride 2) into two sub-frames.
  private let stageA: Model
  /// At 4×: conv, MemBlocks 17–19, ×2, TGrow (stride 2) into two sub-frames.
  private let stageB: Model
  /// At 8×: conv, ReLU, conv, ReLU, conv to RGB.
  private let stageC: Model
  private let graph: DynamicGraph
  /// The previous input of each MemBlock (zeros at the start of a stream).
  private var pastA: [DynamicGraph.Tensor<FloatType>] = []
  private var pastB: [DynamicGraph.Tensor<FloatType>] = []
  /// Raw frames made so far in the stream, counting the dropped first 3.
  private var rawFrames = 0

  init(graph: DynamicGraph, checkpoint: FlashVSRCheckpoint, latentHeight: Int, latentWidth: Int)
    throws
  {
    self.graph = graph
    self.latentHeight = latentHeight
    self.latentWidth = latentWidth
    let h = latentHeight, w = latentWidth
    var loaders: [(Model.Parameters, String, TensorShape)] = []
    func conv(_ index: Int, _ inChannels: Int, _ outChannels: Int, size: Int = 3, bias: Bool, name: String? = nil)
      -> Convolution
    {
      let key = name ?? "decoder.\(index)"
      let conv = Convolution(
        groups: 1, filters: outChannels, filterSize: [size, size], noBias: !bias,
        hint: Hint(
          stride: [1, 1],
          border: Hint.Border(begin: [size / 2, size / 2], end: [size / 2, size / 2])),
        format: .OIHW, name: key)
      loaders.append((conv.weight, "\(key).weight", [outChannels, inChannels, size, size]))
      if bias { loaders.append((conv.bias, "\(key).bias", [outChannels])) }
      return conv
    }
    /// MemBlock: ReLU(conv4(ReLU(conv2(ReLU(conv0(cat[x, past]))))) + x).
    func memBlock(_ index: Int, _ channels: Int, _ x: Model.IO, _ past: Model.IO) -> Model.IO {
      let conv0 = conv(0, 2 * channels, channels, bias: true, name: "decoder.\(index).conv.0")
      let conv2 = conv(0, channels, channels, bias: true, name: "decoder.\(index).conv.2")
      let conv4 = conv(0, channels, channels, bias: true, name: "decoder.\(index).conv.4")
      var out = conv0(Functional.concat(axis: 3, x, past)).ReLU()
      out = conv2(out).ReLU()
      out = conv4(out)
      return (out + x).ReLU()
    }
    func upsample(_ x: Model.IO) -> Model.IO {
      Upsample(.nearest, widthScale: 2, heightScale: 2)(x)
    }

    // Stage A, at h×w, then 2h×2w, ending in TGrow 15's two sub-frames at 4h×4w.
    do {
      let x = Input()
      let pasts = (0..<6).map { _ in Input() }
      var out = conv(1, 784, 512, bias: true)((3 * (x * (1.0 / 3)).tanh()).to(.Float16)).ReLU()
      out = conv(3, 512, 512, bias: false)(out).ReLU()
      var inputs: [Model.IO] = []
      for (slot, index) in [5, 6, 7].enumerated() {
        inputs.append(out)
        out = memBlock(index, 512, out, pasts[slot])
      }
      out = upsample(out)
      out = conv(9, 512, 512, size: 1, bias: false, name: "decoder.9.conv")(out)
      out = conv(10, 512, 256, bias: false)(out)
      for (slot, index) in [11, 12, 13].enumerated() {
        inputs.append(out)
        out = memBlock(index, 256, out, pasts[3 + slot])
      }
      out = upsample(out)
      out = conv(15, 256, 512, size: 1, bias: false, name: "decoder.15.conv")(out)
      stageA = Model([x] + pasts, [out] + inputs)
    }
    // Stage B, one sub-frame at 4h×4w, ending in TGrow 21's two sub-frames at 8h×8w.
    do {
      let x = Input()
      let pasts = (0..<3).map { _ in Input() }
      var out = conv(16, 256, 128, bias: false)(x)
      var inputs: [Model.IO] = []
      for (slot, index) in [17, 18, 19].enumerated() {
        inputs.append(out)
        out = memBlock(index, 128, out, pasts[slot])
      }
      out = upsample(out)
      out = conv(21, 128, 256, size: 1, bias: false, name: "decoder.21.conv")(out)
      stageB = Model([x] + pasts, [out] + inputs)
    }
    // Stage C, one frame at 8h×8w.
    do {
      let x = Input()
      var out = conv(22, 128, 128, bias: false)(x).ReLU()
      out = conv(24, 128, 128, bias: false)(out).ReLU()
      out = conv(26, 128, 3, bias: true)(out)
      stageC = Model([x], [out])
    }

    func zeros(_ height: Int, _ width: Int, _ channels: Int) -> DynamicGraph.Tensor<FloatType> {
      let tensor = graph.variable(.GPU(0), .NHWC(1, height, width, channels), of: FloatType.self)
      tensor.full(0)
      return tensor
    }
    let input = zeros(h, w, 784)
    stageA.compile(
      inputs: [input] + (0..<3).map { _ in zeros(h, w, 512) } + (0..<3).map { _ in zeros(2 * h, 2 * w, 256) })
    stageB.compile(inputs: [zeros(4 * h, 4 * w, 256)] + (0..<3).map { _ in zeros(4 * h, 4 * w, 128) })
    stageC.compile(inputs: zeros(8 * h, 8 * w, 128))
    for (parameters, name, shape) in loaders {
      parameters.copy(from: try checkpoint.tensor(name, shape: shape))
    }
    reset()
  }

  /// Back to the start of a stream.
  func reset() {
    let h = latentHeight, w = latentWidth
    func zeros(_ height: Int, _ width: Int, _ channels: Int) -> DynamicGraph.Tensor<FloatType> {
      let tensor = graph.variable(.GPU(0), .NHWC(1, height, width, channels), of: FloatType.self)
      tensor.full(0)
      return tensor
    }
    pastA = (0..<3).map { _ in zeros(h, w, 512) } + (0..<3).map { _ in zeros(2 * h, 2 * w, 256) }
    pastB = (0..<3).map { _ in zeros(4 * h, 4 * w, 128) }
    rawFrames = 0
  }

  /// Decodes the next latent frame (`[1, h, w, 16]`, as the denoiser left it) with the source
  /// frames it covers (`[1, h, w, 768]`, packed by `packed(_:)`), and returns its frames as
  /// `[1, 8h, 8w, 3]` in about [-1, 1] (not clamped), the stream's first three left out.
  func decode(
    latent: DynamicGraph.Tensor<FloatType>, source: DynamicGraph.Tensor<FloatType>
  ) -> [DynamicGraph.Tensor<FloatType>] {
    let h = latentHeight, w = latentWidth
    let input = Functional.concat(axis: 3, source, latent)
    let a = stageA(inputs: input, pastA).map { $0.as(of: FloatType.self) }
    pastA = Array(a[1...])
    var frames: [DynamicGraph.Tensor<FloatType>] = []
    for sub in 0..<2 {
      let x = a[0][0..<1, 0..<(4 * h), 0..<(4 * w), (sub * 256)..<((sub + 1) * 256)].copied()
      let b = stageB(inputs: x, pastB).map { $0.as(of: FloatType.self) }
      pastB = Array(b[1...])
      for subsub in 0..<2 {
        defer { rawFrames += 1 }
        // The stream's first three raw frames only feed the memories.
        guard rawFrames >= 3 else { continue }
        let y = b[0][0..<1, 0..<(8 * h), 0..<(8 * w), (subsub * 128)..<((subsub + 1) * 128)].copied()
        let rgb = stageC(inputs: y)[0].as(of: FloatType.self)
        frames.append(2 * rgb - 1)
      }
    }
    return frames
  }

  /// The four source frames a latent frame covers (`[8h, 8w]` interleaved u8 RGB), packed as the
  /// decoder reads them: [-1, 1] (`u / 127.5 - 1`), channel `((c * 4 + f) * 8 + y) * 8 + x` for
  /// pixel (y, x) of each 8×8 block.
  static func packed(_ frames: [[UInt8]], latentHeight h: Int, latentWidth w: Int) -> Tensor<FloatType> {
    precondition(frames.count == 4)
    let width = 8 * w
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, h, w, 768))
    tensor.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: FloatType.self)
      for (f, frame) in frames.enumerated() {
        frame.withUnsafeBufferPointer { pixels in
          for y in 0..<h {
            for x in 0..<w {
              let base = (y * w + x) * 768
              for hh in 0..<8 {
                let row = ((y * 8 + hh) * width + x * 8) * 3
                for ww in 0..<8 {
                  for c in 0..<3 {
                    let value = Float(pixels[row + ww * 3 + c]) / 127.5 - 1
                    out[base + ((c * 4 + f) * 8 + hh) * 8 + ww] = FloatType(value)
                  }
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
