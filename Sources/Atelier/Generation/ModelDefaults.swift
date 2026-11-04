import _MediaGenerationKit
import Diffusion
import Foundation
import ModelZoo

/// App-side defaults for models the community config catalog doesn't cover yet.
///
/// MGK falls back to generic settings (20 steps, UniPC AYS, guidance 4.5) when the catalog has no
/// entry. Values here come from each model's catalog description. A fallback that
/// `replacesCatalog` applies even when MGK found an entry, for models whose catalog entry only
/// matches some of their files.
enum ModelDefaults {
  struct Fallback {
    var prefix: String
    var steps: Int
    var guidanceScale: Float
    var shift: Float
    var resolutionDependentShift: Bool
    var sampler: SamplerType
    var size: (width: Int, height: Int)?
    var fps: Int?
    var numFrames: Int?
    var shiftForAudio: Float?
    var replacesCatalog = false
  }

  /// Models the engine runs and static.libnnc.org hosts, but that no catalog lists: neither
  /// ModelZoo's built-in list nor models.drawthings.ai has them, and draw-things-cli can't resolve
  /// them without an entry of its own either. Added to `ModelZoo.availableSpecifications` by
  /// `ModelLibrary.loadCustomSpecifications(in:)`, unless a catalog or custom.json has the file.
  static let uncatalogedSpecifications: [ModelZoo.Specification] = [
    longCatSpecification(name: "LongCat-Video Avatar 1.5 DMD (8-bit S)", file: "longcat_video_avatar_1.5_dmd_i8x.ckpt"),
    longCatSpecification(name: "LongCat-Video Avatar 1.5 DMD", file: "longcat_video_avatar_1.5_dmd_q8p.ckpt"),
  ]

  /// The dependencies the engine's run-longcat-avatar-video skill lists. Its third, Whisper, has no
  /// field here: see `ModelLibrary.downloadAudioEncoder(for:progress:)`. `.kontext` is what makes
  /// the portrait count: `LocalImageGenerator.encodeImageCond` only reaches LongCat's reference
  /// frame under that modifier, and without it the avatar is a stranger who lip-syncs the voice.
  private static func longCatSpecification(name: String, file: String) -> ModelZoo.Specification {
    ModelZoo.Specification(
      name: name, file: file, prefix: "", version: .longcatVideoAvatar1_5, defaultScale: 12,
      textEncoder: "umt5_xxl_encoder_q8p.ckpt", autoencoder: "wan_v2.1_video_vae_f16.ckpt",
      modifier: .kontext,
      note:
      "[LongCat-Video Avatar](https://huggingface.co/meituan-longcat/LongCat-Video-Avatar-1.5) animates a portrait to lip-sync to an audio file. Put the image on the canvas and add a voice; the clip keeps that voice. This distilled version runs at 8 steps with guidance 1 and takes 4k + 1 frames at 25 fps.",
      huggingFaceLink: "meituan-longcat/LongCat-Video-Avatar-1.5")
  }

  static let fallbacks: [Fallback] = [
    Fallback(
      prefix: "moss_image_", steps: 50, guidanceScale: 3, shift: 5,
      resolutionDependentShift: false, sampler: .dDIMTrailing),
    // SeedVR2 is a one-step restoration model trained without CFG; guidance above 1 oversharpens.
    Fallback(
      prefix: "seedvr2_", steps: 1, guidanceScale: 1, shift: 1,
      resolutionDependentShift: false, sampler: .dDIMTrailing),
    // FastH3 Omni, an 8-step MiniMax H3 Ref2VA. The catalog only has its 8-bit S file at 832×512,
    // and offline or for the 4-bit file MGK falls back to the 50-step H3 entry.
    Fallback(
      prefix: "fasth3_omni_", steps: 8, guidanceScale: 1, shift: 12,
      resolutionDependentShift: false, sampler: .dDIMTrailing, size: (1280, 768), fps: 24,
      numFrames: 124, shiftForAudio: 3, replacesCatalog: true),
    // The values the engine's run-longcat-avatar-video skill uses for the step-distilled DMD files.
    Fallback(
      prefix: "longcat_video_avatar_", steps: 8, guidanceScale: 1, shift: 7,
      resolutionDependentShift: false, sampler: .dDIMTrailing, size: (832, 512), fps: 25,
      numFrames: 93),
  ]

  /// Recommended configuration for `model`: MGK's template, with the fallback table applied when
  /// MGK had no catalog entry for it.
  static func recommended(
    for model: String, configuration: PipelineConfiguration
  ) -> PipelineConfiguration {
    var settings = configuration
    // Hires fix runs a second sampling pass; keep it off unless the user turns it on.
    settings.hiresFix = false
    guard let fallback = fallbacks.first(where: { model.hasPrefix($0.prefix) }),
          fallback.replacesCatalog || isGenericTemplate(configuration)
    else {
      return settings
    }
    settings.steps = fallback.steps
    settings.guidanceScale = fallback.guidanceScale
    settings.shift = fallback.shift
    settings.resolutionDependentShift = fallback.resolutionDependentShift
    settings.sampler = fallback.sampler
    if let size = fallback.size {
      settings.width = size.width
      settings.height = size.height
    }
    if let fps = fallback.fps { settings.fps = fps }
    if let numFrames = fallback.numFrames { settings.numFrames = numFrames }
    if let shiftForAudio = fallback.shiftForAudio { settings.shiftForAudio = shiftForAudio }
    return settings
  }

  /// ConfigurationResolver is internal to MGK, so infer "not in the catalog" from MGK having
  /// returned the generic GenerationConfiguration.default values.
  private static func isGenericTemplate(_ configuration: PipelineConfiguration)
    -> Bool
  {
    let generic = GenerationConfiguration.default
    return configuration.steps == Int(generic.steps)
      && configuration.sampler == generic.sampler
      && configuration.guidanceScale == generic.guidanceScale
  }
}
