@preconcurrency import DataModels
@preconcurrency import Diffusion
import Foundation
import ModelZoo

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
  /// aren't the user's to count: a model `ModelZoo` doesn't know (a server's), MiniMax H3's fixed
  /// sigma grids, Würstchen, and samplers on manual timesteps or sigmas.
  static func start(
    model: String, sampler: DataModels.SamplerType, steps: Int, strength: Float, shift: Double,
    resolutionDependentShift: Bool, width: Int, height: Int, tile: (width: Int, height: Int)? = nil
  ) -> Start? {
    guard steps > 0, ModelZoo.specificationForModel(model) != nil else { return nil }
    let version = ModelZoo.versionForModel(model)
    switch version {
    case .minimaxH3, .minimaxH3Image, .wurstchenStageB, .wurstchenStageC: return nil
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
