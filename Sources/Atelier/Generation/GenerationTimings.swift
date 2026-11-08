@preconcurrency import _MediaGenerationKit
import Foundation

/// How long each phase of a run took, from the engine's progress signposts, for benchmarks.
///
/// The engine reports when the prompt and inputs are encoded (after each finishes), when each
/// sampling step starts, once more when sampling ends (`LocalImageGenerator` calls
/// `feedback(.sampling(steps))` after the sampler returns; MGK and `GenerationEngine` report that
/// as the last step again), and when the result is decoded (`.imageDecoded`, after the VAE and,
/// for video, the soundtrack). Nothing is estimated: when a run gives no end-of-sampling signal,
/// the last step and decoding stay together in `lastStepAndDecode`.
nonisolated struct GenerationTimings: Codable, Sendable, Equatable {
  /// From the start of the run until the prompt was encoded: loading the models and encoding.
  var prepareAndEncodePrompt: Double?
  /// From the encoded prompt until the image inputs (canvas, moodboard, audio) were encoded.
  var encodeInputs: Double?
  /// From the last encoding until the first sampling step began.
  var beforeSampling: Double?
  /// Each sampling step, start to start; the last one ends when sampling ends, if that's known.
  var steps: [Double] = []
  /// From the end of sampling until the result was decoded (frames and soundtrack).
  var decode: Double?
  /// The last step and decoding together, when the engine didn't signal the end of sampling.
  var lastStepAndDecode: Double?
  /// From the decoded result until the engine handed it back.
  var afterDecode: Double?
  /// Saving the result into the project (the job's timings only).
  var save: Double?
  var total: Double

  var sampling: Double { steps.reduce(0, +) }

  /// One line per phase, for the Queue and info panels.
  var lines: [String] {
    func t(_ seconds: Double) -> String {
      Duration.seconds(seconds).formatted(.units(width: .narrow, fractionalPart: .show(length: 1)))
    }
    var lines: [String] = []
    if let prepareAndEncodePrompt { lines.append("Load + encode prompt \(t(prepareAndEncodePrompt))") }
    if let encodeInputs { lines.append("Encode inputs \(t(encodeInputs))") }
    if let beforeSampling { lines.append("Before step 1 \(t(beforeSampling))") }
    if !steps.isEmpty {
      let each = steps.map { t($0) }.joined(separator: ", ")
      lines.append("Sampling \(t(sampling)) (\(steps.count) steps: \(each))")
    }
    if let decode { lines.append("Decode \(t(decode))") }
    if let lastStepAndDecode { lines.append("Last step + decode \(t(lastStepAndDecode))") }
    if let afterDecode { lines.append("After decode \(t(afterDecode))") }
    if let save { lines.append("Save \(t(save))") }
    lines.append("Total \(t(total))")
    return lines
  }

  /// Draw Things' `GenerationProfile.timings` (name and durations), kept in `profile_data`.
  var profileTimings: [ProjectMapping.Profile.Timing] {
    var timings: [ProjectMapping.Profile.Timing] = []
    func add(_ name: String, _ value: Double?) {
      if let value { timings.append(.init(durations: [value], name: name)) }
    }
    add("Load and Encode Prompt", prepareAndEncodePrompt)
    add("Encode Inputs", encodeInputs)
    add("Before Sampling", beforeSampling)
    if !steps.isEmpty { timings.append(.init(durations: steps, name: "Sampling")) }
    add("Decode", decode)
    add("Last Step and Decode", lastStepAndDecode)
    add("After Decode", afterDecode)
    add("Save", save)
    return timings
  }

  /// Rebuilt from `profile_data` timings; nil when a step has none (older steps, Draw Things').
  init?(profile: ProjectMapping.Profile) {
    guard !profile.timings.isEmpty else { return nil }
    func value(_ name: String) -> Double? { profile.timings.first { $0.name == name }?.durations.first }
    prepareAndEncodePrompt = value("Load and Encode Prompt")
    encodeInputs = value("Encode Inputs")
    beforeSampling = value("Before Sampling")
    steps = profile.timings.first { $0.name == "Sampling" }?.durations ?? []
    decode = value("Decode")
    lastStepAndDecode = value("Last Step and Decode")
    afterDecode = value("After Decode")
    save = value("Save")
    total = profile.duration
  }

  init(total: Double) {
    self.total = total
  }

  /// For MCP results: seconds, rounded to 0.1.
  var json: [String: Any] {
    func r(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    var json: [String: Any] = ["total": r(total), "steps": steps.map(r), "sampling": r(sampling)]
    if let prepareAndEncodePrompt { json["load_and_encode_prompt"] = r(prepareAndEncodePrompt) }
    if let encodeInputs { json["encode_inputs"] = r(encodeInputs) }
    if let beforeSampling { json["before_sampling"] = r(beforeSampling) }
    if let decode { json["decode"] = r(decode) }
    if let lastStepAndDecode { json["last_step_and_decode"] = r(lastStepAndDecode) }
    if let afterDecode { json["after_decode"] = r(afterDecode) }
    if let save { json["save"] = r(save) }
    return json
  }
}

/// Timestamps a run's progress states as they arrive (`CreateModel`'s progress callback, for
/// every local job) and turns them into `GenerationTimings`.
nonisolated struct GenerationTimingRecorder {
  let startedAt: Date
  private var promptEncoded: Date?
  private var inputsEncoded: Date?
  private var firstStepStarted: Date?
  private var stepStarted: Date?
  private var step = 0
  private var stepDurations: [Double] = []
  private(set) var samplingEnded: Date?
  private var decoded: Date?

  init(startedAt: Date) {
    self.startedAt = startedAt
  }

  /// Notes a progress state that arrived at `date`. Returns true when it marks the end of
  /// sampling (the last step reported a second time).
  @discardableResult
  mutating func note(_ state: MediaGenerationPipeline.State, at date: Date) -> Bool {
    switch state {
    case .encodingText:
      if promptEncoded == nil { promptEncoded = date }
    case .encodingInputs:
      if inputsEncoded == nil { inputsEncoded = date }
    case .generating(let reported, let total):
      if let stepStarted, reported == step {
        // The engine's end-of-sampling report repeats the last step (MGK clamps its index).
        guard reported == total, samplingEnded == nil else { return false }
        stepDurations.append(date.timeIntervalSince(stepStarted))
        samplingEnded = date
        return true
      }
      if let stepStarted { stepDurations.append(date.timeIntervalSince(stepStarted)) }
      if firstStepStarted == nil { firstStepStarted = date }
      stepStarted = date
      step = reported
    case .decoding:
      if decoded == nil { decoded = date }
    default:
      break
    }
    return false
  }

  /// The timings once the engine handed the result back at `returnedAt`.
  func timings(returnedAt: Date) -> GenerationTimings {
    var timings = GenerationTimings(total: returnedAt.timeIntervalSince(startedAt))
    if let promptEncoded { timings.prepareAndEncodePrompt = promptEncoded.timeIntervalSince(startedAt) }
    if let promptEncoded, let inputsEncoded { timings.encodeInputs = inputsEncoded.timeIntervalSince(promptEncoded) }
    if let firstStepStarted {
      timings.beforeSampling = firstStepStarted.timeIntervalSince(inputsEncoded ?? promptEncoded ?? startedAt)
    }
    timings.steps = stepDurations
    // Without a decoded signal, decoding runs until the engine returned.
    let decodeEnd = decoded ?? returnedAt
    if let samplingEnded {
      timings.decode = decodeEnd.timeIntervalSince(samplingEnded)
    } else if let stepStarted {
      timings.lastStepAndDecode = decodeEnd.timeIntervalSince(stepStarted)
    }
    if let decoded { timings.afterDecode = returnedAt.timeIntervalSince(decoded) }
    return timings
  }
}
