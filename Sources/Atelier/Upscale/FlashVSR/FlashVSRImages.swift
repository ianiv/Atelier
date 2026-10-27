import CoreGraphics
import Diffusion
import Foundation
import NNC

/// The pictures around FlashVSR: the source stretched to the output size the way the reference
/// does (Pillow's bicubic), and the wavelet color fix that gives each restored frame its
/// source's low frequencies.
enum FlashVSRImages {
  /// `image` as interleaved u8 RGB at its own size.
  static func rgb(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
    let width = image.width, height = image.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var rgb = [UInt8](repeating: 0, count: width * height * 3)
    for i in 0..<(width * height) {
      rgb[i * 3] = rgba[i * 4]
      rgb[i * 3 + 1] = rgba[i * 4 + 1]
      rgb[i * 3 + 2] = rgba[i * 4 + 2]
    }
    return (rgb, width, height)
  }

  /// Pillow's bicubic (a = -0.5) filter taps for resizing `source` samples to `target`:
  /// per output sample, the first input sample and the normalized weights.
  private static func cubicTaps(source: Int, target: Int) -> [(start: Int, weights: [Float])] {
    let scale = Double(source) / Double(target)
    let filterScale = max(1, scale)
    let support = 2 * filterScale
    func cubic(_ x: Double) -> Double {
      let a = -0.5
      let x = abs(x)
      if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
      if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
      return 0
    }
    return (0..<target).map { o in
      let center = (Double(o) + 0.5) * scale
      let start = max(0, Int(center - support + 0.5))
      let end = min(source, Int(center + support + 0.5))
      var weights = (start..<end).map { Float(cubic((Double($0) - center + 0.5) / filterScale)) }
      let sum = weights.reduce(0, +)
      if sum != 0 { weights = weights.map { $0 / sum } }
      return (start, weights)
    }
  }

  /// `rgb` (interleaved u8, `width`×`height`) stretched to `targetWidth`×`targetHeight` with
  /// Pillow's bicubic weights, both passes in float and rounded once, as vpipe resizes the source.
  static func bicubic(
    _ rgb: [UInt8], width: Int, height: Int, targetWidth: Int, targetHeight: Int
  ) -> [UInt8] {
    let xTaps = cubicTaps(source: width, target: targetWidth)
    let yTaps = cubicTaps(source: height, target: targetHeight)
    // Horizontal pass into floats.
    var horizontal = [Float](repeating: 0, count: height * targetWidth * 3)
    rgb.withUnsafeBufferPointer { pixels in
      horizontal.withUnsafeMutableBufferPointer { out in
        for y in 0..<height {
          let row = y * width * 3
          for (x, tap) in xTaps.enumerated() {
            var r: Float = 0, g: Float = 0, b: Float = 0
            for (k, weight) in tap.weights.enumerated() {
              let pixel = row + (tap.start + k) * 3
              r += weight * Float(pixels[pixel])
              g += weight * Float(pixels[pixel + 1])
              b += weight * Float(pixels[pixel + 2])
            }
            let o = (y * targetWidth + x) * 3
            out[o] = r
            out[o + 1] = g
            out[o + 2] = b
          }
        }
      }
    }
    // Vertical pass, rounded to u8.
    var result = [UInt8](repeating: 0, count: targetHeight * targetWidth * 3)
    horizontal.withUnsafeBufferPointer { input in
      result.withUnsafeMutableBufferPointer { out in
        for (y, tap) in yTaps.enumerated() {
          for x in 0..<(targetWidth * 3) {
            var value: Float = 0
            for (k, weight) in tap.weights.enumerated() {
              value += weight * input[(tap.start + k) * targetWidth * 3 + x]
            }
            out[y * targetWidth * 3 + x] = UInt8(max(0, min(255, value + 0.5)))
          }
        }
      }
    }
    return result
  }

  /// `rgb` (interleaved u8) as `[1, height, width, 3]` in [-1, 1] (`u / 127.5 - 1`).
  static func tensor(_ rgb: [UInt8], width: Int, height: Int) -> Tensor<FloatType> {
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, height, width, 3))
    tensor.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: FloatType.self)
      for i in 0..<(width * height * 3) { out[i] = FloatType(Float(rgb[i]) / 127.5 - 1) }
    }
    return tensor
  }

  /// The wavelet color fix (the reference's `--cf`): `clamp(x - low(x) + low(ref), -1, 1)`, where
  /// `low` is `levels` passes of a [1 2 1]ᵀ[1 2 1] / 16 blur, its taps 1, 2, 4, ... pixels apart,
  /// edges replicated. Built for one frame size; inputs `[1, height, width, 3]` in [-1, 1].
  final class ColorFix {
    private let model: Model

    init(graph: DynamicGraph, width: Int, height: Int, levels: Int = 5) {
      let x = Input()
      let reference = Input()
      var blurs: [Convolution] = []
      func low(_ input: Model.IO) -> Model.IO {
        var out = input
        for level in 0..<levels {
          let d = 1 << level
          let blur = Convolution(
            groups: 3, filters: 3, filterSize: [3, 3], dilation: [d, d], noBias: true,
            hint: Hint(stride: [1, 1], border: Hint.Border(begin: [0, 0], end: [0, 0])),
            format: .OIHW, name: "blur\(level)")
          blurs.append(blur)
          out = blur(out.padded(.replicate, begin: [0, d, d, 0], end: [0, d, d, 0]))
        }
        return out
      }
      let xFloat = x.to(.Float32)
      let out = (xFloat - low(xFloat) + low(reference.to(.Float32))).clamped(-1...1)
      model = Model([x, reference], [out.to(.Float16)])
      let zeros = graph.variable(.GPU(0), .NHWC(1, height, width, 3), of: FloatType.self)
      zeros.full(0)
      model.compile(inputs: zeros, zeros)
      var kernel = Tensor<Float>(.CPU, .NCHW(3, 1, 3, 3))
      let taps: [Float] = [0.25, 0.5, 0.25]
      for c in 0..<3 {
        for i in 0..<3 {
          for j in 0..<3 { kernel[c, 0, i, j] = taps[i] * taps[j] }
        }
      }
      for blur in blurs { blur.weight.copy(from: kernel) }
    }

    func callAsFunction(
      _ x: DynamicGraph.Tensor<FloatType>, reference: DynamicGraph.Tensor<FloatType>
    ) -> DynamicGraph.Tensor<FloatType> {
      model(inputs: x, reference)[0].as(of: FloatType.self)
    }
  }
}

/// `tensors` joined along `axis` (a lone tensor as is).
func concatenated<T: TensorNumeric>(_ tensors: [DynamicGraph.Tensor<T>], axis: Int = 0)
  -> DynamicGraph.Tensor<T>
{
  if tensors.count == 1 { return tensors[0] }
  return Concat(axis: axis)(inputs: tensors[0], Array(tensors.dropFirst()))[0].as(of: T.self)
}
