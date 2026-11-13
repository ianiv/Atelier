@testable import Atelier
@preconcurrency import DataModels
@preconcurrency import Diffusion
import Testing

/// Strength's start step, worked out as the engine's samplers work it out
/// (`DDIMSampler.timestep(for:sampling:)`), pinned so a change in the engine's schedules shows.
struct StrengthStepsTests {
  private static let flow = Denoiser.Parameterization.rf(.init())
  private static let flowObjective = Denoiser.Objective.u(conditionScale: 1000)

  private static func start(
    _ strength: Float, steps: Int = 8, shift: Double, sampler: DataModels.SamplerType = .eulerATrailing,
    parameterization: Denoiser.Parameterization = flow, objective: Denoiser.Objective = flowObjective,
    version: ModelVersion = .flux1
  ) -> StrengthSteps.Start? {
    StrengthSteps.start(
      parameterization: parameterization, objective: objective, version: version, sampler: sampler,
      sampling: Sampling(steps: steps, shift: shift), strength: strength)
  }

  /// At Shift 5 most of 8 steps sit at high noise: low Strength runs very little. The trailing
  /// schedule's sigmas are 5t / (1 + 4t) at t = 1, 7/8, … 0, so Strength 0.3 lands 28% of the
  /// way from step 7 (sigma 0.417) to step 8 (0).
  @Test func aHighShiftStartsLate() throws {
    for (strength, expected) in [(Float(0.3), Float(7.28)), (0.5, 6.6), (0.7, 5.4)] {
      let start = try #require(Self.start(strength, shift: 5))
      #expect(abs(start.startStep - expected) < 0.02, "strength \(strength): \(start.startStep)")
    }
    let half = try #require(Self.start(0.5, shift: 5))
    #expect(half.modelPasses == 2)
    #expect(StrengthSteps.hint(half, strength: 0.5, shift: 5).text == "≈1.4 of 8 steps at Shift 5")
    #expect(
      StrengthSteps.hint(half, strength: 0.5, shift: 5).help
        == "Strength 0.5 starts denoising at step 6.6 of 8, so it runs 2 model passes. With a high Shift, low Strength changes very little.")
  }

  /// At Shift 1 the trailing schedule is even: Strength is the share of the steps that runs.
  @Test func shiftOneIsLinear() throws {
    let start = try #require(Self.start(0.5, shift: 1))
    #expect(abs(start.startStep - 4) < 0.05)
    #expect(StrengthSteps.hint(start, strength: 0.5, shift: nil).text == "≈4 of 8 steps")
    #expect(try #require(Self.start(1, shift: 5)).startStep == 0)
  }

  /// SD-style models on Karras sigmas, and PLMS's whole steps.
  @Test func karrasAndPLMS() throws {
    let ddpm = Denoiser.Parameterization.ddpm(.init(linearStart: 0.00085, linearEnd: 0.012, timesteps: 1_000, linspace: .linearWrtSigma))
    let karras = try #require(
      Self.start(0.5, steps: 20, shift: 1, sampler: .dPMPP2MKarras, parameterization: ddpm, objective: .epsilon, version: .sdxlBase))
    #expect(karras.startStep > 5 && karras.startStep < 15)
    let more = try #require(
      Self.start(0.75, steps: 20, shift: 1, sampler: .dPMPP2MKarras, parameterization: ddpm, objective: .epsilon, version: .sdxlBase))
    #expect(more.startStep < karras.startStep)
    let plms = try #require(Self.start(0.3, steps: 20, shift: 1, sampler: .PLMS, parameterization: ddpm, objective: .epsilon, version: .v1))
    #expect(plms.startStep == 14)
    // Align Your Steps' own timesteps for SD 1.x, and manual substeps: not counted.
    #expect(Self.start(0.5, steps: 20, shift: 1, sampler: .DPMPP2MAYS, parameterization: ddpm, objective: .epsilon, version: .v1) == nil)
    #expect(Self.start(0.5, shift: 1, sampler: .eulerASubstep) == nil)
  }

  @Test func unknownModelsAreNotCounted() {
    #expect(
      StrengthSteps.start(
        model: "not-a-model.ckpt", sampler: .eulerATrailing, steps: 8, strength: 0.5, shift: 5,
        resolutionDependentShift: false, width: 1024, height: 1024) == nil)
  }
}
