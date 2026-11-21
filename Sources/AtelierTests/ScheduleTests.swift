@testable import Atelier
@preconcurrency import Diffusion
import Testing

/// The engine's schedulers (`Denoiser.ScheduledDiscretization`) against ComfyUI's: the sigmas
/// below come from comfy/samplers.py's scheduler functions on comfy/model_sampling.py's samplings
/// (`ModelSamplingDiscreteFlow` at shift 3, `ModelSamplingDiscrete` for Stable Diffusion 1.5's
/// betas, and `MiniMaxH3ImageModelSampling` on MiniMax H3 Image's grid), in float64. For H3 Image
/// the engine keeps every step at or above the grid's last nonzero sigma (0.232): Karras and
/// exponential end there, and the others' nonzero sigmas are remapped linearly onto
/// [0.232, top] when they'd go lower (`ScheduledDiscretization.floored`), so the H3 tables are
/// ComfyUI's with that floor.
@Suite(.tags(.smoke))
struct ScheduleTests {
  private static let flow = Denoiser.Parameterization.rf(.init())
  private static let flowObjective = Denoiser.Objective.u(conditionScale: 1000)
  private static let sd15 = Denoiser.Parameterization.ddpm(
    .init(linearStart: 0.00085, linearEnd: 0.012, timesteps: 1000, linspace: .linearWrtSigma))
  private static let grid = [
    1.0, 0.9675236940383911, 0.8875485062599182, 0.75, 0.5327739119529724, 0.23200887441635132, 0.0,
  ]

  private static let flowShift3At8: [Denoiser.Scheduler: [Double]] = [
    .simple: [1.0000000000, 0.9545454545, 0.9000000000, 0.8333333333, 0.7500000000, 0.6428571429, 0.5000000000, 0.3000000000, 0.0000000000],
    .sgmUniform: [1.0000000000, 0.9546938776, 0.9003590664, 0.8339980060, 0.7511210762, 0.6446862996, 0.5029850746, 0.3050089445, 0.0000000000],
    .normal: [1.0000000000, 0.9475425331, 0.8827877508, 0.8008373206, 0.6937931034, 0.5480456026, 0.3379721670, 0.0089285714, 0.0000000000],
    .karras: [1.0000000000, 0.5554125367, 0.2922762271, 0.1441427126, 0.0656554292, 0.0270687672, 0.0098130223, 0.0029940120, 0.0000000000],
    .exponential: [1.0000000000, 0.4359782165, 0.1900770053, 0.0828694338, 0.0361292679, 0.0157515738, 0.0068673431, 0.0029940120, 0.0000000000],
    .linearQuadratic: [1.0000000000, 0.9937500000, 0.9875000000, 0.9812500000, 0.9750000000, 0.9093750000, 0.7250000000, 0.4218750000, 0.0000000000],
    .beta: [1.0000000000, 0.9802494802, 0.9335347432, 0.8595217763, 0.7507492507, 0.5963855422, 0.3921713442, 0.1559139785, 0.0000000000],
  ]
  private static let sd15At8: [Denoiser.Scheduler: [Double]] = [
    .simple: [14.6146412293, 7.2973520304, 4.0817293637, 2.4925305845, 1.6128861943, 1.0689513811, 0.6932048996, 0.3977456272, 0.0000000000],
    .sgmUniform: [14.6146412293, 7.3019823185, 4.0860810712, 2.4959668356, 1.6155802602, 1.0711591548, 0.6951495191, 0.3997014336, 0.0000000000],
    .normal: [14.6146412293, 6.6779995870, 3.5220566255, 2.0606413507, 1.2768323025, 0.7912598364, 0.4396657597, 0.0291671582, 0.0000000000],
    .karras: [14.6146412293, 7.9029350443, 4.0277375131, 1.9103565118, 0.8288677369, 0.3211195202, 0.1071983933, 0.0291671582, 0.0000000000],
    .exponential: [14.6146412293, 6.0129696198, 2.4739439772, 1.0178662440, 0.4187854294, 0.1723028314, 0.0708913530, 0.0291671582, 0.0000000000],
    .linearQuadratic: [14.6146412293, 14.5232997217, 14.4319582140, 14.3406167063, 14.2492751986, 13.2901893679, 10.5956148913, 6.1655517686, 0.0000000000],
    .beta: [14.6146412293, 10.4834726803, 5.6865914543, 2.9636127305, 1.6182788260, 0.9198332946, 0.5153906127, 0.2432697536, 0.0000000000],
  ]
  private static let h3ImageAt6: [Denoiser.Scheduler: [Double]] = [
    .simple: [1.0000000000, 0.9676535993, 0.8877084566, 0.7500000000, 0.5336428163, 0.2326104045, 0.0000000000],
    .sgmUniform: [1.0000000000, 0.9675689028, 0.8877711657, 0.7505744245, 0.5339834731, 0.2341022792, 0.0000000000],
    .normal: [1.0000000000, 0.9628049616, 0.8714877276, 0.7081761330, 0.4568775452, 0.2320088744, 0.0000000000],
    .karras: [1.0000000000, 0.7642847484, 0.5778930567, 0.4319055799, 0.3187429775, 0.2320088744, 0.0000000000],
    .exponential: [1.0000000000, 0.7466222350, 0.5574447618, 0.4162006540, 0.3107446625, 0.2320088744, 0.0000000000],
    .linearQuadratic: [1.0000000000, 0.9916666667, 0.9833333333, 0.9750000000, 0.8611111111, 0.5361111111, 0.0000000000],
    .beta: [1.0000000000, 0.9843817166, 0.9256080359, 0.7805285705, 0.4973406876, 0.2320088744, 0.0000000000],
  ]
  private static let h3ImageAt8: [Denoiser.Scheduler: [Double]] = [
    .simple: [1.0000000000, 0.9773531637, 0.9326245999, 0.8634725593, 0.7675552924, 0.6160761288, 0.4257605918, 0.2320088744, 0.0000000000],
    .sgmUniform: [1.0000000000, 0.9773381694, 0.9326415957, 0.8635931113, 0.7676123385, 0.6163428990, 0.4263347442, 0.2320088744, 0.0000000000],
    .normal: [1.0000000000, 0.9786098686, 0.9312001398, 0.8533687912, 0.7367908071, 0.5757347269, 0.3848187508, 0.2320088744, 0.0000000000],
    .karras: [1.0000000000, 0.8261726683, 0.6789156915, 0.5547545061, 0.4505879801, 0.3636574657, 0.2915176099, 0.2320088744, 0.0000000000],
    .exponential: [1.0000000000, 0.8116294548, 0.6587423718, 0.5346547121, 0.4339415125, 0.3521997132, 0.2858556612, 0.2320088744, 0.0000000000],
    .linearQuadratic: [1.0000000000, 0.9937500000, 0.9875000000, 0.9812500000, 0.9750000000, 0.9093750000, 0.7250000000, 0.4218750000, 0.0000000000],
    .beta: [1.0000000000, 0.9907208085, 0.9691262322, 0.9077902453, 0.7918284540, 0.6046332633, 0.3739652159, 0.2320088744, 0.0000000000],
  ]

  private static func sigmas(
    _ scheduler: Denoiser.Scheduler, _ parameterization: Denoiser.Parameterization,
    objective: Denoiser.Objective = flowObjective, steps: Int, shift: Double, grid: [Double] = []
  ) -> [Double]? {
    Denoiser.ScheduledDiscretization(
      parameterization, objective: objective, scheduler: scheduler, sigmaGrid: grid
    ).sigmas(steps: steps, shift: shift)
  }

  private static func expectClose(_ actual: [Double]?, _ expected: [Double], _ label: String) {
    guard let actual, actual.count == expected.count else {
      Issue.record("\(label): \(String(describing: actual)) has the wrong length")
      return
    }
    for (a, e) in zip(actual, expected) where abs(a - e) > 1e-7 * max(1, abs(e)) {
      Issue.record("\(label): \(actual) vs ComfyUI \(expected)")
      return
    }
  }

  @Test func flowShift3MatchesComfyUI() {
    for (scheduler, expected) in Self.flowShift3At8 {
      Self.expectClose(Self.sigmas(scheduler, Self.flow, steps: 8, shift: 3), expected, "\(scheduler)")
    }
  }

  @Test func stableDiffusion15MatchesComfyUI() {
    for (scheduler, expected) in Self.sd15At8 {
      Self.expectClose(
        Self.sigmas(scheduler, Self.sd15, objective: .epsilon, steps: 8, shift: 1), expected, "\(scheduler)")
    }
  }

  /// ComfyUI's `MiniMaxH3ImageModelSampling` ignores the shift, and so does the engine.
  @Test func h3ImageMatchesComfyUIWhateverTheShift() {
    for shift in [1.0, 3.0] {
      for (scheduler, expected) in Self.h3ImageAt6 {
        Self.expectClose(
          Self.sigmas(scheduler, Self.flow, steps: 6, shift: shift, grid: Self.grid), expected, "\(scheduler) @6 shift \(shift)")
      }
      for (scheduler, expected) in Self.h3ImageAt8 {
        Self.expectClose(
          Self.sigmas(scheduler, Self.flow, steps: 8, shift: shift, grid: Self.grid), expected, "\(scheduler) @8 shift \(shift)")
      }
    }
  }

  /// At the grid's own step count, Simple lands on the trained grid (within ComfyUI's table
  /// rounding), which is what the output heads were distilled for.
  @Test func h3ImageSimpleAt6FollowsTheGrid() throws {
    let sigmas = try #require(Self.sigmas(.simple, Self.flow, steps: 6, shift: 1, grid: Self.grid))
    for (sigma, point) in zip(sigmas, Self.grid) {
      #expect(abs(sigma - point) < 1e-3, "\(sigmas) vs \(Self.grid)")
    }
  }

  /// No H3 Image step sits below the grid's last nonzero sigma, at any step count, and no two
  /// steps repeat.
  @Test func h3ImageNeverGoesBelowTheGridFloor() throws {
    for scheduler in Denoiser.Scheduler.allCases where scheduler != .samplerDefault {
      for steps in [1, 4, 6, 8, 20, 50] {
        let sigmas = try #require(Self.sigmas(scheduler, Self.flow, steps: steps, shift: 1, grid: Self.grid))
        let nonzero = sigmas.dropLast()
        #expect(nonzero.allSatisfy { $0 >= Self.grid[5] - 1e-12 }, "\(scheduler) @\(steps): \(sigmas)")
        #expect(zip(nonzero, nonzero.dropFirst()).allSatisfy { $0 > $1 } || steps == 1, "\(scheduler) @\(steps): \(sigmas)")
      }
    }
  }

  /// Every schedule ends at alphaCumprod 1 (sigma 0), with one entry per step plus the end.
  @Test func schedulesEndClean() {
    for scheduler in Denoiser.Scheduler.allCases where scheduler != .samplerDefault {
      for steps in [1, 2, 5, 30] {
        let alphas = Denoiser.ScheduledDiscretization(
          Self.flow, objective: Self.flowObjective, scheduler: scheduler
        ).alphasCumprod(steps: steps, shift: 3)
        #expect(alphas.count == steps + 1 && alphas.last == 1, "\(scheduler) at \(steps)")
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $0 <= $1 }, "\(scheduler) at \(steps): \(alphas)")
      }
    }
  }

  /// EDM only takes the sigma-space schedulers; the rest keep the sampler's own schedule.
  @Test func edmFallsBackForTimestepSchedulers() {
    let edm = Denoiser.Parameterization.edm(.init())
    #expect(Self.sigmas(.simple, edm, objective: .edm(sigmaData: 0.5), steps: 8, shift: 1) == nil)
    #expect(Self.sigmas(.beta, edm, objective: .edm(sigmaData: 0.5), steps: 8, shift: 1) == nil)
    let karras = Self.sigmas(.karras, edm, objective: .edm(sigmaData: 0.5), steps: 8, shift: 1)
    #expect(karras?.first == 80 && karras?.last == 0)
  }

  /// scipy.stats.beta.ppf(q, 0.6, 0.6), which `beta` spaces its steps by.
  @Test func betaQuantileMatchesSciPy() {
    let q = Denoiser.ScheduledDiscretization.betaQuantile
    #expect(q(0.5, 0.6, 0.6) == 0.5 || abs(q(0.5, 0.6, 0.6) - 0.5) < 1e-12)
    #expect(abs(q(0.875, 0.6, 0.6) - 0.9428436364) < 1e-8)
    #expect(q(1, 0.6, 0.6) == 1 && q(0, 0.6, 0.6) == 0)
  }
}
