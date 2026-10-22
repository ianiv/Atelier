import Dflat
import SQLiteDflat
import SQLite3
import FlatBuffers
import Foundation

// MARK - SQLiteValue for Enumerations

extension SamplerType: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

extension SeedMode: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

extension ControlMode: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

extension ControlInputType: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

extension LoRAMode: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

extension Reason: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

extension CompressionMethod: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

extension ColorCalibration: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

// MARK - Serializer

extension Control: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __file = self.file.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __controlMode = zzz_DflatGen_ControlMode(rawValue: self.controlMode.rawValue) ?? .balanced
    var __targetBlocks = [Offset]()
    for i in targetBlocks {
      __targetBlocks.append(flatBufferBuilder.create(string: i))
    }
    let __vector_targetBlocks = flatBufferBuilder.createVector(ofOffsets: __targetBlocks)
    let __inputOverride = zzz_DflatGen_ControlInputType(rawValue: self.inputOverride.rawValue) ?? .unspecified
    let start = zzz_DflatGen_Control.startControl(&flatBufferBuilder)
    zzz_DflatGen_Control.add(file: __file, &flatBufferBuilder)
    zzz_DflatGen_Control.add(weight: self.weight, &flatBufferBuilder)
    zzz_DflatGen_Control.add(guidanceStart: self.guidanceStart, &flatBufferBuilder)
    zzz_DflatGen_Control.add(guidanceEnd: self.guidanceEnd, &flatBufferBuilder)
    zzz_DflatGen_Control.add(noPrompt: self.noPrompt, &flatBufferBuilder)
    zzz_DflatGen_Control.add(globalAveragePooling: self.globalAveragePooling, &flatBufferBuilder)
    zzz_DflatGen_Control.add(downSamplingRate: self.downSamplingRate, &flatBufferBuilder)
    zzz_DflatGen_Control.add(controlMode: __controlMode, &flatBufferBuilder)
    zzz_DflatGen_Control.addVectorOf(targetBlocks: __vector_targetBlocks, &flatBufferBuilder)
    zzz_DflatGen_Control.add(inputOverride: __inputOverride, &flatBufferBuilder)
    return zzz_DflatGen_Control.endControl(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == Control {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension LoRA: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __file = self.file.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __mode = zzz_DflatGen_LoRAMode(rawValue: self.mode.rawValue) ?? .all
    let start = zzz_DflatGen_LoRA.startLoRA(&flatBufferBuilder)
    zzz_DflatGen_LoRA.add(file: __file, &flatBufferBuilder)
    zzz_DflatGen_LoRA.add(weight: self.weight, &flatBufferBuilder)
    zzz_DflatGen_LoRA.add(mode: __mode, &flatBufferBuilder)
    return zzz_DflatGen_LoRA.endLoRA(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == LoRA {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension TensorHistoryNode: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __model = self.model.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __sampler = zzz_DflatGen_SamplerType(rawValue: self.sampler.rawValue) ?? .dpmpp2mkarras
    let __upscaler = self.upscaler.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __seedMode = zzz_DflatGen_SeedMode(rawValue: self.seedMode.rawValue) ?? .legacy
    var __controls = [Offset]()
    for i in self.controls {
      __controls.append(i.to(flatBufferBuilder: &flatBufferBuilder))
    }
    let __vector_controls = flatBufferBuilder.createVector(ofOffsets: __controls)
    var __loras = [Offset]()
    for i in self.loras {
      __loras.append(i.to(flatBufferBuilder: &flatBufferBuilder))
    }
    let __vector_loras = flatBufferBuilder.createVector(ofOffsets: __loras)
    let __faceRestoration = self.faceRestoration.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __refinerModel = self.refinerModel.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __clipLText = self.clipLText.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __openClipGText = self.openClipGText.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __vector_profileData = flatBufferBuilder.createVector(self.profileData)
    let __t5Text = self.t5Text.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __textPrompt = self.textPrompt.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __negativeTextPrompt = self.negativeTextPrompt.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __reason = zzz_DflatGen_Reason(rawValue: self.reason.rawValue) ?? .other
    let __compressionArtifacts = zzz_DflatGen_CompressionMethod(rawValue: self.compressionArtifacts.rawValue) ?? .disabled
    let __colorCalibration = zzz_DflatGen_ColorCalibration(rawValue: self.colorCalibration.rawValue) ?? .disabled
    let start = zzz_DflatGen_TensorHistoryNode.startTensorHistoryNode(&flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(lineage: self.lineage, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(logicalTime: self.logicalTime, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(startWidth: self.startWidth, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(startHeight: self.startHeight, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(seed: self.seed, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(steps: self.steps, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(guidanceScale: self.guidanceScale, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(strength: self.strength, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(model: __model, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(tensorId: self.tensorId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(maskId: self.maskId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(wallClock: self.wallClock, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(textEdits: self.textEdits, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(textLineage: self.textLineage, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(batchSize: self.batchSize, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(sampler: __sampler, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(hiresFix: self.hiresFix, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(hiresFixStartWidth: self.hiresFixStartWidth, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(hiresFixStartHeight: self.hiresFixStartHeight, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(hiresFixStrength: self.hiresFixStrength, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(upscaler: __upscaler, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(scaleFactor: self.scaleFactor, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(depthMapId: self.depthMapId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(generated: self.generated, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(imageGuidanceScale: self.imageGuidanceScale, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(seedMode: __seedMode, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(clipSkip: self.clipSkip, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.addVectorOf(controls: __vector_controls, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(scribbleId: self.scribbleId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(poseId: self.poseId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.addVectorOf(loras: __vector_loras, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(colorPaletteId: self.colorPaletteId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(maskBlur: self.maskBlur, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(customId: self.customId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(faceRestoration: __faceRestoration, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(clipWeight: self.clipWeight, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(negativePromptForImagePrior: self.negativePromptForImagePrior, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(imagePriorSteps: self.imagePriorSteps, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(dataStored: self.dataStored, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(previewId: self.previewId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(contentOffsetX: self.contentOffsetX, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(contentOffsetY: self.contentOffsetY, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(scaleFactorBy120: self.scaleFactorBy120, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(refinerModel: __refinerModel, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(originalImageHeight: self.originalImageHeight, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(originalImageWidth: self.originalImageWidth, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(cropTop: self.cropTop, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(cropLeft: self.cropLeft, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(targetImageHeight: self.targetImageHeight, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(targetImageWidth: self.targetImageWidth, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(aestheticScore: self.aestheticScore, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(negativeAestheticScore: self.negativeAestheticScore, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(zeroNegativePrompt: self.zeroNegativePrompt, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(refinerStart: self.refinerStart, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(negativeOriginalImageHeight: self.negativeOriginalImageHeight, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(negativeOriginalImageWidth: self.negativeOriginalImageWidth, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(shuffleDataStored: self.shuffleDataStored, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(fpsId: self.fpsId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(motionBucketId: self.motionBucketId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(condAug: self.condAug, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(startFrameCfg: self.startFrameCfg, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(numFrames: self.numFrames, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(maskBlurOutset: self.maskBlurOutset, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(sharpness: self.sharpness, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(shift: self.shift, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(stage2Steps: self.stage2Steps, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(stage2Cfg: self.stage2Cfg, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(stage2Shift: self.stage2Shift, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(tiledDecoding: self.tiledDecoding, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(decodingTileWidth: self.decodingTileWidth, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(decodingTileHeight: self.decodingTileHeight, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(decodingTileOverlap: self.decodingTileOverlap, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(stochasticSamplingGamma: self.stochasticSamplingGamma, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(preserveOriginalAfterInpaint: self.preserveOriginalAfterInpaint, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(tiledDiffusion: self.tiledDiffusion, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(diffusionTileWidth: self.diffusionTileWidth, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(diffusionTileHeight: self.diffusionTileHeight, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(diffusionTileOverlap: self.diffusionTileOverlap, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(upscalerScaleFactor: self.upscalerScaleFactor, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(scriptSessionId: self.scriptSessionId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(t5TextEncoder: self.t5TextEncoder, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(separateClipL: self.separateClipL, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(clipLText: __clipLText, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(separateOpenClipG: self.separateOpenClipG, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(openClipGText: __openClipGText, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(speedUpWithGuidanceEmbed: self.speedUpWithGuidanceEmbed, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(guidanceEmbed: self.guidanceEmbed, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(resolutionDependentShift: self.resolutionDependentShift, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.addVectorOf(profileData: __vector_profileData, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(teaCacheStart: self.teaCacheStart, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(teaCacheEnd: self.teaCacheEnd, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(teaCacheThreshold: self.teaCacheThreshold, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(teaCache: self.teaCache, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(separateT5: self.separateT5, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(t5Text: __t5Text, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(teaCacheMaxSkipSteps: self.teaCacheMaxSkipSteps, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(textPrompt: __textPrompt, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(negativeTextPrompt: __negativeTextPrompt, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(clipId: self.clipId, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(indexInAClip: self.indexInAClip, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(causalInferenceEnabled: self.causalInferenceEnabled, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(causalInference: self.causalInference, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(causalInferencePad: self.causalInferencePad, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(cfgZeroStar: self.cfgZeroStar, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(cfgZeroInitSteps: self.cfgZeroInitSteps, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(generationTime: self.generationTime, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(reason: __reason, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(compressionArtifacts: __compressionArtifacts, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(compressionArtifactsQuality: self.compressionArtifactsQuality, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(audio: self.audio, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(colorCalibration: __colorCalibration, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(expandPromptToJson: self.expandPromptToJson, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(shiftForAudio: self.shiftForAudio, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(usesSolAttention: self.usesSolAttention, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(solAttentionStart: self.solAttentionStart, &flatBufferBuilder)
    zzz_DflatGen_TensorHistoryNode.add(solAttentionTau: self.solAttentionTau, &flatBufferBuilder)
    return zzz_DflatGen_TensorHistoryNode.endTensorHistoryNode(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == TensorHistoryNode {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension TensorHistoryNode {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class TensorHistoryNodeChangeRequest: Dflat.ChangeRequest {
  private var _o: TensorHistoryNode?
  public typealias Element = TensorHistoryNode
  public var _type: ChangeRequestType
  public var _rowid: Int64
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
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    lineage = 0
    logicalTime = 0
    startWidth = 0
    startHeight = 0
    seed = 0
    steps = 0
    guidanceScale = 0.0
    strength = 0.0
    model = nil
    tensorId = 0
    maskId = 0
    wallClock = 0
    textEdits = -1
    textLineage = -1
    batchSize = 1
    sampler = .dPMPP2MKarras
    hiresFix = false
    hiresFixStartWidth = 0
    hiresFixStartHeight = 0
    hiresFixStrength = 0.7
    upscaler = nil
    scaleFactor = 1
    depthMapId = 0
    generated = true
    imageGuidanceScale = 1.5
    seedMode = .legacy
    clipSkip = 1
    controls = []
    scribbleId = 0
    poseId = 0
    loras = []
    colorPaletteId = 0
    maskBlur = 0.0
    customId = 0
    faceRestoration = nil
    clipWeight = 1.0
    negativePromptForImagePrior = true
    imagePriorSteps = 5
    dataStored = 0
    previewId = 0
    contentOffsetX = 0
    contentOffsetY = 0
    scaleFactorBy120 = 120
    refinerModel = nil
    originalImageHeight = 0
    originalImageWidth = 0
    cropTop = 0
    cropLeft = 0
    targetImageHeight = 0
    targetImageWidth = 0
    aestheticScore = 0.0
    negativeAestheticScore = 0.0
    zeroNegativePrompt = false
    refinerStart = 0.0
    negativeOriginalImageHeight = 0
    negativeOriginalImageWidth = 0
    shuffleDataStored = 0
    fpsId = 5
    motionBucketId = 127
    condAug = 0.02
    startFrameCfg = 1.0
    numFrames = 14
    maskBlurOutset = 0
    sharpness = 0.0
    shift = 1.0
    stage2Steps = 10
    stage2Cfg = 1.0
    stage2Shift = 1.0
    tiledDecoding = false
    decodingTileWidth = 10
    decodingTileHeight = 10
    decodingTileOverlap = 2
    stochasticSamplingGamma = 0.3
    preserveOriginalAfterInpaint = true
    tiledDiffusion = false
    diffusionTileWidth = 16
    diffusionTileHeight = 16
    diffusionTileOverlap = 2
    upscalerScaleFactor = 0
    scriptSessionId = 0
    t5TextEncoder = true
    separateClipL = false
    clipLText = nil
    separateOpenClipG = false
    openClipGText = nil
    speedUpWithGuidanceEmbed = true
    guidanceEmbed = 3.5
    resolutionDependentShift = true
    profileData = []
    teaCacheStart = 5
    teaCacheEnd = -1
    teaCacheThreshold = 0.06
    teaCache = false
    separateT5 = false
    t5Text = nil
    teaCacheMaxSkipSteps = 3
    textPrompt = nil
    negativeTextPrompt = nil
    clipId = -1
    indexInAClip = 0
    causalInferenceEnabled = false
    causalInference = 3
    causalInferencePad = 0
    cfgZeroStar = false
    cfgZeroInitSteps = 0
    generationTime = 0.0
    reason = .other
    compressionArtifacts = .disabled
    compressionArtifactsQuality = 43.1
    audio = false
    colorCalibration = .disabled
    expandPromptToJson = false
    shiftForAudio = 3.0
    usesSolAttention = false
    solAttentionStart = 2
    solAttentionTau = 0.5
  }
  private init(type _type: ChangeRequestType, _ _o: TensorHistoryNode) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    lineage = _o.lineage
    logicalTime = _o.logicalTime
    startWidth = _o.startWidth
    startHeight = _o.startHeight
    seed = _o.seed
    steps = _o.steps
    guidanceScale = _o.guidanceScale
    strength = _o.strength
    model = _o.model
    tensorId = _o.tensorId
    maskId = _o.maskId
    wallClock = _o.wallClock
    textEdits = _o.textEdits
    textLineage = _o.textLineage
    batchSize = _o.batchSize
    sampler = _o.sampler
    hiresFix = _o.hiresFix
    hiresFixStartWidth = _o.hiresFixStartWidth
    hiresFixStartHeight = _o.hiresFixStartHeight
    hiresFixStrength = _o.hiresFixStrength
    upscaler = _o.upscaler
    scaleFactor = _o.scaleFactor
    depthMapId = _o.depthMapId
    generated = _o.generated
    imageGuidanceScale = _o.imageGuidanceScale
    seedMode = _o.seedMode
    clipSkip = _o.clipSkip
    controls = _o.controls
    scribbleId = _o.scribbleId
    poseId = _o.poseId
    loras = _o.loras
    colorPaletteId = _o.colorPaletteId
    maskBlur = _o.maskBlur
    customId = _o.customId
    faceRestoration = _o.faceRestoration
    clipWeight = _o.clipWeight
    negativePromptForImagePrior = _o.negativePromptForImagePrior
    imagePriorSteps = _o.imagePriorSteps
    dataStored = _o.dataStored
    previewId = _o.previewId
    contentOffsetX = _o.contentOffsetX
    contentOffsetY = _o.contentOffsetY
    scaleFactorBy120 = _o.scaleFactorBy120
    refinerModel = _o.refinerModel
    originalImageHeight = _o.originalImageHeight
    originalImageWidth = _o.originalImageWidth
    cropTop = _o.cropTop
    cropLeft = _o.cropLeft
    targetImageHeight = _o.targetImageHeight
    targetImageWidth = _o.targetImageWidth
    aestheticScore = _o.aestheticScore
    negativeAestheticScore = _o.negativeAestheticScore
    zeroNegativePrompt = _o.zeroNegativePrompt
    refinerStart = _o.refinerStart
    negativeOriginalImageHeight = _o.negativeOriginalImageHeight
    negativeOriginalImageWidth = _o.negativeOriginalImageWidth
    shuffleDataStored = _o.shuffleDataStored
    fpsId = _o.fpsId
    motionBucketId = _o.motionBucketId
    condAug = _o.condAug
    startFrameCfg = _o.startFrameCfg
    numFrames = _o.numFrames
    maskBlurOutset = _o.maskBlurOutset
    sharpness = _o.sharpness
    shift = _o.shift
    stage2Steps = _o.stage2Steps
    stage2Cfg = _o.stage2Cfg
    stage2Shift = _o.stage2Shift
    tiledDecoding = _o.tiledDecoding
    decodingTileWidth = _o.decodingTileWidth
    decodingTileHeight = _o.decodingTileHeight
    decodingTileOverlap = _o.decodingTileOverlap
    stochasticSamplingGamma = _o.stochasticSamplingGamma
    preserveOriginalAfterInpaint = _o.preserveOriginalAfterInpaint
    tiledDiffusion = _o.tiledDiffusion
    diffusionTileWidth = _o.diffusionTileWidth
    diffusionTileHeight = _o.diffusionTileHeight
    diffusionTileOverlap = _o.diffusionTileOverlap
    upscalerScaleFactor = _o.upscalerScaleFactor
    scriptSessionId = _o.scriptSessionId
    t5TextEncoder = _o.t5TextEncoder
    separateClipL = _o.separateClipL
    clipLText = _o.clipLText
    separateOpenClipG = _o.separateOpenClipG
    openClipGText = _o.openClipGText
    speedUpWithGuidanceEmbed = _o.speedUpWithGuidanceEmbed
    guidanceEmbed = _o.guidanceEmbed
    resolutionDependentShift = _o.resolutionDependentShift
    profileData = _o.profileData
    teaCacheStart = _o.teaCacheStart
    teaCacheEnd = _o.teaCacheEnd
    teaCacheThreshold = _o.teaCacheThreshold
    teaCache = _o.teaCache
    separateT5 = _o.separateT5
    t5Text = _o.t5Text
    teaCacheMaxSkipSteps = _o.teaCacheMaxSkipSteps
    textPrompt = _o.textPrompt
    negativeTextPrompt = _o.negativeTextPrompt
    clipId = _o.clipId
    indexInAClip = _o.indexInAClip
    causalInferenceEnabled = _o.causalInferenceEnabled
    causalInference = _o.causalInference
    causalInferencePad = _o.causalInferencePad
    cfgZeroStar = _o.cfgZeroStar
    cfgZeroInitSteps = _o.cfgZeroInitSteps
    generationTime = _o.generationTime
    reason = _o.reason
    compressionArtifacts = _o.compressionArtifacts
    compressionArtifactsQuality = _o.compressionArtifactsQuality
    audio = _o.audio
    colorCalibration = _o.colorCalibration
    expandPromptToJson = _o.expandPromptToJson
    shiftForAudio = _o.shiftForAudio
    usesSolAttention = _o.usesSolAttention
    solAttentionStart = _o.solAttentionStart
    solAttentionTau = _o.solAttentionTau
  }
  public static func changeRequest(_ o: TensorHistoryNode) -> TensorHistoryNodeChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.lineage, o.logicalTime])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: TensorHistoryNode.self, for: key)
    return u.map { TensorHistoryNodeChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: TensorHistoryNode) -> TensorHistoryNodeChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.lineage, o.logicalTime])
    guard let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: TensorHistoryNode.self, for: key) else {
      return Self.creationRequest(o)
    }
    let changeRequest = TensorHistoryNodeChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: TensorHistoryNode) -> TensorHistoryNodeChangeRequest {
    let creationRequest = TensorHistoryNodeChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> TensorHistoryNodeChangeRequest {
    return TensorHistoryNodeChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: TensorHistoryNode) -> TensorHistoryNodeChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.lineage, o.logicalTime])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: TensorHistoryNode.self, for: key)
    return u.map { TensorHistoryNodeChangeRequest(type: .deletion, $0) }
  }
  var _atom: TensorHistoryNode {
    let atom = TensorHistoryNode(lineage: lineage, logicalTime: logicalTime, startWidth: startWidth, startHeight: startHeight, seed: seed, steps: steps, guidanceScale: guidanceScale, strength: strength, model: model, tensorId: tensorId, maskId: maskId, wallClock: wallClock, textEdits: textEdits, textLineage: textLineage, batchSize: batchSize, sampler: sampler, hiresFix: hiresFix, hiresFixStartWidth: hiresFixStartWidth, hiresFixStartHeight: hiresFixStartHeight, hiresFixStrength: hiresFixStrength, upscaler: upscaler, scaleFactor: scaleFactor, depthMapId: depthMapId, generated: generated, imageGuidanceScale: imageGuidanceScale, seedMode: seedMode, clipSkip: clipSkip, controls: controls, scribbleId: scribbleId, poseId: poseId, loras: loras, colorPaletteId: colorPaletteId, maskBlur: maskBlur, customId: customId, faceRestoration: faceRestoration, clipWeight: clipWeight, negativePromptForImagePrior: negativePromptForImagePrior, imagePriorSteps: imagePriorSteps, dataStored: dataStored, previewId: previewId, contentOffsetX: contentOffsetX, contentOffsetY: contentOffsetY, scaleFactorBy120: scaleFactorBy120, refinerModel: refinerModel, originalImageHeight: originalImageHeight, originalImageWidth: originalImageWidth, cropTop: cropTop, cropLeft: cropLeft, targetImageHeight: targetImageHeight, targetImageWidth: targetImageWidth, aestheticScore: aestheticScore, negativeAestheticScore: negativeAestheticScore, zeroNegativePrompt: zeroNegativePrompt, refinerStart: refinerStart, negativeOriginalImageHeight: negativeOriginalImageHeight, negativeOriginalImageWidth: negativeOriginalImageWidth, shuffleDataStored: shuffleDataStored, fpsId: fpsId, motionBucketId: motionBucketId, condAug: condAug, startFrameCfg: startFrameCfg, numFrames: numFrames, maskBlurOutset: maskBlurOutset, sharpness: sharpness, shift: shift, stage2Steps: stage2Steps, stage2Cfg: stage2Cfg, stage2Shift: stage2Shift, tiledDecoding: tiledDecoding, decodingTileWidth: decodingTileWidth, decodingTileHeight: decodingTileHeight, decodingTileOverlap: decodingTileOverlap, stochasticSamplingGamma: stochasticSamplingGamma, preserveOriginalAfterInpaint: preserveOriginalAfterInpaint, tiledDiffusion: tiledDiffusion, diffusionTileWidth: diffusionTileWidth, diffusionTileHeight: diffusionTileHeight, diffusionTileOverlap: diffusionTileOverlap, upscalerScaleFactor: upscalerScaleFactor, scriptSessionId: scriptSessionId, t5TextEncoder: t5TextEncoder, separateClipL: separateClipL, clipLText: clipLText, separateOpenClipG: separateOpenClipG, openClipGText: openClipGText, speedUpWithGuidanceEmbed: speedUpWithGuidanceEmbed, guidanceEmbed: guidanceEmbed, resolutionDependentShift: resolutionDependentShift, profileData: profileData, teaCacheStart: teaCacheStart, teaCacheEnd: teaCacheEnd, teaCacheThreshold: teaCacheThreshold, teaCache: teaCache, separateT5: separateT5, t5Text: t5Text, teaCacheMaxSkipSteps: teaCacheMaxSkipSteps, textPrompt: textPrompt, negativeTextPrompt: negativeTextPrompt, clipId: clipId, indexInAClip: indexInAClip, causalInferenceEnabled: causalInferenceEnabled, causalInference: causalInference, causalInferencePad: causalInferencePad, cfgZeroStar: cfgZeroStar, cfgZeroInitSteps: cfgZeroInitSteps, generationTime: generationTime, reason: reason, compressionArtifacts: compressionArtifacts, compressionArtifactsQuality: compressionArtifactsQuality, audio: audio, colorCalibration: colorCalibration, expandPromptToJson: expandPromptToJson, shiftForAudio: shiftForAudio, usesSolAttention: usesSolAttention, solAttentionStart: solAttentionStart, solAttentionTau: solAttentionTau)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      let indexSurvey = toolbox.connection.indexSurvey(TensorHistoryNode.indexFields, table: TensorHistoryNode.table)
      guard let insert = toolbox.connection.prepareStaticStatement("INSERT INTO tensorhistorynode (__pk0, __pk1, p) VALUES (?1, ?2, ?3)") else { return nil }
      lineage.bindSQLite(insert, parameterId: 1)
      logicalTime.bindSQLite(insert, parameterId: 2)
      let atom = self._atom
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(insert, 3, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      guard SQLITE_DONE == sqlite3_step(insert) else { return nil }
      _rowid = sqlite3_last_insert_rowid(toolbox.connection.sqlite)
      if indexSurvey.full.contains("f22") {
        guard let i0 = toolbox.connection.prepareStaticStatement("INSERT INTO tensorhistorynode__f22 (rowid, f22) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i0, parameterId: 1)
        if let r0 = TensorHistoryNode.tensorId.evaluate(object: atom) {
          r0.bindSQLite(i0, parameterId: 2)
        } else {
          sqlite3_bind_null(i0, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i0) else { return nil }
      }
      if indexSurvey.full.contains("f24") {
        guard let i1 = toolbox.connection.prepareStaticStatement("INSERT INTO tensorhistorynode__f24 (rowid, f24) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i1, parameterId: 1)
        if let r1 = TensorHistoryNode.maskId.evaluate(object: atom) {
          r1.bindSQLite(i1, parameterId: 2)
        } else {
          sqlite3_bind_null(i1, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i1) else { return nil }
      }
      if indexSurvey.full.contains("f48") {
        guard let i2 = toolbox.connection.prepareStaticStatement("INSERT INTO tensorhistorynode__f48 (rowid, f48) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i2, parameterId: 1)
        if let r2 = TensorHistoryNode.depthMapId.evaluate(object: atom) {
          r2.bindSQLite(i2, parameterId: 2)
        } else {
          sqlite3_bind_null(i2, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i2) else { return nil }
      }
      if indexSurvey.full.contains("f60") {
        guard let i3 = toolbox.connection.prepareStaticStatement("INSERT INTO tensorhistorynode__f60 (rowid, f60) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i3, parameterId: 1)
        if let r3 = TensorHistoryNode.scribbleId.evaluate(object: atom) {
          r3.bindSQLite(i3, parameterId: 2)
        } else {
          sqlite3_bind_null(i3, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i3) else { return nil }
      }
      if indexSurvey.full.contains("f62") {
        guard let i4 = toolbox.connection.prepareStaticStatement("INSERT INTO tensorhistorynode__f62 (rowid, f62) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i4, parameterId: 1)
        if let r4 = TensorHistoryNode.poseId.evaluate(object: atom) {
          r4.bindSQLite(i4, parameterId: 2)
        } else {
          sqlite3_bind_null(i4, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i4) else { return nil }
      }
      if indexSurvey.full.contains("f66") {
        guard let i5 = toolbox.connection.prepareStaticStatement("INSERT INTO tensorhistorynode__f66 (rowid, f66) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i5, parameterId: 1)
        if let r5 = TensorHistoryNode.colorPaletteId.evaluate(object: atom) {
          r5.bindSQLite(i5, parameterId: 2)
        } else {
          sqlite3_bind_null(i5, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i5) else { return nil }
      }
      if indexSurvey.full.contains("f70") {
        guard let i6 = toolbox.connection.prepareStaticStatement("INSERT INTO tensorhistorynode__f70 (rowid, f70) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i6, parameterId: 1)
        if let r6 = TensorHistoryNode.customId.evaluate(object: atom) {
          r6.bindSQLite(i6, parameterId: 2)
        } else {
          sqlite3_bind_null(i6, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i6) else { return nil }
      }
      if indexSurvey.full.contains("f86") {
        guard let i7 = toolbox.connection.prepareStaticStatement("INSERT INTO tensorhistorynode__f86 (rowid, f86) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i7, parameterId: 1)
        if let r7 = TensorHistoryNode.previewId.evaluate(object: atom) {
          r7.bindSQLite(i7, parameterId: 2)
        } else {
          sqlite3_bind_null(i7, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i7) else { return nil }
      }
      _type = .none
      atom._rowid = _rowid
      return .inserted(atom)
    case .update:
      guard let o = _o else { return nil }
      let atom = self._atom
      guard atom != o else {
        _type = .none
        return .identity(atom)
      }
      let indexSurvey = toolbox.connection.indexSurvey(TensorHistoryNode.indexFields, table: TensorHistoryNode.table)
      guard let update = toolbox.connection.prepareStaticStatement("REPLACE INTO tensorhistorynode (__pk0, __pk1, p, rowid) VALUES (?1, ?2, ?3, ?4)") else { return nil }
      lineage.bindSQLite(update, parameterId: 1)
      logicalTime.bindSQLite(update, parameterId: 2)
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(update, 3, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      _rowid.bindSQLite(update, parameterId: 4)
      guard SQLITE_DONE == sqlite3_step(update) else { return nil }
      if indexSurvey.full.contains("f22") {
        let or0 = TensorHistoryNode.tensorId.evaluate(object: o)
        let r0 = TensorHistoryNode.tensorId.evaluate(object: atom)
        if or0 != r0 {
          guard let u0 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensorhistorynode__f22 (rowid, f22) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u0, parameterId: 1)
          if let ur0 = r0 {
            ur0.bindSQLite(u0, parameterId: 2)
          } else {
            sqlite3_bind_null(u0, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u0) else { return nil }
        }
      }
      if indexSurvey.full.contains("f24") {
        let or1 = TensorHistoryNode.maskId.evaluate(object: o)
        let r1 = TensorHistoryNode.maskId.evaluate(object: atom)
        if or1 != r1 {
          guard let u1 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensorhistorynode__f24 (rowid, f24) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u1, parameterId: 1)
          if let ur1 = r1 {
            ur1.bindSQLite(u1, parameterId: 2)
          } else {
            sqlite3_bind_null(u1, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u1) else { return nil }
        }
      }
      if indexSurvey.full.contains("f48") {
        let or2 = TensorHistoryNode.depthMapId.evaluate(object: o)
        let r2 = TensorHistoryNode.depthMapId.evaluate(object: atom)
        if or2 != r2 {
          guard let u2 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensorhistorynode__f48 (rowid, f48) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u2, parameterId: 1)
          if let ur2 = r2 {
            ur2.bindSQLite(u2, parameterId: 2)
          } else {
            sqlite3_bind_null(u2, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u2) else { return nil }
        }
      }
      if indexSurvey.full.contains("f60") {
        let or3 = TensorHistoryNode.scribbleId.evaluate(object: o)
        let r3 = TensorHistoryNode.scribbleId.evaluate(object: atom)
        if or3 != r3 {
          guard let u3 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensorhistorynode__f60 (rowid, f60) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u3, parameterId: 1)
          if let ur3 = r3 {
            ur3.bindSQLite(u3, parameterId: 2)
          } else {
            sqlite3_bind_null(u3, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u3) else { return nil }
        }
      }
      if indexSurvey.full.contains("f62") {
        let or4 = TensorHistoryNode.poseId.evaluate(object: o)
        let r4 = TensorHistoryNode.poseId.evaluate(object: atom)
        if or4 != r4 {
          guard let u4 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensorhistorynode__f62 (rowid, f62) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u4, parameterId: 1)
          if let ur4 = r4 {
            ur4.bindSQLite(u4, parameterId: 2)
          } else {
            sqlite3_bind_null(u4, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u4) else { return nil }
        }
      }
      if indexSurvey.full.contains("f66") {
        let or5 = TensorHistoryNode.colorPaletteId.evaluate(object: o)
        let r5 = TensorHistoryNode.colorPaletteId.evaluate(object: atom)
        if or5 != r5 {
          guard let u5 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensorhistorynode__f66 (rowid, f66) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u5, parameterId: 1)
          if let ur5 = r5 {
            ur5.bindSQLite(u5, parameterId: 2)
          } else {
            sqlite3_bind_null(u5, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u5) else { return nil }
        }
      }
      if indexSurvey.full.contains("f70") {
        let or6 = TensorHistoryNode.customId.evaluate(object: o)
        let r6 = TensorHistoryNode.customId.evaluate(object: atom)
        if or6 != r6 {
          guard let u6 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensorhistorynode__f70 (rowid, f70) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u6, parameterId: 1)
          if let ur6 = r6 {
            ur6.bindSQLite(u6, parameterId: 2)
          } else {
            sqlite3_bind_null(u6, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u6) else { return nil }
        }
      }
      if indexSurvey.full.contains("f86") {
        let or7 = TensorHistoryNode.previewId.evaluate(object: o)
        let r7 = TensorHistoryNode.previewId.evaluate(object: atom)
        if or7 != r7 {
          guard let u7 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensorhistorynode__f86 (rowid, f86) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u7, parameterId: 1)
          if let ur7 = r7 {
            ur7.bindSQLite(u7, parameterId: 2)
          } else {
            sqlite3_bind_null(u7, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u7) else { return nil }
        }
      }
      _type = .none
      return .updated(atom)
    case .deletion:
      guard let deletion = toolbox.connection.prepareStaticStatement("DELETE FROM tensorhistorynode WHERE rowid=?1") else { return nil }
      _rowid.bindSQLite(deletion, parameterId: 1)
      guard SQLITE_DONE == sqlite3_step(deletion) else { return nil }
      if let d0 = toolbox.connection.prepareStaticStatement("DELETE FROM tensorhistorynode__f22 WHERE rowid=?1") {
        _rowid.bindSQLite(d0, parameterId: 1)
        sqlite3_step(d0)
      }
      if let d1 = toolbox.connection.prepareStaticStatement("DELETE FROM tensorhistorynode__f24 WHERE rowid=?1") {
        _rowid.bindSQLite(d1, parameterId: 1)
        sqlite3_step(d1)
      }
      if let d2 = toolbox.connection.prepareStaticStatement("DELETE FROM tensorhistorynode__f48 WHERE rowid=?1") {
        _rowid.bindSQLite(d2, parameterId: 1)
        sqlite3_step(d2)
      }
      if let d3 = toolbox.connection.prepareStaticStatement("DELETE FROM tensorhistorynode__f60 WHERE rowid=?1") {
        _rowid.bindSQLite(d3, parameterId: 1)
        sqlite3_step(d3)
      }
      if let d4 = toolbox.connection.prepareStaticStatement("DELETE FROM tensorhistorynode__f62 WHERE rowid=?1") {
        _rowid.bindSQLite(d4, parameterId: 1)
        sqlite3_step(d4)
      }
      if let d5 = toolbox.connection.prepareStaticStatement("DELETE FROM tensorhistorynode__f66 WHERE rowid=?1") {
        _rowid.bindSQLite(d5, parameterId: 1)
        sqlite3_step(d5)
      }
      if let d6 = toolbox.connection.prepareStaticStatement("DELETE FROM tensorhistorynode__f70 WHERE rowid=?1") {
        _rowid.bindSQLite(d6, parameterId: 1)
        sqlite3_step(d6)
      }
      if let d7 = toolbox.connection.prepareStaticStatement("DELETE FROM tensorhistorynode__f86 WHERE rowid=?1") {
        _rowid.bindSQLite(d7, parameterId: 1)
        sqlite3_step(d7)
      }
      _type = .none
      return .deleted(_rowid)
    case .none:
      preconditionFailure()
    }
  }
}
