@preconcurrency import _MediaGenerationKit
import Diffusion
import Foundation
import ModelZoo

/// App-side defaults for models the community config catalog doesn't cover yet.
///
/// MGK falls back to generic settings (20 steps, UniPC AYS, guidance 4.5) when the catalog has no
/// entry. Values here come from each model's catalog description. A fallback that
/// `replacesCatalog` applies even when MGK found an entry, for models whose catalog entry only
/// matches some of their files.
nonisolated enum ModelDefaults {
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
    /// A second model that takes over at `refinerStart`, for models distilled as two halves.
    var refiner: (model: String, start: Float)?
    var replacesCatalog = false
    /// Matches every file of this model family instead of a file name prefix, for imports whose
    /// name is the user's.
    var version: ModelVersion?
  }

  /// Models the engine runs that no catalog lists, hosted on static.libnnc.org or, for files in
  /// `downloadSources`, on Hugging Face: neither ModelZoo's built-in list nor models.drawthings.ai
  /// has them, and draw-things-cli can't resolve
  /// them without an entry of its own either. Added to `ModelZoo.availableSpecifications` by
  /// `ModelLibrary.loadCustomSpecifications(in:)`, unless a catalog or custom.json has the file.
  static var uncatalogedSpecifications: [ModelZoo.Specification] {
    [
      longCatSpecification(name: "LongCat-Video Avatar 1.5 DMD (8-bit S)", file: "longcat_video_avatar_1.5_dmd_i8x.ckpt"),
      longCatSpecification(name: "LongCat-Video Avatar 1.5 DMD", file: "longcat_video_avatar_1.5_dmd_q8p.ckpt"),
      longCat16Specification(
        name: "LongCat-Video Avatar 1.6 (8-bit S)", file: longCat16DMD, refiner: longCat16OPSD,
        note:
        "[LongCat-Video Avatar 1.6](https://huggingface.co/meituan-longcat/LongCat-Video-Avatar-1.6) animates a portrait to lip-sync to an audio file. Put the image on the canvas and add a voice; the clip keeps that voice. It runs 8 steps at guidance 1 and takes 4k + 1 frames at 25 fps: its DMD half for the first four steps, then its OPSD half as the refiner, which downloads with it."),
      longCat16Specification(
        name: "LongCat-Video Avatar 1.6 OPSD (8-bit S)", file: longCat16OPSD, refiner: nil,
        note:
        "The second half of [LongCat-Video Avatar 1.6](https://huggingface.co/meituan-longcat/LongCat-Video-Avatar-1.6): the refiner LongCat-Video Avatar 1.6 (8-bit S) switches to for its last four steps. On its own it finishes poorly; pick LongCat-Video Avatar 1.6 instead."),
    ]
  }

  /// LongCat-Video Avatar 1.6's two files. Meituan ships 1.6 as a base model and two
  /// step-distillation LoRAs, DMD for steps 0-3 and OPSD for steps 4-7 (the official
  /// `--mix_steps 4 --mix_alpha 1.0` recipe), and the engine can't load LoRAs for LongCat, so
  /// each is merged into its own copy of the base model (Scripts/longcat-avatar-merge.py) and the
  /// OPSD copy runs as the DMD copy's refiner.
  static let longCat16DMD = "longcat_video_avatar_1.6_dmd_i8x.ckpt"
  static let longCat16OPSD = "longcat_video_avatar_1.6_opsd_i8x.ckpt"

  /// A file that downloads from somewhere other than static.libnnc.org, and the SHA-256 of the
  /// file published there, which the download is checked against.
  struct DownloadSource {
    var url: URL
    var sha256: String
  }

  /// Where files that static.libnnc.org doesn't host download from, by file name. Atelier's own
  /// conversions of LongCat-Video Avatar 1.6 (MIT) are published on Hugging Face; the hashes are
  /// of the files as converted (`Scripts/longcat-avatar-merge.py`, import, Make 8-bit S Copy).
  static let downloadSources: [String: DownloadSource] = [
    longCat16DMD: DownloadSource(
      url: huggingFaceFile("ianivs/LongCat-Video-Avatar-1.6-DrawThings", longCat16DMD),
      sha256: "e42689bff60bb752289364707d546b7f71f951c85690dfcc8933de1e5b7fe42d"),
    longCat16OPSD: DownloadSource(
      url: huggingFaceFile("ianivs/LongCat-Video-Avatar-1.6-DrawThings", longCat16OPSD),
      sha256: "ca4e3750f8480bfe6b7c1847c03001e59a6422924a1100cbdbbbc1671da43d95"),
  ]

  /// Files that only make sense as another model's refiner, kept out of the model picker and the
  /// Models list. They still download with that model (`Specification.defaultRefiner`) and stay
  /// in the Refiner setting's choices. ModelZoo's specification has no field for this.
  static let hiddenFromModelPicker: Set<String> = [longCat16OPSD]

  /// The model each `hiddenFromModelPicker` file belongs to: picking a hidden file (an agent, a
  /// preset or a restored session can) selects this one instead.
  static let hiddenModelParents: [String: String] = [longCat16OPSD: longCat16DMD]

  /// `file`'s hidden refiner, which is deleted and moved with it: a file with no row of its own
  /// would otherwise be left behind.
  static func hiddenCompanions(of _: String, defaultRefiner: String?) -> [String] {
    guard let defaultRefiner, hiddenFromModelPicker.contains(defaultRefiner) else { return [] }
    return [defaultRefiner]
  }

  /// The refiners this table pairs with a model (`Fallback.refiner`), which belong to that model
  /// alone.
  static var pairedRefiners: Set<String> {
    Set(fallbacks.compactMap { $0.refiner?.model })
  }

  /// Why a run of `model` can't start, when its refiner is the one its specification pairs it
  /// with (`defaultRefiner`) and that file isn't in any models folder; nil otherwise. A refiner the
  /// person picked that's missing is left to the engine, which skips it, as before.
  static func missingRefinerMessage(
    model: String, refiner: String?, defaultRefiner: String?, isDownloaded: (String) -> Bool
  ) -> String? {
    guard let refiner, refiner == defaultRefiner, !isDownloaded(refiner) else { return nil }
    let modelName = uncatalogedSpecifications.first { $0.file == model }?.name ?? model
    return "\(modelName) needs its refiner file (\(refiner)), which isn't downloaded. Download the model in Models, or turn the refiner off."
  }

  /// Why `model` can't run: `files`, text encoders or a VAE it needs, are in no models folder and
  /// the download server doesn't have them.
  static func missingFilesMessage(model: String, files: [String]) -> String {
    let list = files.joined(separator: ", ")
    if files == [Fibo2TextEncoderImporter.file] {
      return "\(model) needs its text encoder (\(list)), which isn't in any models folder. Delete the model in Models and import it again with Import… ▸ From Hugging Face Link…, which converts the text encoder too."
    }
    return "\(model) needs \(list), which isn't in any models folder and can't be downloaded."
  }

  /// The refiner to keep when the model changes. Switching models keeps the current settings,
  /// but a paired refiner is part of its model's recipe: a model that has one gets it (and its
  /// start), and one model's paired refiner doesn't carry over to another, which would otherwise
  /// keep running it (same family, so the engine's `isCompatibleRefiner` lets it through), so it
  /// goes back to the new model's recommendation. Only this table's pairs count: refiners MGK's
  /// catalog recommends (Wan 2.2's low-noise expert) or a default preset sets behave as they did,
  /// and a refiner the person chose stays.
  static func refinerAfterModelSwitch(
    current: (model: String?, start: Float), recommended: (model: String?, start: Float),
    pairedRefiners: Set<String> = pairedRefiners
  ) -> (model: String?, start: Float) {
    if let model = recommended.model, pairedRefiners.contains(model) { return recommended }
    if let model = current.model, pairedRefiners.contains(model) { return recommended }
    return current
  }

  private static func huggingFaceFile(_ repository: String, _ path: String) -> URL {
    URL(string: "https://huggingface.co/\(repository)/resolve/main/\(path)")!
  }

  /// The refiner start that hands `steps` sampling steps over to the refiner after `kickInStep`
  /// of them, for a flow model sampled with DDIM Trailing at `shift`. The engine swaps models at
  /// the first step whose timestep is below `(1 - refinerStart) * 1000`
  /// (`DDIMSampler.sample`'s `refinerKickIn`), and step i of the trailing schedule has timestep
  /// `1000 * shift * t / (1 + (shift - 1) * t)` with `t = (steps - i) / steps`
  /// (`Denoiser.LinearDiscretization.alphasCumprod` with `.trailing` spacing), so any start whose
  /// threshold falls between steps `kickInStep - 1` and `kickInStep` works; this is the midpoint.
  static func refinerStart(kickInStep: Int, steps: Int, shift: Double) -> Double {
    func timestep(_ i: Int) -> Double {
      let t = Double(steps - i) / Double(steps)
      return 1000 * shift * t / (1 + (shift - 1) * t)
    }
    let threshold = (timestep(kickInStep - 1) + timestep(kickInStep)) / 2
    return 1 - threshold / 1000
  }

  /// The step at which the engine hands over to the refiner, as `DDIMSampler.sample` decides it
  /// for the trailing schedule above (`steps` when it never does).
  static func refinerKickInStep(refinerStart: Double, steps: Int, shift: Double) -> Int {
    let kickIn = (1 - refinerStart) * 1000
    for i in 0..<steps {
      let t = Double(steps - i) / Double(steps)
      if 1000 * shift * t / (1 + (shift - 1) * t) < kickIn { return i }
    }
    return steps
  }

  /// The dependencies the engine's run-longcat-avatar-video skill lists. Its third, Whisper, has no
  /// field here: see `ModelLibrary.downloadAudioEncoder(for:progress:)`. `.kontext` is what makes
  /// the portrait count: `LocalImageGenerator.encodeImageCond` only reaches LongCat's reference
  /// frame under that modifier, and without it the avatar is a stranger who lip-syncs the voice.
  /// 1.6 has 1.5's network and dependencies but not its audio preprocessing: its pipeline feeds
  /// Whisper the voice as it is, without 1.5's -23 LUFS normalization.
  private static func longCat16Specification(name: String, file: String, refiner: String?, note: String)
    -> ModelZoo.Specification
  {
    var specification = longCatSpecification(name: name, file: file)
    specification.defaultRefiner = refiner
    specification.audioLoudnessNormalization = false
    specification.note = note
    specification.huggingFaceLink = "meituan-longcat/LongCat-Video-Avatar-1.6"
    return specification
  }

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
    // HyperFlow H3 Flash, a compressed few-step MiniMax H3 (FL2VA or Ref2VA) imported from its GGUF
    // as `hyperflow_h3_flash_*`. It's distilled for 4, 6 and 8 steps without CFG; the engine runs it
    // with Euler on that step count's fixed sigma grid (`MiniMaxH3Layout.hyperFlowSigmaGrids`)
    // whatever the sampler, so the sampler here only matters for display.
    Fallback(
      prefix: "hyperflow_", steps: 6, guidanceScale: 1, shift: 12,
      resolutionDependentShift: false, sampler: .dDIMTrailing, size: (1344, 768), fps: 24,
      numFrames: 124, shiftForAudio: 3, replacesCatalog: true),
    // Fibo 2.0 Edit Turbo, imported: distilled for 4 steps without CFG, which the engine forces
    // off (`isCfgEnabled`). Its scheduler shifts by image size from a base of 3, as FLUX does, so
    // resolution-dependent shift is on. Matched by family, not file name: a Hugging Face link
    // import names it after the repo (`fibo_2.0_edit_turbo_f16.ckpt`).
    Fallback(
      prefix: "", steps: 4, guidanceScale: 1, shift: 3,
      resolutionDependentShift: true, sampler: .eulerATrailing, size: (1024, 1024),
      version: .fibo2),
    // MiniMax H3 Image, imported: distilled to 6 steps without CFG (the engine forces it off) on
    // its own sigma grid. The engine samples that grid with Euler only for DDIM Trailing at a step
    // count that has one (`LocalImageGenerator.sampler(from:)`, `MiniMaxH3Layout.sigmaGrids`), so
    // these defaults are the native schedule; any other sampler or step count runs as on other
    // flow models. Shift 1 runs that grid as trained; other values shift it, as Draw Things does
    // (ComfyUI ignores Shift for this model). Tuned for about 2,048 x 2,048 pixels of
    // area; the size popover offers up to 48 megapixels for it (`SizePreset.largeMegapixels`).
    Fallback(
      prefix: "", steps: 6, guidanceScale: 1, shift: 1,
      resolutionDependentShift: false, sampler: .dDIMTrailing, size: (2048, 2048),
      replacesCatalog: true, version: .minimaxH3Image),
    // LongCat-Video Avatar 1.6: 1.5's values, with the OPSD half taking the last four of the
    // eight steps as the official recipe does (`refinerStart(kickInStep: 4, steps: 8, shift: 7)`
    // is about 0.10).
    Fallback(
      prefix: "longcat_video_avatar_1.6_dmd", steps: 8, guidanceScale: 1, shift: 7,
      resolutionDependentShift: false, sampler: .dDIMTrailing, size: (832, 512), fps: 25,
      numFrames: 93, refiner: (longCat16OPSD, 0.10)),
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
    // Every model starts on its sampler's own schedule.
    settings.scheduler = .samplerDefault
    let version = ModelZoo.specificationForModel(model)?.version
    guard
      let fallback = fallbacks.first(where: {
        $0.version.map { $0 == version } ?? model.hasPrefix($0.prefix)
      }),
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
    if let refiner = fallback.refiner {
      settings.refinerModel = refiner.model
      settings.refinerStart = refiner.start
    }
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
