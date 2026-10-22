import Dflat
import FlatBuffers
import Foundation
import SQLiteDflat
import SQLite3

public enum SamplerType: Int8, DflatFriendlyValue, CaseIterable {
  case dPMPP2MKarras = 0
  case eulerA = 1
  case DDIM = 2
  case PLMS = 3
  case dPMPPSDEKarras = 4
  case uniPC = 5
  case LCM = 6
  case eulerASubstep = 7
  case dPMPPSDESubstep = 8
  case TCD = 9
  case eulerATrailing = 10
  case dPMPPSDETrailing = 11
  case DPMPP2MAYS = 12
  case eulerAAYS = 13
  case DPMPPSDEAYS = 14
  case dPMPP2MTrailing = 15
  case dDIMTrailing = 16
  case uniPCTrailing = 17
  case uniPCAYS = 18
  case tCDTrailing = 19
  public static func < (lhs: SamplerType, rhs: SamplerType) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public enum SeedMode: Int8, DflatFriendlyValue, CaseIterable {
  case legacy = 0
  case torchCpuCompatible = 1
  case scaleAlike = 2
  case nvidiaGpuCompatible = 3
  public static func < (lhs: SeedMode, rhs: SeedMode) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public enum ControlMode: Int8, DflatFriendlyValue, CaseIterable {
  case balanced = 0
  case prompt = 1
  case control = 2
  public static func < (lhs: ControlMode, rhs: ControlMode) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public enum ControlInputType: Int8, DflatFriendlyValue, CaseIterable {
  case unspecified = 0
  case custom = 1
  case depth = 2
  case canny = 3
  case scribble = 4
  case pose = 5
  case normalbae = 6
  case color = 7
  case lineart = 8
  case softedge = 9
  case seg = 10
  case inpaint = 11
  case ip2p = 12
  case shuffle = 13
  case mlsd = 14
  case tile = 15
  case blur = 16
  case lowquality = 17
  case gray = 18
  public static func < (lhs: ControlInputType, rhs: ControlInputType) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public enum LoRAMode: Int8, DflatFriendlyValue, CaseIterable {
  case all = 0
  case base = 1
  case refiner = 2
  public static func < (lhs: LoRAMode, rhs: LoRAMode) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public enum Reason: Int32, DflatFriendlyValue, CaseIterable {
  case other = 0
  case generate = 1
  case imported = 2
  case draw = 3
  case mask = 4
  case scribble = 5
  case moodboard = 6
  case depthMap = 7
  case clear = 8
  public static func < (lhs: Reason, rhs: Reason) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public enum CompressionMethod: Int8, DflatFriendlyValue, CaseIterable {
  case disabled = 0
  case H264 = 1
  case H265 = 2
  case jpeg = 3
  public static func < (lhs: CompressionMethod, rhs: CompressionMethod) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public enum ColorCalibration: Int8, DflatFriendlyValue, CaseIterable {
  case disabled = 0
  case lab = 1
  public static func < (lhs: ColorCalibration, rhs: ColorCalibration) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public struct Control: Equatable, FlatBuffersDecodable {
  public var file: String?
  public var weight: Float32
  public var guidanceStart: Float32
  public var guidanceEnd: Float32
  public var noPrompt: Bool
  public var globalAveragePooling: Bool
  public var downSamplingRate: Float32
  public var controlMode: ControlMode
  public var targetBlocks: [String]
  public var inputOverride: ControlInputType
  public init(file: String? = nil, weight: Float32? = 1.0, guidanceStart: Float32? = 0.0, guidanceEnd: Float32? = 1.0, noPrompt: Bool? = false, globalAveragePooling: Bool? = true, downSamplingRate: Float32? = 1.0, controlMode: ControlMode? = .balanced, targetBlocks: [String]? = [], inputOverride: ControlInputType? = .unspecified) {
    self.file = file ?? nil
    self.weight = weight ?? 1.0
    self.guidanceStart = guidanceStart ?? 0.0
    self.guidanceEnd = guidanceEnd ?? 1.0
    self.noPrompt = noPrompt ?? false
    self.globalAveragePooling = globalAveragePooling ?? true
    self.downSamplingRate = downSamplingRate ?? 1.0
    self.controlMode = controlMode ?? .balanced
    self.targetBlocks = targetBlocks ?? []
    self.inputOverride = inputOverride ?? .unspecified
  }
  public init(_ obj: zzz_DflatGen_Control) {
    self.file = obj.file
    self.weight = obj.weight
    self.guidanceStart = obj.guidanceStart
    self.guidanceEnd = obj.guidanceEnd
    self.noPrompt = obj.noPrompt
    self.globalAveragePooling = obj.globalAveragePooling
    self.downSamplingRate = obj.downSamplingRate
    self.controlMode = ControlMode(rawValue: obj.controlMode.rawValue) ?? .balanced
    var __targetBlocks = [String]()
    for i: Int32 in 0..<obj.targetBlocksCount {
      guard let o = obj.targetBlocks(at: i) else { break }
      __targetBlocks.append(String(o))
    }
    self.targetBlocks = __targetBlocks
    self.inputOverride = ControlInputType(rawValue: obj.inputOverride.rawValue) ?? .unspecified
  }

  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_Control.getRootAsControl(bb: bb))
  }

  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_Control>.verify(&verifier, at: 0, of: zzz_DflatGen_Control.self)
      return true
    } catch {
      return false
    }
  }

  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
}

public struct LoRA: Equatable, FlatBuffersDecodable {
  public var file: String?
  public var weight: Float32
  public var mode: LoRAMode
  public init(file: String? = nil, weight: Float32? = 0.6, mode: LoRAMode? = .all) {
    self.file = file ?? nil
    self.weight = weight ?? 0.6
    self.mode = mode ?? .all
  }
  public init(_ obj: zzz_DflatGen_LoRA) {
    self.file = obj.file
    self.weight = obj.weight
    self.mode = LoRAMode(rawValue: obj.mode.rawValue) ?? .all
  }

  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_LoRA.getRootAsLoRA(bb: bb))
  }

  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_LoRA>.verify(&verifier, at: 0, of: zzz_DflatGen_LoRA.self)
      return true
    } catch {
      return false
    }
  }

  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
}

public final class TensorHistoryNode: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable, Equatable {
  public static func == (lhs: TensorHistoryNode, rhs: TensorHistoryNode) -> Bool {
    guard lhs.lineage == rhs.lineage else { return false }
    guard lhs.logicalTime == rhs.logicalTime else { return false }
    guard lhs.startWidth == rhs.startWidth else { return false }
    guard lhs.startHeight == rhs.startHeight else { return false }
    guard lhs.seed == rhs.seed else { return false }
    guard lhs.steps == rhs.steps else { return false }
    guard lhs.guidanceScale == rhs.guidanceScale else { return false }
    guard lhs.strength == rhs.strength else { return false }
    guard lhs.model == rhs.model else { return false }
    guard lhs.tensorId == rhs.tensorId else { return false }
    guard lhs.maskId == rhs.maskId else { return false }
    guard lhs.wallClock == rhs.wallClock else { return false }
    guard lhs.textEdits == rhs.textEdits else { return false }
    guard lhs.textLineage == rhs.textLineage else { return false }
    guard lhs.batchSize == rhs.batchSize else { return false }
    guard lhs.sampler == rhs.sampler else { return false }
    guard lhs.hiresFix == rhs.hiresFix else { return false }
    guard lhs.hiresFixStartWidth == rhs.hiresFixStartWidth else { return false }
    guard lhs.hiresFixStartHeight == rhs.hiresFixStartHeight else { return false }
    guard lhs.hiresFixStrength == rhs.hiresFixStrength else { return false }
    guard lhs.upscaler == rhs.upscaler else { return false }
    guard lhs.scaleFactor == rhs.scaleFactor else { return false }
    guard lhs.depthMapId == rhs.depthMapId else { return false }
    guard lhs.generated == rhs.generated else { return false }
    guard lhs.imageGuidanceScale == rhs.imageGuidanceScale else { return false }
    guard lhs.seedMode == rhs.seedMode else { return false }
    guard lhs.clipSkip == rhs.clipSkip else { return false }
    guard lhs.controls == rhs.controls else { return false }
    guard lhs.scribbleId == rhs.scribbleId else { return false }
    guard lhs.poseId == rhs.poseId else { return false }
    guard lhs.loras == rhs.loras else { return false }
    guard lhs.colorPaletteId == rhs.colorPaletteId else { return false }
    guard lhs.maskBlur == rhs.maskBlur else { return false }
    guard lhs.customId == rhs.customId else { return false }
    guard lhs.faceRestoration == rhs.faceRestoration else { return false }
    guard lhs.clipWeight == rhs.clipWeight else { return false }
    guard lhs.negativePromptForImagePrior == rhs.negativePromptForImagePrior else { return false }
    guard lhs.imagePriorSteps == rhs.imagePriorSteps else { return false }
    guard lhs.dataStored == rhs.dataStored else { return false }
    guard lhs.previewId == rhs.previewId else { return false }
    guard lhs.contentOffsetX == rhs.contentOffsetX else { return false }
    guard lhs.contentOffsetY == rhs.contentOffsetY else { return false }
    guard lhs.scaleFactorBy120 == rhs.scaleFactorBy120 else { return false }
    guard lhs.refinerModel == rhs.refinerModel else { return false }
    guard lhs.originalImageHeight == rhs.originalImageHeight else { return false }
    guard lhs.originalImageWidth == rhs.originalImageWidth else { return false }
    guard lhs.cropTop == rhs.cropTop else { return false }
    guard lhs.cropLeft == rhs.cropLeft else { return false }
    guard lhs.targetImageHeight == rhs.targetImageHeight else { return false }
    guard lhs.targetImageWidth == rhs.targetImageWidth else { return false }
    guard lhs.aestheticScore == rhs.aestheticScore else { return false }
    guard lhs.negativeAestheticScore == rhs.negativeAestheticScore else { return false }
    guard lhs.zeroNegativePrompt == rhs.zeroNegativePrompt else { return false }
    guard lhs.refinerStart == rhs.refinerStart else { return false }
    guard lhs.negativeOriginalImageHeight == rhs.negativeOriginalImageHeight else { return false }
    guard lhs.negativeOriginalImageWidth == rhs.negativeOriginalImageWidth else { return false }
    guard lhs.shuffleDataStored == rhs.shuffleDataStored else { return false }
    guard lhs.fpsId == rhs.fpsId else { return false }
    guard lhs.motionBucketId == rhs.motionBucketId else { return false }
    guard lhs.condAug == rhs.condAug else { return false }
    guard lhs.startFrameCfg == rhs.startFrameCfg else { return false }
    guard lhs.numFrames == rhs.numFrames else { return false }
    guard lhs.maskBlurOutset == rhs.maskBlurOutset else { return false }
    guard lhs.sharpness == rhs.sharpness else { return false }
    guard lhs.shift == rhs.shift else { return false }
    guard lhs.stage2Steps == rhs.stage2Steps else { return false }
    guard lhs.stage2Cfg == rhs.stage2Cfg else { return false }
    guard lhs.stage2Shift == rhs.stage2Shift else { return false }
    guard lhs.tiledDecoding == rhs.tiledDecoding else { return false }
    guard lhs.decodingTileWidth == rhs.decodingTileWidth else { return false }
    guard lhs.decodingTileHeight == rhs.decodingTileHeight else { return false }
    guard lhs.decodingTileOverlap == rhs.decodingTileOverlap else { return false }
    guard lhs.stochasticSamplingGamma == rhs.stochasticSamplingGamma else { return false }
    guard lhs.preserveOriginalAfterInpaint == rhs.preserveOriginalAfterInpaint else { return false }
    guard lhs.tiledDiffusion == rhs.tiledDiffusion else { return false }
    guard lhs.diffusionTileWidth == rhs.diffusionTileWidth else { return false }
    guard lhs.diffusionTileHeight == rhs.diffusionTileHeight else { return false }
    guard lhs.diffusionTileOverlap == rhs.diffusionTileOverlap else { return false }
    guard lhs.upscalerScaleFactor == rhs.upscalerScaleFactor else { return false }
    guard lhs.scriptSessionId == rhs.scriptSessionId else { return false }
    guard lhs.t5TextEncoder == rhs.t5TextEncoder else { return false }
    guard lhs.separateClipL == rhs.separateClipL else { return false }
    guard lhs.clipLText == rhs.clipLText else { return false }
    guard lhs.separateOpenClipG == rhs.separateOpenClipG else { return false }
    guard lhs.openClipGText == rhs.openClipGText else { return false }
    guard lhs.speedUpWithGuidanceEmbed == rhs.speedUpWithGuidanceEmbed else { return false }
    guard lhs.guidanceEmbed == rhs.guidanceEmbed else { return false }
    guard lhs.resolutionDependentShift == rhs.resolutionDependentShift else { return false }
    guard lhs.profileData == rhs.profileData else { return false }
    guard lhs.teaCacheStart == rhs.teaCacheStart else { return false }
    guard lhs.teaCacheEnd == rhs.teaCacheEnd else { return false }
    guard lhs.teaCacheThreshold == rhs.teaCacheThreshold else { return false }
    guard lhs.teaCache == rhs.teaCache else { return false }
    guard lhs.separateT5 == rhs.separateT5 else { return false }
    guard lhs.t5Text == rhs.t5Text else { return false }
    guard lhs.teaCacheMaxSkipSteps == rhs.teaCacheMaxSkipSteps else { return false }
    guard lhs.textPrompt == rhs.textPrompt else { return false }
    guard lhs.negativeTextPrompt == rhs.negativeTextPrompt else { return false }
    guard lhs.clipId == rhs.clipId else { return false }
    guard lhs.indexInAClip == rhs.indexInAClip else { return false }
    guard lhs.causalInferenceEnabled == rhs.causalInferenceEnabled else { return false }
    guard lhs.causalInference == rhs.causalInference else { return false }
    guard lhs.causalInferencePad == rhs.causalInferencePad else { return false }
    guard lhs.cfgZeroStar == rhs.cfgZeroStar else { return false }
    guard lhs.cfgZeroInitSteps == rhs.cfgZeroInitSteps else { return false }
    guard lhs.generationTime == rhs.generationTime else { return false }
    guard lhs.reason == rhs.reason else { return false }
    guard lhs.compressionArtifacts == rhs.compressionArtifacts else { return false }
    guard lhs.compressionArtifactsQuality == rhs.compressionArtifactsQuality else { return false }
    guard lhs.audio == rhs.audio else { return false }
    guard lhs.colorCalibration == rhs.colorCalibration else { return false }
    guard lhs.expandPromptToJson == rhs.expandPromptToJson else { return false }
    guard lhs.shiftForAudio == rhs.shiftForAudio else { return false }
    guard lhs.usesSolAttention == rhs.usesSolAttention else { return false }
    guard lhs.solAttentionStart == rhs.solAttentionStart else { return false }
    guard lhs.solAttentionTau == rhs.solAttentionTau else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let lineage: Int64
  public let logicalTime: Int64
  public let startWidth: UInt16
  public let startHeight: UInt16
  public let seed: UInt32
  public let steps: UInt32
  public let guidanceScale: Float32
  public let strength: Float32
  public let model: String?
  public let tensorId: Int64
  public let maskId: Int64
  public let wallClock: Int64
  public let textEdits: Int64
  public let textLineage: Int64
  public let batchSize: UInt32
  public let sampler: SamplerType
  public let hiresFix: Bool
  public let hiresFixStartWidth: UInt16
  public let hiresFixStartHeight: UInt16
  public let hiresFixStrength: Float32
  public let upscaler: String?
  public let scaleFactor: UInt16
  public let depthMapId: Int64
  public let generated: Bool
  public let imageGuidanceScale: Float32
  public let seedMode: SeedMode
  public let clipSkip: UInt32
  public let controls: [Control]
  public let scribbleId: Int64
  public let poseId: Int64
  public let loras: [LoRA]
  public let colorPaletteId: Int64
  public let maskBlur: Float32
  public let customId: Int64
  public let faceRestoration: String?
  public let clipWeight: Float32
  public let negativePromptForImagePrior: Bool
  public let imagePriorSteps: UInt32
  public let dataStored: Int32
  public let previewId: Int64
  public let contentOffsetX: Int32
  public let contentOffsetY: Int32
  public let scaleFactorBy120: Int32
  public let refinerModel: String?
  public let originalImageHeight: UInt32
  public let originalImageWidth: UInt32
  public let cropTop: Int32
  public let cropLeft: Int32
  public let targetImageHeight: UInt32
  public let targetImageWidth: UInt32
  public let aestheticScore: Float32
  public let negativeAestheticScore: Float32
  public let zeroNegativePrompt: Bool
  public let refinerStart: Float32
  public let negativeOriginalImageHeight: UInt32
  public let negativeOriginalImageWidth: UInt32
  public let shuffleDataStored: Int32
  public let fpsId: UInt32
  public let motionBucketId: UInt32
  public let condAug: Float32
  public let startFrameCfg: Float32
  public let numFrames: UInt32
  public let maskBlurOutset: Int32
  public let sharpness: Float32
  public let shift: Float32
  public let stage2Steps: UInt32
  public let stage2Cfg: Float32
  public let stage2Shift: Float32
  public let tiledDecoding: Bool
  public let decodingTileWidth: UInt16
  public let decodingTileHeight: UInt16
  public let decodingTileOverlap: UInt16
  public let stochasticSamplingGamma: Float32
  public let preserveOriginalAfterInpaint: Bool
  public let tiledDiffusion: Bool
  public let diffusionTileWidth: UInt16
  public let diffusionTileHeight: UInt16
  public let diffusionTileOverlap: UInt16
  public let upscalerScaleFactor: UInt8
  public let scriptSessionId: UInt64
  public let t5TextEncoder: Bool
  public let separateClipL: Bool
  public let clipLText: String?
  public let separateOpenClipG: Bool
  public let openClipGText: String?
  public let speedUpWithGuidanceEmbed: Bool
  public let guidanceEmbed: Float32
  public let resolutionDependentShift: Bool
  public let profileData: [UInt8]
  public let teaCacheStart: Int32
  public let teaCacheEnd: Int32
  public let teaCacheThreshold: Float32
  public let teaCache: Bool
  public let separateT5: Bool
  public let t5Text: String?
  public let teaCacheMaxSkipSteps: Int32
  public let textPrompt: String?
  public let negativeTextPrompt: String?
  public let clipId: Int64
  public let indexInAClip: Int32
  public let causalInferenceEnabled: Bool
  public let causalInference: Int32
  public let causalInferencePad: Int32
  public let cfgZeroStar: Bool
  public let cfgZeroInitSteps: Int32
  public let generationTime: Double
  public let reason: Reason
  public let compressionArtifacts: CompressionMethod
  public let compressionArtifactsQuality: Float32
  public let audio: Bool
  public let colorCalibration: ColorCalibration
  public let expandPromptToJson: Bool
  public let shiftForAudio: Float32
  public let usesSolAttention: Bool
  public let solAttentionStart: Int32
  public let solAttentionTau: Float32
  public init(lineage: Int64, logicalTime: Int64, startWidth: UInt16? = 0, startHeight: UInt16? = 0, seed: UInt32? = 0, steps: UInt32? = 0, guidanceScale: Float32? = 0.0, strength: Float32? = 0.0, model: String? = nil, tensorId: Int64? = 0, maskId: Int64? = 0, wallClock: Int64? = 0, textEdits: Int64? = -1, textLineage: Int64? = -1, batchSize: UInt32? = 1, sampler: SamplerType? = .dPMPP2MKarras, hiresFix: Bool? = false, hiresFixStartWidth: UInt16? = 0, hiresFixStartHeight: UInt16? = 0, hiresFixStrength: Float32? = 0.7, upscaler: String? = nil, scaleFactor: UInt16? = 1, depthMapId: Int64? = 0, generated: Bool? = true, imageGuidanceScale: Float32? = 1.5, seedMode: SeedMode? = .legacy, clipSkip: UInt32? = 1, controls: [Control]? = [], scribbleId: Int64? = 0, poseId: Int64? = 0, loras: [LoRA]? = [], colorPaletteId: Int64? = 0, maskBlur: Float32? = 0.0, customId: Int64? = 0, faceRestoration: String? = nil, clipWeight: Float32? = 1.0, negativePromptForImagePrior: Bool? = true, imagePriorSteps: UInt32? = 5, dataStored: Int32? = 0, previewId: Int64? = 0, contentOffsetX: Int32? = 0, contentOffsetY: Int32? = 0, scaleFactorBy120: Int32? = 120, refinerModel: String? = nil, originalImageHeight: UInt32? = 0, originalImageWidth: UInt32? = 0, cropTop: Int32? = 0, cropLeft: Int32? = 0, targetImageHeight: UInt32? = 0, targetImageWidth: UInt32? = 0, aestheticScore: Float32? = 0.0, negativeAestheticScore: Float32? = 0.0, zeroNegativePrompt: Bool? = false, refinerStart: Float32? = 0.0, negativeOriginalImageHeight: UInt32? = 0, negativeOriginalImageWidth: UInt32? = 0, shuffleDataStored: Int32? = 0, fpsId: UInt32? = 5, motionBucketId: UInt32? = 127, condAug: Float32? = 0.02, startFrameCfg: Float32? = 1.0, numFrames: UInt32? = 14, maskBlurOutset: Int32? = 0, sharpness: Float32? = 0.0, shift: Float32? = 1.0, stage2Steps: UInt32? = 10, stage2Cfg: Float32? = 1.0, stage2Shift: Float32? = 1.0, tiledDecoding: Bool? = false, decodingTileWidth: UInt16? = 10, decodingTileHeight: UInt16? = 10, decodingTileOverlap: UInt16? = 2, stochasticSamplingGamma: Float32? = 0.3, preserveOriginalAfterInpaint: Bool? = true, tiledDiffusion: Bool? = false, diffusionTileWidth: UInt16? = 16, diffusionTileHeight: UInt16? = 16, diffusionTileOverlap: UInt16? = 2, upscalerScaleFactor: UInt8? = 0, scriptSessionId: UInt64? = 0, t5TextEncoder: Bool? = true, separateClipL: Bool? = false, clipLText: String? = nil, separateOpenClipG: Bool? = false, openClipGText: String? = nil, speedUpWithGuidanceEmbed: Bool? = true, guidanceEmbed: Float32? = 3.5, resolutionDependentShift: Bool? = true, profileData: [UInt8]? = [], teaCacheStart: Int32? = 5, teaCacheEnd: Int32? = -1, teaCacheThreshold: Float32? = 0.06, teaCache: Bool? = false, separateT5: Bool? = false, t5Text: String? = nil, teaCacheMaxSkipSteps: Int32? = 3, textPrompt: String? = nil, negativeTextPrompt: String? = nil, clipId: Int64? = -1, indexInAClip: Int32? = 0, causalInferenceEnabled: Bool? = false, causalInference: Int32? = 3, causalInferencePad: Int32? = 0, cfgZeroStar: Bool? = false, cfgZeroInitSteps: Int32? = 0, generationTime: Double? = 0.0, reason: Reason? = .other, compressionArtifacts: CompressionMethod? = .disabled, compressionArtifactsQuality: Float32? = 43.1, audio: Bool? = false, colorCalibration: ColorCalibration? = .disabled, expandPromptToJson: Bool? = false, shiftForAudio: Float32? = 3.0, usesSolAttention: Bool? = false, solAttentionStart: Int32? = 2, solAttentionTau: Float32? = 0.5) {
    self.lineage = lineage
    self.logicalTime = logicalTime
    self.startWidth = startWidth ?? 0
    self.startHeight = startHeight ?? 0
    self.seed = seed ?? 0
    self.steps = steps ?? 0
    self.guidanceScale = guidanceScale ?? 0.0
    self.strength = strength ?? 0.0
    self.model = model ?? nil
    self.tensorId = tensorId ?? 0
    self.maskId = maskId ?? 0
    self.wallClock = wallClock ?? 0
    self.textEdits = textEdits ?? -1
    self.textLineage = textLineage ?? -1
    self.batchSize = batchSize ?? 1
    self.sampler = sampler ?? .dPMPP2MKarras
    self.hiresFix = hiresFix ?? false
    self.hiresFixStartWidth = hiresFixStartWidth ?? 0
    self.hiresFixStartHeight = hiresFixStartHeight ?? 0
    self.hiresFixStrength = hiresFixStrength ?? 0.7
    self.upscaler = upscaler ?? nil
    self.scaleFactor = scaleFactor ?? 1
    self.depthMapId = depthMapId ?? 0
    self.generated = generated ?? true
    self.imageGuidanceScale = imageGuidanceScale ?? 1.5
    self.seedMode = seedMode ?? .legacy
    self.clipSkip = clipSkip ?? 1
    self.controls = controls ?? []
    self.scribbleId = scribbleId ?? 0
    self.poseId = poseId ?? 0
    self.loras = loras ?? []
    self.colorPaletteId = colorPaletteId ?? 0
    self.maskBlur = maskBlur ?? 0.0
    self.customId = customId ?? 0
    self.faceRestoration = faceRestoration ?? nil
    self.clipWeight = clipWeight ?? 1.0
    self.negativePromptForImagePrior = negativePromptForImagePrior ?? true
    self.imagePriorSteps = imagePriorSteps ?? 5
    self.dataStored = dataStored ?? 0
    self.previewId = previewId ?? 0
    self.contentOffsetX = contentOffsetX ?? 0
    self.contentOffsetY = contentOffsetY ?? 0
    self.scaleFactorBy120 = scaleFactorBy120 ?? 120
    self.refinerModel = refinerModel ?? nil
    self.originalImageHeight = originalImageHeight ?? 0
    self.originalImageWidth = originalImageWidth ?? 0
    self.cropTop = cropTop ?? 0
    self.cropLeft = cropLeft ?? 0
    self.targetImageHeight = targetImageHeight ?? 0
    self.targetImageWidth = targetImageWidth ?? 0
    self.aestheticScore = aestheticScore ?? 0.0
    self.negativeAestheticScore = negativeAestheticScore ?? 0.0
    self.zeroNegativePrompt = zeroNegativePrompt ?? false
    self.refinerStart = refinerStart ?? 0.0
    self.negativeOriginalImageHeight = negativeOriginalImageHeight ?? 0
    self.negativeOriginalImageWidth = negativeOriginalImageWidth ?? 0
    self.shuffleDataStored = shuffleDataStored ?? 0
    self.fpsId = fpsId ?? 5
    self.motionBucketId = motionBucketId ?? 127
    self.condAug = condAug ?? 0.02
    self.startFrameCfg = startFrameCfg ?? 1.0
    self.numFrames = numFrames ?? 14
    self.maskBlurOutset = maskBlurOutset ?? 0
    self.sharpness = sharpness ?? 0.0
    self.shift = shift ?? 1.0
    self.stage2Steps = stage2Steps ?? 10
    self.stage2Cfg = stage2Cfg ?? 1.0
    self.stage2Shift = stage2Shift ?? 1.0
    self.tiledDecoding = tiledDecoding ?? false
    self.decodingTileWidth = decodingTileWidth ?? 10
    self.decodingTileHeight = decodingTileHeight ?? 10
    self.decodingTileOverlap = decodingTileOverlap ?? 2
    self.stochasticSamplingGamma = stochasticSamplingGamma ?? 0.3
    self.preserveOriginalAfterInpaint = preserveOriginalAfterInpaint ?? true
    self.tiledDiffusion = tiledDiffusion ?? false
    self.diffusionTileWidth = diffusionTileWidth ?? 16
    self.diffusionTileHeight = diffusionTileHeight ?? 16
    self.diffusionTileOverlap = diffusionTileOverlap ?? 2
    self.upscalerScaleFactor = upscalerScaleFactor ?? 0
    self.scriptSessionId = scriptSessionId ?? 0
    self.t5TextEncoder = t5TextEncoder ?? true
    self.separateClipL = separateClipL ?? false
    self.clipLText = clipLText ?? nil
    self.separateOpenClipG = separateOpenClipG ?? false
    self.openClipGText = openClipGText ?? nil
    self.speedUpWithGuidanceEmbed = speedUpWithGuidanceEmbed ?? true
    self.guidanceEmbed = guidanceEmbed ?? 3.5
    self.resolutionDependentShift = resolutionDependentShift ?? true
    self.profileData = profileData ?? []
    self.teaCacheStart = teaCacheStart ?? 5
    self.teaCacheEnd = teaCacheEnd ?? -1
    self.teaCacheThreshold = teaCacheThreshold ?? 0.06
    self.teaCache = teaCache ?? false
    self.separateT5 = separateT5 ?? false
    self.t5Text = t5Text ?? nil
    self.teaCacheMaxSkipSteps = teaCacheMaxSkipSteps ?? 3
    self.textPrompt = textPrompt ?? nil
    self.negativeTextPrompt = negativeTextPrompt ?? nil
    self.clipId = clipId ?? -1
    self.indexInAClip = indexInAClip ?? 0
    self.causalInferenceEnabled = causalInferenceEnabled ?? false
    self.causalInference = causalInference ?? 3
    self.causalInferencePad = causalInferencePad ?? 0
    self.cfgZeroStar = cfgZeroStar ?? false
    self.cfgZeroInitSteps = cfgZeroInitSteps ?? 0
    self.generationTime = generationTime ?? 0.0
    self.reason = reason ?? .other
    self.compressionArtifacts = compressionArtifacts ?? .disabled
    self.compressionArtifactsQuality = compressionArtifactsQuality ?? 43.1
    self.audio = audio ?? false
    self.colorCalibration = colorCalibration ?? .disabled
    self.expandPromptToJson = expandPromptToJson ?? false
    self.shiftForAudio = shiftForAudio ?? 3.0
    self.usesSolAttention = usesSolAttention ?? false
    self.solAttentionStart = solAttentionStart ?? 2
    self.solAttentionTau = solAttentionTau ?? 0.5
  }
  public init(_ obj: zzz_DflatGen_TensorHistoryNode) {
    self.lineage = obj.lineage
    self.logicalTime = obj.logicalTime
    self.startWidth = obj.startWidth
    self.startHeight = obj.startHeight
    self.seed = obj.seed
    self.steps = obj.steps
    self.guidanceScale = obj.guidanceScale
    self.strength = obj.strength
    self.model = obj.model
    self.tensorId = obj.tensorId
    self.maskId = obj.maskId
    self.wallClock = obj.wallClock
    self.textEdits = obj.textEdits
    self.textLineage = obj.textLineage
    self.batchSize = obj.batchSize
    self.sampler = SamplerType(rawValue: obj.sampler.rawValue) ?? .dPMPP2MKarras
    self.hiresFix = obj.hiresFix
    self.hiresFixStartWidth = obj.hiresFixStartWidth
    self.hiresFixStartHeight = obj.hiresFixStartHeight
    self.hiresFixStrength = obj.hiresFixStrength
    self.upscaler = obj.upscaler
    self.scaleFactor = obj.scaleFactor
    self.depthMapId = obj.depthMapId
    self.generated = obj.generated
    self.imageGuidanceScale = obj.imageGuidanceScale
    self.seedMode = SeedMode(rawValue: obj.seedMode.rawValue) ?? .legacy
    self.clipSkip = obj.clipSkip
    var __controls = [Control]()
    for i: Int32 in 0..<obj.controlsCount {
      guard let o = obj.controls(at: i) else { break }
      __controls.append(Control(o))
    }
    self.controls = __controls
    self.scribbleId = obj.scribbleId
    self.poseId = obj.poseId
    var __loras = [LoRA]()
    for i: Int32 in 0..<obj.lorasCount {
      guard let o = obj.loras(at: i) else { break }
      __loras.append(LoRA(o))
    }
    self.loras = __loras
    self.colorPaletteId = obj.colorPaletteId
    self.maskBlur = obj.maskBlur
    self.customId = obj.customId
    self.faceRestoration = obj.faceRestoration
    self.clipWeight = obj.clipWeight
    self.negativePromptForImagePrior = obj.negativePromptForImagePrior
    self.imagePriorSteps = obj.imagePriorSteps
    self.dataStored = obj.dataStored
    self.previewId = obj.previewId
    self.contentOffsetX = obj.contentOffsetX
    self.contentOffsetY = obj.contentOffsetY
    self.scaleFactorBy120 = obj.scaleFactorBy120
    self.refinerModel = obj.refinerModel
    self.originalImageHeight = obj.originalImageHeight
    self.originalImageWidth = obj.originalImageWidth
    self.cropTop = obj.cropTop
    self.cropLeft = obj.cropLeft
    self.targetImageHeight = obj.targetImageHeight
    self.targetImageWidth = obj.targetImageWidth
    self.aestheticScore = obj.aestheticScore
    self.negativeAestheticScore = obj.negativeAestheticScore
    self.zeroNegativePrompt = obj.zeroNegativePrompt
    self.refinerStart = obj.refinerStart
    self.negativeOriginalImageHeight = obj.negativeOriginalImageHeight
    self.negativeOriginalImageWidth = obj.negativeOriginalImageWidth
    self.shuffleDataStored = obj.shuffleDataStored
    self.fpsId = obj.fpsId
    self.motionBucketId = obj.motionBucketId
    self.condAug = obj.condAug
    self.startFrameCfg = obj.startFrameCfg
    self.numFrames = obj.numFrames
    self.maskBlurOutset = obj.maskBlurOutset
    self.sharpness = obj.sharpness
    self.shift = obj.shift
    self.stage2Steps = obj.stage2Steps
    self.stage2Cfg = obj.stage2Cfg
    self.stage2Shift = obj.stage2Shift
    self.tiledDecoding = obj.tiledDecoding
    self.decodingTileWidth = obj.decodingTileWidth
    self.decodingTileHeight = obj.decodingTileHeight
    self.decodingTileOverlap = obj.decodingTileOverlap
    self.stochasticSamplingGamma = obj.stochasticSamplingGamma
    self.preserveOriginalAfterInpaint = obj.preserveOriginalAfterInpaint
    self.tiledDiffusion = obj.tiledDiffusion
    self.diffusionTileWidth = obj.diffusionTileWidth
    self.diffusionTileHeight = obj.diffusionTileHeight
    self.diffusionTileOverlap = obj.diffusionTileOverlap
    self.upscalerScaleFactor = obj.upscalerScaleFactor
    self.scriptSessionId = obj.scriptSessionId
    self.t5TextEncoder = obj.t5TextEncoder
    self.separateClipL = obj.separateClipL
    self.clipLText = obj.clipLText
    self.separateOpenClipG = obj.separateOpenClipG
    self.openClipGText = obj.openClipGText
    self.speedUpWithGuidanceEmbed = obj.speedUpWithGuidanceEmbed
    self.guidanceEmbed = obj.guidanceEmbed
    self.resolutionDependentShift = obj.resolutionDependentShift
    self.profileData = obj.profileData
    self.teaCacheStart = obj.teaCacheStart
    self.teaCacheEnd = obj.teaCacheEnd
    self.teaCacheThreshold = obj.teaCacheThreshold
    self.teaCache = obj.teaCache
    self.separateT5 = obj.separateT5
    self.t5Text = obj.t5Text
    self.teaCacheMaxSkipSteps = obj.teaCacheMaxSkipSteps
    self.textPrompt = obj.textPrompt
    self.negativeTextPrompt = obj.negativeTextPrompt
    self.clipId = obj.clipId
    self.indexInAClip = obj.indexInAClip
    self.causalInferenceEnabled = obj.causalInferenceEnabled
    self.causalInference = obj.causalInference
    self.causalInferencePad = obj.causalInferencePad
    self.cfgZeroStar = obj.cfgZeroStar
    self.cfgZeroInitSteps = obj.cfgZeroInitSteps
    self.generationTime = obj.generationTime
    self.reason = Reason(rawValue: obj.reason.rawValue) ?? .other
    self.compressionArtifacts = CompressionMethod(rawValue: obj.compressionArtifacts.rawValue) ?? .disabled
    self.compressionArtifactsQuality = obj.compressionArtifactsQuality
    self.audio = obj.audio
    self.colorCalibration = ColorCalibration(rawValue: obj.colorCalibration.rawValue) ?? .disabled
    self.expandPromptToJson = obj.expandPromptToJson
    self.shiftForAudio = obj.shiftForAudio
    self.usesSolAttention = obj.usesSolAttention
    self.solAttentionStart = obj.solAttentionStart
    self.solAttentionTau = obj.solAttentionTau
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!), capacity: buffer.count)
      return Self(zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_TensorHistoryNode>.verify(&verifier, at: 0, of: zzz_DflatGen_TensorHistoryNode.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "tensorhistorynode" }
  public static var indexFields: [String] { ["f22", "f24", "f48", "f60", "f62", "f66", "f70", "f86"] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return }
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensorhistorynode (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, __pk1 INTEGER, p BLOB, UNIQUE(__pk0, __pk1))", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensorhistorynode__f22 (rowid INTEGER PRIMARY KEY, f22 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensorhistorynode__f22 ON tensorhistorynode__f22 (f22)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensorhistorynode__f24 (rowid INTEGER PRIMARY KEY, f24 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensorhistorynode__f24 ON tensorhistorynode__f24 (f24)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensorhistorynode__f48 (rowid INTEGER PRIMARY KEY, f48 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensorhistorynode__f48 ON tensorhistorynode__f48 (f48)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensorhistorynode__f60 (rowid INTEGER PRIMARY KEY, f60 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensorhistorynode__f60 ON tensorhistorynode__f60 (f60)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensorhistorynode__f62 (rowid INTEGER PRIMARY KEY, f62 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensorhistorynode__f62 ON tensorhistorynode__f62 (f62)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensorhistorynode__f66 (rowid INTEGER PRIMARY KEY, f66 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensorhistorynode__f66 ON tensorhistorynode__f66 (f66)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensorhistorynode__f70 (rowid INTEGER PRIMARY KEY, f70 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensorhistorynode__f70 ON tensorhistorynode__f70 (f70)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensorhistorynode__f86 (rowid INTEGER PRIMARY KEY, f86 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensorhistorynode__f86 ON tensorhistorynode__f86 (f86)", nil, nil, nil)
    sqlite.clearIndexStatus(for: Self.table)
  }
  public static func insertIndex(_ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer) -> Bool {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return false }
    switch field {
    case "f22":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensorhistorynode__f22 (rowid, f22) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorHistoryNode.tensorId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f24":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensorhistorynode__f24 (rowid, f24) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorHistoryNode.maskId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f48":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensorhistorynode__f48 (rowid, f48) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorHistoryNode.depthMapId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f60":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensorhistorynode__f60 (rowid, f60) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorHistoryNode.scribbleId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f62":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensorhistorynode__f62 (rowid, f62) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorHistoryNode.poseId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f66":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensorhistorynode__f66 (rowid, f66) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorHistoryNode.colorPaletteId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f70":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensorhistorynode__f70 (rowid, f70) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorHistoryNode.customId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f86":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensorhistorynode__f86 (rowid, f86) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorHistoryNode.previewId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    default:
      break
    }
    return true
  }
}

public struct TensorHistoryNodeBuilder {
  public var lineage: Int64
  public var logicalTime: Int64
  public var startWidth: UInt16
  public var startHeight: UInt16
  public var seed: UInt32
  public var steps: UInt32
  public var guidanceScale: Float32
  public var strength: Float32
  public var model: String?
  public var tensorId: Int64
  public var maskId: Int64
  public var wallClock: Int64
  public var textEdits: Int64
  public var textLineage: Int64
  public var batchSize: UInt32
  public var sampler: SamplerType
  public var hiresFix: Bool
  public var hiresFixStartWidth: UInt16
  public var hiresFixStartHeight: UInt16
  public var hiresFixStrength: Float32
  public var upscaler: String?
  public var scaleFactor: UInt16
  public var depthMapId: Int64
  public var generated: Bool
  public var imageGuidanceScale: Float32
  public var seedMode: SeedMode
  public var clipSkip: UInt32
  public var controls: [Control]
  public var scribbleId: Int64
  public var poseId: Int64
  public var loras: [LoRA]
  public var colorPaletteId: Int64
  public var maskBlur: Float32
  public var customId: Int64
  public var faceRestoration: String?
  public var clipWeight: Float32
  public var negativePromptForImagePrior: Bool
  public var imagePriorSteps: UInt32
  public var dataStored: Int32
  public var previewId: Int64
  public var contentOffsetX: Int32
  public var contentOffsetY: Int32
  public var scaleFactorBy120: Int32
  public var refinerModel: String?
  public var originalImageHeight: UInt32
  public var originalImageWidth: UInt32
  public var cropTop: Int32
  public var cropLeft: Int32
  public var targetImageHeight: UInt32
  public var targetImageWidth: UInt32
  public var aestheticScore: Float32
  public var negativeAestheticScore: Float32
  public var zeroNegativePrompt: Bool
  public var refinerStart: Float32
  public var negativeOriginalImageHeight: UInt32
  public var negativeOriginalImageWidth: UInt32
  public var shuffleDataStored: Int32
  public var fpsId: UInt32
  public var motionBucketId: UInt32
  public var condAug: Float32
  public var startFrameCfg: Float32
  public var numFrames: UInt32
  public var maskBlurOutset: Int32
  public var sharpness: Float32
  public var shift: Float32
  public var stage2Steps: UInt32
  public var stage2Cfg: Float32
  public var stage2Shift: Float32
  public var tiledDecoding: Bool
  public var decodingTileWidth: UInt16
  public var decodingTileHeight: UInt16
  public var decodingTileOverlap: UInt16
  public var stochasticSamplingGamma: Float32
  public var preserveOriginalAfterInpaint: Bool
  public var tiledDiffusion: Bool
  public var diffusionTileWidth: UInt16
  public var diffusionTileHeight: UInt16
  public var diffusionTileOverlap: UInt16
  public var upscalerScaleFactor: UInt8
  public var scriptSessionId: UInt64
  public var t5TextEncoder: Bool
  public var separateClipL: Bool
  public var clipLText: String?
  public var separateOpenClipG: Bool
  public var openClipGText: String?
  public var speedUpWithGuidanceEmbed: Bool
  public var guidanceEmbed: Float32
  public var resolutionDependentShift: Bool
  public var profileData: [UInt8]
  public var teaCacheStart: Int32
  public var teaCacheEnd: Int32
  public var teaCacheThreshold: Float32
  public var teaCache: Bool
  public var separateT5: Bool
  public var t5Text: String?
  public var teaCacheMaxSkipSteps: Int32
  public var textPrompt: String?
  public var negativeTextPrompt: String?
  public var clipId: Int64
  public var indexInAClip: Int32
  public var causalInferenceEnabled: Bool
  public var causalInference: Int32
  public var causalInferencePad: Int32
  public var cfgZeroStar: Bool
  public var cfgZeroInitSteps: Int32
  public var generationTime: Double
  public var reason: Reason
  public var compressionArtifacts: CompressionMethod
  public var compressionArtifactsQuality: Float32
  public var audio: Bool
  public var colorCalibration: ColorCalibration
  public var expandPromptToJson: Bool
  public var shiftForAudio: Float32
  public var usesSolAttention: Bool
  public var solAttentionStart: Int32
  public var solAttentionTau: Float32
  public init(from object: TensorHistoryNode) {
    lineage = object.lineage
    logicalTime = object.logicalTime
    startWidth = object.startWidth
    startHeight = object.startHeight
    seed = object.seed
    steps = object.steps
    guidanceScale = object.guidanceScale
    strength = object.strength
    model = object.model
    tensorId = object.tensorId
    maskId = object.maskId
    wallClock = object.wallClock
    textEdits = object.textEdits
    textLineage = object.textLineage
    batchSize = object.batchSize
    sampler = object.sampler
    hiresFix = object.hiresFix
    hiresFixStartWidth = object.hiresFixStartWidth
    hiresFixStartHeight = object.hiresFixStartHeight
    hiresFixStrength = object.hiresFixStrength
    upscaler = object.upscaler
    scaleFactor = object.scaleFactor
    depthMapId = object.depthMapId
    generated = object.generated
    imageGuidanceScale = object.imageGuidanceScale
    seedMode = object.seedMode
    clipSkip = object.clipSkip
    controls = object.controls
    scribbleId = object.scribbleId
    poseId = object.poseId
    loras = object.loras
    colorPaletteId = object.colorPaletteId
    maskBlur = object.maskBlur
    customId = object.customId
    faceRestoration = object.faceRestoration
    clipWeight = object.clipWeight
    negativePromptForImagePrior = object.negativePromptForImagePrior
    imagePriorSteps = object.imagePriorSteps
    dataStored = object.dataStored
    previewId = object.previewId
    contentOffsetX = object.contentOffsetX
    contentOffsetY = object.contentOffsetY
    scaleFactorBy120 = object.scaleFactorBy120
    refinerModel = object.refinerModel
    originalImageHeight = object.originalImageHeight
    originalImageWidth = object.originalImageWidth
    cropTop = object.cropTop
    cropLeft = object.cropLeft
    targetImageHeight = object.targetImageHeight
    targetImageWidth = object.targetImageWidth
    aestheticScore = object.aestheticScore
    negativeAestheticScore = object.negativeAestheticScore
    zeroNegativePrompt = object.zeroNegativePrompt
    refinerStart = object.refinerStart
    negativeOriginalImageHeight = object.negativeOriginalImageHeight
    negativeOriginalImageWidth = object.negativeOriginalImageWidth
    shuffleDataStored = object.shuffleDataStored
    fpsId = object.fpsId
    motionBucketId = object.motionBucketId
    condAug = object.condAug
    startFrameCfg = object.startFrameCfg
    numFrames = object.numFrames
    maskBlurOutset = object.maskBlurOutset
    sharpness = object.sharpness
    shift = object.shift
    stage2Steps = object.stage2Steps
    stage2Cfg = object.stage2Cfg
    stage2Shift = object.stage2Shift
    tiledDecoding = object.tiledDecoding
    decodingTileWidth = object.decodingTileWidth
    decodingTileHeight = object.decodingTileHeight
    decodingTileOverlap = object.decodingTileOverlap
    stochasticSamplingGamma = object.stochasticSamplingGamma
    preserveOriginalAfterInpaint = object.preserveOriginalAfterInpaint
    tiledDiffusion = object.tiledDiffusion
    diffusionTileWidth = object.diffusionTileWidth
    diffusionTileHeight = object.diffusionTileHeight
    diffusionTileOverlap = object.diffusionTileOverlap
    upscalerScaleFactor = object.upscalerScaleFactor
    scriptSessionId = object.scriptSessionId
    t5TextEncoder = object.t5TextEncoder
    separateClipL = object.separateClipL
    clipLText = object.clipLText
    separateOpenClipG = object.separateOpenClipG
    openClipGText = object.openClipGText
    speedUpWithGuidanceEmbed = object.speedUpWithGuidanceEmbed
    guidanceEmbed = object.guidanceEmbed
    resolutionDependentShift = object.resolutionDependentShift
    profileData = object.profileData
    teaCacheStart = object.teaCacheStart
    teaCacheEnd = object.teaCacheEnd
    teaCacheThreshold = object.teaCacheThreshold
    teaCache = object.teaCache
    separateT5 = object.separateT5
    t5Text = object.t5Text
    teaCacheMaxSkipSteps = object.teaCacheMaxSkipSteps
    textPrompt = object.textPrompt
    negativeTextPrompt = object.negativeTextPrompt
    clipId = object.clipId
    indexInAClip = object.indexInAClip
    causalInferenceEnabled = object.causalInferenceEnabled
    causalInference = object.causalInference
    causalInferencePad = object.causalInferencePad
    cfgZeroStar = object.cfgZeroStar
    cfgZeroInitSteps = object.cfgZeroInitSteps
    generationTime = object.generationTime
    reason = object.reason
    compressionArtifacts = object.compressionArtifacts
    compressionArtifactsQuality = object.compressionArtifactsQuality
    audio = object.audio
    colorCalibration = object.colorCalibration
    expandPromptToJson = object.expandPromptToJson
    shiftForAudio = object.shiftForAudio
    usesSolAttention = object.usesSolAttention
    solAttentionStart = object.solAttentionStart
    solAttentionTau = object.solAttentionTau
  }
  public func build() -> TensorHistoryNode {
    TensorHistoryNode(lineage: lineage, logicalTime: logicalTime, startWidth: startWidth, startHeight: startHeight, seed: seed, steps: steps, guidanceScale: guidanceScale, strength: strength, model: model, tensorId: tensorId, maskId: maskId, wallClock: wallClock, textEdits: textEdits, textLineage: textLineage, batchSize: batchSize, sampler: sampler, hiresFix: hiresFix, hiresFixStartWidth: hiresFixStartWidth, hiresFixStartHeight: hiresFixStartHeight, hiresFixStrength: hiresFixStrength, upscaler: upscaler, scaleFactor: scaleFactor, depthMapId: depthMapId, generated: generated, imageGuidanceScale: imageGuidanceScale, seedMode: seedMode, clipSkip: clipSkip, controls: controls, scribbleId: scribbleId, poseId: poseId, loras: loras, colorPaletteId: colorPaletteId, maskBlur: maskBlur, customId: customId, faceRestoration: faceRestoration, clipWeight: clipWeight, negativePromptForImagePrior: negativePromptForImagePrior, imagePriorSteps: imagePriorSteps, dataStored: dataStored, previewId: previewId, contentOffsetX: contentOffsetX, contentOffsetY: contentOffsetY, scaleFactorBy120: scaleFactorBy120, refinerModel: refinerModel, originalImageHeight: originalImageHeight, originalImageWidth: originalImageWidth, cropTop: cropTop, cropLeft: cropLeft, targetImageHeight: targetImageHeight, targetImageWidth: targetImageWidth, aestheticScore: aestheticScore, negativeAestheticScore: negativeAestheticScore, zeroNegativePrompt: zeroNegativePrompt, refinerStart: refinerStart, negativeOriginalImageHeight: negativeOriginalImageHeight, negativeOriginalImageWidth: negativeOriginalImageWidth, shuffleDataStored: shuffleDataStored, fpsId: fpsId, motionBucketId: motionBucketId, condAug: condAug, startFrameCfg: startFrameCfg, numFrames: numFrames, maskBlurOutset: maskBlurOutset, sharpness: sharpness, shift: shift, stage2Steps: stage2Steps, stage2Cfg: stage2Cfg, stage2Shift: stage2Shift, tiledDecoding: tiledDecoding, decodingTileWidth: decodingTileWidth, decodingTileHeight: decodingTileHeight, decodingTileOverlap: decodingTileOverlap, stochasticSamplingGamma: stochasticSamplingGamma, preserveOriginalAfterInpaint: preserveOriginalAfterInpaint, tiledDiffusion: tiledDiffusion, diffusionTileWidth: diffusionTileWidth, diffusionTileHeight: diffusionTileHeight, diffusionTileOverlap: diffusionTileOverlap, upscalerScaleFactor: upscalerScaleFactor, scriptSessionId: scriptSessionId, t5TextEncoder: t5TextEncoder, separateClipL: separateClipL, clipLText: clipLText, separateOpenClipG: separateOpenClipG, openClipGText: openClipGText, speedUpWithGuidanceEmbed: speedUpWithGuidanceEmbed, guidanceEmbed: guidanceEmbed, resolutionDependentShift: resolutionDependentShift, profileData: profileData, teaCacheStart: teaCacheStart, teaCacheEnd: teaCacheEnd, teaCacheThreshold: teaCacheThreshold, teaCache: teaCache, separateT5: separateT5, t5Text: t5Text, teaCacheMaxSkipSteps: teaCacheMaxSkipSteps, textPrompt: textPrompt, negativeTextPrompt: negativeTextPrompt, clipId: clipId, indexInAClip: indexInAClip, causalInferenceEnabled: causalInferenceEnabled, causalInference: causalInference, causalInferencePad: causalInferencePad, cfgZeroStar: cfgZeroStar, cfgZeroInitSteps: cfgZeroInitSteps, generationTime: generationTime, reason: reason, compressionArtifacts: compressionArtifacts, compressionArtifactsQuality: compressionArtifactsQuality, audio: audio, colorCalibration: colorCalibration, expandPromptToJson: expandPromptToJson, shiftForAudio: shiftForAudio, usesSolAttention: usesSolAttention, solAttentionStart: solAttentionStart, solAttentionTau: solAttentionTau)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
extension TensorHistoryNode: @unchecked Sendable {}
#endif
