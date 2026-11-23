@testable import Atelier
import CoreGraphics
import Foundation
import Testing

/// How a History clip becomes H3 Ref2VA's reference video (`ReferenceVideo`), following
/// MiniMax's own reference pipeline (diffusers `minimax_h3`).
@Suite(.tags(.smoke))
struct ReferenceVideoTests {
  func indices(_ numFrames: Int, _ sourceCount: Int, _ sourceRate: Double) -> [Int] {
    ReferenceVideo.sourceIndices(numFrames: numFrames, rate: 24, sourceCount: sourceCount, sourceRate: sourceRate)
  }

  @Test func aClipAtTheModelsRateGivesItsFramesInOrder() {
    #expect(indices(22, 100, 24) == Array(0..<22))
    #expect(indices(39, 100, 24) == Array(0..<39))
  }

  @Test func aLongerClipIsCutToTheVideosLength() {
    #expect(indices(56, 1000, 24).count == 56)
  }

  @Test func aShorterClipIsAShorterReferenceNeverPadded() {
    // 30 frames at 24: snapped down to 22, not held to the run's 56.
    #expect(indices(56, 30, 24) == Array(0..<22))
    // 50 frames: 39.
    #expect(indices(56, 50, 24) == Array(0..<39))
    // Under 22: too short to be one.
    #expect(indices(56, 21, 24).isEmpty)
  }

  @Test func anotherRateIsResampledAsMiniMaxDoes() {
    // 30 fps onto 24: source frame i takes the slots from floor(i × 0.8 + 0.5) to the next one's,
    // so every fifth frame (3, 8, …) is dropped (diffusers' `_normalize_video`).
    #expect(indices(22, 100, 30) == [0, 1, 3, 4, 5, 6, 8, 9, 10, 11, 13, 14, 15, 16, 18, 19, 20, 21, 23, 24, 25, 26])
    // 12 fps onto 24 shows each frame twice.
    #expect(ReferenceVideo.resampled(sourceCount: 100, sourceRate: 12, rate: 24, limit: 6) == [0, 0, 1, 1, 2, 2])
    // 36 frames at 30 fps are 29 at 24: a 22-frame reference.
    #expect(ReferenceVideo.resampled(sourceCount: 36, sourceRate: 30, rate: 24, limit: 1000).count == 29)
    #expect(indices(56, 36, 30).count == 22)
  }

  @Test func aDamagedRateNeverTraps() {
    #expect(indices(22, 30, .nan) == Array(0..<22))
    #expect(indices(22, 30, .infinity) == Array(0..<22))
    #expect(indices(22, 4, 1e300).isEmpty)
    #expect(indices(22, 0, 24).isEmpty)
    #expect(indices(0, 100, 24).isEmpty)
    #expect(ReferenceVideo.resampled(sourceCount: 4, sourceRate: 1e-300, rate: 24, limit: 50).count == 50)
  }

  @Test func referenceLengthsAreWholeOnes() {
    #expect(ReferenceVideo.length(available: 100, numFrames: 56) == 56)
    #expect(ReferenceVideo.length(available: 55, numFrames: 56) == 39)
    #expect(ReferenceVideo.length(available: 21, numFrames: 56) == 0)
    #expect(ReferenceVideo.isLength(22) && ReferenceVideo.isLength(39) && !ReferenceVideo.isLength(23) && !ReferenceVideo.isLength(5))
  }

  @Test func aClipKeepsItsOwnShapeOnMiniMaxsCanvas() {
    // diffusers' `resolve_canvas_size` with 768, 768 × 1344 and 32.
    func size(_ width: Int, _ height: Int) -> [Int] {
      let size = ReferenceVideo.canvasSize(width: width, height: height)
      return [size.width, size.height]
    }
    #expect(size(1920, 1080) == [1344, 768])
    #expect(size(2354, 1320) == [1344, 768])
    #expect(size(1080, 1920) == [768, 1344])
    #expect(size(512, 512) == [768, 768])
    #expect(size(64, 32) == [1440, 704])
    // Beyond 4:1 it's held at 4:1.
    #expect(size(4000, 500) == [2016, 512])
    #expect(size(0, 0) == [768, 768])
  }

  @Test func aFrameIsMadeAtItsCanvasSize() throws {
    let frame = try #require(ReferenceVideo.frame(smallImage()))
    #expect(frame.width == 768 && frame.height == 768)
  }

  @Test func framesBecomeOneTensor() throws {
    // In sRGB, as the project's frames are, so drawing converts no color.
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
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
    #expect(ReferenceVideo.problem(takesReferences: true, strength: 1, numFrames: 56, hasAudio: false, clipFrames: 21)?.contains("short") == true)
    #expect(ReferenceVideo.problem(takesReferences: true, strength: 1, numFrames: 56, hasAudio: false, clipFrames: 22) == nil)
  }
}
