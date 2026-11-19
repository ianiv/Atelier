@testable import Atelier
import Foundation
@preconcurrency import NNC
import Synchronization
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

  /// Small sizes for a copy a test can write: a DiT 64 wide, feed-forward 128.
  private static let smallHidden = 64
  private static let smallWide = 128

  /// A copy laid out as the quantizer writes one, at the small sizes: every name, the layers'
  /// matrices row-wise 8-bit.
  private func writeSmallCopy(_ url: URL) {
    DynamicGraph().openStore(url.path) { store in
      for name in ReCaVSREightBitFile.expectedNames() {
        if let shape = ReCaVSREightBitFile.eightBitShape(name, hidden: Self.smallHidden, wide: Self.smallWide) {
          var matrix = Tensor<Float16>(.CPU, .NC(shape[0], shape[1]))
          for row in 0..<shape[0] {
            for column in 0..<shape[1] { matrix[row, column] = Float16(sin(Double(row * 31 + column * 7))) }
          }
          store.write(name, tensor: matrix, codec: [.i8x, .ezm7])
        } else {
          store.write(name, tensor: Tensor<Float>([1, 2, 3, 4], .CPU, .C(4)))
        }
      }
    }
  }

  private static let checkSmall: @Sendable (URL) throws -> Void = {
    try ReCaVSREightBitFile.validate($0, hidden: smallHidden, wide: smallWide)
  }

  @Test func eightBitCopySizes() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let copy = folder.appending(path: "renamed copy.bin")
    writeSmallCopy(copy)
    // Right in every way at its own sizes; not ReCaVSR's at the real ones.
    try ReCaVSREightBitFile.validate(copy, hidden: Self.smallHidden, wide: Self.smallWide)
    #expect(problem(copy) == .wrongShape("blocks.0.attn1.to_q.weight"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["renamed copy.bin"])
  }

  /// What an import test starts from: a small copy in its own folder, optionally with the
  /// prompt and the decoder beside it, and an empty ReCaVSR folder to import into.
  private func importSetup(siblings: Bool) throws -> (root: URL, source: URL, folder: URL) {
    let root = try scratchFolder()
    let from = root.appending(path: "elsewhere")
    try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
    let source = from.appending(path: "my 8-bit copy.ckpt")
    writeSmallCopy(source)
    if siblings {
      for file in ReCaVSRFiles.companions { try place(file.path, bytes: file.bytes, in: from) }
    }
    return (root, source, root.appending(path: "ReCaVSR"))
  }

  /// Stands in for the downloader: records what was asked for and writes a file of the right size.
  private final class Fetched: Sendable {
    let names = Mutex<[String]>([])

    var fetch: ReCaVSREightBitFile.Fetch {
      { [self] from, to, _ in
        names.withLock { $0.append(from.lastPathComponent) }
        let bytes = ReCaVSRFiles.companions.first { $0.path == to.lastPathComponent }?.bytes ?? 0
        _ = FileManager.default.createFile(atPath: to.path, contents: nil)
        let handle = try FileHandle(forWritingTo: to)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
      }
    }
  }

  private func listing(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  private static let imported = ["flashdecoder.safetensors", "prompt.safetensors", "transformer_i8x.ckpt"]

  @Test func importClonesWithItsSiblings() async throws {
    let (root, source, folder) = try importSetup(siblings: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try Data(contentsOf: source)
    let fetched = Fetched()
    try await ReCaVSREightBitFile.importCopy(
      of: source, into: folder, validate: Self.checkSmall, fetch: fetched.fetch, progress: { _ in })
    #expect(listing(folder) == Self.imported)
    #expect(fetched.names.withLock { $0 }.isEmpty)
    #expect(try Data(contentsOf: folder.appending(path: ReCaVSRFiles.eightBitName)) == original)
    #expect(ReCaVSRFiles.installed(.eightBit, in: folder) != nil)
    #expect(ReCaVSRFiles.installed(.full, in: folder) == nil)
    // The original and what was beside it stay as they were.
    #expect(try Data(contentsOf: source) == original)
    #expect(listing(source.deletingLastPathComponent()) == ["flashdecoder.safetensors", "my 8-bit copy.ckpt", "prompt.safetensors"])
  }

  @Test func importDownloadsMissingSiblings() async throws {
    let (root, source, folder) = try importSetup(siblings: false)
    defer { try? FileManager.default.removeItem(at: root) }
    // One is beside the copy at the wrong size, which doesn't count.
    try place("prompt.safetensors", bytes: 1000, in: source.deletingLastPathComponent())
    let fetched = Fetched()
    try await ReCaVSREightBitFile.importCopy(
      of: source, into: folder, validate: Self.checkSmall, fetch: fetched.fetch, progress: { _ in })
    #expect(fetched.names.withLock { $0 } == ["prompt.safetensors", "flashdecoder.safetensors"])
    #expect(listing(folder) == Self.imported)
    #expect(ReCaVSRFiles.installed(.eightBit, in: folder) != nil)
  }

  @Test func importCopiesAndChecksWithoutCloning() async throws {
    let (root, source, folder) = try importSetup(siblings: false)
    defer { try? FileManager.default.removeItem(at: root) }
    // The folder has the small files already; a stale staged copy from a run that quit, too.
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for file in ReCaVSRFiles.companions { try place(file.path, bytes: file.bytes, in: folder) }
    try place(ReCaVSRFiles.eightBitName + ReCaVSREightBitFile.stagingSuffix, bytes: 5000, in: folder)
    try place(ReCaVSRFiles.eightBitName + ".part", bytes: 5000, in: folder)
    let fetched = Fetched()
    let last = Mutex(0.0)
    try await ReCaVSREightBitFile.importCopy(
      of: source, into: folder, allowsCloning: false, validate: Self.checkSmall, fetch: fetched.fetch,
      progress: { value in last.withLock { $0 = value } })
    #expect(fetched.names.withLock { $0 }.isEmpty)
    // The quantizer's own unfinished copy is left for it.
    #expect(listing(folder) == Self.imported + ["transformer_i8x.ckpt.part"])
    #expect(try Data(contentsOf: folder.appending(path: ReCaVSRFiles.eightBitName)) == Data(contentsOf: source))
    #expect(last.withLock { $0 } == 1)
  }

  @Test func importLeavesAnExistingCopy() async throws {
    let (root, source, folder) = try importSetup(siblings: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try place(ReCaVSRFiles.eightBitName, bytes: 4096, in: folder)
    await #expect(throws: ReCaVSREightBitFile.ImportFailure.self) {
      try await ReCaVSREightBitFile.importCopy(
        of: source, into: folder, validate: Self.checkSmall, fetch: Fetched().fetch, progress: { _ in })
    }
    // Nothing replaced, nothing brought.
    #expect(listing(folder) == [ReCaVSRFiles.eightBitName])
    #expect(try FileManager.default.attributesOfItem(
      atPath: folder.appending(path: ReCaVSRFiles.eightBitName).path)[.size] as? Int64 == 4096)
  }

  @Test func importOfTheCopyInPlaceDoesNothing() async throws {
    let root = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let copy = root.appending(path: ReCaVSRFiles.eightBitName)
    writeSmallCopy(copy)
    let original = try Data(contentsOf: copy)
    let fetched = Fetched()
    try await ReCaVSREightBitFile.importCopy(
      of: copy, into: root, validate: Self.checkSmall, fetch: fetched.fetch, progress: { _ in })
    #expect(listing(root) == [ReCaVSRFiles.eightBitName])
    #expect(try Data(contentsOf: copy) == original)
    #expect(fetched.names.withLock { $0 }.isEmpty)
  }

  @Test func importRejectsWhatIsNotACopy() async throws {
    let (root, source, folder) = try importSetup(siblings: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // The real check, at ReCaVSR's sizes: this small file isn't one.
    await #expect(throws: ReCaVSREightBitFile.Problem.wrongShape("blocks.0.attn1.to_q.weight")) {
      try await ReCaVSREightBitFile.importCopy(of: source, into: folder, fetch: Fetched().fetch, progress: { _ in })
    }
    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }

  @Test(arguments: [true, false]) func importThatFailsOrIsCancelledLeavesNoCopy(cancelled: Bool) async throws {
    let (root, source, folder) = try importSetup(siblings: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try Data(contentsOf: source)
    // The second check is of the staged copy: it fails there, or Cancel arrives during it.
    let checks = Mutex(0)
    let check: @Sendable (URL) throws -> Void = { url in
      try Self.checkSmall(url)
      guard checks.withLock({ $0 += 1; return $0 }) == 2 else { return }
      #expect(url.lastPathComponent == ReCaVSRFiles.eightBitName + ReCaVSREightBitFile.stagingSuffix)
      if cancelled {
        withUnsafeCurrentTask { $0?.cancel() }
      } else {
        throw ReCaVSREightBitFile.Problem.truncated
      }
    }
    let task = Task {
      try await ReCaVSREightBitFile.importCopy(
        of: source, into: folder, allowsCloning: cancelled, validate: check, fetch: Fetched().fetch, progress: { _ in })
    }
    let result = await task.result
    switch result {
    case .success: Issue.record("the import finished")
    case .failure(let error):
      #expect(cancelled ? error is CancellationError : error as? ReCaVSREightBitFile.Problem == .truncated)
    }
    #expect(checks.withLock { $0 } == 2)
    // The small files stay (they're whole); the copy and its staged file don't.
    #expect(listing(folder) == ["flashdecoder.safetensors", "prompt.safetensors"])
    #expect(try Data(contentsOf: source) == original)
  }

  @Test func staleStagingIsRemoved() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["transformer_i8x.ckpt.import", "prompt.safetensors.import", "transformer_i8x.ckpt.part", "transformer_i8x.ckpt"] {
      try place(name, bytes: 100, in: folder)
    }
    ReCaVSREightBitFile.removeStaging(in: folder)
    #expect(listing(folder) == ["transformer_i8x.ckpt", "transformer_i8x.ckpt.part"])
  }

  @Test func smallFilesDownloadFirst() {
    #expect(ReCaVSRFiles.downloadOrder.map(\.path) == ["prompt.safetensors", "flashdecoder.safetensors", "transformer.safetensors"])
    #expect(ReCaVSRFiles.downloadOrder.count == ReCaVSRFiles.required.count)
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
