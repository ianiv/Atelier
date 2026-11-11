#if os(macOS)
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC

extension Automation {
  /// Checks the ReCaVSR port against the reference's dumps (a PyTorch run of
  /// recavsr_infer, saved per block as safetensors with a manifest.json): feeds the dumped
  /// source and noise through the source projection, the DiT and FlashDecoder, and compares
  /// every intermediate the dump has, printing max abs, relative L2 and cosine per tensor and
  /// the worst relative L2 per stage, then PASS or FAIL against the thresholds.
  ///
  ///   Atelier --recavsr-check --reference DIR [--blocks N] [--own-latents] [--verbose] [--quit]
  ///
  /// Loads only the ReCaVSR folder of the models directory.
  static func recaVSRCheck() {
    let args = CommandLine.arguments
    let value: @Sendable (String) -> String? = { name in
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    let started = Date()
    let log: @Sendable (String) -> Void = { message in
      print(String(format: "[%7.2fs] ", Date().timeIntervalSince(started)) + message)
      fflush(stdout)
    }
    let finish: @Sendable () -> Void = {
      if args.contains("--quit") { Task { @MainActor in AppLifecycle.quit() } }
    }
    guard let files = ReCaVSRFiles.installed(.full) else {
      log("FAIL ReCaVSR isn't in \(AppSettings.modelsDirectory)/\(ReCaVSRFiles.folderName)")
      return finish()
    }
    guard let reference = value("--reference") else {
      log("FAIL --reference DIR is needed")
      return finish()
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try ReCaVSRReferenceCheck(
          files: files, directory: URL(fileURLWithPath: reference),
          blocks: value("--blocks").flatMap(Int.init), verbose: args.contains("--verbose"),
          ownLatents: args.contains("--own-latents"), log: log
        ).run()
      } catch {
        log("FAIL \(error)")
      }
      finish()
    }
  }
}

/// The comparison `--recavsr-check --reference` runs.
nonisolated struct ReCaVSRReferenceCheck {
  var files: ReCaVSRFiles
  var directory: URL
  var blocks: Int?
  var verbose: Bool
  var ownLatents = false
  var log: @Sendable (String) -> Void

  struct Manifest: Decodable {
    var frames: Int
    var padded_hw: [Int]
    var dit_window_tokens: [Int]
  }

  /// Relative L2 each stage must stay under.
  static func threshold(_ stage: String) -> Float {
    switch stage {
    case "x0", "pred": 1e-2
    case "decoder_rgb": 1
    default: 2e-2
    }
  }

  /// Decoded RGB against the reference's, in dB over [-1, 1].
  static let minimumPSNR = 40.0

  /// The stage a tensor name belongs to, for the summary.
  static func stage(_ name: String) -> String {
    if name.hasPrefix("layer_"), name.hasSuffix("_out") { return "layers" }
    if name.hasPrefix("layer_"), name.hasSuffix("_v") { return "values" }
    return name
  }

  func run() throws {
    let manifest = try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    let height = manifest.padded_hw[0], width = manifest.padded_hw[1]
    let blockList = ReCaVSRRouter.blocks(manifest.frames).prefix(blocks ?? .max)
    log("reference \(directory.lastPathComponent): \(manifest.frames) frames, \(width)x\(height), window \(manifest.dit_window_tokens), \(blockList.count) blocks")
    let graph = DynamicGraph()
    var worst: [String: (Float, String)] = [:]
    var failed = false
    var psnrs: [Double] = []
    func compare(_ name: String, _ ours: [Float], _ theirs: [Float]) {
      guard ours.count == theirs.count else {
        log("FAIL \(name): \(ours.count) values, reference \(theirs.count)")
        failed = true
        return
      }
      var maxAbs: Float = 0, diff: Double = 0, norm: Double = 0, dot: Double = 0, ourNorm: Double = 0
      var nonFinite = 0
      for i in 0..<ours.count {
        let a = ours[i], b = theirs[i]
        if !a.isFinite { nonFinite += 1 }
        let d = abs(a - b)
        maxAbs = max(maxAbs, d)
        diff += Double(d) * Double(d)
        norm += Double(b) * Double(b)
        ourNorm += Double(a) * Double(a)
        dot += Double(a) * Double(b)
      }
      let rel = Float((diff / max(norm, 1e-30)).squareRoot())
      let cosine = dot / max((norm * ourNorm).squareRoot(), 1e-30)
      let stage = Self.stage(String(name.split(separator: ".", maxSplits: 1).last!))
      if rel > (worst[stage]?.0 ?? -1) { worst[stage] = (rel, name) }
      let bad = nonFinite > 0 || !(rel < Self.threshold(stage))
      if bad { failed = true }
      if verbose || bad {
        log(String(format: "%@ %@ maxabs %.4g relL2 %.3e cos %.6f%@", bad ? "BAD" : "ok ", name, maxAbs, rel, cosine, nonFinite > 0 ? " NONFINITE \(nonFinite)" : ""))
      }
      if bad, verbose, ours.count % 3072 == 0 {
        // Where it's off: the worst tokens (rows of 3072) by error norm.
        var errors: [(Int, Double, Double)] = []
        for token in 0..<(ours.count / 3072) {
          var e = 0.0, r = 0.0
          for c in 0..<3072 {
            let d = Double(ours[token * 3072 + c] - theirs[token * 3072 + c])
            e += d * d
            r += Double(theirs[token * 3072 + c] * theirs[token * 3072 + c])
          }
          errors.append((token, e.squareRoot(), r.squareRoot()))
        }
        let worst = errors.sorted { $0.1 > $1.1 }.prefix(8).map { String(format: "%d:%.2f/%.2f", $0.0, $0.1, $0.2) }
        log("  worst tokens (error/norm) \(worst.joined(separator: " "))")
      }
    }
    func floats(_ tensor: DynamicGraph.Tensor<Float>) -> [Float] {
      floats(tensor.rawValue.toCPU())
    }
    func floats(_ tensor: Tensor<Float>) -> [Float] {
      tensor.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    /// A dumped `[1, C, F, h, w]` as `[F, h, w, C]`.
    func channelsLast(_ tensor: Tensor<Float>) -> DynamicGraph.Tensor<Float> {
      let s = tensor.shape
      return graph.variable(tensor.toGPU(0)).reshaped(format: .NCHW, shape: [s[1], s[2] * s[3] * s[4]])
        .transposed(0, 1).copied().reshaped(.NHWC(s[2], s[3], s[4], s[1]))
    }

    // RECAVSR_KEEP_NA=1 runs without the attention workaround, to see whether it's still needed.
    let keepAccelerators = ProcessInfo.processInfo.environment["RECAVSR_KEEP_NA"] != nil
    try ReCaVSRConfig.withAttentionWorkaround(keepAccelerators ? false : true) {
    try graph.withNoGrad {
      var loadStarted = Date()
      let checkpoint = try FlashVSRCheckpoint(files.transformer)
      let projection = try ReCaVSRSourceProjection(
        graph: graph, checkpoint: checkpoint, height: height, width: width)
      let denoiser = try ReCaVSRDenoiser(
        graph: graph, checkpoint: checkpoint, prompt: FlashVSRCheckpoint(files.prompt), height: height,
        width: width, window: (manifest.dit_window_tokens[0], manifest.dit_window_tokens[1]))
      let decoder = try ReCaVSRDecoder(
        graph: graph, checkpoint: FlashVSRCheckpoint(files.decoder), latentHeight: height / 16,
        latentWidth: width / 16)
      graph.garbageCollect()
      log(String(format: "loaded in %.1fs, attention %@", Date().timeIntervalSince(loadStarted), denoiser.isWindowed ? "windowed" : "full"))
      for block in blockList {
        loadStarted = Date()
        let dump = try FlashVSRCheckpoint(directory.appending(path: "block_\(block.index).safetensors"))
        // The source, [1, 3, T, H, W] → [T, H, W, 3].
        let lq = try dump.tensor("lq")
        let T = lq.shape[2]
        let frames = DynamicGraph.Tensor<FloatType>(
          from: graph.variable(lq.toGPU(0)).reshaped(format: .NCHW, shape: [3, T * height * width])
            .transposed(0, 1).copied()
        ).reshaped(.NHWC(T, height, width, 3))
        let rows = projection.next(projection.unshuffled(frames))
        compare("b\(block.index).lq_proj", floats(DynamicGraph.Tensor<Float>(from: rows)), floats(try dump.tensor("lq_proj")))
        let noise = channelsLast(try dump.tensor("noise"))
        let x0 = try denoiser.next(
          noise: noise, rows: rows, shouldContinue: { true },
          inspect: { name, tensor in
            let key = name == "pred" ? "pred" : name
            guard dump.contains(key) else { return }
            if name == "pred" {
              compare("b\(block.index).pred", floats(tensor), floats(channelsLast(try! dump.tensor("pred"))))
            } else {
              compare("b\(block.index).\(name)", floats(tensor), floats(try! dump.tensor(key)))
            }
          })!
        compare("b\(block.index).x0", floats(x0), floats(channelsLast(try dump.tensor("x0"))))
        // FlashDecoder on the reference's x0 (ours with --own-latents), each latent with the
        // source frames it covers.
        let latents = ownLatents ? x0 : channelsLast(try dump.tensor("x0"))
        let source = DynamicGraph.Tensor<Float>(from: frames)
        var decoded: [DynamicGraph.Tensor<Float>] = []
        var next = 0
        for i in 0..<block.latents {
          let take = decoder.frameIndex == 0 ? 1 : 4
          decoded.append(
            decoder.decode(
              latent: latents[i..<(i + 1), 0..<(height / 16), 0..<(width / 16), 0..<48].copied(),
              source: source[next..<(next + take), 0..<height, 0..<width, 0..<3].copied()))
          next += take
        }
        let rgb = floats(concatenated(decoded))
        let reference = floats(channelsLast(try dump.tensor("decoder_rgb")))
        compare("b\(block.index).decoder_rgb", rgb, reference)
        if rgb.count == reference.count {
          let mse = zip(rgb, reference).reduce(0.0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) } / Double(rgb.count)
          let psnr = 10 * log10(4 / max(mse, 1e-20))
          psnrs.append(psnr)
          log(String(format: "b%d decoder PSNR %.2f dB", block.index, psnr))
        }
        graph.garbageCollect()
        log(String(format: "block %d done in %.1fs", block.index, Date().timeIntervalSince(loadStarted)))
      }
    }
    }
    for (stage, value) in worst.sorted(by: { $0.key < $1.key }) {
      log(String(format: "worst %@ relL2 %.3e (%@)", stage, value.0, value.1))
    }
    if let lowest = psnrs.min() {
      log(String(format: "lowest decoder PSNR %.2f dB (needs > %.0f)", lowest, Self.minimumPSNR))
      if lowest <= Self.minimumPSNR { failed = true }
    }
    log(failed ? "FAIL" : "PASS")
  }
}
#endif
