@testable import Atelier
@preconcurrency import DataModels
@preconcurrency import Diffusion
@preconcurrency import LocalImageGenerator
import Testing

/// Strength's start step, worked out as the engine's samplers work it out
/// (`DDIMSampler.timestep(for:sampling:)`), pinned so a change in the engine's schedules shows.
@Suite(.tags(.smoke))
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

  /// MiniMax H3 Image counts DDIM Trailing on its own grid, as `RFSigmaGridDiscretization`
  /// samples it: at Strength 0.5 and shift 1 the 6-step grid (1, .97, .89, .75, .53, .23, 0)
  /// reaches sigma 0.5 between steps 4 (.53) and 5 (.23). Other step counts stretch the grid.
  @Test func h3ImageCountsOnItsGrid() throws {
    let grid = [1.0, 0.9675, 0.8875, 0.75, 0.5328, 0.2320, 0.0]
    let grids: [Int: [Double]] = [1: [1, 0], 2: [1, 0.75, 0], 3: [1, 0.8875, 0.5328, 0], 6: grid]
    func start(_ steps: Int, _ sampler: DataModels.SamplerType = .dDIMTrailing) -> StrengthSteps.Start? {
      StrengthSteps.start(
        parameterization: Self.flow, objective: Self.flowObjective, version: .minimaxH3Image, sampler: sampler,
        sampling: Sampling(steps: steps, shift: 1), strength: 0.5, h3ImageGrids: grids)
    }
    let six = try #require(start(6))
    #expect(six.startStep > 4 && six.startStep < 5, "\(six.startStep)")
    let eight = try #require(start(8))
    #expect(eight.startStep > 5 && eight.startStep < 7, "\(eight.startStep)")
    // Karras ends at the grid's lowest nonzero sigma, so no step sits below it but the last.
    let karras = try #require(start(8, .dPMPP2MKarras))
    let plain = try #require(Self.start(0.5, steps: 8, shift: 1, sampler: .dPMPP2MKarras))
    #expect(karras.startStep > plain.startStep)
  }

  /// MiniMax H3 Image takes Shift as the engine does, on top of its grid: at Shift 3 the 6-step
  /// grid becomes (1, .99, .96, .90, .77, .47, 0), so Strength 0.5 starts about 92% of the way
  /// from step 4 to step 5, later than at Shift 1, a Simple scheduler counts the same, and the
  /// hint names the Shift.
  @Test func h3ImageTakesShift() throws {
    let grid = [1.0, 0.9675, 0.8875, 0.75, 0.5328, 0.2320, 0.0]
    let grids: [Int: [Double]] = [6: grid]
    func start(
      _ shift: Double, _ sampler: DataModels.SamplerType = .dDIMTrailing, _ scheduler: Denoiser.Scheduler = .samplerDefault
    ) -> StrengthSteps.Start? {
      StrengthSteps.start(
        parameterization: Self.flow, objective: Self.flowObjective, version: .minimaxH3Image, sampler: sampler,
        sampling: Sampling(steps: 6, shift: shift), strength: 0.5, h3ImageGrids: grids, scheduler: scheduler)
    }
    let shift3 = try #require(start(3))
    #expect(abs(shift3.startStep - 4.92) < 0.01, "\(shift3.startStep)")
    #expect(shift3.startStep > (try #require(start(1))).startStep)
    let simple = try #require(start(3, .eulerA, .simple))
    #expect(abs(simple.startStep - shift3.startStep) < 0.01, "\(simple.startStep) vs \(shift3.startStep)")
    #expect(StrengthSteps.hint(shift3, strength: 0.5, shift: 3).text == "≈1.1 of 6 steps at Shift 3")
  }

  /// Flow models on Karras sigmas count from the sigma each step is told
  /// (`KarrasDiscretization.timestep(for:)` = sigma × 1000): Strength 1 starts at the top, and
  /// lower Strength starts later.
  @Test func flowKarras() throws {
    #expect(try #require(Self.start(1, steps: 8, shift: 3, sampler: .dPMPP2MKarras)).startStep == 0)
    let half = try #require(Self.start(0.5, steps: 8, shift: 3, sampler: .dPMPP2MKarras))
    let less = try #require(Self.start(0.3, steps: 8, shift: 3, sampler: .dPMPP2MKarras))
    #expect(half.startStep > 0 && half.startStep < 8 && less.startStep > half.startStep)
  }

  /// A scheduler other than the sampler's own counts on its schedule: at Shift 1 the Simple
  /// schedule on a flow model is the trailing one (sigma = t), so Strength 0.5 starts at step 4 of
  /// 8 whatever the sampler, Karras included; Beta spends more steps near the ends.
  @Test func aSchedulerCountsOnItsSchedule() throws {
    func start(_ sampler: DataModels.SamplerType, _ scheduler: Denoiser.Scheduler) -> StrengthSteps.Start? {
      StrengthSteps.start(
        parameterization: Self.flow, objective: Self.flowObjective, version: .flux1, sampler: sampler,
        sampling: Sampling(steps: 8, shift: 1), strength: 0.5, scheduler: scheduler)
    }
    for sampler in [DataModels.SamplerType.dPMPP2MKarras, .eulerA, .LCM, .uniPCAYS] {
      let simple = try #require(start(sampler, .simple))
      #expect(abs(simple.startStep - 4) < 1e-3, "\(sampler): \(simple.startStep)")
    }
    let karras = try #require(start(.eulerATrailing, .karras))
    let plainKarras = try #require(Self.start(0.5, steps: 8, shift: 1, sampler: .dPMPP2MKarras))
    #expect(karras.startStep != plainKarras.startStep)
    // PLMS starts at a whole step whatever the schedule, as `PLMSSampler.timestep(for:)` does.
    #expect(try #require(start(.PLMS, .beta)).startStep == 4)
    // Substep samplers keep their own timesteps.
    #expect(start(.eulerASubstep, .simple) == nil)
  }

  /// MiniMax H3 Image's LCM steps on its grid as DDIM Trailing does, and a scheduler on it follows
  /// the grid too (`MiniMaxH3ImageModelSampling`).
  @Test func h3ImageLCMAndSchedulersCountOnTheGrid() throws {
    let grid = [1.0, 0.9675, 0.8875, 0.75, 0.5328, 0.2320, 0.0]
    let grids: [Int: [Double]] = [6: grid]
    func start(_ sampler: DataModels.SamplerType, _ scheduler: Denoiser.Scheduler = .samplerDefault) -> StrengthSteps.Start? {
      StrengthSteps.start(
        parameterization: Self.flow, objective: Self.flowObjective, version: .minimaxH3Image, sampler: sampler,
        sampling: Sampling(steps: 6, shift: 1), strength: 0.5, h3ImageGrids: grids, scheduler: scheduler)
    }
    let ddim = try #require(start(.dDIMTrailing))
    #expect(try #require(start(.LCM)) == ddim)
    let simple = try #require(start(.eulerA, .simple))
    #expect(abs(simple.startStep - ddim.startStep) < 0.01, "\(simple.startStep) vs \(ddim.startStep)")
  }

  /// The ComfyUI samplers count on a scheduler's schedule, their own being Simple on flow models
  /// (`Scheduler.resolved(for:sampler:)`), with a fractional start between steps, as their sampler
  /// interpolates it; on MiniMax H3 video they count as their fallback does.
  @Test func comfySamplersCountOnTheirScheduler() throws {
    func start(
      _ sampler: DataModels.SamplerType, _ scheduler: Denoiser.Scheduler = .samplerDefault,
      version: ModelVersion = .flux1, strength: Float = 0.5
    ) -> StrengthSteps.Start? {
      StrengthSteps.start(
        parameterization: Self.flow, objective: Self.flowObjective, version: version, sampler: sampler,
        sampling: Sampling(steps: 8, shift: 3), strength: strength, scheduler: scheduler)
    }
    for sampler in [DataModels.SamplerType.DPMPP2MSDE, .resMultistep, .heun, .ERSDE] {
      let own = try #require(start(sampler))
      #expect(own == start(.eulerA, .simple), "\(sampler)")
      #expect(try #require(start(sampler, .beta)) == start(.eulerA, .beta), "\(sampler)")
      let fractional = try #require(start(sampler, strength: 0.55))
      #expect(fractional.startStep != fractional.startStep.rounded(), "\(sampler): \(fractional.startStep)")
      #expect(start(sampler, version: .minimaxH3) == start(sampler.comfyFallback, version: .minimaxH3))
    }
  }

  @Test func unknownModelsAreNotCounted() {
    #expect(
      StrengthSteps.start(
        model: "not-a-model.ckpt", sampler: .eulerATrailing, steps: 8, strength: 0.5, shift: 5,
        resolutionDependentShift: false, width: 1024, height: 1024) == nil)
  }
}
