@testable import Atelier
import Foundation
@preconcurrency import NNC
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

  @Test func olderPeersDecode() throws {
    // A server or saved queue from before ReCaVSR: no weights, no recaVSR list.
    let upscale = try JSONDecoder().decode(
      ClipUpscale.self, from: Data(#"{"method":"flashVSR","scale":2,"sourceTensorId":7}"#.utf8))
    #expect(upscale.weights == nil)
    let upscalers = try JSONDecoder().decode(
      RemoteUpscalers.self, from: Data(#"{"flashVSR":["turbo"],"superResolution":true}"#.utf8))
    #expect(upscalers.recaVSR == nil)
    let new = ClipUpscale(method: .recaVSR, scale: 4, sourceTensorId: 1, weights: .eightBit)
    let decoded = try JSONDecoder().decode(ClipUpscale.self, from: JSONEncoder().encode(new))
    #expect(decoded == new)
  }

  @Test func clipSizesAndScales() {
    #expect(ClipUpscale.outputSize(width: 448, height: 320, scale: 2, method: .recaVSR) == (896, 640))
    #expect(ClipUpscale.outputSize(width: 480, height: 270, scale: 4, method: .recaVSR) == (1920, 1080))
    // 4× of 448×320 is past 1920×1088.
    #expect(ClipUpscale.offeredScales(width: 448, height: 320, method: .recaVSR) == [2])
    #expect(ClipUpscale.offeredScales(width: 480, height: 272, method: .recaVSR) == [2, 4])
  }

  // MARK: - Importing an 8-bit copy (`ReCaVSREightBitFile`, `ReCaVSRFiles`' install state)

  @Test func eightBitCopyNames() {
    let names = ReCaVSREightBitFile.expectedNames()
    // 27 tensors a layer and 25 outside them: what the published checkpoint has.
    #expect(names.count == 30 * 27 + 25)
    #expect(Set(names).count == names.count)
    for name in [
      "blocks.0.attn1.to_q.weight", "blocks.0.attn1.to_q.bias", "blocks.29.ffn.net.2.weight",
      "blocks.14.attn2.to_k.bias", "blocks.7.attn2.norm_k.weight", "blocks.7.norm2.bias",
      "blocks.29.scale_shift_table", "scale_shift_table", "patch_embedding.weight", "sr_proj.bias",
      "proj_out.weight", "condition_embedder.time_proj.bias", "condition_embedder.text_embedder.linear_2.weight",
      "lq_proj.conv2.weight", "lq_proj.norm1.weight", "lq_proj.out_proj.bias",
    ] {
      #expect(names.contains(name), "\(name)")
    }
    // The quantizer's resume marker isn't part of a copy.
    #expect(!names.contains(ReCaVSRQuantizer.sourceKey))
  }

  @Test func eightBitCopyMatrices() {
    let names = ReCaVSREightBitFile.expectedNames()
    let eightBit = names.filter(ReCaVSRQuantizer.isEightBit)
    // Ten matrices a layer: the eight the pieces multiply by and the cross-attention's keys and values.
    #expect(eightBit.count == 30 * 10)
    #expect(eightBit.allSatisfy { $0.hasPrefix("blocks.") && $0.hasSuffix(".weight") && !$0.contains("norm") })
    #expect(names.allSatisfy { (ReCaVSREightBitFile.eightBitShape($0) != nil) == ReCaVSRQuantizer.isEightBit($0) })
    #expect(ReCaVSREightBitFile.eightBitShape("blocks.3.attn1.to_q.weight") == [3072, 3072])
    #expect(ReCaVSREightBitFile.eightBitShape("blocks.3.attn2.to_v.weight") == [3072, 3072])
    #expect(ReCaVSREightBitFile.eightBitShape("blocks.3.ffn.net.0.proj.weight") == [14336, 3072])
    #expect(ReCaVSREightBitFile.eightBitShape("blocks.3.ffn.net.2.weight") == [3072, 14336])
    #expect(ReCaVSREightBitFile.eightBitShape("blocks.3.ffn.net.2.bias") == nil)
    #expect(ReCaVSREightBitFile.eightBitShape("sr_proj.weight") == nil)
  }

  /// An SQLite header saying `pages` pages of 4096 bytes.
  private func storeHeader(pages: UInt32, journal: UInt8 = 1) -> Data {
    var header = Data("SQLite format 3\0".utf8) + Data(count: 84)
    header[16] = 0x10
    header[18] = journal
    header[19] = journal
    for index in 0..<4 { header[28 + index] = UInt8(truncatingIfNeeded: pages >> (8 * UInt32(3 - index))) }
    return header
  }

  @Test func eightBitCopyHeader() {
    typealias File = ReCaVSREightBitFile
    #expect(File.headerProblem(storeHeader(pages: 1000), fileBytes: 4_096_000) == nil)
    // Longer than its pages is fine; shorter was cut off.
    #expect(File.headerProblem(storeHeader(pages: 1000), fileBytes: 4_100_000) == nil)
    #expect(File.headerProblem(storeHeader(pages: 1000), fileBytes: 4_095_999) == .truncated)
    #expect(File.headerProblem(storeHeader(pages: 1_394_852), fileBytes: 5_713_313_792) == nil)
    #expect(File.headerProblem(storeHeader(pages: 1_394_852), fileBytes: 3_000_000_000) == .truncated)
    // Write-ahead mode: copied while it was open.
    #expect(File.headerProblem(storeHeader(pages: 1000, journal: 2), fileBytes: 4_096_000) == .notClosed)
    #expect(File.headerProblem(Data("not a store, just some text that goes on".utf8), fileBytes: 40) == .notStore)
    #expect(File.headerProblem(Data(), fileBytes: 0) == .notStore)
    #expect(File.headerProblem(storeHeader(pages: 1000).prefix(50), fileBytes: 50) == .notStore)
    // A safetensors file: its JSON header's length, then the JSON.
    var safetensors = Data([0x40, 0x9c, 0, 0, 0, 0, 0, 0]) + Data("{\"blocks.0.attn1.to_q.weight\":{".utf8)
    safetensors += Data(count: 100)
    #expect(File.headerProblem(safetensors, fileBytes: 10_603_673_624) == .fullPrecision)
  }

  private func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ReCaVSRTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func problem(_ url: URL) -> ReCaVSREightBitFile.Problem? {
    do {
      try ReCaVSREightBitFile.validate(url)
      return nil
    } catch {
      return error as? ReCaVSREightBitFile.Problem ?? .unreadable
    }
  }

  @Test func eightBitCopyValidation() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(problem(folder.appending(path: "nothing.ckpt")) == .unreadable)
    let text = folder.appending(path: "text.ckpt")
    try Data(String(repeating: "This is not a model. ", count: 20).utf8).write(to: text)
    #expect(problem(text) == .notStore)
    // A real store, without ReCaVSR's tensors.
    let other = folder.appending(path: "other.ckpt")
    DynamicGraph().openStore(other.path) { store in
      store.write("some.weight", tensor: Tensor<Float>([1, 2, 3, 4], .CPU, .C(4)))
    }
    #expect(problem(other) == .missing("blocks.0.attn1.to_q.weight"))
    // The right name, not stored 8-bit.
    let plain = folder.appending(path: "plain.ckpt")
    DynamicGraph().openStore(plain.path) { store in
      for name in ReCaVSREightBitFile.expectedNames() {
        store.write(name, tensor: Tensor<Float>([1, 2, 3, 4], .CPU, .C(4)))
      }
    }
    #expect(problem(plain) == .notEightBit("blocks.0.attn1.to_q.weight"))
    // Cut short.
    let whole = try Data(contentsOf: plain)
    let cut = folder.appending(path: "cut.ckpt")
    try whole.prefix(whole.count / 2).write(to: cut)
    #expect(problem(cut) == .truncated)
    // A journal beside it.
    try Data([1, 2, 3]).write(to: URL(fileURLWithPath: plain.path + "-wal"))
    #expect(problem(plain) == .notClosed)
    // Checking wrote nothing beside the files.
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(left == ["cut.ckpt", "other.ckpt", "plain.ckpt", "plain.ckpt-wal", "text.ckpt"])
  }

  /// A file of `bytes` bytes with nothing in them (sparse, so it takes no room).
  private func place(_ name: String, bytes: Int64, in folder: URL) throws {
    let url = folder.appending(path: name)
    try? FileManager.default.removeItem(at: url)
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(bytes))
    try handle.close()
  }

  @Test func installStates() throws {
    typealias Files = ReCaVSRFiles
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let installed = { Files.Weights.allCases.filter { Files.installed($0, in: folder) != nil } }
    #expect(Files.companions.map(\.path) == ["prompt.safetensors", "flashdecoder.safetensors"])
    #expect(Files.companionBytes == 232_918_168)

    // Nothing there.
    #expect(installed().isEmpty)
    #expect(Files.missing(.full, in: folder) == .missing)
    #expect(Files.missing(.eightBit, in: folder) == .missingEightBit)

    // An imported 8-bit copy alone: its other files are still needed.
    try place(Files.eightBitName, bytes: 4096, in: folder)
    #expect(Files.hasEightBitCopy(in: folder))
    #expect(installed().isEmpty)
    #expect(Files.missing(.eightBit, in: folder) == .missingCompanions)

    // A companion at the wrong size doesn't count.
    try place("prompt.safetensors", bytes: 4_194_392, in: folder)
    try place("flashdecoder.safetensors", bytes: 1000, in: folder)
    #expect(!Files.companionsDownloaded(in: folder))
    #expect(installed().isEmpty)

    // The 8-bit copy with the prompt and the decoder: 8-bit runs, Full doesn't.
    try place("flashdecoder.safetensors", bytes: 228_723_776, in: folder)
    #expect(Files.companionsDownloaded(in: folder))
    #expect(!Files.fullDownloaded(in: folder))
    #expect(installed() == [.eightBit])
    #expect(Files.missing(.full, in: folder) == .missing)
    #expect(Files.installed(.eightBit, in: folder)?.eightBitTransformer.lastPathComponent == Files.eightBitName)

    // A copy still on its way in isn't one yet.
    try FileManager.default.moveItem(
      at: folder.appending(path: Files.eightBitName),
      to: folder.appending(path: Files.eightBitName + ReCaVSREightBitFile.stagingSuffix))
    #expect(!Files.hasEightBitCopy(in: folder))
    #expect(installed().isEmpty)

    // The published files without a copy: Full only.
    try place(Files.transformerName, bytes: 10_603_673_624, in: folder)
    #expect(installed() == [.full])
    #expect(Files.missing(.eightBit, in: folder) == .missingEightBit)

    // Everything.
    try place(Files.eightBitName, bytes: 4096, in: folder)
    #expect(installed() == [.full, .eightBit])

    // A transformer that's partly downloaded: 8-bit still runs.
    try place(Files.transformerName, bytes: 1_000_000, in: folder)
    #expect(installed() == [.eightBit])
  }
}
