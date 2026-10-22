import DataModels
import Foundation
import ProjectFormat
import _MediaGenerationKit

/// Conversion between Atelier's settings dump (MGK's `Configuration` field by field) and Draw
/// Things' `TensorHistoryNode`, following the engine's own bridge (`JSGenerationConfiguration` in
/// Libraries/Scripting/Sources/ScriptModels.swift): sizes and tiles are stored in 64-pixel units, fps/motion/frame-noise use their node names, and
/// causal inference is "enabled" when its value is above zero.
///
/// The two schemas declare their enums in the same order, so enums convert by raw value.
enum ProjectMapping {
  struct Step {
    var lineage: Int64
    var logicalTime: Int64
    var model: String
    var prompt: String
    var negativePrompt: String
    var seed: UInt32
    var tensorId: Int64
    var previewId: Int64
    var wallClock: Int64
    var generationTime: Double
    var reason: ProjectFormat.Reason
    /// False for an image brought in from outside (Draw Things' Imported steps).
    var generated = true
    /// How many moodboard images the step has (`tensormoodboarddata` rows).
    var moodboardCount = 0
    /// For a step generated from the canvas (Edit), the image tensor of its input: the step
    /// before it. Kept in `profile_data`, see `Profile`.
    var inputTensorId: Int64?
  }

  /// `profile_data`: Draw Things' `GenerationProfile` as snake-case JSON (timings and duration),
  /// plus Atelier's `input_tensor_id` for Edit steps. Draw Things has no field for "this step
  /// was made from the canvas": in its model every step's input is the canvas, i.e. the step
  /// before. Atelier's Generate mode ignores the canvas, so Edit steps carry the input's tensor
  /// id here. Draw Things decodes the profile with Codable, which skips the extra key.
  struct Profile: Codable {
    var timings: [Timing] = []
    var duration: Double
    var inputTensorId: Int64?

    struct Timing: Codable {
      var durations: [Double]
      var name: String
    }

    var bytes: [UInt8] {
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      return (try? encoder.encode(self)).map { [UInt8]($0) } ?? []
    }

    init(duration: Double, inputTensorId: Int64?) {
      self.duration = duration
      self.inputTensorId = inputTensorId
    }

    init?(_ bytes: [UInt8]) {
      guard !bytes.isEmpty else { return nil }
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      guard let profile = try? decoder.decode(Profile.self, from: Data(bytes)) else { return nil }
      self = profile
    }
  }

  /// A step for `settings`, given in the history dump format (`JSONValue.fields(of:)` of MGK's
  /// configuration), so old PNG sidecars and live settings take the same path.
  static func node(for step: Step, settings dump: [String: JSONValue]) -> TensorHistoryNode {
    let d = Dump(dump)
    func units(_ key: String, _ fallback: Int) -> UInt16 { UInt16(clamping: d.int(key, fallback) / 64) }
    func u32(_ key: String, _ fallback: Int) -> UInt32 { UInt32(clamping: d.int(key, fallback)) }
    func i32(_ key: String, _ fallback: Int) -> Int32 { Int32(clamping: d.int(key, fallback)) }
    let causalInference = d.int("causalInference", 0)
    return TensorHistoryNode(
      lineage: step.lineage, logicalTime: step.logicalTime,
      startWidth: units("width", 1024), startHeight: units("height", 1024), seed: step.seed,
      steps: u32("steps", 20), guidanceScale: d.float("guidanceScale", 4.5),
      strength: d.float("strength", 1), model: step.model, tensorId: 0, maskId: 0,
      wallClock: step.wallClock, batchSize: UInt32(clamping: max(d.int("batchSize", 1), 1)),
      sampler: d.enumeration("sampler", DataModels.SamplerType.self).flatMap {
        ProjectFormat.SamplerType(rawValue: $0.rawValue)
      },
      hiresFix: d.bool("hiresFix", false), hiresFixStartWidth: units("hiresFixWidth", 0),
      hiresFixStartHeight: units("hiresFixHeight", 0),
      hiresFixStrength: d.float("hiresFixStrength", 0.7), upscaler: d.string("upscaler"),
      scaleFactor: 1, depthMapId: 0, generated: step.generated,
      imageGuidanceScale: d.float("imageGuidanceScale", 1.5),
      seedMode: d.enumeration("seedMode", DataModels.SeedMode.self).flatMap {
        ProjectFormat.SeedMode(rawValue: $0.rawValue)
      },
      clipSkip: u32("clipSkip", 1), controls: d.objects("controls").map(control(_:)),
      loras: d.objects("loras").map(lora(_:)), maskBlur: d.float("maskBlur", 0),
      faceRestoration: d.string("faceRestoration"), clipWeight: d.float("clipWeight", 1),
      negativePromptForImagePrior: d.bool("negativePromptForImagePrior", true),
      imagePriorSteps: u32("imagePriorSteps", 5),
      dataStored: step.tensorId != 0 ? 1 : 0, previewId: step.previewId,
      refinerModel: d.string("refinerModel"),
      originalImageHeight: u32("originalImageHeight", 0),
      originalImageWidth: u32("originalImageWidth", 0),
      cropTop: i32("cropTop", 0), cropLeft: i32("cropLeft", 0),
      targetImageHeight: u32("targetImageHeight", 0),
      targetImageWidth: u32("targetImageWidth", 0),
      aestheticScore: d.float("aestheticScore", 6),
      negativeAestheticScore: d.float("negativeAestheticScore", 2.5),
      zeroNegativePrompt: d.bool("zeroNegativePrompt", false),
      refinerStart: d.float("refinerStart", 0.85),
      negativeOriginalImageHeight: u32("negativeOriginalImageHeight", 0),
      negativeOriginalImageWidth: u32("negativeOriginalImageWidth", 0),
      shuffleDataStored: Int32(clamping: step.moodboardCount),
      fpsId: u32("fps", 5), motionBucketId: u32("motionScale", 127),
      condAug: d.float("guidingFrameNoise", 0.02),
      startFrameCfg: d.float("startFrameGuidance", 1), numFrames: u32("numFrames", 14),
      maskBlurOutset: i32("maskBlurOutset", 0), sharpness: d.float("sharpness", 0),
      shift: d.float("shift", 1), stage2Steps: u32("stage2Steps", 10),
      stage2Cfg: d.float("stage2Guidance", 1), stage2Shift: d.float("stage2Shift", 1),
      tiledDecoding: d.bool("tiledDecoding", false),
      decodingTileWidth: units("decodingTileWidth", 640),
      decodingTileHeight: units("decodingTileHeight", 640),
      decodingTileOverlap: units("decodingTileOverlap", 128),
      stochasticSamplingGamma: d.float("stochasticSamplingGamma", 0.3),
      preserveOriginalAfterInpaint: d.bool("preserveOriginalAfterInpaint", true),
      tiledDiffusion: d.bool("tiledDiffusion", false),
      diffusionTileWidth: units("diffusionTileWidth", 1024),
      diffusionTileHeight: units("diffusionTileHeight", 1024),
      diffusionTileOverlap: units("diffusionTileOverlap", 128),
      upscalerScaleFactor: UInt8(clamping: d.int("upscalerScaleFactor", 0)),
      t5TextEncoder: d.bool("t5TextEncoder", true),
      separateClipL: d.bool("separateClipL", false), clipLText: d.string("clipLText"),
      separateOpenClipG: d.bool("separateOpenClipG", false),
      openClipGText: d.string("openClipGText"),
      speedUpWithGuidanceEmbed: d.bool("speedUpWithGuidanceEmbed", true),
      guidanceEmbed: d.float("guidanceEmbed", 3.5),
      resolutionDependentShift: d.bool("resolutionDependentShift", true),
      profileData: step.inputTensorId.map {
        Profile(duration: step.generationTime, inputTensorId: $0).bytes
      },
      teaCacheStart: i32("teaCacheStart", 5), teaCacheEnd: i32("teaCacheEnd", -1),
      teaCacheThreshold: d.float("teaCacheThreshold", 0.06), teaCache: d.bool("teaCache", false),
      separateT5: d.bool("separateT5", false), t5Text: d.string("t5Text"),
      teaCacheMaxSkipSteps: i32("teaCacheMaxSkipSteps", 3),
      textPrompt: step.prompt, negativeTextPrompt: step.negativePrompt,
      causalInferenceEnabled: causalInference > 0,
      causalInference: Int32(clamping: causalInference),
      causalInferencePad: i32("causalInferencePad", 0),
      cfgZeroStar: d.bool("cfgZeroStar", false), cfgZeroInitSteps: i32("cfgZeroInitSteps", 0),
      generationTime: step.generationTime, reason: step.reason,
      compressionArtifacts: d.enumeration("compressionArtifacts", DataModels.CompressionMethod.self)
        .flatMap { ProjectFormat.CompressionMethod(rawValue: $0.rawValue) },
      compressionArtifactsQuality: min(max(d.float("compressionArtifactsQuality", 43.1), 0), 100),
      colorCalibration: d.enumeration("colorCalibration", DataModels.ColorCalibration.self)
        .flatMap { ProjectFormat.ColorCalibration(rawValue: $0.rawValue) },
      expandPromptToJson: d.bool("expandPromptToJson", false)
    )
  }

  /// Typed reads from a dump, with the schema's defaults for missing keys.
  private struct Dump {
    var values: [String: JSONValue]
    init(_ values: [String: JSONValue]) { self.values = values }

    func int(_ key: String, _ fallback: Int) -> Int {
      if case .number(let value)? = values[key] { return Int(value) }
      return fallback
    }
    func float(_ key: String, _ fallback: Float) -> Float {
      if case .number(let value)? = values[key] { return Float(value) }
      return fallback
    }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
      if case .bool(let value)? = values[key] { return value }
      return fallback
    }
    /// Empty strings read as nil, as in the engine's bridge.
    func string(_ key: String) -> String? {
      if case .string(let value)? = values[key], !value.isEmpty { return value }
      return nil
    }
    func enumeration<E: CaseIterable>(_ key: String, _ type: E.Type) -> E? {
      guard case .string(let name)? = values[key] else { return nil }
      return E.allCases.first { String(describing: $0) == name }
    }
    func objects(_ key: String) -> [Dump] {
      guard case .array(let items)? = values[key] else { return [] }
      return items.compactMap {
        if case .object(let fields) = $0 { return Dump(fields) }
        return nil
      }
    }
    func strings(_ key: String) -> [String] {
      guard case .array(let items)? = values[key] else { return [] }
      return items.compactMap {
        if case .string(let value) = $0 { return value }
        return nil
      }
    }
  }

  /// A node's settings in the history dump format (`JSONValue.fields(of: configuration)`): MGK's
  /// field names, enums as their DataModels case names.
  static func dump(of node: TensorHistoryNode) -> [String: JSONValue] {
    func n<T: BinaryInteger>(_ value: T) -> JSONValue { .number(Double(value)) }
    func f(_ value: Float) -> JSONValue { JSONValue(value) }
    func s(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    func e(_ value: Any?) -> JSONValue { value.map { JSONValue($0) } ?? .null }
    let causal = node.causalInferenceEnabled
    return [
      "model": s(node.model),
      "width": n(Int(node.startWidth) * 64),
      "height": n(Int(node.startHeight) * 64),
      "seed": n(node.seed),
      "steps": n(node.steps),
      "guidanceScale": f(node.guidanceScale),
      "strength": f(node.strength),
      "seedMode": e(DataModels.SeedMode(rawValue: node.seedMode.rawValue)),
      "clipSkip": n(node.clipSkip),
      "batchCount": n(1),
      "batchSize": n(node.batchSize),
      "numFrames": n(node.numFrames),
      "fps": n(node.fpsId),
      "motionScale": n(node.motionBucketId),
      "sampler": e(DataModels.SamplerType(rawValue: node.sampler.rawValue)),
      "hiresFix": .bool(node.hiresFix),
      "hiresFixWidth": n(Int(node.hiresFixStartWidth) * 64),
      "hiresFixHeight": n(Int(node.hiresFixStartHeight) * 64),
      "hiresFixStrength": f(node.hiresFixStrength),
      "tiledDecoding": .bool(node.tiledDecoding),
      "decodingTileWidth": n(Int(node.decodingTileWidth) * 64),
      "decodingTileHeight": n(Int(node.decodingTileHeight) * 64),
      "decodingTileOverlap": n(Int(node.decodingTileOverlap) * 64),
      "tiledDiffusion": .bool(node.tiledDiffusion),
      "diffusionTileWidth": n(Int(node.diffusionTileWidth) * 64),
      "diffusionTileHeight": n(Int(node.diffusionTileHeight) * 64),
      "diffusionTileOverlap": n(Int(node.diffusionTileOverlap) * 64),
      "upscaler": s(node.upscaler),
      "upscalerScaleFactor": n(node.upscalerScaleFactor),
      "imageGuidanceScale": f(node.imageGuidanceScale),
      "loras": .array(
        node.loras.map {
          JSONValue(
            DataModels.LoRA(
              file: $0.file, weight: $0.weight, mode: DataModels.LoRAMode(rawValue: $0.mode.rawValue)
            ))
        }),
      "controls": .array(node.controls.map { JSONValue(control($0)) }),
      "maskBlur": f(node.maskBlur),
      "maskBlurOutset": n(node.maskBlurOutset),
      "sharpness": f(node.sharpness),
      "faceRestoration": s(node.faceRestoration),
      "clipWeight": f(node.clipWeight),
      "negativePromptForImagePrior": .bool(node.negativePromptForImagePrior),
      "imagePriorSteps": n(node.imagePriorSteps),
      "refinerModel": s(node.refinerModel),
      "originalImageHeight": n(node.originalImageHeight),
      "originalImageWidth": n(node.originalImageWidth),
      "cropTop": n(node.cropTop),
      "cropLeft": n(node.cropLeft),
      "targetImageHeight": n(node.targetImageHeight),
      "targetImageWidth": n(node.targetImageWidth),
      "aestheticScore": f(node.aestheticScore),
      "negativeAestheticScore": f(node.negativeAestheticScore),
      "zeroNegativePrompt": .bool(node.zeroNegativePrompt),
      "refinerStart": f(node.refinerStart),
      "negativeOriginalImageHeight": n(node.negativeOriginalImageHeight),
      "negativeOriginalImageWidth": n(node.negativeOriginalImageWidth),
      "guidingFrameNoise": f(node.condAug),
      "startFrameGuidance": f(node.startFrameCfg),
      "shift": f(node.shift),
      "stage2Steps": n(node.stage2Steps),
      "stage2Guidance": f(node.stage2Cfg),
      "stage2Shift": f(node.stage2Shift),
      "stochasticSamplingGamma": f(node.stochasticSamplingGamma),
      "preserveOriginalAfterInpaint": .bool(node.preserveOriginalAfterInpaint),
      "t5TextEncoder": .bool(node.t5TextEncoder),
      "separateClipL": .bool(node.separateClipL),
      "clipLText": s(node.clipLText),
      "separateOpenClipG": .bool(node.separateOpenClipG),
      "openClipGText": s(node.openClipGText),
      "speedUpWithGuidanceEmbed": .bool(node.speedUpWithGuidanceEmbed),
      "guidanceEmbed": f(node.guidanceEmbed),
      "resolutionDependentShift": .bool(node.resolutionDependentShift),
      "teaCache": .bool(node.teaCache),
      "teaCacheStart": n(node.teaCacheStart),
      "teaCacheEnd": n(node.teaCacheEnd),
      "teaCacheThreshold": f(node.teaCacheThreshold),
      "teaCacheMaxSkipSteps": n(node.teaCacheMaxSkipSteps),
      "separateT5": .bool(node.separateT5),
      "t5Text": s(node.t5Text),
      "causalInference": n(causal ? node.causalInference : 0),
      "causalInferencePad": n(causal ? node.causalInferencePad : 0),
      "cfgZeroStar": .bool(node.cfgZeroStar),
      "cfgZeroInitSteps": n(node.cfgZeroInitSteps),
      "compressionArtifacts": e(
        DataModels.CompressionMethod(rawValue: node.compressionArtifacts.rawValue)),
      "compressionArtifactsQuality": f(node.compressionArtifactsQuality),
      "colorCalibration": e(DataModels.ColorCalibration(rawValue: node.colorCalibration.rawValue)),
      "expandPromptToJson": .bool(node.expandPromptToJson),
    ]
  }

  private static func lora(_ d: Dump) -> ProjectFormat.LoRA {
    ProjectFormat.LoRA(
      file: d.string("file"), weight: d.float("weight", 0.6),
      mode: d.enumeration("mode", DataModels.LoRAMode.self).flatMap {
        ProjectFormat.LoRAMode(rawValue: $0.rawValue)
      })
  }

  private static func control(_ d: Dump) -> ProjectFormat.Control {
    ProjectFormat.Control(
      file: d.string("file"), weight: d.float("weight", 1),
      guidanceStart: d.float("guidanceStart", 0), guidanceEnd: d.float("guidanceEnd", 1),
      noPrompt: d.bool("noPrompt", false),
      globalAveragePooling: d.bool("globalAveragePooling", true),
      downSamplingRate: d.float("downSamplingRate", 1),
      controlMode: d.enumeration("controlMode", DataModels.ControlMode.self).flatMap {
        ProjectFormat.ControlMode(rawValue: $0.rawValue)
      },
      targetBlocks: d.strings("targetBlocks"),
      inputOverride: d.enumeration("inputOverride", DataModels.ControlInputType.self).flatMap {
        ProjectFormat.ControlInputType(rawValue: $0.rawValue)
      })
  }

  private static func control(_ control: ProjectFormat.Control) -> DataModels.Control {
    DataModels.Control(
      file: control.file, weight: control.weight, guidanceStart: control.guidanceStart,
      guidanceEnd: control.guidanceEnd, noPrompt: control.noPrompt,
      globalAveragePooling: control.globalAveragePooling,
      downSamplingRate: control.downSamplingRate,
      controlMode: DataModels.ControlMode(rawValue: control.controlMode.rawValue),
      targetBlocks: control.targetBlocks,
      inputOverride: DataModels.ControlInputType(rawValue: control.inputOverride.rawValue))
  }
}
