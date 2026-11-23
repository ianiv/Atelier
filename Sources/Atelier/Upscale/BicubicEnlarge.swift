import CoreGraphics
import Dispatch
import Foundation

/// Enlarges an image with bicubic interpolation the way the engine's command line tool does before
/// it gives an image to a model (`DrawThingsCLI.resizeImage`, ccv's `ccv_resample` with
/// `CCV_INTER_CUBIC`): Keys' kernel with a = -0.75, as OpenCV and torchvision upsample. SeedVR2 was
/// trained on bicubic-upsampled inputs, so a smoother or sharper stretch (CoreGraphics' `.high`)
/// moves its result. `Edit/Resample.swift` is a different filter (Pillow's a = -0.5, bit-matched
/// for grain) and stays as it is.
nonisolated enum BicubicEnlarge {
  /// Keys' cubic convolution kernel at distance `x` from a tap.
  static func keys(_ x: Double, a: Double = -0.75) -> Double {
    let x = abs(x)
    if x <= 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
    if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
    return 0
  }

  /// One output coordinate's four source taps and their weights.
  private struct Taps {
    var first: Int
    var weights: [Float]
  }

  /// The taps for each of `count` outputs along an axis, enlarged by
  /// `scale` (source pixels per output pixel, below 1). Centers line up as
  /// `source = (output + 0.5) * scale - 0.5`; taps off the edge repeat the edge pixel (clamping
  /// happens when they are read, so weights still sum to 1).
  private static func taps(count: Int, scale: Double) -> [Taps] {
    (0..<count).map { index in
      let center = (Double(index) + 0.5) * scale - 0.5
      let base = Int(center.rounded(.down))
      let fraction = center - Double(base)
      var weights = (0..<4).map { Float(keys(fraction - Double($0 - 1))) }
      let sum = weights.reduce(0, +)
      if sum != 0 { weights = weights.map { $0 / sum } }
      return Taps(first: base - 1, weights: weights)
    }
  }

  /// `image` covered to exactly `width`×`height` and center-cropped, as an sRGB 8-bit RGBA image
  /// with premultiplied alpha (the colors are resized premultiplied, so what a transparent pixel
  /// stores doesn't bleed into its neighbors). Nil when the image would shrink on an axis, which
  /// isn't an enlargement, or when it can't be drawn.
  static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    let sourceWidth = image.width
    let sourceHeight = image.height
    guard sourceWidth > 0, sourceHeight > 0, width > 0, height > 0 else { return nil }
    // `loadTrainingTensor`'s fit: scale to cover, then crop.
    let scaledWidth: Int
    let scaledHeight: Int
    if sourceWidth * height > sourceHeight * width {
      scaledWidth = Int((Double(sourceWidth) * Double(height) / Double(sourceHeight)).rounded())
      scaledHeight = height
    } else {
      scaledWidth = width
      scaledHeight = Int((Double(sourceHeight) * Double(width) / Double(sourceWidth)).rounded())
    }
    guard scaledWidth >= sourceWidth, scaledHeight >= sourceHeight, scaledWidth >= width, scaledHeight >= height
    else { return nil }

    // The source as 8-bit premultiplied RGBA in sRGB.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue
    var source = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
    let drawn = source.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: sourceWidth, height: sourceHeight, bitsPerComponent: 8,
        bytesPerRow: sourceWidth * 4, space: space, bitmapInfo: bitmap)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
      return true
    }
    guard drawn else { return nil }

    let horizontal = taps(count: scaledWidth, scale: Double(sourceWidth) / Double(scaledWidth))
    let vertical = taps(count: scaledHeight, scale: Double(sourceHeight) / Double(scaledHeight))

    // Pass 1: every source row to the scaled width.
    var wide = [Float](repeating: 0, count: scaledWidth * sourceHeight * 4)
    source.withUnsafeBufferPointer { src in
      wide.withUnsafeMutableBufferPointer { out in
        nonisolated(unsafe) let src = src
        nonisolated(unsafe) let out = out
        DispatchQueue.concurrentPerform(iterations: sourceHeight) { y in
          let row = y * sourceWidth * 4
          for x in 0..<scaledWidth {
            let tap = horizontal[x]
            var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
            for k in 0..<4 {
              let sx = min(max(tap.first + k, 0), sourceWidth - 1)
              let w = tap.weights[k]
              let i = row + sx * 4
              r += w * Float(src[i])
              g += w * Float(src[i + 1])
              b += w * Float(src[i + 2])
              a += w * Float(src[i + 3])
            }
            let o = (y * scaledWidth + x) * 4
            out[o] = r
            out[o + 1] = g
            out[o + 2] = b
            out[o + 3] = a
          }
        }
      }
    }

    // Pass 2: columns to the scaled height, writing only the cropped window.
    let offsetX = (scaledWidth - width) / 2
    let offsetY = (scaledHeight - height) / 2
    var result = [UInt8](repeating: 0, count: width * height * 4)
    wide.withUnsafeBufferPointer { src in
      result.withUnsafeMutableBufferPointer { out in
        nonisolated(unsafe) let src = src
        nonisolated(unsafe) let out = out
        DispatchQueue.concurrentPerform(iterations: height) { y in
          let tap = vertical[y + offsetY]
          for x in 0..<width {
            var sums: (Float, Float, Float, Float) = (0, 0, 0, 0)
            for k in 0..<4 {
              let sy = min(max(tap.first + k, 0), sourceHeight - 1)
              let w = tap.weights[k]
              let i = (sy * scaledWidth + x + offsetX) * 4
              sums.0 += w * src[i]
              sums.1 += w * src[i + 1]
              sums.2 += w * src[i + 2]
              sums.3 += w * src[i + 3]
            }
            // Bicubic overshoots; premultiplied colors can't exceed alpha.
            let alpha = clamp(sums.3)
            let o = (y * width + x) * 4
            out[o] = UInt8(min(clamp(sums.0), alpha).rounded())
            out[o + 1] = UInt8(min(clamp(sums.1), alpha).rounded())
            out[o + 2] = UInt8(min(clamp(sums.2), alpha).rounded())
            out[o + 3] = UInt8(alpha.rounded())
          }
        }
      }
    }

    return result.withUnsafeMutableBytes { buffer -> CGImage? in
      CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space, bitmapInfo: bitmap)?.makeImage()
    }
  }

  /// `value` as a byte value; a non-finite one (nothing finite in gives one) is 0.
  private static func clamp(_ value: Float) -> Float {
    value.isFinite ? min(max(value, 0), 255) : 0
  }
}
