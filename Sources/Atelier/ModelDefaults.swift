import Foundation
import _MediaGenerationKit

/// The settings the inspector exposes, seeded per model.
struct GenerationSettings: Equatable {
  var width: Int
  var height: Int
  var steps: Int
  var guidanceScale: Float
  var shift: Float
  var sampler: SamplerType
  var resolutionDependentShift: Bool
  var hiresFix: Bool

  init(
    width: Int, height: Int, steps: Int, guidanceScale: Float, shift: Float,
    sampler: SamplerType, resolutionDependentShift: Bool, hiresFix: Bool
  ) {
    self.width = width
    self.height = height
    self.steps = steps
    self.guidanceScale = guidanceScale
    self.shift = shift
    self.sampler = sampler
    self.resolutionDependentShift = resolutionDependentShift
    self.hiresFix = hiresFix
  }

  init(configuration: MediaGenerationPipeline.Configuration) {
    width = configuration.width
    height = configuration.height
    steps = configuration.steps
    guidanceScale = configuration.guidanceScale
    shift = configuration.shift
    sampler = configuration.sampler
    resolutionDependentShift = configuration.resolutionDependentShift
    hiresFix = configuration.hiresFix
  }

  func apply(to configuration: inout MediaGenerationPipeline.Configuration) {
    configuration.width = width
    configuration.height = height
    configuration.steps = steps
    configuration.guidanceScale = guidanceScale
    configuration.shift = shift
    configuration.sampler = sampler
    configuration.resolutionDependentShift = resolutionDependentShift
    configuration.hiresFix = hiresFix
  }
}

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
      resolutionDependentShift: false, sampler: .dDIMTrailing)
  ]

  /// Recommended settings for `model`: MGK's template, with the fallback table applied when MGK
  /// had no catalog entry for it.
  static func recommended(
    for model: String, configuration: MediaGenerationPipeline.Configuration
  ) -> GenerationSettings {
    var settings = GenerationSettings(configuration: configuration)
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
