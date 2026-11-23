@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// How a History clip becomes H3 Ref2VA's reference video (`ReferenceVideo`), following the
/// engine CLI's `loadInputVideoTensor`.
@Suite(.tags(.smoke))
struct ReferenceVideoTests {
  @Test func aClipAtTheModelsRateGivesItsFramesInOrder() {
    #expect(ReferenceVideo.sourceIndices(count: 5, rate: 24, sourceCount: 10, sourceRate: 24) == [0, 1, 2, 3, 4])
  }

  @Test func aShorterClipHoldsItsLastFrame() {
    #expect(ReferenceVideo.sourceIndices(count: 6, rate: 24, sourceCount: 3, sourceRate: 24) == [0, 1, 2, 2, 2, 2])
  }

  @Test func anotherRateTakesTheFrameOnScreenAtEachTime() {
    // 30 fps read at 24: frame i is at i/24 s, which is source frame floor(i × 1.25).
    #expect(ReferenceVideo.sourceIndices(count: 5, rate: 24, sourceCount: 100, sourceRate: 30) == [0, 1, 2, 3, 5])
    // 12 fps read at 24 shows each frame twice.
    #expect(ReferenceVideo.sourceIndices(count: 6, rate: 24, sourceCount: 100, sourceRate: 12) == [0, 0, 1, 1, 2, 2])
  }

  @Test func aDamagedRateNeverTraps() {
    #expect(ReferenceVideo.sourceIndices(count: 3, rate: 24, sourceCount: 4, sourceRate: .nan) == [0, 1, 2])
    #expect(ReferenceVideo.sourceIndices(count: 3, rate: 24, sourceCount: 4, sourceRate: .infinity) == [0, 1, 2])
    #expect(ReferenceVideo.sourceIndices(count: 3, rate: 24, sourceCount: 4, sourceRate: 1e300) == [0, 3, 3])
    #expect(ReferenceVideo.sourceIndices(count: 3, rate: 24, sourceCount: 0, sourceRate: 24).isEmpty)
    #expect(ReferenceVideo.sourceIndices(count: 0, rate: 24, sourceCount: 4, sourceRate: 24).isEmpty)
  }

  @Test func aWiderFrameIsCroppedAtItsSides() {
    // 1920×1080 covering 512×512: 910×512, 199 px off the left (halved toward zero).
    let rect = ReferenceVideo.coverRect(sourceWidth: 1920, sourceHeight: 1080, width: 512, height: 512)
    #expect(rect == CGRect(x: -199, y: 0, width: 910, height: 512))
  }

  @Test func aTallerFrameIsCroppedTopAndBottom() {
    let rect = ReferenceVideo.coverRect(sourceWidth: 512, sourceHeight: 832, width: 832, height: 512)
    #expect(rect == CGRect(x: 0, y: -420, width: 832, height: 1352))
    #expect(ReferenceVideo.coverRect(sourceWidth: 64, sourceHeight: 32, width: 128, height: 64) == CGRect(x: 0, y: 0, width: 128, height: 64))
  }

  @Test func aFrameIsMadeAtTheOutputSize() throws {
    let frame = try #require(ReferenceVideo.frame(smallImage(), width: 8, height: 6))
    #expect(frame.width == 8 && frame.height == 6)
  }

  @Test func framesBecomeOneTensor() throws {
    // In sRGB, as the project's frames are, so drawing converts no color.
    let context = CGContext(
      data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let red = try #require(context.makeImage())
    let tensor = try #require(ImageTensor.tensor(frames: [red, red, red], width: 4, height: 2))
    #expect(tensor.shape == [3, 2, 4, 3])
    #expect(abs(Float(tensor[2, 1, 3, 0]) - 1) < 0.01)
    #expect(abs(Float(tensor[2, 1, 3, 1]) + 1) < 0.01)
    #expect(ImageTensor.tensor(frames: [], width: 4, height: 2) == nil)
  }

  @Test func onlyRef2VATakesAReferenceVideoFromNoiseWithoutAudio() {
    func problem(_ takes: Bool = true, strength: Float = 1, frames: Int = 22, audio: Bool = false) -> String? {
      ReferenceVideo.problem(takesReferences: takes, strength: strength, numFrames: frames, hasAudio: audio)
    }
    #expect(problem() == nil)
    #expect(problem(frames: 124) == nil)
    #expect(problem(false)?.contains("Ref2VA") == true)
    #expect(problem(audio: true)?.contains("audio") == true)
    #expect(problem(strength: 0.5)?.contains("Strength") == true)
    #expect(problem(strength: .nan)?.contains("Strength") == true)
    #expect(problem(frames: 5)?.contains("22") == true)
    #expect(problem(frames: 21) != nil)
  }
}
