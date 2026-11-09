@preconcurrency import _MediaGenerationKit
@preconcurrency import DataModels
import Foundation
import ModelZoo
@preconcurrency import ScriptDataModels

nonisolated extension PipelineConfiguration {
  /// The engine's own configuration for these settings: MGK's fields as MGK writes them, then the
  /// ones only the app carries. For runs that call the engine directly
  /// (`GenerationEngine.generateVideo`).
  func engineConfiguration(template: GenerationConfiguration) -> GenerationConfiguration {
    let options = base.engineOptions(template: template)
    options.shiftForAudio = shiftForAudio
    options.usesSolAttention = usesSolAttention
    options.solAttentionStart = Int32(clamping: solAttentionStart)
    options.solAttentionTau = solAttentionTau
    // MiniMax H3's video decoder normalizes its rotary coordinates per tile and only decodes
    // 16-latent (256-pixel) tiles correctly; larger tiles cover the video in a ~32-pixel block grid.
    // The engine uses that size itself when tiled decoding is off (`FirstStage.decode`, the
    // `.minimaxH3` case), but passes the user's size through when it's on.
    if ModelZoo.versionForModel(base.model) == .minimaxH3 {
      options.decodingTileWidth = 256
      options.decodingTileHeight = 256
      options.decodingTileOverlap = 64
    }
    return options.createGenerationConfiguration()
  }
}

nonisolated extension MediaGenerationPipeline.Configuration {
  /// The engine's own configuration for these settings, as MGK builds it before a run
  /// (`MediaGenerationPipeline.Configuration.runtimeConfiguration`, internal there): the model's
  /// recommended template with every public field written over it, through the engine's
  /// scripting bridge. Settings MGK doesn't expose keep the template's values.
  fileprivate func engineOptions(template: GenerationConfiguration) -> JSGenerationConfiguration {
    let options = JSGenerationConfiguration(configuration: template)
    options.model = model
    options.width = UInt32(clamping: width)
    options.height = UInt32(clamping: height)
    options.seed = Int64(seed)
    options.steps = UInt32(clamping: steps)
    options.guidanceScale = guidanceScale
    options.strength = strength
    options.seedMode = seedMode.rawValue
    options.clipSkip = UInt32(clamping: clipSkip)
    options.batchCount = UInt32(clamping: batchCount)
    options.batchSize = UInt32(clamping: batchSize)
    options.numFrames = UInt32(clamping: numFrames)
    options.fps = UInt32(clamping: fps)
    options.motionScale = UInt32(clamping: motionScale)
    options.sampler = sampler.rawValue
    options.hiresFix = hiresFix
    options.hiresFixWidth = UInt32(clamping: hiresFixWidth)
    options.hiresFixHeight = UInt32(clamping: hiresFixHeight)
    options.hiresFixStrength = hiresFixStrength
    options.tiledDecoding = tiledDecoding
    options.decodingTileWidth = UInt32(clamping: decodingTileWidth)
    options.decodingTileHeight = UInt32(clamping: decodingTileHeight)
    options.decodingTileOverlap = UInt32(clamping: decodingTileOverlap)
    options.tiledDiffusion = tiledDiffusion
    options.diffusionTileWidth = UInt32(clamping: diffusionTileWidth)
    options.diffusionTileHeight = UInt32(clamping: diffusionTileHeight)
    options.diffusionTileOverlap = UInt32(clamping: diffusionTileOverlap)
    options.upscaler = upscaler
    options.upscalerScaleFactor = UInt8(clamping: upscalerScaleFactor)
    options.imageGuidanceScale = imageGuidanceScale
    options.loras = loras.map(JSLoRA.init(lora:))
    options.controls = controls.map(JSControl.init(control:))
    options.maskBlur = maskBlur
    options.maskBlurOutset = Int32(maskBlurOutset)
    options.sharpness = sharpness
    options.faceRestoration = faceRestoration
    options.clipWeight = clipWeight
    options.negativePromptForImagePrior = negativePromptForImagePrior
    options.imagePriorSteps = UInt32(clamping: imagePriorSteps)
    options.refinerModel = refinerModel
    options.originalImageHeight = UInt32(clamping: originalImageHeight)
    options.originalImageWidth = UInt32(clamping: originalImageWidth)
    options.cropTop = Int32(cropTop)
    options.cropLeft = Int32(cropLeft)
    options.targetImageHeight = UInt32(clamping: targetImageHeight)
    options.targetImageWidth = UInt32(clamping: targetImageWidth)
    options.aestheticScore = aestheticScore
    options.negativeAestheticScore = negativeAestheticScore
    options.zeroNegativePrompt = zeroNegativePrompt
    options.refinerStart = refinerStart
    options.negativeOriginalImageHeight = UInt32(clamping: negativeOriginalImageHeight)
    options.negativeOriginalImageWidth = UInt32(clamping: negativeOriginalImageWidth)
    options.guidingFrameNoise = guidingFrameNoise
    options.startFrameGuidance = startFrameGuidance
    options.shift = shift
    options.stage2Steps = UInt32(clamping: stage2Steps)
    options.stage2Guidance = stage2Guidance
    options.stage2Shift = stage2Shift
    options.stochasticSamplingGamma = stochasticSamplingGamma
    options.preserveOriginalAfterInpaint = preserveOriginalAfterInpaint
    options.t5TextEncoder = t5TextEncoder
    options.separateClipL = separateClipL
    options.clipLText = clipLText
    options.separateOpenClipG = separateOpenClipG
    options.openClipGText = openClipGText
    options.speedUpWithGuidanceEmbed = speedUpWithGuidanceEmbed
    options.guidanceEmbed = guidanceEmbed
    options.resolutionDependentShift = resolutionDependentShift
    options.teaCache = teaCache
    options.teaCacheStart = Int32(teaCacheStart)
    options.teaCacheEnd = Int32(teaCacheEnd)
    options.teaCacheThreshold = teaCacheThreshold
    options.teaCacheMaxSkipSteps = Int32(teaCacheMaxSkipSteps)
    options.separateT5 = separateT5
    options.t5Text = t5Text
    options.causalInference = Int32(causalInference)
    options.causalInferencePad = Int32(causalInferencePad)
    options.cfgZeroStar = cfgZeroStar
    options.cfgZeroInitSteps = Int32(cfgZeroInitSteps)
    options.compressionArtifacts = compressionArtifactsName
    options.compressionArtifactsQuality = compressionArtifactsQuality
    options.colorCalibration = colorCalibrationName
    options.expandPromptToJson = expandPromptToJson
    return options
  }

  private var compressionArtifactsName: String {
    switch compressionArtifacts {
    case .disabled: "disabled"
    case .H264: "h264"
    case .H265: "h265"
    case .jpeg: "jpeg"
    }
  }

  private var colorCalibrationName: String {
    switch colorCalibration {
    case .disabled: "none"
    case .lab: "lab"
    }
  }
}
