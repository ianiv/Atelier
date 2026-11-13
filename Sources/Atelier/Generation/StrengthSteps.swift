@preconcurrency import DataModels
@preconcurrency import Diffusion
import Foundation
import ModelZoo
import Synchronization

/// Where an Edit run at Strength below 1 starts in its schedule, so the inspector can say how much
/// of it actually runs. Strength is a noise level, not a share of the steps: the sampler starts at
/// the first step whose timestep, on the *shifted* schedule, is at or below Strength × the
/// schedule's length (`DDIMSampler.timestep(for:sampling:)`). With a high Shift most steps sit at
/// high noise, so at Shift 5 with 8 steps, Strength 0.3 runs about one model pass.
nonisolated enum StrengthSteps {
  struct Start: Equatable {
    /// The step denoising starts at, fractional between two of the schedule's steps.
    var startStep: Float
    var steps: Int

    /// How much of the schedule runs: from `startStep` to the end.
    var remaining: Double { Double(steps) - Double(startStep) }
    /// How many times the model runs: the sampler goes from the step before a fractional start
    /// (`startStep.integral..<endStep.integral` in `DDIMSampler.sample`).
    var modelPasses: Int { steps - Int(startStep.rounded(.down)) }
  }

  /// The start for a run of `model` with these settings, as `LocalImageGenerator.generate` sets
  /// it up: the model's noise parameterization (`ModelZoo.noiseDiscretizationForModel`), the shift
  /// (`ModelZoo.shiftFor` at the run's size, tiled diffusion's tile when smaller, when
  /// Resolution-Dependent Shift is on and the model takes it; else the Shift setting), and the
  /// sampler's discretization (`LocalImageGenerator.sampler(from:)`). Nil where the steps run
  /// aren't the user's to count: a model `ModelZoo` doesn't know (a server's), the fixed sigma
  /// grids of HyperFlow H3 Flash and MiniMax H3 Image, Würstchen, and samplers on manual timesteps or sigmas.
  static func start(
    model: String, sampler: DataModels.SamplerType, steps: Int, strength: Float, shift: Double,
    resolutionDependentShift: Bool, width: Int, height: Int, tile: (width: Int, height: Int)? = nil
  ) -> Start? {
    guard steps > 0, ModelZoo.specificationForModel(model) != nil else { return nil }
    let version = ModelZoo.versionForModel(model)
    switch version {
    case .wurstchenStageB, .wurstchenStageC: return nil
    case .minimaxH3, .minimaxH3Image:
      // Only once `checkFixedGrid` has read the file: the inspector asks on the main actor.
      guard knownFixedGrid(model) == false else { return nil }
    default: break
    }
    let parameterization: Denoiser.Parameterization
    switch ModelZoo.noiseDiscretizationForModel(model) {
    case .edm(let edm): parameterization = .edm(edm)
    case .ddpm(let ddpm): parameterization = .ddpm(ddpm)
    case .rf(let rf): parameterization = .rf(rf)
    }
    var runShift = shift
    if resolutionDependentShift,
       ModelZoo.isResolutionDependentShiftAvailable(version, isConsistencyModel: ModelZoo.isConsistencyModelForModel(model))
    {
      // In 64-pixel units, as `GenerationConfiguration.startWidth`.
      let units = (width: width / 64, height: height / 64)
      let tiled = tile.map { (width: min($0.width / 64, units.width), height: min($0.height / 64, units.height)) } ?? units
      runShift = ModelZoo.shiftFor((width: UInt16(clamping: tiled.width), height: UInt16(clamping: tiled.height)), version: version)
    }
    return start(
      parameterization: parameterization, objective: ModelZoo.objectiveForModel(model), version: version,
      sampler: sampler, sampling: Sampling(steps: steps, shift: runShift), strength: strength)
  }

  /// Whether each MiniMax H3 file checked so far runs its own fixed sigma grid.
  private static let fixedGrids = Mutex<[String: Bool]>([:])

  /// What `checkFixedGrid` found for `model`; nil until it has run.
  static func knownFixedGrid(_ model: String) -> Bool? {
    fixedGrids.withLock { $0[model] }
  }

  /// Whether a MiniMax H3 file runs Euler on its own sigma grid whatever the sampler, as
  /// `LocalImageGenerator.sampler(from:)` decides: HyperFlow's two-time checkpoints and H3 Image
  /// files with output-head grids (`MiniMaxH3Layout.load`). Reads the file once, off the main
  /// actor, and remembers it; a file that isn't there counts as fixed (nothing to count).
  @concurrent static func checkFixedGrid(_ model: String) async -> Bool {
    if let known = knownFixedGrid(model) { return known }
    let path = ModelZoo.filePathForModelDownloaded(model)
    var fixed = true
    if FileManager.default.fileExists(atPath: path) {
      let layout = MiniMaxH3Layout.load(filePath: path)
      fixed = ModelZoo.versionForModel(model) == .minimaxH3 ? layout.isTwoTime : !layout.sigmaGrids.isEmpty
    }
    fixedGrids.withLock { $0[model] = fixed }
    return fixed
  }

  /// The start for a parameterization and sampler: the discretization each sampler type is built
  /// with (`LocalImageGenerator.sampler(from:)`), then its `timestep(for:sampling:)`. Every
  /// sampler but PLMS shares DDIM's; PLMS starts at a whole step (`PLMSSampler.timestep`).
  static func start(
    parameterization: Denoiser.Parameterization, objective: Denoiser.Objective, version: ModelVersion,
    sampler: DataModels.SamplerType, sampling: Sampling, strength: Float
  ) -> Start? {
    let strength = min(max(strength, 0), 1)
    func at(_ discretization: some Denoiser.Discretization) -> Start {
      Start(startStep: startStep(for: strength, sampling: sampling, discretization: discretization), steps: sampling.steps)
    }
    switch sampler {
    case .dPMPP2MKarras, .dPMPPSDEKarras:
      return at(Denoiser.KarrasDiscretization(parameterization, objective: objective))
    case .DPMPP2MAYS, .eulerAAYS, .DPMPPSDEAYS, .uniPCAYS:
      // Align Your Steps has its own timesteps or sigmas for these models; otherwise it's trailing.
      guard !hasAlignYourStepsSchedule(version, parameterization: parameterization) else { return nil }
      return at(Denoiser.LinearDiscretization(parameterization, objective: objective, timestepSpacing: .trailing))
    case .dPMPP2MTrailing, .eulerATrailing, .dDIMTrailing, .dPMPPSDETrailing, .uniPCTrailing, .tCDTrailing:
      return at(Denoiser.LinearDiscretization(parameterization, objective: objective, timestepSpacing: .trailing))
    case .eulerA, .uniPC, .LCM, .TCD:
      return at(Denoiser.LinearDiscretization(parameterization, objective: objective))
    case .DDIM:
      return at(Denoiser.LinearDiscretization(parameterization, objective: objective, timestepSpacing: .leading))
    case .PLMS:
      let encoded = Int(strength * Float(sampling.steps))
      return Start(startStep: Float(sampling.steps - encoded), steps: sampling.steps)
    case .eulerASubstep, .dPMPPSDESubstep:
      // Fixed manual timesteps (`LinearManualDiscretization`).
      return nil
    }
  }

  /// Whether `LocalImageGenerator.sampler(from:)` gives this model Align Your Steps' own timesteps
  /// (SD 1.x/2.x, SDXL on DDPM) or sigmas (Stable Video Diffusion).
  private static func hasAlignYourStepsSchedule(_ version: ModelVersion, parameterization: Denoiser.Parameterization) -> Bool {
    switch version {
    case .v1, .v2, .svdI2v: return true
    case .sdxlBase, .sdxlRefiner, .ssd1b:
      if case .ddpm = parameterization { return true }
      return false
    default: return false
    }
  }

  /// `DDIMSampler.timestep(for:sampling:)`'s start step: the schedule's first step whose timestep
  /// is at or below Strength × its length, interpolated between that step and the one before.
  static func startStep(
    for strength: Float, sampling: Sampling, discretization: some Denoiser.Discretization
  ) -> Float {
    let initTimestep = strength * discretization.timesteps
    let alphasCumprod = discretization.alphasCumprod(steps: sampling.steps, shift: sampling.shift)
    var previousTimestep = discretization.timesteps
    for (i, alphaCumprod) in alphasCumprod.enumerated() {
      let timestep = discretization.timestep(for: alphaCumprod)
      if initTimestep >= timestep {
        guard i > 0 else { return 0 }
        guard initTimestep > timestep + 1e-3 else { return Float(i) }
        return Float(i - 1) + Float(initTimestep - previousTimestep) / Float(timestep - previousTimestep)
      }
      previousTimestep = timestep
    }
    return Float(alphasCumprod.count - 1)
  }

  /// The inspector's line under Strength: "≈1.3 of 8 steps at Shift 5" (one decimal below 2,
  /// "at Shift" only for a model that takes it), and the longer explanation for its help.
  static func hint(_ start: Start, strength: Float, shift: Double?) -> (text: String, help: String) {
    let remaining = start.remaining
    let count = remaining < 2
      ? remaining.formatted(.number.precision(.fractionLength(0...1)))
      : Int(remaining.rounded()).formatted()
    let shiftText = shift.map { " at Shift \($0.formatted(.number.precision(.fractionLength(0...2))))" } ?? ""
    let passes = start.modelPasses
    var help = "Strength \(strength.formatted(.number.precision(.fractionLength(0...2)))) starts denoising at step "
      + "\(Double(start.startStep).formatted(.number.precision(.fractionLength(0...1)))) of \(start.steps), "
      + "so it runs \(passes) model \(passes == 1 ? "pass" : "passes")."
    if shift != nil { help += " With a high Shift, low Strength changes very little." }
    return ("≈\(count) of \(start.steps) steps\(shiftText)", help)
  }
}

/// A line under a setting's row in the inspector (`SettingDescriptor.hint`), with the longer
/// explanation for its help and VoiceOver; `dimmed` for one that only says nothing special applies.
struct SettingHint: Equatable {
  var text: String
  var help: String
  var dimmed = false
}

extension CreateModel {
  /// Strength's hint: with an input image on the canvas and Strength below 1, how many of the
  /// steps the run goes through (`StrengthSteps`); otherwise that it runs all of them. Nothing
  /// where the count can't be worked out.
  var strengthHint: SettingHint? {
    guard let settings, let file = selectedModel,
          let sampler = DataModels.SamplerType(rawValue: settings.sampler.rawValue)
    else { return nil }
    // An H3 file's schedule is read from it once, in the background; the hint shows once it's in.
    let version = ModelZoo.versionForModel(file)
    if version == .minimaxH3 || version == .minimaxH3Image, StrengthSteps.knownFixedGrid(file) == nil {
      _ = fixedGridChecks
      if !fixedGridsChecking.contains(file) {
        fixedGridsChecking.insert(file)
        Task {
          _ = await StrengthSteps.checkFixedGrid(file)
          fixedGridChecks += 1
        }
      }
      return nil
    }
    let steps = Int(settings.steps)
    let tile = settings.tiledDiffusion ? (width: settings.diffusionTileWidth, height: settings.diffusionTileHeight) : nil
    guard let start = StrengthSteps.start(
      model: file, sampler: sampler, steps: steps, strength: settings.strength, shift: Double(settings.shift),
      resolutionDependentShift: settings.resolutionDependentShift, width: settings.width, height: settings.height,
      tile: tile)
    else { return nil }
    let editsInput = settings.strength < 1 && effectiveCanvasMode == .edit && image != nil && canvasClip == nil
    guard editsInput else {
      return SettingHint(
        text: "Runs all \(steps) steps",
        help: "With an input image on the canvas, Strength below 1 starts partway into the steps.", dimmed: true)
    }
    let takesShift = SettingsRegistry.byID["shift"]?.applies(traits) == true
    let hint = StrengthSteps.hint(start, strength: settings.strength, shift: takesShift ? Double(settings.shift) : nil)
    return SettingHint(text: hint.text, help: hint.help)
  }
}
