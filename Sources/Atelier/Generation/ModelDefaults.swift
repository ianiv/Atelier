import Foundation
import _MediaGenerationKit

/// App-side defaults for models the community config catalog doesn't cover yet.
///
/// MGK falls back to generic settings (20 steps, UniPC AYS, guidance 4.5) when the catalog has no
/// entry. Values here come from each model's catalog description.
enum ModelDefaults {
  struct Fallback {
    var prefix: String
    var steps: Int
    var guidanceScale: Float
    var shift: Float
    var resolutionDependentShift: Bool
    var sampler: SamplerType
  }

  static let fallbacks: [Fallback] = [
    Fallback(
      prefix: "moss_image_", steps: 50, guidanceScale: 3, shift: 5,
      resolutionDependentShift: false, sampler: .dDIMTrailing),
    // SeedVR2 is a one-step restoration model trained without CFG; guidance above 1 oversharpens.
    Fallback(
      prefix: "seedvr2_", steps: 1, guidanceScale: 1, shift: 1,
      resolutionDependentShift: false, sampler: .dDIMTrailing),
  ]

  /// Recommended configuration for `model`: MGK's template, with the fallback table applied when
  /// MGK had no catalog entry for it.
  static func recommended(
    for model: String, configuration: PipelineConfiguration
  ) -> PipelineConfiguration {
    var settings = configuration
    // Hires fix runs a second sampling pass; keep it off unless the user turns it on.
    settings.hiresFix = false
    guard isGenericTemplate(configuration),
      let fallback = fallbacks.first(where: { model.hasPrefix($0.prefix) })
    else {
      return settings
    }
    settings.steps = fallback.steps
    settings.guidanceScale = fallback.guidanceScale
    settings.shift = fallback.shift
    settings.resolutionDependentShift = fallback.resolutionDependentShift
    settings.sampler = fallback.sampler
    return settings
  }

  /// ConfigurationResolver is internal to MGK, so infer "not in the catalog" from MGK having
  /// returned the generic GenerationConfiguration.default values.
  private static func isGenericTemplate(_ configuration: MediaGenerationPipeline.Configuration)
    -> Bool
  {
    let generic = GenerationConfiguration.default
    return configuration.steps == Int(generic.steps)
      && configuration.sampler == generic.sampler
      && configuration.guidanceScale == generic.guidanceScale
  }
}
