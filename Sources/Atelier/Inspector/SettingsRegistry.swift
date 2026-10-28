import _MediaGenerationKit
import Foundation

/// MGK's configuration plus the engine settings MGK doesn't expose, which runs that call the
/// engine directly write over the template (`engineConfiguration(template:)`). MGK's fields read
/// and write through it as if it were MGK's own.
@dynamicMemberLookup
struct PipelineConfiguration: Sendable {
  var base: MediaGenerationPipeline.Configuration
  /// MiniMax H3's shift for its audio latents.
  var shiftForAudio: Float = 3

  init(_ base: MediaGenerationPipeline.Configuration) { self.base = base }

  subscript<T>(dynamicMember keyPath: KeyPath<MediaGenerationPipeline.Configuration, T>) -> T {
    base[keyPath: keyPath]
  }

  subscript<T>(dynamicMember keyPath: WritableKeyPath<MediaGenerationPipeline.Configuration, T>) -> T {
    get { base[keyPath: keyPath] }
    set { base[keyPath: keyPath] = newValue }
  }
}

/// What the inspector knows about the selected model, for hiding settings it doesn't use.
struct ModelTraits: Equatable {
  /// MGK's human-readable version name, e.g. "MOSS Image" or "Stable Diffusion XL Base".
  var version: String
  /// The selected sampler, for settings only some samplers read.
  var sampler: SamplerType?

  init(_ model: MediaGenerationResolvedModel?, sampler: SamplerType? = nil) {
    version = model?.version ?? ""
    self.sampler = sampler
  }

  private static let unet: Set<String> = [
    "Stable Diffusion v1", "Stable Diffusion v2", "Stable Diffusion XL Base",
    "Stable Diffusion XL Refiner", "Segmind Stable Diffusion XL 1B", "Kandinsky v2.1",
    "Stable Video Diffusion", "Stable Cascade (Würstchen v3.0)",
  ]
  private static let videoPrefixes = [
    "Stable Video", "Hunyuan Video", "Wan", "LTX", "Cosmos", "SeedVR", "MiniMax H3", "LongCat",
  ]

  var isUnknown: Bool { version.isEmpty }
  var isUNet: Bool { Self.unet.contains(version) }
  var isSDXL: Bool { version.contains("XL") }
  var isSD1or2: Bool { version == "Stable Diffusion v1" || version == "Stable Diffusion v2" }
  var isSD3: Bool { version.hasPrefix("Stable Diffusion 3") }
  var isFlux1: Bool { version == "FLUX.1" }
  var isVideo: Bool { Self.videoPrefixes.contains { version.hasPrefix($0) } }
  var isSVD: Bool { version == "Stable Video Diffusion" }
  var isWan: Bool { version.hasPrefix("Wan") }
  /// Mirrors `ModelZoo.teaCacheCoefficientsForModel`'s built-in table.
  var hasTeaCache: Bool {
    ["FLUX.1", "Hunyuan Video", "HiDream I1", "MiniMax H3"].contains(version) || isWan
  }
  /// TCD and TCD Trailing are the only samplers that read Strategic Stochastic Sampling.
  var usesTCD: Bool { sampler == .TCD || sampler == .tCDTrailing }
}

enum SettingSection: String, CaseIterable, Identifiable, Codable {
  case essentials, sampling, loras, hiresFix, refiner, upscaler, video, textEncoders, sdxl,
       imageToImage, tiledDecoding, tiledDiffusion, teaCache, cfgZero, output, kandinsky

  var id: String { rawValue }

  var title: String {
    switch self {
    case .essentials: "Essentials"
    case .sampling: "Sampling"
    case .loras: "LoRAs"
    case .hiresFix: "Hires Fix"
    case .refiner: "Refiner"
    case .upscaler: "Upscaler"
    case .video: "Video"
    case .textEncoders: "Text Encoders"
    case .sdxl: "SDXL Conditioning"
    case .imageToImage: "Image to Image"
    case .tiledDecoding: "Tiled Decoding"
    case .tiledDiffusion: "Tiled Diffusion"
    case .teaCache: "TeaCache"
    case .cfgZero: "CFG-Zero*"
    case .output: "Output"
    case .kandinsky: "Image Prior"
    }
  }

  /// The Bool setting shown as the section header's enable checkbox, for feature sections.
  var featureToggle: String? {
    switch self {
    case .hiresFix: "hiresFix"
    case .tiledDecoding: "tiledDecoding"
    case .tiledDiffusion: "tiledDiffusion"
    case .teaCache: "teaCache"
    case .cfgZero: "cfgZeroStar"
    default: nil
    }
  }

  /// The file setting whose None/picked state the header checkbox stands for (no Bool exists).
  var enableSetting: String? {
    switch self {
    case .refiner: "refinerModel"
    case .upscaler: "upscaler"
    default: nil
    }
  }
}

struct SettingOption: Hashable {
  var value: JSONValue
  var title: String
}

/// What the inspector needs to build option lists that depend on the machine.
struct SettingContext {
  var models: [MediaGenerationResolvedModel]
  /// File names in the models directory, listed once per reload (it may be a slow external disk).
  var files: [String]
}

enum SettingControl {
  case toggle
  case integer(ClosedRange<Int>, step: Int)
  case slider(ClosedRange<Double>, step: Double, digits: Int)
  case choice([SettingOption])
  /// A file picked from the models directory; `.null` means none.
  case file(@Sendable (SettingContext) -> [SettingOption])
  case text
  case size
  case loras
  /// A video's length: frame counts the model takes, shown with their duration.
  case frames
}

/// One inspector setting: how to show it and how to read and write it on a configuration.
/// Values travel as `JSONValue` so presets, history sidecars and changed-checks share one format.
struct SettingDescriptor: Identifiable {
  /// The `Configuration` property name (stable; used in layouts, presets and sidecars).
  let id: String
  let title: String
  let help: String
  let section: SettingSection
  var control: SettingControl
  var keywords: [String] = []
  let applies: (ModelTraits) -> Bool
  let get: (PipelineConfiguration) -> JSONValue
  let set: (inout PipelineConfiguration, JSONValue) -> Void
  /// Reads this setting from a sidecar's configuration dump (keyed by property name).
  var read: ([String: JSONValue]) -> JSONValue? = { _ in nil }

  var isFeatureToggle: Bool { section.featureToggle == id }

  func matches(_ query: String) -> Bool {
    ([title, id, help, section.title] + keywords).contains {
      $0.localizedCaseInsensitiveContains(query)
    }
  }
}

enum SettingsRegistry {
  static let all: [SettingDescriptor] = build()
  static let byID: [String: SettingDescriptor] = Dictionary(
    uniqueKeysWithValues: all.map { ($0.id, $0) })

  static func descriptors(in section: SettingSection) -> [SettingDescriptor] {
    all.filter { $0.section == section }
  }

  /// Writes every registry setting found in a sidecar's configuration dump onto `configuration`.
  static func apply(dump: [String: JSONValue], to configuration: inout PipelineConfiguration) {
    for descriptor in all {
      if let value = descriptor.read(dump) { descriptor.set(&configuration, value) }
    }
  }

  static let samplerTitles: [SamplerType: String] = [
    .dPMPP2MKarras: "DPM++ 2M Karras", .eulerA: "Euler A", .DDIM: "DDIM", .PLMS: "PLMS",
    .dPMPPSDEKarras: "DPM++ SDE Karras", .uniPC: "UniPC", .LCM: "LCM",
    .eulerASubstep: "Euler A Substep", .dPMPPSDESubstep: "DPM++ SDE Substep", .TCD: "TCD",
    .eulerATrailing: "Euler A Trailing", .dPMPPSDETrailing: "DPM++ SDE Trailing",
    .DPMPP2MAYS: "DPM++ 2M AYS", .eulerAAYS: "Euler A AYS", .DPMPPSDEAYS: "DPM++ SDE AYS",
    .dPMPP2MTrailing: "DPM++ 2M Trailing", .dDIMTrailing: "DDIM Trailing",
    .uniPCTrailing: "UniPC Trailing", .uniPCAYS: "UniPC AYS", .tCDTrailing: "TCD Trailing",
  ]

  // MARK: - Building

  private typealias KP<T> = WritableKeyPath<PipelineConfiguration, T>
  private static let always: (ModelTraits) -> Bool = { _ in true }

  private static func toggle(
    _ id: String, _ kp: KP<Bool>, _ title: String, _ section: SettingSection, _ help: String,
    keywords: [String] = [], applies: @escaping (ModelTraits) -> Bool = always
  ) -> SettingDescriptor {
    SettingDescriptor(
      id: id, title: title, help: help, section: section, control: .toggle, keywords: keywords,
      applies: applies, get: { .bool($0[keyPath: kp]) },
      set: { if case .bool(let v) = $1 { $0[keyPath: kp] = v } },
      read: { $0[id] })
  }

  private static func integer(
    _ id: String, _ kp: KP<Int>, _ title: String, _ section: SettingSection, _ help: String,
    range: ClosedRange<Int>, step: Int = 1, keywords: [String] = [],
    applies: @escaping (ModelTraits) -> Bool = always
  ) -> SettingDescriptor {
    SettingDescriptor(
      id: id, title: title, help: help, section: section, control: .integer(range, step: step),
      keywords: keywords, applies: applies, get: { .number(Double($0[keyPath: kp])) },
      set: { if let v = $1.doubleValue { $0[keyPath: kp] = Int(v.rounded()) } },
      read: { $0[id] })
  }

  private static func float(
    _ id: String, _ kp: KP<Float>, _ title: String, _ section: SettingSection, _ help: String,
    range: ClosedRange<Double>, step: Double, digits: Int = 1, keywords: [String] = [],
    applies: @escaping (ModelTraits) -> Bool = always
  ) -> SettingDescriptor {
    SettingDescriptor(
      id: id, title: title, help: help, section: section,
      control: .slider(range, step: step, digits: digits), keywords: keywords, applies: applies,
      get: { JSONValue($0[keyPath: kp]) },
      set: { if let v = $1.doubleValue { $0[keyPath: kp] = Float(v) } },
      read: { $0[id] })
  }

  private static func choice<E: CaseIterable & Hashable>(
    _ id: String, _ kp: KP<E>, _ title: String, _ section: SettingSection, _ help: String,
    titles: [E: String] = [:], keywords: [String] = [],
    applies: @escaping (ModelTraits) -> Bool = always
  ) -> SettingDescriptor {
    let options = E.allCases.map {
      SettingOption(value: .string(String(describing: $0)), title: titles[$0] ?? String(describing: $0))
    }
    return SettingDescriptor(
      id: id, title: title, help: help, section: section, control: .choice(options),
      keywords: keywords, applies: applies, get: { .string(String(describing: $0[keyPath: kp])) },
      set: { configuration, value in
        guard case .string(let name) = value,
              let match = E.allCases.first(where: { String(describing: $0) == name })
        else { return }
        configuration[keyPath: kp] = match
      },
      read: { $0[id] })
  }

  private static func text(
    _ id: String, _ kp: KP<String?>, _ title: String, _ section: SettingSection, _ help: String,
    keywords: [String] = [], applies: @escaping (ModelTraits) -> Bool = always
  ) -> SettingDescriptor {
    SettingDescriptor(
      id: id, title: title, help: help, section: section, control: .text, keywords: keywords,
      applies: applies, get: { $0[keyPath: kp].map(JSONValue.string) ?? .null },
      set: { configuration, value in
        if case .string(let text) = value, !text.isEmpty {
          configuration[keyPath: kp] = text
        } else {
          configuration[keyPath: kp] = nil
        }
      },
      read: { $0[id] })
  }

  private static func file(
    _ id: String, _ kp: KP<String?>, _ title: String, _ section: SettingSection, _ help: String,
    keywords: [String] = [], applies: @escaping (ModelTraits) -> Bool = always,
    options: @escaping @Sendable (SettingContext) -> [SettingOption]
  ) -> SettingDescriptor {
    var descriptor = text(id, kp, title, section, help, keywords: keywords, applies: applies)
    descriptor.control = .file(options)
    return descriptor
  }

  /// Model-directory files whose names contain any of `fragments`.
  private static func files(matching fragments: [String]) -> @Sendable (SettingContext) -> [SettingOption] {
    { context in
      context.files.filter { name in
        name.hasSuffix(".ckpt") && fragments.contains { name.localizedCaseInsensitiveContains($0) }
      }.sorted().map { SettingOption(value: .string($0), title: $0) }
    }
  }

  private static func build() -> [SettingDescriptor] {
    let flow: (ModelTraits) -> Bool = { $0.isUnknown || !$0.isUNet }
    let video: (ModelTraits) -> Bool = { $0.isUnknown || $0.isVideo }
    let svd: (ModelTraits) -> Bool = { $0.isSVD }
    let sdxl: (ModelTraits) -> Bool = { $0.isSDXL }
    let clipL: (ModelTraits) -> Bool = { $0.isSDXL || $0.isSD3 || $0.isFlux1 }
    let t5: (ModelTraits) -> Bool = { $0.isSD3 || $0.isFlux1 }
    let kandinsky: (ModelTraits) -> Bool = { $0.version == "Kandinsky v2.1" }

    let size = SettingDescriptor(
      id: "size", title: "Size", help: "Output width and height in pixels, in steps of 64.",
      section: .essentials, control: .size, keywords: ["width", "height", "aspect", "megapixels"],
      applies: always,
      get: { .object(["width": .number(Double($0.width)), "height": .number(Double($0.height))]) },
      set: { configuration, value in
        guard case .object(let size) = value,
              let width = size["width"]?.doubleValue, let height = size["height"]?.doubleValue
        else { return }
        configuration.width = Int(width)
        configuration.height = Int(height)
      },
      read: { dump in
        guard let width = dump["width"], let height = dump["height"] else { return nil }
        return .object(["width": width, "height": height])
      })

    let loras = SettingDescriptor(
      id: "loras", title: "LoRAs", help: "LoRA files applied on top of the model, with weights.",
      section: .loras, control: .loras, keywords: ["lora", "style"], applies: always,
      get: { configuration in
        .array(configuration.loras.map { lora in
          .object([
            "file": lora.file.map(JSONValue.string) ?? .null,
            "weight": JSONValue(lora.weight),
            "mode": .string(String(describing: lora.mode)),
          ])
        })
      },
      set: { configuration, value in
        guard case .array(let entries) = value else { return }
        configuration.loras = entries.compactMap { entry in
          guard case .object(let fields) = entry, case .string(let file)? = fields["file"]
          else { return nil }
          let weight = fields["weight"]?.doubleValue.map(Float.init) ?? 1
          var mode = LoRAMode.all
          if case .string(let name)? = fields["mode"],
             let match = LoRAMode.allCases.first(where: { String(describing: $0) == name })
          {
            mode = match
          }
          return LoRA(file: file, weight: weight, mode: mode)
        }
      },
      read: { $0["loras"] })

    return [
      // Essentials
      size,
      integer(
        "steps", \.steps, "Steps", .essentials,
        "Number of denoising steps. More is slower and usually finer.", range: 1...150),
      float(
        "guidanceScale", \.guidanceScale, "Guidance", .essentials,
        "How strongly the image follows the prompt (CFG scale).", range: 0...30, step: 0.5,
        keywords: ["cfg", "text guidance"]),
      choice(
        "sampler", \.sampler, "Sampler", .essentials, "The sampling algorithm and its noise schedule.",
        titles: samplerTitles),
      loras,

      // Sampling
      float(
        "shift", \.shift, "Shift", .sampling,
        "Shifts the noise schedule toward high noise; flow models like 3 to 6.", range: 0...12,
        step: 0.1, applies: flow),
      toggle(
        "resolutionDependentShift", \.resolutionDependentShift, "Resolution-Dependent Shift",
        .sampling, "Scale the shift with image size. Off uses Shift as is.", applies: flow),
      float(
        "shiftForAudio", \.shiftForAudio, "Audio Shift", .sampling,
        "Shifts the soundtrack's noise schedule, as Shift does the video's.", range: 0...12,
        step: 0.1, applies: { $0.version.hasPrefix("MiniMax H3") }),
      choice(
        "seedMode", \.seedMode, "Seed Mode", .sampling,
        "How the seed turns into noise. Scale Alike keeps compositions similar across sizes.",
        titles: [
          .legacy: "Legacy", .torchCpuCompatible: "Torch CPU Compatible",
          .scaleAlike: "Scale Alike", .nvidiaGpuCompatible: "NVIDIA GPU Compatible",
        ]),
      integer(
        "clipSkip", \.clipSkip, "CLIP Skip", .sampling,
        "Skip the last CLIP layers when encoding the prompt. Some anime models want 2.",
        range: 1...23, applies: { $0.isSD1or2 || $0.isSDXL }),
      float(
        "sharpness", \.sharpness, "Sharpness", .sampling,
        "Adds detail during sampling. 0 is off.", range: 0...30, step: 0.1),
      float(
        "stochasticSamplingGamma", \.stochasticSamplingGamma, "Strategic Stochastic Sampling",
        .sampling, "Noise injected per step by the TCD samplers.", range: 0...1, step: 0.01,
        digits: 2, keywords: ["tcd", "gamma", "sss"], applies: { $0.usesTCD }),
      toggle(
        "speedUpWithGuidanceEmbed", \.speedUpWithGuidanceEmbed, "Speed Up With Guidance Embed",
        .sampling, "Use the distilled guidance embedding instead of a second CFG pass.",
        applies: { $0.isFlux1 || $0.version == "Hunyuan Video" }),
      float(
        "guidanceEmbed", \.guidanceEmbed, "Guidance Embed", .sampling,
        "Distilled guidance strength when Speed Up With Guidance Embed is on.", range: 0...30,
        step: 0.5, applies: { $0.isFlux1 || $0.version == "Hunyuan Video" }),
      toggle(
        "zeroNegativePrompt", \.zeroNegativePrompt, "Zero Negative Prompt", .sampling,
        "Use a zeroed embedding when the negative prompt is empty.", applies: sdxl),
      toggle(
        "expandPromptToJson", \.expandPromptToJson, "Expand Prompt to JSON", .sampling,
        "Let the model expand the prompt into its structured JSON form.",
        applies: { $0.version == "Ideogram 4" }),

      // Hires fix
      toggle(
        "hiresFix", \.hiresFix, "Hires Fix", .hiresFix,
        "Renders small, then upscales and runs a second sampling pass."),
      integer(
        "hiresFixWidth", \.hiresFixWidth, "First Pass Width", .hiresFix,
        "Width of the first, smaller pass.", range: 64...2048, step: 64),
      integer(
        "hiresFixHeight", \.hiresFixHeight, "First Pass Height", .hiresFix,
        "Height of the first, smaller pass.", range: 64...2048, step: 64),
      float(
        "hiresFixStrength", \.hiresFixStrength, "Second Pass Strength", .hiresFix,
        "How much the second pass may change the upscaled image.", range: 0...1, step: 0.01,
        digits: 2),

      // Refiner
      file(
        "refinerModel", \.refinerModel, "Refiner Model", .refiner,
        "A second model that finishes the last part of sampling.", keywords: ["refiner"]
      ) { context in
        context.models.map { SettingOption(value: .string($0.file), title: $0.name) }
      },
      float(
        "refinerStart", \.refinerStart, "Refiner Start", .refiner,
        "Fraction of the steps after which the refiner takes over.", range: 0...1, step: 0.01,
        digits: 2),

      // Upscaler
      file(
        "upscaler", \.upscaler, "Upscaler", .upscaler, "Upscale the result with an ESRGAN model.",
        options: files(matching: ["esrgan", "upscaler", "ultrasharp", "remacri", "4x_", "2x_"])),
      integer(
        "upscalerScaleFactor", \.upscalerScaleFactor, "Scale Factor", .upscaler,
        "Upscale factor; 0 uses the upscaler's native scale.", range: 0...4),
      file(
        "faceRestoration", \.faceRestoration, "Face Restoration", .output,
        "Restore faces with a GFPGAN or RestoreFormer model.",
        options: files(matching: ["restoreformer", "gfpgan"])),

      // Video
      {
        var length = integer(
          "numFrames", \.numFrames, "Length", .video,
          "How long the video is, in frames. Each model takes some frame counts only; the length snaps to them.",
          range: 1...1000, keywords: ["frames", "duration", "seconds"], applies: video)
        length.control = .frames
        return length
      }(),
      integer(
        "fps", \.fps, "FPS", .video,
        "Frames per second Stable Video Diffusion is told the video plays at; the clip plays at it too.",
        range: 1...60, applies: svd),
      integer(
        "motionScale", \.motionScale, "Motion Scale", .video, "Amount of motion (SVD motion bucket).",
        range: 0...255, applies: svd),
      float(
        "guidingFrameNoise", \.guidingFrameNoise, "Guiding Frame Noise", .video,
        "Noise added to the start frame (SVD conditioning augmentation).", range: 0...1,
        step: 0.01, digits: 2, applies: svd),
      float(
        "startFrameGuidance", \.startFrameGuidance, "Start Frame Guidance", .video,
        "Guidance at the first frame; ramps to Guidance at the last.", range: 0...30, step: 0.5,
        applies: svd),
      integer(
        "causalInference", \.causalInference, "Causal Inference", .video,
        "Generate in overlapping chunks of this many latent frames; 0 is off.", range: 0...129,
        applies: { $0.isWan }),
      integer(
        "causalInferencePad", \.causalInferencePad, "Causal Inference Pad", .video,
        "Extra latent frames of context per chunk.", range: 0...129, applies: { $0.isWan }),
      integer(
        "stage2Steps", \.stage2Steps, "Stage 2 Steps", .video, "Steps for the second stage.",
        range: 1...150, keywords: ["stage 2"],
        applies: { $0.version.hasPrefix("Stable Cascade") || $0.version.hasPrefix("LTX") }),
      float(
        "stage2Guidance", \.stage2Guidance, "Stage 2 Guidance", .video,
        "Guidance for the second stage.", range: 0...30, step: 0.5,
        applies: { $0.version.hasPrefix("Stable Cascade") || $0.version.hasPrefix("LTX") }),
      float(
        "stage2Shift", \.stage2Shift, "Stage 2 Shift", .video, "Shift for the second stage.",
        range: 0...12, step: 0.1,
        applies: { $0.version.hasPrefix("Stable Cascade") || $0.version.hasPrefix("LTX") }),

      // Text encoders
      toggle(
        "t5TextEncoder", \.t5TextEncoder, "T5 Text Encoder", .textEncoders,
        "Encode the prompt with T5 as well as CLIP.", applies: { $0.isSD3 }),
      toggle(
        "separateClipL", \.separateClipL, "Separate CLIP-L Prompt", .textEncoders,
        "Give CLIP-L its own prompt.", applies: clipL),
      text(
        "clipLText", \.clipLText, "CLIP-L Prompt", .textEncoders,
        "Prompt for CLIP-L when Separate CLIP-L Prompt is on.", applies: clipL),
      toggle(
        "separateOpenClipG", \.separateOpenClipG, "Separate OpenCLIP-G Prompt", .textEncoders,
        "Give OpenCLIP-G its own prompt.", applies: { $0.isSDXL || $0.isSD3 }),
      text(
        "openClipGText", \.openClipGText, "OpenCLIP-G Prompt", .textEncoders,
        "Prompt for OpenCLIP-G when Separate OpenCLIP-G Prompt is on.",
        applies: { $0.isSDXL || $0.isSD3 }),
      toggle(
        "separateT5", \.separateT5, "Separate T5 Prompt", .textEncoders,
        "Give T5 its own prompt.", applies: t5),
      text(
        "t5Text", \.t5Text, "T5 Prompt", .textEncoders,
        "Prompt for T5 when Separate T5 Prompt is on.", applies: t5),
      float(
        "clipWeight", \.clipWeight, "CLIP Weight", .kandinsky, "Weight of the CLIP image embedding.",
        range: 0...1, step: 0.01, digits: 2, applies: kandinsky),
      integer(
        "imagePriorSteps", \.imagePriorSteps, "Image Prior Steps", .kandinsky,
        "Steps for the image prior.", range: 1...150, applies: kandinsky),
      toggle(
        "negativePromptForImagePrior", \.negativePromptForImagePrior,
        "Negative Prompt for Image Prior", .kandinsky,
        "Use the negative prompt in the image prior too.", applies: kandinsky),

      // SDXL conditioning
      float(
        "aestheticScore", \.aestheticScore, "Aesthetic Score", .sdxl,
        "Refiner conditioning: target aesthetic score.", range: 0...10, step: 0.5, applies: sdxl),
      float(
        "negativeAestheticScore", \.negativeAestheticScore, "Negative Aesthetic Score", .sdxl,
        "Refiner conditioning for the negative prompt.", range: 0...10, step: 0.5, applies: sdxl),
      integer(
        "originalImageWidth", \.originalImageWidth, "Original Width", .sdxl,
        "Size conditioning; 0 uses the output width.", range: 0...4096, step: 64, applies: sdxl),
      integer(
        "originalImageHeight", \.originalImageHeight, "Original Height", .sdxl,
        "Size conditioning; 0 uses the output height.", range: 0...4096, step: 64, applies: sdxl),
      integer(
        "targetImageWidth", \.targetImageWidth, "Target Width", .sdxl,
        "Target size conditioning; 0 uses the output width.", range: 0...4096, step: 64,
        applies: sdxl),
      integer(
        "targetImageHeight", \.targetImageHeight, "Target Height", .sdxl,
        "Target size conditioning; 0 uses the output height.", range: 0...4096, step: 64,
        applies: sdxl),
      integer(
        "negativeOriginalImageWidth", \.negativeOriginalImageWidth, "Negative Original Width",
        .sdxl, "Size conditioning for the negative prompt; 0 uses the default.", range: 0...4096,
        step: 64, applies: sdxl),
      integer(
        "negativeOriginalImageHeight", \.negativeOriginalImageHeight, "Negative Original Height",
        .sdxl, "Size conditioning for the negative prompt; 0 uses the default.", range: 0...4096,
        step: 64, applies: sdxl),
      integer(
        "cropTop", \.cropTop, "Crop Top", .sdxl, "Crop conditioning, in pixels.", range: 0...4096,
        step: 64, applies: sdxl),
      integer(
        "cropLeft", \.cropLeft, "Crop Left", .sdxl, "Crop conditioning, in pixels.",
        range: 0...4096, step: 64, applies: sdxl),

      // Image to image
      float(
        "strength", \.strength, "Strength", .imageToImage,
        "How much an input image may change. 1 ignores it.", range: 0...1, step: 0.01, digits: 2,
        keywords: ["denoise", "img2img"]),
      float(
        "imageGuidanceScale", \.imageGuidanceScale, "Image Guidance", .imageToImage,
        "How closely edit models follow the input image.", range: 0...30, step: 0.1),
      float(
        "maskBlur", \.maskBlur, "Mask Blur", .imageToImage, "Feathering of the inpainting mask.",
        range: 0...50, step: 0.5, keywords: ["inpaint"]),
      integer(
        "maskBlurOutset", \.maskBlurOutset, "Mask Blur Outset", .imageToImage,
        "Grow (or shrink) the mask before blurring, in pixels.", range: -100...100,
        keywords: ["inpaint"]),
      toggle(
        "preserveOriginalAfterInpaint", \.preserveOriginalAfterInpaint,
        "Preserve Original After Inpaint", .imageToImage,
        "Paste the unmasked original back over the result.", keywords: ["inpaint"]),

      // Tiled decoding
      toggle(
        "tiledDecoding", \.tiledDecoding, "Tiled Decoding", .tiledDecoding,
        "Decode the image in tiles to save memory at large sizes.", keywords: ["vae", "memory"]),
      integer(
        "decodingTileWidth", \.decodingTileWidth, "Tile Width", .tiledDecoding,
        "Decoding tile width in pixels.", range: 128...2048, step: 64),
      integer(
        "decodingTileHeight", \.decodingTileHeight, "Tile Height", .tiledDecoding,
        "Decoding tile height in pixels.", range: 128...2048, step: 64),
      integer(
        "decodingTileOverlap", \.decodingTileOverlap, "Tile Overlap", .tiledDecoding,
        "Overlap between decoding tiles in pixels.", range: 64...1024, step: 64),

      // Tiled diffusion
      toggle(
        "tiledDiffusion", \.tiledDiffusion, "Tiled Diffusion", .tiledDiffusion,
        "Sample in tiles to make images larger than the model handles at once.",
        keywords: ["memory"]),
      integer(
        "diffusionTileWidth", \.diffusionTileWidth, "Tile Width", .tiledDiffusion,
        "Diffusion tile width in pixels.", range: 256...4096, step: 64),
      integer(
        "diffusionTileHeight", \.diffusionTileHeight, "Tile Height", .tiledDiffusion,
        "Diffusion tile height in pixels.", range: 256...4096, step: 64),
      integer(
        "diffusionTileOverlap", \.diffusionTileOverlap, "Tile Overlap", .tiledDiffusion,
        "Overlap between diffusion tiles in pixels.", range: 64...1024, step: 64),

      // TeaCache
      toggle(
        "teaCache", \.teaCache, "TeaCache", .teaCache,
        "Skip steps whose output barely changes. Faster, slightly less detail.",
        keywords: ["speed", "cache"], applies: { $0.hasTeaCache }),
      integer(
        "teaCacheStart", \.teaCacheStart, "Start Step", .teaCache,
        "First step where skipping is allowed.", range: 0...150, applies: { $0.hasTeaCache }),
      integer(
        "teaCacheEnd", \.teaCacheEnd, "End Step", .teaCache,
        "Last step where skipping is allowed; -1 means the end.", range: -1...150,
        applies: { $0.hasTeaCache }),
      float(
        "teaCacheThreshold", \.teaCacheThreshold, "Threshold", .teaCache,
        "Higher skips more steps.", range: 0...1, step: 0.01, digits: 2,
        applies: { $0.hasTeaCache }),
      integer(
        "teaCacheMaxSkipSteps", \.teaCacheMaxSkipSteps, "Max Skipped Steps", .teaCache,
        "Most consecutive steps that may be skipped.", range: 1...50,
        applies: { $0.hasTeaCache }),

      // CFG-Zero*
      toggle(
        "cfgZeroStar", \.cfgZeroStar, "CFG-Zero*", .cfgZero,
        "Rescale guidance and zero the first steps; helps flow models at high guidance.",
        keywords: ["cfg zero"], applies: flow),
      integer(
        "cfgZeroInitSteps", \.cfgZeroInitSteps, "Zero Init Steps", .cfgZero,
        "Number of initial steps whose output is zeroed.", range: 0...20, applies: flow),

      // Output
      choice(
        "colorCalibration", \.colorCalibration, "Color Calibration", .output,
        "Match the output's colors to the input image.",
        titles: [.disabled: "Off", .lab: "LAB"]),
      choice(
        "compressionArtifacts", \.compressionArtifacts, "Compression Artifacts", .output,
        "Simulate codec artifacts on the input.",
        titles: [.disabled: "Off", .H264: "H.264", .H265: "H.265", .jpeg: "JPEG"]),
      SettingDescriptor(
        id: "compressionArtifactsQuality", title: "Compression Quality",
        help: "Quality of the simulated compression.", section: .output,
        control: .slider(0...100, step: 1, digits: 0), applies: always,
        get: { $0.compressionArtifactsQuality.map(JSONValue.init) ?? .null },
        set: { configuration, value in
          configuration.compressionArtifactsQuality = value.doubleValue.map(Float.init)
        },
        read: { $0["compressionArtifactsQuality"] }),
    ]
  }
}

extension JSONValue {
  var doubleValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  /// Floats go through their shortest decimal form so presets read 0.7, not 0.699999988.
  init(_ value: Float) {
    self = .number(Double(value.description) ?? Double(value))
  }
}
