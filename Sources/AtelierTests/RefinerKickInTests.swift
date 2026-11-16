@testable import Atelier
@preconcurrency import Diffusion
import Testing

/// LongCat-Video Avatar 1.6 runs its DMD half for steps 0-3 and its OPSD half, as the refiner,
/// for steps 4-7. The engine swaps at the first step whose timestep is below
/// `(1 - refinerStart) * 1000` (`DDIMSampler.sample`'s `refinerKickIn`), on the schedule
/// `Denoiser.LinearDiscretization` gives DDIM Trailing; these pin that schedule and the default.
struct RefinerKickInTests {
  /// The step at which the engine hands over, from the engine's own trailing schedule.
  private static func engineKickInStep(refinerStart: Float, steps: Int, shift: Double) -> Int {
    let discretization = Denoiser.LinearDiscretization(
      .rf(.init()), objective: .u(conditionScale: 1000), timestepSpacing: .trailing)
    let alphasCumprod = discretization.alphasCumprod(steps: steps, shift: shift)
    let kickIn = (1 - refinerStart) * discretization.timesteps
    return (0..<steps).first { discretization.timestep(for: alphasCumprod[$0]) < kickIn } ?? steps
  }

  private static var longCat16Fallback: ModelDefaults.Fallback? {
    // As `ModelDefaults.recommended` picks one: by family when it names one, else by prefix.
    ModelDefaults.fallbacks.first { $0.version == nil && ModelDefaults.longCat16DMD.hasPrefix($0.prefix) }
  }

  /// Shift 7's trailing timesteps at 8 steps are 1000, 979.6, 954.5, 921.1, 875, 807.7, 700 and
  /// 500: a refiner start of 0.10 (threshold 900) lands between steps 3 and 4.
  @Test func longCat16DefaultSwapsAtStepFour() throws {
    let fallback = try #require(Self.longCat16Fallback)
    let refiner = try #require(fallback.refiner)
    #expect(refiner.model == ModelDefaults.longCat16OPSD)
    #expect(fallback.steps == 8 && fallback.shift == 7 && fallback.sampler == .dDIMTrailing)
    #expect(Self.engineKickInStep(refinerStart: refiner.start, steps: 8, shift: 7) == 4)
    #expect(ModelDefaults.refinerKickInStep(refinerStart: Double(refiner.start), steps: 8, shift: 7) == 4)
  }

  /// The window that still swaps at step 4 is 0.079-0.125; 0.10 sits inside it with room. A
  /// lower start raises the threshold and swaps earlier.
  @Test func stepFourWindow() {
    #expect(Self.engineKickInStep(refinerStart: 0.07, steps: 8, shift: 7) == 3)
    #expect(Self.engineKickInStep(refinerStart: 0.08, steps: 8, shift: 7) == 4)
    #expect(Self.engineKickInStep(refinerStart: 0.12, steps: 8, shift: 7) == 4)
    #expect(Self.engineKickInStep(refinerStart: 0.13, steps: 8, shift: 7) == 5)
    let midpoint = ModelDefaults.refinerStart(kickInStep: 4, steps: 8, shift: 7)
    #expect(abs(midpoint - 0.10) < 0.005)
  }

  /// `ModelDefaults`' closed form agrees with the engine's schedule across step counts and shifts.
  @Test func closedFormMatchesEngine() {
    for steps in [4, 8, 12] {
      for shift in [1.0, 3, 7, 12] {
        // Off the step boundaries, where Float and Double rounding could disagree.
        for start in (0..<20).map({ Float(0.03) + Float($0) * 0.05 }) {
          #expect(
            ModelDefaults.refinerKickInStep(refinerStart: Double(start), steps: steps, shift: shift)
              == Self.engineKickInStep(refinerStart: start, steps: steps, shift: shift),
            "steps \(steps), shift \(shift), start \(start)")
        }
      }
    }
  }
}

/// A paired refiner (LongCat-Video Avatar 1.6's OPSD half) goes with its model when the model
/// changes; a refiner the person picked stays (`ModelDefaults.refinerAfterModelSwitch`).
struct RefinerModelSwitchTests {
  private static let opsd = ModelDefaults.longCat16OPSD
  private static let paired = ModelDefaults.pairedRefiners

  @Test func switchingTo16BringsItsRefiner() {
    for current in [(String?.none, Float(0.7)), ("sdxl_refiner_v1.0_f16.ckpt", 0.8)] {
      let kept = ModelDefaults.refinerAfterModelSwitch(current: current, recommended: (Self.opsd, 0.10))
      #expect(kept.model == Self.opsd && kept.start == 0.10)
    }
  }

  @Test func switchingFrom16To15DropsTheOPSDRefiner() {
    #expect(Self.paired.contains(Self.opsd))
    let kept = ModelDefaults.refinerAfterModelSwitch(current: (Self.opsd, 0.10), recommended: (nil, 0.7))
    #expect(kept.model == nil && kept.start == 0.7)
  }

  @Test func anUnrelatedModelKeepsThePersonsRefiner() {
    let chosen = ("sd_xl_refiner_1.0_f16.ckpt", Float(0.8))
    let kept = ModelDefaults.refinerAfterModelSwitch(current: chosen, recommended: (nil, 0.7))
    #expect(kept.model == chosen.0 && kept.start == chosen.1)
    let none = ModelDefaults.refinerAfterModelSwitch(current: (nil, 0.5), recommended: (nil, 0.7))
    #expect(none.model == nil && none.start == 0.5)
  }

  @Test func aMissingPairedRefinerStopsTheRun() {
    let dmd = ModelDefaults.longCat16DMD
    let missing = ModelDefaults.missingRefinerMessage(
      model: dmd, refiner: Self.opsd, defaultRefiner: Self.opsd, isDownloaded: { _ in false })
    #expect(missing?.contains("isn't downloaded") == true)
    #expect(ModelDefaults.missingRefinerMessage(
      model: dmd, refiner: Self.opsd, defaultRefiner: Self.opsd, isDownloaded: { _ in true }) == nil)
    #expect(ModelDefaults.missingRefinerMessage(
      model: dmd, refiner: nil, defaultRefiner: Self.opsd, isDownloaded: { _ in false }) == nil)
    // A refiner the person picked is left to the engine, as before.
    #expect(ModelDefaults.missingRefinerMessage(
      model: dmd, refiner: "other.ckpt", defaultRefiner: Self.opsd, isDownloaded: { _ in false }) == nil)
  }

  @Test func theOPSDFileIsHiddenAndHashed() {
    #expect(ModelDefaults.hiddenFromModelPicker.contains(Self.opsd))
    #expect(!ModelDefaults.hiddenFromModelPicker.contains(ModelDefaults.longCat16DMD))
    for file in [ModelDefaults.longCat16DMD, Self.opsd] {
      #expect(ModelDefaults.downloadSources[file]?.sha256.count == 64)
    }
  }
}
