@testable import Atelier
import Testing

/// ReCaVSR's streaming bookkeeping (`ReCaVSRRouter`) against sequences worked out from the
/// reference (runtime/cache.py, runtime/rope.py, video.py, models/lq_proj.py).
struct ReCaVSRTests {
  /// Runs a layer's retention through the blocks of a stream: the prefix (latents 0–5), then two
  /// latents a block. Returns what it keeps after each block.
  private func kept(_ action: ReCaVSRRouter.Action, blocks: Int) -> [[Int]] {
    var kept: [Int] = []
    var history: [[Int]] = []
    var next = 0
    for block in 0..<blocks {
      let count = block == 0 ? 6 : 2
      kept = ReCaVSRRouter.retained(kept + Array(next..<(next + count)), action: action)
      #expect(kept.count <= action.capacity)
      history.append(kept)
      next += count
    }
    return history
  }

  @Test func routerTable() {
    #expect(ReCaVSRRouter.actions.count == ReCaVSRConfig.layers)
    #expect(ReCaVSRRouter.actions[9] == .recent2Anchor)
    #expect(ReCaVSRRouter.actions[14] == .anchor)
    #expect(ReCaVSRRouter.actions[27] == .recent1)
    // Capacity: recent plus two anchor slots (cache.py:61-62).
    #expect(ReCaVSRRouter.Action.recent4Anchor.capacity == 6)
    #expect(ReCaVSRRouter.Action.anchor.capacity == 2)
    #expect(ReCaVSRRouter.Action.none.capacity == 0)
  }

  @Test func anchors() {
    #expect((0..<30).filter(ReCaVSRRouter.isAnchor) == [5, 11, 17, 23, 29])
  }

  @Test func recentFourWithAnchors() {
    let history = kept(.recent4Anchor, blocks: 10)
    #expect(history[0] == [2, 3, 4, 5])
    #expect(history[1] == [4, 5, 6, 7])
    #expect(history[2] == [5, 6, 7, 8, 9])
    #expect(history[3] == [5, 8, 9, 10, 11])
    #expect(history[4] == [5, 10, 11, 12, 13])
    #expect(history[5] == [5, 11, 12, 13, 14, 15])
    // 17 arrives: 5 is evicted for good.
    #expect(history[6] == [11, 14, 15, 16, 17])
    #expect(history[9] == [17, 20, 21, 22, 23])
  }

  @Test func anchorOnly() {
    let history = kept(.anchor, blocks: 10)
    #expect(history[0] == [5])
    #expect(history[3] == [5, 11])
    #expect(history[6] == [11, 17])
    #expect(history[9] == [17, 23])
  }

  @Test func recentOnly() {
    #expect(kept(.recent1, blocks: 3) == [[5], [7], [9]])
    #expect(kept(.recent2, blocks: 2) == [[4, 5], [6, 7]])
    #expect(kept(.none, blocks: 3) == [[], [], []])
  }

  @Test func evictedNeverReturn() {
    // A latent once dropped isn't a candidate again: retention only ever narrows the kept set.
    for action in Set(ReCaVSRRouter.actions.map(\.recent)).map({ ReCaVSRRouter.Action(recent: $0, anchors: true) }) {
      let history = kept(action, blocks: 20)
      var dropped = Set<Int>()
      for (previous, current) in zip([[]] + history, history) {
        dropped.formUnion(Set(previous).subtracting(current))
        #expect(dropped.isDisjoint(with: current))
      }
    }
  }

  @Test func ropeOrigin() {
    // Positions stay inside the 22-latent training interval (rope.py:85-101).
    #expect(ReCaVSRRouter.ropeOrigin(start: 0, frames: 6) == 0)
    #expect(ReCaVSRRouter.ropeOrigin(start: 18, frames: 2) == 0)
    #expect(ReCaVSRRouter.ropeOrigin(start: 20, frames: 2) == 0)
    #expect(ReCaVSRRouter.ropeOrigin(start: 22, frames: 2) == 2)
    #expect(ReCaVSRRouter.ropeOrigin(start: 30, frames: 2) == 10)
    // Every kept latent maps inside the interval too (cache.py:79-80).
    for (layer, action) in ReCaVSRRouter.actions.enumerated() where action.capacity > 0 {
      var kept: [Int] = []
      var start = 0
      for block in 0..<40 {
        let count = block == 0 ? 6 : 2
        let origin = ReCaVSRRouter.ropeOrigin(start: start, frames: count)
        for latent in kept {
          #expect(latent - origin >= 0 && latent - origin < 22, "layer \(layer) latent \(latent)")
        }
        kept = ReCaVSRRouter.retained(kept + Array(start..<(start + count)), action: action)
        start += count
      }
    }
  }

  @Test func blockSchedule() {
    let blocks = ReCaVSRRouter.blocks(77)
    #expect(blocks.count == 8)
    #expect(blocks[0] == .init(index: 0, start: 0, valid: 21, frames: 21))
    #expect(blocks[1] == .init(index: 1, start: 21, valid: 8, frames: 8))
    #expect(blocks[7] == .init(index: 7, start: 69, valid: 8, frames: 8))
    #expect(blocks[7].latentStart == 18 && blocks[7].latents == 2)
    // A short last block is padded to 8 (video.py:119-131).
    let short = ReCaVSRRouter.blocks(75)
    #expect(short.last == .init(index: 7, start: 69, valid: 6, frames: 8))
    #expect(ReCaVSRRouter.blocks(5) == [.init(index: 0, start: 0, valid: 5, frames: 21)])
    for count in [1, 20, 21, 22, 29, 30, 45, 77, 1000] {
      #expect(ReCaVSRRouter.blockCount(count) == ReCaVSRRouter.blocks(count).count)
      #expect(ReCaVSRRouter.blocks(count).reduce(0) { $0 + $1.valid } == count)
    }
  }

  @Test func convolutionInputs() {
    // Output 0 reads frame 0 four times (three of them padding); output j reads 2j − 3 … 2j.
    #expect(ReCaVSRRouter.convolutionInputs(0) == -3...0)
    #expect(ReCaVSRRouter.convolutionInputs(10) == 17...20)
    // The prefix's 21 frames make 11; each later 8 make 4, the first reading 19 … 22.
    #expect(ReCaVSRRouter.convolutionInputs(11) == 19...22)
  }

  @Test func windowBounds() {
    // Centered and clamped inside the grid (local_attention.py:98-101).
    #expect(ReCaVSRRouter.windowStart(0, size: 34, window: 22) == 0)
    #expect(ReCaVSRRouter.windowStart(11, size: 34, window: 22) == 0)
    #expect(ReCaVSRRouter.windowStart(12, size: 34, window: 22) == 1)
    #expect(ReCaVSRRouter.windowStart(33, size: 34, window: 22) == 12)
    #expect(ReCaVSRRouter.windowStart(59, size: 60, window: 40) == 20)
    // A grid smaller than the window reads all of it.
    #expect(ReCaVSRRouter.windowStart(5, size: 8, window: 22) == 0)
  }

  @Test func sizes() {
    #expect(ReCaVSRRouter.outputSize(width: 100, height: 60, scale: 2) == (200, 120))
    #expect(ReCaVSRRouter.padded(120) == 128)
    #expect(ReCaVSRRouter.padded(1080) == 1088)
    #expect(ReCaVSRRouter.padded(1920) == 1920)
  }
}
