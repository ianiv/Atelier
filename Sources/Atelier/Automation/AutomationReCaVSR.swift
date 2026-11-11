#if os(macOS)
import AVFoundation
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC
import VideoToolbox

extension Automation {
  /// Checks the ReCaVSR port against the reference's dumps (a PyTorch run of
  /// recavsr_infer, saved per block as safetensors with a manifest.json): feeds the dumped
  /// source and noise through the source projection, the DiT and FlashDecoder, and compares
  /// every intermediate the dump has, printing max abs, relative L2 and cosine per tensor and
  /// the worst relative L2 per stage, then PASS or FAIL against the thresholds.
  ///
  ///   Atelier --recavsr-check --reference DIR [--blocks N] [--own-latents] [--verbose] [--quit]
  ///
  /// Or upscales the first frames of a real clip, printing seconds per frame and peak memory,
  /// and with `--export DIR` writes the result there as an MP4:
  ///
  ///   Atelier --recavsr-check --input FILE [--frames 45] [--scale 4] [--source-size WxH]
  ///           [--export DIR] [--no-color-fix] [--quit]
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
    if let input = value("--input") {
      return recaVSRRun(
        files: files, input: input, frames: value("--frames").flatMap(Int.init) ?? 45,
        scale: value("--scale").flatMap(Int.init) ?? 4, export: value("--export"),
        sourceSize: value("--source-size").map { $0.split(separator: "x").compactMap { Int($0) } },
        colorFix: !args.contains("--no-color-fix"), log: log, finish: finish)
    }
    guard let reference = value("--reference") else {
      log("FAIL --reference DIR or --input FILE is needed")
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

extension Automation {
  /// The process's peak memory footprint so far, GPU allocations included.
  nonisolated static func peakFootprint() -> UInt64 { footprint().peak }

  /// The process's memory footprint now and at its peak.
  nonisolated static func footprint() -> (now: UInt64, peak: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (UInt64(info.phys_footprint), UInt64(max(0, info.ledger_phys_footprint_peak)))
  }

  /// `--recavsr-check --input`: a real clip through `ReCaVSRUpscaler`.
  nonisolated static func recaVSRRun(
    files: ReCaVSRFiles, input: String, frames limit: Int, scale: Int, export: String?, sourceSize: [Int]?,
    colorFix: Bool,
    log: @escaping @Sendable (String) -> Void, finish: @escaping @Sendable () -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: input))
        let reader = try AVAssetReader(asset: asset)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        nonisolated(unsafe) var fps: Double = 24
        Task {
          track = try? await asset.loadTracks(withMediaType: .video).first
          if let track, let rate = try? await track.load(.nominalFrameRate) { fps = Double(rate) }
          semaphore.signal()
        }
        semaphore.wait()
        guard let track else { throw ClipVideoError.noFrames }
        let output = AVAssetReaderTrackOutput(
          track: track,
          outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
        reader.add(output)
        reader.startReading()
        var sources: [CGImage] = []
        while sources.count < limit, let sample = output.copyNextSampleBuffer(), let buffer = sample.imageBuffer {
          var image: CGImage?
          VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
          guard let image else { continue }
          if let sourceSize, sourceSize.count == 2,
            let context = CGContext(
              data: nil, width: sourceSize[0], height: sourceSize[1], bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
          {
            // Shrunk first (`--source-size`), to benchmark an output size.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: sourceSize[0], height: sourceSize[1]))
            if let small = context.makeImage() { sources.append(small) }
          } else if let copy = image.copy() {
            sources.append(copy)
          }
        }
        guard let first = sources.first else { throw ClipVideoError.noFrames }
        let size = ReCaVSRUpscaler.outputSize(width: first.width, height: first.height, scale: scale)
        log("\(sources.count) frames at \(first.width)x\(first.height) -> \(size.width)x\(size.height), full weights")
        var upscaler = ReCaVSRUpscaler(files: files, width: size.width, height: size.height)
        upscaler.colorFix = colorFix
        var frames: [CGImage] = []
        let started = Date()
        var upscaleStarted = Date()
        var blockStarted = Date()
        try upscaler.run(
          count: sources.count, frame: { sources[$0] },
          progress: { phase, done, total in
            if phase == .upscaling, done == 0 {
              upscaleStarted = Date()
              let memory = footprint()
              log(
                String(
                  format: "loaded in %.1fs, memory %.1f GB (peak %.1f GB)", Date().timeIntervalSince(started),
                  Double(memory.now) / 1e9, Double(memory.peak) / 1e9))
            } else if phase == .upscaling {
              let memory = footprint()
              log(
                String(
                  format: "block %d/%d in %.1fs, memory %.1f GB (peak %.1f GB)", done, total,
                  Date().timeIntervalSince(blockStarted), Double(memory.now) / 1e9, Double(memory.peak) / 1e9))
            }
            blockStarted = Date()
          },
          shouldContinue: { true }
        ) { tensor in
          if let image = ImageTensor.cgImage(from: tensor) { frames.append(image) }
        }
        let seconds = Date().timeIntervalSince(upscaleStarted)
        log(
          String(
            format: "PASS %d frames in %.1fs after loading (%.2fs a frame), peak memory %.1f GB", frames.count, seconds,
            seconds / Double(max(frames.count, 1)), Double(peakFootprint()) / 1e9))
        guard let export else { return finish() }
        let url = URL(fileURLWithPath: export).appending(path: "recavsr-\(size.width)x\(size.height)-\(frames.count)f.mp4")
        let written = frames
        Task {
          do {
            try await ClipVideo.write(
              to: url, count: written.count, frame: { written[$0] }, framesPerSecond: fps, audio: nil,
              audioSampleRate: 0, codec: .h264, metadata: nil)
            log("exported \(url.path)")
          } catch {
            log("FAIL export \(error)")
          }
          finish()
        }
      } catch {
        log("FAIL \(error)")
        finish()
      }
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
    var out_hw: [Int]
    var lr_hw: [Int]
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

  /// A u8 tensor from a safetensors file, as bytes.
  static func bytes(_ url: URL, name: String) throws -> [UInt8] {
    let data = try Data(contentsOf: url)
    let length = data.prefix(8).withUnsafeBytes { Int($0.loadUnaligned(as: UInt64.self)) }
    let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + length))) as? [String: Any]
    guard let entry = header?[name] as? [String: Any], let offsets = entry["data_offsets"] as? [Int] else {
      throw ReCaVSRDenoiser.Failure.badCheckpoint("no \(name) in \(url.lastPathComponent)")
    }
    return [UInt8](data.subdata(in: (8 + length + offsets[0])..<(8 + length + offsets[1])))
  }

  /// The source preparation against the reference's: OpenCV's bilinear on frame 0 (to 1 LSB),
  /// then each block's normalized, padded frames.
  func checkPreparation(_ manifest: Manifest, blocks: [ReCaVSRRouter.Block], failed: inout Bool) throws {
    let lrHeight = manifest.lr_hw[0], lrWidth = manifest.lr_hw[1]
    let outHeight = manifest.out_hw[0], outWidth = manifest.out_hw[1]
    let frames = try Self.bytes(directory.appending(path: "lr_frames.safetensors"), name: "lr_frames_uint8_THWC")
    let frameBytes = lrHeight * lrWidth * 3
    func source(_ i: Int) -> [UInt8] { Array(frames[(i * frameBytes)..<((i + 1) * frameBytes)]) }
    let resized = try Self.bytes(directory.appending(path: "resize_frame0.safetensors"), name: "resized_uint8_HWC")
    let ours = ReCaVSRUpscaler.bilinear(source(0), width: lrWidth, height: lrHeight, targetWidth: outWidth, targetHeight: outHeight)
    let differences = zip(ours, resized).map { abs(Int($0) - Int($1)) }
    let off = differences.filter { $0 > 0 }.count
    let maxDifference = differences.max() ?? 0
    if maxDifference > 1 { failed = true }
    log("\(maxDifference > 1 ? "BAD" : "ok ") bilinear frame 0: max diff \(maxDifference) LSB, \(off) of \(ours.count) values differ")
    let Hp = manifest.padded_hw[0], Wp = manifest.padded_hw[1]
    var worstLSB: Float = 0
    for block in blocks {
      var prepared = Tensor<FloatType>(.CPU, .NHWC(block.frames, Hp, Wp, 3))
      for offset in 0..<block.frames {
        let index = block.start + min(offset, block.valid - 1)
        ReCaVSRUpscaler.prepare(
          ReCaVSRUpscaler.bilinear(source(index), width: lrWidth, height: lrHeight, targetWidth: outWidth, targetHeight: outHeight),
          width: outWidth, height: outHeight, into: &prepared, frame: offset)
      }
      // The dump is [1, 3, T, H, W].
      let lq = try ReCaVSRCheckpoint(directory.appending(path: "block_\(block.index).safetensors")).tensor("lq")
      lq.withUnsafeBytes { raw in
        let theirs = raw.bindMemory(to: Float.self)
        prepared.withUnsafeBytes { raw in
          let ours = raw.bindMemory(to: FloatType.self)
          let plane = block.frames * Hp * Wp
          for t in 0..<block.frames {
            for y in 0..<Hp {
              for x in 0..<Wp {
                for c in 0..<3 {
                  let a = Float(ours[((t * Hp + y) * Wp + x) * 3 + c])
                  let b = theirs[c * plane + (t * Hp + y) * Wp + x]
                  worstLSB = max(worstLSB, abs(a - b) * 127.5)
                }
              }
            }
          }
        }
      }
    }
    if worstLSB > 1.1 { failed = true }
    log(String(format: "%@ prepared source (bilinear, normalize, pad, repeat): worst %.2f LSB", worstLSB > 1.1 ? "BAD" : "ok ", worstLSB))
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
    try checkPreparation(manifest, blocks: Array(blockList), failed: &failed)
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
      let checkpoint = try ReCaVSRCheckpoint(files.transformer)
      let projection = try ReCaVSRSourceProjection(
        graph: graph, checkpoint: checkpoint, height: height, width: width)
      let denoiser = try ReCaVSRDenoiser(
        graph: graph, checkpoint: checkpoint, prompt: ReCaVSRCheckpoint(files.prompt), height: height,
        width: width, window: (manifest.dit_window_tokens[0], manifest.dit_window_tokens[1]))
      let decoder = try ReCaVSRDecoder(
        graph: graph, checkpoint: ReCaVSRCheckpoint(files.decoder), latentHeight: height / 16,
        latentWidth: width / 16)
      graph.garbageCollect()
      log(String(format: "loaded in %.1fs, attention %@", Date().timeIntervalSince(loadStarted), denoiser.isWindowed ? "windowed" : "full"))
      for block in blockList {
        loadStarted = Date()
        let dump = try ReCaVSRCheckpoint(directory.appending(path: "block_\(block.index).safetensors"))
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
