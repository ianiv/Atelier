@testable import Atelier
@preconcurrency import DataModels
@preconcurrency import Diffusion
import Foundation
import Testing

/// The ComfyUI samplers' per-step arithmetic (`ComfySamplerSteps`) against ComfyUI's own
/// `sample_dpmpp_2m_sde`, `sample_res_multistep`, `sample_heun` and `sample_er_sde`
/// (comfy/k_diffusion/sampling.py), run in float64 on a toy denoiser D(x, σ) = x / (1 + σ²) with the
/// same injected noise (noise call k returns [sin(k + 1), cos(2k + 1), 0.5 sin(3k + 2)]). The flow
/// model is CONST with shift 3, so the SDE samplers move its first sigma 1 to
/// `percent_to_sigma(1e-4)`; the VE one is EPS. Start 3 runs the tail of the sigmas, as ComfyUI does
/// for a denoise below 1, so each sampler's first-step and history handling is covered too.
@Suite(.tags(.smoke))
struct ComfySamplerTests {
  private static let veSigmas = [14.6146, 6.0, 2.5, 1.0, 0.4, 0.1, 0.0]
  private static let flowSigmas = [1.0, 0.9, 0.75, 0.55, 0.3, 0.12, 0.0]
  private static let x0 = [0.5, -1.2, 2.0]

  /// ComfyUI's outputs, keyed by "model start sampler".
  private static let expected: [String: [Double]] = [
    "ve 0 dpmpp_2m_sde": [0.127973857650, 0.188112667235, 0.022873420799],
    "ve 0 res_multistep": [0.037370814141, -0.089689953938, 0.149483256564],
    "ve 0 heun": [0.038375543022, -0.092101303253, 0.153502172088],
    "ve 0 er_sde": [0.653498959349, -0.033536135239, 0.182303652665],
    "ve 3 dpmpp_2m_sde": [0.789842646495, -0.404249192001, 1.198615648767],
    "ve 3 res_multistep": [0.346249100057, -0.830997840137, 1.384996400228],
    "ve 3 heun": [0.359907214571, -0.863777314970, 1.439628858284],
    "ve 3 er_sde": [0.456755715481, -0.720954454418, 1.323611523857],
    "flow 0 dpmpp_2m_sde": [-0.130627485833, 0.120111531249, 0.016770691462],
    "flow 0 res_multistep": [0.368367898006, -0.884082955214, 1.473471592024],
    "flow 0 heun": [0.352258769420, -0.845421046607, 1.409035077679],
    "flow 0 er_sde": [0.631173455994, 0.041003751551, 0.197061608452],
    "flow 3 dpmpp_2m_sde": [0.637643145663, -0.510884159898, 1.081562758822],
    "flow 3 res_multistep": [0.432614536076, -1.038274886582, 1.730458144303],
    "flow 3 heun": [0.435957426922, -1.046297824613, 1.743829707688],
    "flow 3 er_sde": [0.527742350891, -0.958112134355, 1.673294433062],
  ]

  /// `ModelSamplingDiscreteFlow.percent_to_sigma(1e-4)` at shift 3.
  private static let flowOffset = 3 * 0.9999 / (1 + 2 * 0.9999)

  private static func denoise(_ x: [Double], _ sigma: Double) -> [Double] {
    x.map { $0 / (1 + sigma * sigma) }
  }

  private static func noise(_ k: Int) -> [Double] {
    [sin(Double(k + 1)), cos(Double(2 * k + 1)), 0.5 * sin(Double(3 * k + 2))]
  }

  private static func combine(_ terms: [(Double, [Double])]) -> [Double] {
    (0..<3).map { index in terms.reduce(0) { $0 + $1.0 * $1.1[index] } }
  }

  /// Runs the sampler the way the engine's tensor code does: one denoise per step (two for Heun),
  /// the step's coefficients, and one noise draw per step that has a next sigma.
  private static func run(_ sampler: Denoiser.ComfySampler, sigmas: [Double], isFlow: Bool)
    -> [Double]
  {
    let steps = ComfySamplerSteps(
      sampler, sigmas: sigmas, isFlow: isFlow, firstSigmaOffset: flowOffset)
    var x = x0
    var history: [[Double]] = []
    var noiseCalls = 0
    for i in 0..<steps.count {
      let denoised = denoise(x, steps.sigmas[i])
      if sampler == .heun {
        let step = steps.heunStep(i)
        let x2 = combine([(step.predictor.x, x), (step.predictor.denoised, denoised)])
        if step.isEuler {
          x = x2
        } else {
          let denoised2 = denoise(x2, steps.sigmas[i + 1])
          x = combine([(step.x, x), (step.denoised, denoised), (step.x2, x2), (step.denoised2, denoised2)])
        }
        continue
      }
      let step = steps.step(i)
      let previous = history.last ?? denoised
      let older = history.count >= 2 ? history[history.count - 2] : denoised
      var terms = [(step.x, x), (step.denoised, denoised), (step.previousDenoised, previous), (step.olderDenoised, older)]
      // ComfyUI draws noise on every step with a next sigma (res_multistep at eta 0 draws none).
      if sampler != .resMultistep, steps.sigmas[i + 1] > 0 {
        terms.append((step.noise, noise(noiseCalls)))
        noiseCalls += 1
      }
      x = combine(terms)
      history.append(denoised)
    }
    return x
  }

  @Test(arguments: Denoiser.ComfySampler.allCases)
  func matchesComfyUI(_ sampler: Denoiser.ComfySampler) {
    for (model, sigmas, isFlow) in [("ve", Self.veSigmas, false), ("flow", Self.flowSigmas, true)] {
      for start in [0, 3] {
        let key = "\(model) \(start) \(sampler.rawValue)"
        guard let expected = Self.expected[key] else {
          Issue.record("no ComfyUI value for \(key)")
          continue
        }
        let actual = Self.run(sampler, sigmas: Array(sigmas[start...]), isFlow: isFlow)
        for (a, e) in zip(actual, expected) where abs(a - e) > 1e-5 * max(1, abs(e)) {
          Issue.record("\(key): \(actual) vs ComfyUI \(expected)")
          break
        }
      }
    }
  }

  /// Names from Draw Things, ComfyUI and A1111 / Forge parse to the right sampler; the DPM++ 2M
  /// SDE Heun variants are DPM++ 2M SDE, not Heun (DataModels `SamplerType(from:)`).
  @Test func namesParse() {
    let cases: [(String, DataModels.SamplerType)] = [
      ("DPM++ 2M SDE", .DPMPP2MSDE), ("dpmpp_2m_sde", .DPMPP2MSDE), ("dpmpp_2m_sde_heun", .DPMPP2MSDE),
      ("DPM++ 2M SDE Heun Karras", .DPMPP2MSDE), ("Heun", .heun), ("heun", .heun),
      ("Res Multistep", .resMultistep), ("res_multistep", .resMultistep), ("ER-SDE", .ERSDE),
      ("er_sde", .ERSDE), ("DPM++ SDE Karras", .dPMPPSDEKarras), ("DPM++ 2M Karras", .dPMPP2MKarras),
      ("Euler A Trailing", .eulerATrailing),
    ]
    for (name, sampler) in cases {
      #expect(DataModels.SamplerType(from: name) == sampler, "\(name)")
    }
  }

  @Test func firstSigmaOffsetOnlyForSDESamplersOnFlowAtOne() {
    let flow = [1.0, 0.5, 0.0]
    #expect(ComfySamplerSteps(.dpmpp2mSDE, sigmas: flow, isFlow: true, firstSigmaOffset: 0.9999).sigmas[0] == 0.9999)
    #expect(ComfySamplerSteps(.erSDE, sigmas: flow, isFlow: true, firstSigmaOffset: 0.9999).sigmas[0] == 0.9999)
    #expect(ComfySamplerSteps(.resMultistep, sigmas: flow, isFlow: true, firstSigmaOffset: 0.9999).sigmas[0] == 1)
    #expect(ComfySamplerSteps(.heun, sigmas: flow, isFlow: true, firstSigmaOffset: 0.9999).sigmas[0] == 1)
    // An img2img start below 1 and VE sigmas above 1 stay as they are.
    #expect(ComfySamplerSteps(.dpmpp2mSDE, sigmas: [0.6, 0.3, 0], isFlow: true, firstSigmaOffset: 0.9999).sigmas[0] == 0.6)
    #expect(ComfySamplerSteps(.dpmpp2mSDE, sigmas: [14.6, 1, 0], isFlow: false, firstSigmaOffset: 0.9999).sigmas[0] == 14.6)
  }

  @Test func finalStepReturnsTheDenoisedPrediction() {
    for sampler in [Denoiser.ComfySampler.dpmpp2mSDE, .resMultistep, .erSDE] {
      let steps = ComfySamplerSteps(sampler, sigmas: [0.8, 0.4, 0], isFlow: true, firstSigmaOffset: 1)
      let last = steps.step(1)
      #expect(abs(last.x) < 1e-12 && abs(last.denoised - 1) < 1e-12 && last.noise == 0, "\(sampler)")
    }
    let heun = ComfySamplerSteps(.heun, sigmas: [0.8, 0.4, 0], isFlow: true, firstSigmaOffset: 1).heunStep(1)
    #expect(heun.isEuler && abs(heun.predictor.x) < 1e-12 && abs(heun.predictor.denoised - 1) < 1e-12)
  }

  @Test func ownScheduleIsSimpleOnFlowAndKarrasOtherwise() {
    let flow = Denoiser.Parameterization.rf(.init())
    let sd = Denoiser.Parameterization.ddpm(
      .init(linearStart: 0.00085, linearEnd: 0.012, timesteps: 1000, linspace: .linearWrtSigma))
    let edm = Denoiser.Parameterization.edm(.init())
    #expect(Denoiser.Scheduler.samplerDefault.resolved(for: flow, sampler: .heun) == .simple)
    #expect(Denoiser.Scheduler.samplerDefault.resolved(for: sd, sampler: .erSDE) == .karras)
    #expect(Denoiser.Scheduler.samplerDefault.resolved(for: edm, sampler: .dpmpp2mSDE) == .karras)
    #expect(Denoiser.Scheduler.beta.resolved(for: flow, sampler: .resMultistep) == .beta)
    // EDM has no timestep table for beta, so the sampler's own takes its place.
    #expect(Denoiser.Scheduler.beta.resolved(for: edm, sampler: .resMultistep) == .karras)
    // Other samplers keep the scheduler they were given.
    #expect(Denoiser.Scheduler.samplerDefault.resolved(for: flow, sampler: nil) == .samplerDefault)
  }
}
