@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// The Edit screen's render (`EditPipeline`). Slices B to F add each step's cases; for now the
/// identity look gives the image back.
struct EditPipelineTests {
  @Test func identityLeavesTheImageAlone() async throws {
    let width = 8
    let height = 4
    let pixels: [UInt8] = (0..<width * height).flatMap { (index: Int) -> [UInt8] in [UInt8(index * 7 % 256), UInt8(index * 3 % 256), UInt8(index % 256), 255] }
    let source = try #require(ColorMatch.cgImage(rgba: pixels, width: width, height: height))
    let rendered = try await EditPipeline.render(source: source, options: .identity)
    #expect(ColorMatch.rgba(rendered) == pixels)
    let window = EditPipeline.Window(x: 2, y: 1, width: 4, height: 2)
    let part = try await EditPipeline.render(source: source, options: .identity, window: window)
    let expected = EditPipeline.Planes(rgba: pixels, width: width, height: height).cropped(x: 2, y: 1, width: 4, height: 2).rgba
    #expect(part.width == 4 && part.height == 2 && ColorMatch.rgba(part) == expected)
  }
}
