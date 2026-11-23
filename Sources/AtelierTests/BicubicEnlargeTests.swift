@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// The bicubic enlargement SeedVR2 gets its input through: Keys' kernel (a = -0.75), sampled the way
/// the engine's `ccv_resample` does, edges clamped.
@Suite(.tags(.smoke))
struct BicubicEnlargeTests {
  /// An sRGB RGBA image from `pixels` (r, g, b, a rows).
  private static func image(width: Int, height: Int, _ pixels: [[UInt8]]) throws -> CGImage {
    var data = pixels.flatMap(\.self)
    let image = data.withUnsafeMutableBytes { buffer in
      CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
        .makeImage()
    }
    return try #require(image)
  }

  private static func pixels(_ image: CGImage) throws -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = data.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    #expect(drawn)
    return data
  }

  @Test func kernelValues() {
    #expect(BicubicEnlarge.keys(0) == 1)
    #expect(BicubicEnlarge.keys(1) == 0)
    #expect(BicubicEnlarge.keys(2) == 0)
    #expect(BicubicEnlarge.keys(3) == 0)
    // By hand at x = 0.5: a = -0.5 gives (1.5 * 0.5 - 2.5) * 0.25 + 1 = 0.5625; a = -0.75 gives (1.25 * 0.5 - 2.25) * 0.25 + 1 = 0.59375.
    #expect(abs(BicubicEnlarge.keys(0.5, a: -0.5) - 0.5625) < 1e-12)
    #expect(abs(BicubicEnlarge.keys(0.5, a: -0.75) - 0.59375) < 1e-12)
    #expect(abs(BicubicEnlarge.keys(-0.5) - BicubicEnlarge.keys(0.5)) < 1e-12)
  }

  @Test func weightsPartitionUnity() {
    for step in 0...20 {
      let f = Double(step) / 20
      let sum = (0..<4).map { BicubicEnlarge.keys(f - Double($0 - 1)) }.reduce(0, +)
      #expect(abs(sum - 1) < 1e-12)
    }
  }

  @Test func aConstantImageStaysConstant() throws {
    let source = try Self.image(width: 3, height: 3, Array(repeating: [100, 150, 200, 255], count: 9))
    let result = try #require(BicubicEnlarge.resize(source, width: 9, height: 9))
    let data = try Self.pixels(result)
    for i in stride(from: 0, to: data.count, by: 4) {
      #expect(data[i] == 100 && data[i + 1] == 150 && data[i + 2] == 200 && data[i + 3] == 255)
    }
  }

  @Test func aRampDoublesAsHandComputed() throws {
    // 4 → 8 across: output x samples source (x + 0.5) / 2 - 0.5, so x = 3 is at 1.25 and x = 4 at 1.75.
    let row = [UInt8]([0, 60, 120, 180]).map { [$0, $0, $0, 255] }
    let source = try Self.image(width: 4, height: 1, row)
    // Height 1 can't double; a 4×1 image to 8×2 is a double on both axes.
    let result = try #require(BicubicEnlarge.resize(source, width: 8, height: 2))
    let data = try Self.pixels(result)
    func expected(_ position: Double) -> Double {
      let values = [0.0, 60, 120, 180]
      let base = Int(position.rounded(.down))
      var sum = 0.0
      var total = 0.0
      for k in -1...2 {
        let w = BicubicEnlarge.keys(position - Double(base + k))
        sum += w * values[min(max(base + k, 0), 3)]
        total += w
      }
      return sum / total
    }
    for x in 0..<8 {
      let want = min(max(expected((Double(x) + 0.5) / 2 - 0.5), 0), 255)
      #expect(abs(Double(data[x * 4]) - want) <= 1)
    }
  }

  @Test func edgesAreClamped() throws {
    let source = try Self.image(width: 2, height: 1, [[10, 10, 10, 255], [250, 250, 250, 255]])
    let result = try #require(BicubicEnlarge.resize(source, width: 4, height: 2))
    let data = try Self.pixels(result)
    // Clamped to 0...255 even where the kernel overshoots, and ends stay near their source pixel.
    #expect(data[0] <= 12)
    #expect(data[3 * 4] >= 248)
  }

  @Test func alphaStaysPremultipliedAndInRange() throws {
    let source = try Self.image(width: 2, height: 2, [[255, 0, 0, 255], [0, 0, 0, 0], [0, 0, 0, 0], [0, 255, 0, 255]])
    let result = try #require(BicubicEnlarge.resize(source, width: 6, height: 6))
    let data = try Self.pixels(result)
    for i in stride(from: 0, to: data.count, by: 4) {
      #expect(data[i] <= data[i + 3] && data[i + 1] <= data[i + 3] && data[i + 2] <= data[i + 3])
    }
    #expect(data.contains { $0 == 0 } && data[3] == 255)
  }

  @Test func sizeAndColorSpace() throws {
    let source = try Self.image(width: 4, height: 2, Array(repeating: [1, 2, 3, 255], count: 8))
    let result = try #require(BicubicEnlarge.resize(source, width: 8, height: 4))
    #expect(result.width == 8 && result.height == 4)
    #expect(result.colorSpace?.name == CGColorSpace.sRGB)
    // A target of another shape covers and center-crops to exactly the requested size.
    let wide = try #require(BicubicEnlarge.resize(source, width: 8, height: 2))
    #expect(wide.width == 8 && wide.height == 2)
  }

  @Test func shrinkingIsNotHandled() throws {
    let source = try Self.image(width: 4, height: 4, Array(repeating: [1, 2, 3, 255], count: 16))
    #expect(BicubicEnlarge.resize(source, width: 2, height: 2) == nil)
    #expect(BicubicEnlarge.resize(source, width: 8, height: 2) != nil)
    #expect(BicubicEnlarge.resize(source, width: 0, height: 8) == nil)
  }
}
