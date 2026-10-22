import Dflat
import FlatBuffers

public extension TensorHistoryNode {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.lineage
  }
  private static func _or__f4(_ or0: TensorHistoryNode) -> Int64? {
    return or0.lineage
  }
  static let lineage: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f6(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.logicalTime
  }
  private static func _or__f6(_ or0: TensorHistoryNode) -> Int64? {
    return or0.logicalTime
  }
  static let logicalTime: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "__pk1", primaryKey: true, hasIndex: false, tableReader: _tr__f6, objectReader: _or__f6)

  private static func _tr__f8(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.startWidth
  }
  private static func _or__f8(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.startWidth
  }
  static let startWidth: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f8", primaryKey: false, hasIndex: false, tableReader: _tr__f8, objectReader: _or__f8)

  private static func _tr__f10(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.startHeight
  }
  private static func _or__f10(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.startHeight
  }
  static let startHeight: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f10", primaryKey: false, hasIndex: false, tableReader: _tr__f10, objectReader: _or__f10)

  private static func _tr__f12(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.seed
  }
  private static func _or__f12(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.seed
  }
  static let seed: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f12", primaryKey: false, hasIndex: false, tableReader: _tr__f12, objectReader: _or__f12)

  private static func _tr__f14(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.steps
  }
  private static func _or__f14(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.steps
  }
  static let steps: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f14", primaryKey: false, hasIndex: false, tableReader: _tr__f14, objectReader: _or__f14)

  private static func _tr__f16(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.guidanceScale
  }
  private static func _or__f16(_ or0: TensorHistoryNode) -> Float32? {
    return or0.guidanceScale
  }
  static let guidanceScale: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f16", primaryKey: false, hasIndex: false, tableReader: _tr__f16, objectReader: _or__f16)

  private static func _tr__f18(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.strength
  }
  private static func _or__f18(_ or0: TensorHistoryNode) -> Float32? {
    return or0.strength
  }
  static let strength: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f18", primaryKey: false, hasIndex: false, tableReader: _tr__f18, objectReader: _or__f18)

  private static func _tr__f20(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    guard let s = tr0.model else { return nil }
    return s
  }
  private static func _or__f20(_ or0: TensorHistoryNode) -> String? {
    guard let s = or0.model else { return nil }
    return s
  }
  static let model: FieldExpr<String, TensorHistoryNode> = FieldExpr(name: "f20", primaryKey: false, hasIndex: false, tableReader: _tr__f20, objectReader: _or__f20)

  private static func _tr__f22(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.tensorId
  }
  private static func _or__f22(_ or0: TensorHistoryNode) -> Int64? {
    return or0.tensorId
  }
  static let tensorId: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f22", primaryKey: false, hasIndex: true, tableReader: _tr__f22, objectReader: _or__f22)

  private static func _tr__f24(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.maskId
  }
  private static func _or__f24(_ or0: TensorHistoryNode) -> Int64? {
    return or0.maskId
  }
  static let maskId: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f24", primaryKey: false, hasIndex: true, tableReader: _tr__f24, objectReader: _or__f24)

  private static func _tr__f26(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.wallClock
  }
  private static func _or__f26(_ or0: TensorHistoryNode) -> Int64? {
    return or0.wallClock
  }
  static let wallClock: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f26", primaryKey: false, hasIndex: false, tableReader: _tr__f26, objectReader: _or__f26)

  private static func _tr__f28(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.textEdits
  }
  private static func _or__f28(_ or0: TensorHistoryNode) -> Int64? {
    return or0.textEdits
  }
  static let textEdits: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f28", primaryKey: false, hasIndex: false, tableReader: _tr__f28, objectReader: _or__f28)

  private static func _tr__f30(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.textLineage
  }
  private static func _or__f30(_ or0: TensorHistoryNode) -> Int64? {
    return or0.textLineage
  }
  static let textLineage: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f30", primaryKey: false, hasIndex: false, tableReader: _tr__f30, objectReader: _or__f30)

  private static func _tr__f32(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.batchSize
  }
  private static func _or__f32(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.batchSize
  }
  static let batchSize: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f32", primaryKey: false, hasIndex: false, tableReader: _tr__f32, objectReader: _or__f32)

  private static func _tr__f34(_ table: ByteBuffer) -> SamplerType? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return SamplerType(rawValue: tr0.sampler.rawValue)!
  }
  private static func _or__f34(_ or0: TensorHistoryNode) -> SamplerType? {
    return or0.sampler
  }
  static let sampler: FieldExpr<SamplerType, TensorHistoryNode> = FieldExpr(name: "f34", primaryKey: false, hasIndex: false, tableReader: _tr__f34, objectReader: _or__f34)

  private static func _tr__f36(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.hiresFix
  }
  private static func _or__f36(_ or0: TensorHistoryNode) -> Bool? {
    return or0.hiresFix
  }
  static let hiresFix: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f36", primaryKey: false, hasIndex: false, tableReader: _tr__f36, objectReader: _or__f36)

  private static func _tr__f38(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.hiresFixStartWidth
  }
  private static func _or__f38(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.hiresFixStartWidth
  }
  static let hiresFixStartWidth: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f38", primaryKey: false, hasIndex: false, tableReader: _tr__f38, objectReader: _or__f38)

  private static func _tr__f40(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.hiresFixStartHeight
  }
  private static func _or__f40(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.hiresFixStartHeight
  }
  static let hiresFixStartHeight: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f40", primaryKey: false, hasIndex: false, tableReader: _tr__f40, objectReader: _or__f40)

  private static func _tr__f42(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.hiresFixStrength
  }
  private static func _or__f42(_ or0: TensorHistoryNode) -> Float32? {
    return or0.hiresFixStrength
  }
  static let hiresFixStrength: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f42", primaryKey: false, hasIndex: false, tableReader: _tr__f42, objectReader: _or__f42)

  private static func _tr__f44(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    guard let s = tr0.upscaler else { return nil }
    return s
  }
  private static func _or__f44(_ or0: TensorHistoryNode) -> String? {
    guard let s = or0.upscaler else { return nil }
    return s
  }
  static let upscaler: FieldExpr<String, TensorHistoryNode> = FieldExpr(name: "f44", primaryKey: false, hasIndex: false, tableReader: _tr__f44, objectReader: _or__f44)

  private static func _tr__f46(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.scaleFactor
  }
  private static func _or__f46(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.scaleFactor
  }
  static let scaleFactor: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f46", primaryKey: false, hasIndex: false, tableReader: _tr__f46, objectReader: _or__f46)

  private static func _tr__f48(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.depthMapId
  }
  private static func _or__f48(_ or0: TensorHistoryNode) -> Int64? {
    return or0.depthMapId
  }
  static let depthMapId: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f48", primaryKey: false, hasIndex: true, tableReader: _tr__f48, objectReader: _or__f48)

  private static func _tr__f50(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.generated
  }
  private static func _or__f50(_ or0: TensorHistoryNode) -> Bool? {
    return or0.generated
  }
  static let generated: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f50", primaryKey: false, hasIndex: false, tableReader: _tr__f50, objectReader: _or__f50)

  private static func _tr__f52(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.imageGuidanceScale
  }
  private static func _or__f52(_ or0: TensorHistoryNode) -> Float32? {
    return or0.imageGuidanceScale
  }
  static let imageGuidanceScale: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f52", primaryKey: false, hasIndex: false, tableReader: _tr__f52, objectReader: _or__f52)

  private static func _tr__f54(_ table: ByteBuffer) -> SeedMode? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return SeedMode(rawValue: tr0.seedMode.rawValue)!
  }
  private static func _or__f54(_ or0: TensorHistoryNode) -> SeedMode? {
    return or0.seedMode
  }
  static let seedMode: FieldExpr<SeedMode, TensorHistoryNode> = FieldExpr(name: "f54", primaryKey: false, hasIndex: false, tableReader: _tr__f54, objectReader: _or__f54)

  private static func _tr__f56(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.clipSkip
  }
  private static func _or__f56(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.clipSkip
  }
  static let clipSkip: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f56", primaryKey: false, hasIndex: false, tableReader: _tr__f56, objectReader: _or__f56)

  private static func _tr__f60(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.scribbleId
  }
  private static func _or__f60(_ or0: TensorHistoryNode) -> Int64? {
    return or0.scribbleId
  }
  static let scribbleId: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f60", primaryKey: false, hasIndex: true, tableReader: _tr__f60, objectReader: _or__f60)

  private static func _tr__f62(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.poseId
  }
  private static func _or__f62(_ or0: TensorHistoryNode) -> Int64? {
    return or0.poseId
  }
  static let poseId: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f62", primaryKey: false, hasIndex: true, tableReader: _tr__f62, objectReader: _or__f62)

  private static func _tr__f66(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.colorPaletteId
  }
  private static func _or__f66(_ or0: TensorHistoryNode) -> Int64? {
    return or0.colorPaletteId
  }
  static let colorPaletteId: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f66", primaryKey: false, hasIndex: true, tableReader: _tr__f66, objectReader: _or__f66)

  private static func _tr__f68(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.maskBlur
  }
  private static func _or__f68(_ or0: TensorHistoryNode) -> Float32? {
    return or0.maskBlur
  }
  static let maskBlur: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f68", primaryKey: false, hasIndex: false, tableReader: _tr__f68, objectReader: _or__f68)

  private static func _tr__f70(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.customId
  }
  private static func _or__f70(_ or0: TensorHistoryNode) -> Int64? {
    return or0.customId
  }
  static let customId: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f70", primaryKey: false, hasIndex: true, tableReader: _tr__f70, objectReader: _or__f70)

  private static func _tr__f72(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    guard let s = tr0.faceRestoration else { return nil }
    return s
  }
  private static func _or__f72(_ or0: TensorHistoryNode) -> String? {
    guard let s = or0.faceRestoration else { return nil }
    return s
  }
  static let faceRestoration: FieldExpr<String, TensorHistoryNode> = FieldExpr(name: "f72", primaryKey: false, hasIndex: false, tableReader: _tr__f72, objectReader: _or__f72)

  private static func _tr__f78(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.clipWeight
  }
  private static func _or__f78(_ or0: TensorHistoryNode) -> Float32? {
    return or0.clipWeight
  }
  static let clipWeight: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f78", primaryKey: false, hasIndex: false, tableReader: _tr__f78, objectReader: _or__f78)

  private static func _tr__f80(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.negativePromptForImagePrior
  }
  private static func _or__f80(_ or0: TensorHistoryNode) -> Bool? {
    return or0.negativePromptForImagePrior
  }
  static let negativePromptForImagePrior: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f80", primaryKey: false, hasIndex: false, tableReader: _tr__f80, objectReader: _or__f80)

  private static func _tr__f82(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.imagePriorSteps
  }
  private static func _or__f82(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.imagePriorSteps
  }
  static let imagePriorSteps: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f82", primaryKey: false, hasIndex: false, tableReader: _tr__f82, objectReader: _or__f82)

  private static func _tr__f84(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.dataStored
  }
  private static func _or__f84(_ or0: TensorHistoryNode) -> Int32? {
    return or0.dataStored
  }
  static let dataStored: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f84", primaryKey: false, hasIndex: false, tableReader: _tr__f84, objectReader: _or__f84)

  private static func _tr__f86(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.previewId
  }
  private static func _or__f86(_ or0: TensorHistoryNode) -> Int64? {
    return or0.previewId
  }
  static let previewId: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f86", primaryKey: false, hasIndex: true, tableReader: _tr__f86, objectReader: _or__f86)

  private static func _tr__f88(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.contentOffsetX
  }
  private static func _or__f88(_ or0: TensorHistoryNode) -> Int32? {
    return or0.contentOffsetX
  }
  static let contentOffsetX: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f88", primaryKey: false, hasIndex: false, tableReader: _tr__f88, objectReader: _or__f88)

  private static func _tr__f90(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.contentOffsetY
  }
  private static func _or__f90(_ or0: TensorHistoryNode) -> Int32? {
    return or0.contentOffsetY
  }
  static let contentOffsetY: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f90", primaryKey: false, hasIndex: false, tableReader: _tr__f90, objectReader: _or__f90)

  private static func _tr__f92(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.scaleFactorBy120
  }
  private static func _or__f92(_ or0: TensorHistoryNode) -> Int32? {
    return or0.scaleFactorBy120
  }
  static let scaleFactorBy120: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f92", primaryKey: false, hasIndex: false, tableReader: _tr__f92, objectReader: _or__f92)

  private static func _tr__f94(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    guard let s = tr0.refinerModel else { return nil }
    return s
  }
  private static func _or__f94(_ or0: TensorHistoryNode) -> String? {
    guard let s = or0.refinerModel else { return nil }
    return s
  }
  static let refinerModel: FieldExpr<String, TensorHistoryNode> = FieldExpr(name: "f94", primaryKey: false, hasIndex: false, tableReader: _tr__f94, objectReader: _or__f94)

  private static func _tr__f96(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.originalImageHeight
  }
  private static func _or__f96(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.originalImageHeight
  }
  static let originalImageHeight: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f96", primaryKey: false, hasIndex: false, tableReader: _tr__f96, objectReader: _or__f96)

  private static func _tr__f98(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.originalImageWidth
  }
  private static func _or__f98(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.originalImageWidth
  }
  static let originalImageWidth: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f98", primaryKey: false, hasIndex: false, tableReader: _tr__f98, objectReader: _or__f98)

  private static func _tr__f100(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.cropTop
  }
  private static func _or__f100(_ or0: TensorHistoryNode) -> Int32? {
    return or0.cropTop
  }
  static let cropTop: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f100", primaryKey: false, hasIndex: false, tableReader: _tr__f100, objectReader: _or__f100)

  private static func _tr__f102(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.cropLeft
  }
  private static func _or__f102(_ or0: TensorHistoryNode) -> Int32? {
    return or0.cropLeft
  }
  static let cropLeft: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f102", primaryKey: false, hasIndex: false, tableReader: _tr__f102, objectReader: _or__f102)

  private static func _tr__f104(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.targetImageHeight
  }
  private static func _or__f104(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.targetImageHeight
  }
  static let targetImageHeight: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f104", primaryKey: false, hasIndex: false, tableReader: _tr__f104, objectReader: _or__f104)

  private static func _tr__f106(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.targetImageWidth
  }
  private static func _or__f106(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.targetImageWidth
  }
  static let targetImageWidth: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f106", primaryKey: false, hasIndex: false, tableReader: _tr__f106, objectReader: _or__f106)

  private static func _tr__f108(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.aestheticScore
  }
  private static func _or__f108(_ or0: TensorHistoryNode) -> Float32? {
    return or0.aestheticScore
  }
  static let aestheticScore: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f108", primaryKey: false, hasIndex: false, tableReader: _tr__f108, objectReader: _or__f108)

  private static func _tr__f110(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.negativeAestheticScore
  }
  private static func _or__f110(_ or0: TensorHistoryNode) -> Float32? {
    return or0.negativeAestheticScore
  }
  static let negativeAestheticScore: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f110", primaryKey: false, hasIndex: false, tableReader: _tr__f110, objectReader: _or__f110)

  private static func _tr__f112(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.zeroNegativePrompt
  }
  private static func _or__f112(_ or0: TensorHistoryNode) -> Bool? {
    return or0.zeroNegativePrompt
  }
  static let zeroNegativePrompt: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f112", primaryKey: false, hasIndex: false, tableReader: _tr__f112, objectReader: _or__f112)

  private static func _tr__f114(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.refinerStart
  }
  private static func _or__f114(_ or0: TensorHistoryNode) -> Float32? {
    return or0.refinerStart
  }
  static let refinerStart: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f114", primaryKey: false, hasIndex: false, tableReader: _tr__f114, objectReader: _or__f114)

  private static func _tr__f116(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.negativeOriginalImageHeight
  }
  private static func _or__f116(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.negativeOriginalImageHeight
  }
  static let negativeOriginalImageHeight: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f116", primaryKey: false, hasIndex: false, tableReader: _tr__f116, objectReader: _or__f116)

  private static func _tr__f118(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.negativeOriginalImageWidth
  }
  private static func _or__f118(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.negativeOriginalImageWidth
  }
  static let negativeOriginalImageWidth: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f118", primaryKey: false, hasIndex: false, tableReader: _tr__f118, objectReader: _or__f118)

  private static func _tr__f120(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.shuffleDataStored
  }
  private static func _or__f120(_ or0: TensorHistoryNode) -> Int32? {
    return or0.shuffleDataStored
  }
  static let shuffleDataStored: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f120", primaryKey: false, hasIndex: false, tableReader: _tr__f120, objectReader: _or__f120)

  private static func _tr__f122(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.fpsId
  }
  private static func _or__f122(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.fpsId
  }
  static let fpsId: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f122", primaryKey: false, hasIndex: false, tableReader: _tr__f122, objectReader: _or__f122)

  private static func _tr__f124(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.motionBucketId
  }
  private static func _or__f124(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.motionBucketId
  }
  static let motionBucketId: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f124", primaryKey: false, hasIndex: false, tableReader: _tr__f124, objectReader: _or__f124)

  private static func _tr__f126(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.condAug
  }
  private static func _or__f126(_ or0: TensorHistoryNode) -> Float32? {
    return or0.condAug
  }
  static let condAug: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f126", primaryKey: false, hasIndex: false, tableReader: _tr__f126, objectReader: _or__f126)

  private static func _tr__f128(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.startFrameCfg
  }
  private static func _or__f128(_ or0: TensorHistoryNode) -> Float32? {
    return or0.startFrameCfg
  }
  static let startFrameCfg: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f128", primaryKey: false, hasIndex: false, tableReader: _tr__f128, objectReader: _or__f128)

  private static func _tr__f130(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.numFrames
  }
  private static func _or__f130(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.numFrames
  }
  static let numFrames: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f130", primaryKey: false, hasIndex: false, tableReader: _tr__f130, objectReader: _or__f130)

  private static func _tr__f132(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.maskBlurOutset
  }
  private static func _or__f132(_ or0: TensorHistoryNode) -> Int32? {
    return or0.maskBlurOutset
  }
  static let maskBlurOutset: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f132", primaryKey: false, hasIndex: false, tableReader: _tr__f132, objectReader: _or__f132)

  private static func _tr__f134(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.sharpness
  }
  private static func _or__f134(_ or0: TensorHistoryNode) -> Float32? {
    return or0.sharpness
  }
  static let sharpness: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f134", primaryKey: false, hasIndex: false, tableReader: _tr__f134, objectReader: _or__f134)

  private static func _tr__f136(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.shift
  }
  private static func _or__f136(_ or0: TensorHistoryNode) -> Float32? {
    return or0.shift
  }
  static let shift: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f136", primaryKey: false, hasIndex: false, tableReader: _tr__f136, objectReader: _or__f136)

  private static func _tr__f138(_ table: ByteBuffer) -> UInt32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.stage2Steps
  }
  private static func _or__f138(_ or0: TensorHistoryNode) -> UInt32? {
    return or0.stage2Steps
  }
  static let stage2Steps: FieldExpr<UInt32, TensorHistoryNode> = FieldExpr(name: "f138", primaryKey: false, hasIndex: false, tableReader: _tr__f138, objectReader: _or__f138)

  private static func _tr__f140(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.stage2Cfg
  }
  private static func _or__f140(_ or0: TensorHistoryNode) -> Float32? {
    return or0.stage2Cfg
  }
  static let stage2Cfg: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f140", primaryKey: false, hasIndex: false, tableReader: _tr__f140, objectReader: _or__f140)

  private static func _tr__f142(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.stage2Shift
  }
  private static func _or__f142(_ or0: TensorHistoryNode) -> Float32? {
    return or0.stage2Shift
  }
  static let stage2Shift: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f142", primaryKey: false, hasIndex: false, tableReader: _tr__f142, objectReader: _or__f142)

  private static func _tr__f144(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.tiledDecoding
  }
  private static func _or__f144(_ or0: TensorHistoryNode) -> Bool? {
    return or0.tiledDecoding
  }
  static let tiledDecoding: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f144", primaryKey: false, hasIndex: false, tableReader: _tr__f144, objectReader: _or__f144)

  private static func _tr__f146(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.decodingTileWidth
  }
  private static func _or__f146(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.decodingTileWidth
  }
  static let decodingTileWidth: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f146", primaryKey: false, hasIndex: false, tableReader: _tr__f146, objectReader: _or__f146)

  private static func _tr__f148(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.decodingTileHeight
  }
  private static func _or__f148(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.decodingTileHeight
  }
  static let decodingTileHeight: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f148", primaryKey: false, hasIndex: false, tableReader: _tr__f148, objectReader: _or__f148)

  private static func _tr__f150(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.decodingTileOverlap
  }
  private static func _or__f150(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.decodingTileOverlap
  }
  static let decodingTileOverlap: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f150", primaryKey: false, hasIndex: false, tableReader: _tr__f150, objectReader: _or__f150)

  private static func _tr__f152(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.stochasticSamplingGamma
  }
  private static func _or__f152(_ or0: TensorHistoryNode) -> Float32? {
    return or0.stochasticSamplingGamma
  }
  static let stochasticSamplingGamma: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f152", primaryKey: false, hasIndex: false, tableReader: _tr__f152, objectReader: _or__f152)

  private static func _tr__f154(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.preserveOriginalAfterInpaint
  }
  private static func _or__f154(_ or0: TensorHistoryNode) -> Bool? {
    return or0.preserveOriginalAfterInpaint
  }
  static let preserveOriginalAfterInpaint: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f154", primaryKey: false, hasIndex: false, tableReader: _tr__f154, objectReader: _or__f154)

  private static func _tr__f156(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.tiledDiffusion
  }
  private static func _or__f156(_ or0: TensorHistoryNode) -> Bool? {
    return or0.tiledDiffusion
  }
  static let tiledDiffusion: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f156", primaryKey: false, hasIndex: false, tableReader: _tr__f156, objectReader: _or__f156)

  private static func _tr__f158(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.diffusionTileWidth
  }
  private static func _or__f158(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.diffusionTileWidth
  }
  static let diffusionTileWidth: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f158", primaryKey: false, hasIndex: false, tableReader: _tr__f158, objectReader: _or__f158)

  private static func _tr__f160(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.diffusionTileHeight
  }
  private static func _or__f160(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.diffusionTileHeight
  }
  static let diffusionTileHeight: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f160", primaryKey: false, hasIndex: false, tableReader: _tr__f160, objectReader: _or__f160)

  private static func _tr__f162(_ table: ByteBuffer) -> UInt16? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.diffusionTileOverlap
  }
  private static func _or__f162(_ or0: TensorHistoryNode) -> UInt16? {
    return or0.diffusionTileOverlap
  }
  static let diffusionTileOverlap: FieldExpr<UInt16, TensorHistoryNode> = FieldExpr(name: "f162", primaryKey: false, hasIndex: false, tableReader: _tr__f162, objectReader: _or__f162)

  private static func _tr__f164(_ table: ByteBuffer) -> UInt8? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.upscalerScaleFactor
  }
  private static func _or__f164(_ or0: TensorHistoryNode) -> UInt8? {
    return or0.upscalerScaleFactor
  }
  static let upscalerScaleFactor: FieldExpr<UInt8, TensorHistoryNode> = FieldExpr(name: "f164", primaryKey: false, hasIndex: false, tableReader: _tr__f164, objectReader: _or__f164)

  private static func _tr__f166(_ table: ByteBuffer) -> UInt64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.scriptSessionId
  }
  private static func _or__f166(_ or0: TensorHistoryNode) -> UInt64? {
    return or0.scriptSessionId
  }
  static let scriptSessionId: FieldExpr<UInt64, TensorHistoryNode> = FieldExpr(name: "f166", primaryKey: false, hasIndex: false, tableReader: _tr__f166, objectReader: _or__f166)

  private static func _tr__f168(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.t5TextEncoder
  }
  private static func _or__f168(_ or0: TensorHistoryNode) -> Bool? {
    return or0.t5TextEncoder
  }
  static let t5TextEncoder: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f168", primaryKey: false, hasIndex: false, tableReader: _tr__f168, objectReader: _or__f168)

  private static func _tr__f170(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.separateClipL
  }
  private static func _or__f170(_ or0: TensorHistoryNode) -> Bool? {
    return or0.separateClipL
  }
  static let separateClipL: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f170", primaryKey: false, hasIndex: false, tableReader: _tr__f170, objectReader: _or__f170)

  private static func _tr__f172(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    guard let s = tr0.clipLText else { return nil }
    return s
  }
  private static func _or__f172(_ or0: TensorHistoryNode) -> String? {
    guard let s = or0.clipLText else { return nil }
    return s
  }
  static let clipLText: FieldExpr<String, TensorHistoryNode> = FieldExpr(name: "f172", primaryKey: false, hasIndex: false, tableReader: _tr__f172, objectReader: _or__f172)

  private static func _tr__f174(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.separateOpenClipG
  }
  private static func _or__f174(_ or0: TensorHistoryNode) -> Bool? {
    return or0.separateOpenClipG
  }
  static let separateOpenClipG: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f174", primaryKey: false, hasIndex: false, tableReader: _tr__f174, objectReader: _or__f174)

  private static func _tr__f176(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    guard let s = tr0.openClipGText else { return nil }
    return s
  }
  private static func _or__f176(_ or0: TensorHistoryNode) -> String? {
    guard let s = or0.openClipGText else { return nil }
    return s
  }
  static let openClipGText: FieldExpr<String, TensorHistoryNode> = FieldExpr(name: "f176", primaryKey: false, hasIndex: false, tableReader: _tr__f176, objectReader: _or__f176)

  private static func _tr__f178(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.speedUpWithGuidanceEmbed
  }
  private static func _or__f178(_ or0: TensorHistoryNode) -> Bool? {
    return or0.speedUpWithGuidanceEmbed
  }
  static let speedUpWithGuidanceEmbed: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f178", primaryKey: false, hasIndex: false, tableReader: _tr__f178, objectReader: _or__f178)

  private static func _tr__f180(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.guidanceEmbed
  }
  private static func _or__f180(_ or0: TensorHistoryNode) -> Float32? {
    return or0.guidanceEmbed
  }
  static let guidanceEmbed: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f180", primaryKey: false, hasIndex: false, tableReader: _tr__f180, objectReader: _or__f180)

  private static func _tr__f182(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.resolutionDependentShift
  }
  private static func _or__f182(_ or0: TensorHistoryNode) -> Bool? {
    return or0.resolutionDependentShift
  }
  static let resolutionDependentShift: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f182", primaryKey: false, hasIndex: false, tableReader: _tr__f182, objectReader: _or__f182)

  private static func _tr__f186(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.teaCacheStart
  }
  private static func _or__f186(_ or0: TensorHistoryNode) -> Int32? {
    return or0.teaCacheStart
  }
  static let teaCacheStart: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f186", primaryKey: false, hasIndex: false, tableReader: _tr__f186, objectReader: _or__f186)

  private static func _tr__f188(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.teaCacheEnd
  }
  private static func _or__f188(_ or0: TensorHistoryNode) -> Int32? {
    return or0.teaCacheEnd
  }
  static let teaCacheEnd: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f188", primaryKey: false, hasIndex: false, tableReader: _tr__f188, objectReader: _or__f188)

  private static func _tr__f190(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.teaCacheThreshold
  }
  private static func _or__f190(_ or0: TensorHistoryNode) -> Float32? {
    return or0.teaCacheThreshold
  }
  static let teaCacheThreshold: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f190", primaryKey: false, hasIndex: false, tableReader: _tr__f190, objectReader: _or__f190)

  private static func _tr__f192(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.teaCache
  }
  private static func _or__f192(_ or0: TensorHistoryNode) -> Bool? {
    return or0.teaCache
  }
  static let teaCache: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f192", primaryKey: false, hasIndex: false, tableReader: _tr__f192, objectReader: _or__f192)

  private static func _tr__f194(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.separateT5
  }
  private static func _or__f194(_ or0: TensorHistoryNode) -> Bool? {
    return or0.separateT5
  }
  static let separateT5: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f194", primaryKey: false, hasIndex: false, tableReader: _tr__f194, objectReader: _or__f194)

  private static func _tr__f196(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    guard let s = tr0.t5Text else { return nil }
    return s
  }
  private static func _or__f196(_ or0: TensorHistoryNode) -> String? {
    guard let s = or0.t5Text else { return nil }
    return s
  }
  static let t5Text: FieldExpr<String, TensorHistoryNode> = FieldExpr(name: "f196", primaryKey: false, hasIndex: false, tableReader: _tr__f196, objectReader: _or__f196)

  private static func _tr__f198(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.teaCacheMaxSkipSteps
  }
  private static func _or__f198(_ or0: TensorHistoryNode) -> Int32? {
    return or0.teaCacheMaxSkipSteps
  }
  static let teaCacheMaxSkipSteps: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f198", primaryKey: false, hasIndex: false, tableReader: _tr__f198, objectReader: _or__f198)

  private static func _tr__f200(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    guard let s = tr0.textPrompt else { return nil }
    return s
  }
  private static func _or__f200(_ or0: TensorHistoryNode) -> String? {
    guard let s = or0.textPrompt else { return nil }
    return s
  }
  static let textPrompt: FieldExpr<String, TensorHistoryNode> = FieldExpr(name: "f200", primaryKey: false, hasIndex: false, tableReader: _tr__f200, objectReader: _or__f200)

  private static func _tr__f202(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    guard let s = tr0.negativeTextPrompt else { return nil }
    return s
  }
  private static func _or__f202(_ or0: TensorHistoryNode) -> String? {
    guard let s = or0.negativeTextPrompt else { return nil }
    return s
  }
  static let negativeTextPrompt: FieldExpr<String, TensorHistoryNode> = FieldExpr(name: "f202", primaryKey: false, hasIndex: false, tableReader: _tr__f202, objectReader: _or__f202)

  private static func _tr__f204(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.clipId
  }
  private static func _or__f204(_ or0: TensorHistoryNode) -> Int64? {
    return or0.clipId
  }
  static let clipId: FieldExpr<Int64, TensorHistoryNode> = FieldExpr(name: "f204", primaryKey: false, hasIndex: false, tableReader: _tr__f204, objectReader: _or__f204)

  private static func _tr__f206(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.indexInAClip
  }
  private static func _or__f206(_ or0: TensorHistoryNode) -> Int32? {
    return or0.indexInAClip
  }
  static let indexInAClip: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f206", primaryKey: false, hasIndex: false, tableReader: _tr__f206, objectReader: _or__f206)

  private static func _tr__f208(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.causalInferenceEnabled
  }
  private static func _or__f208(_ or0: TensorHistoryNode) -> Bool? {
    return or0.causalInferenceEnabled
  }
  static let causalInferenceEnabled: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f208", primaryKey: false, hasIndex: false, tableReader: _tr__f208, objectReader: _or__f208)

  private static func _tr__f210(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.causalInference
  }
  private static func _or__f210(_ or0: TensorHistoryNode) -> Int32? {
    return or0.causalInference
  }
  static let causalInference: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f210", primaryKey: false, hasIndex: false, tableReader: _tr__f210, objectReader: _or__f210)

  private static func _tr__f212(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.causalInferencePad
  }
  private static func _or__f212(_ or0: TensorHistoryNode) -> Int32? {
    return or0.causalInferencePad
  }
  static let causalInferencePad: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f212", primaryKey: false, hasIndex: false, tableReader: _tr__f212, objectReader: _or__f212)

  private static func _tr__f214(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.cfgZeroStar
  }
  private static func _or__f214(_ or0: TensorHistoryNode) -> Bool? {
    return or0.cfgZeroStar
  }
  static let cfgZeroStar: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f214", primaryKey: false, hasIndex: false, tableReader: _tr__f214, objectReader: _or__f214)

  private static func _tr__f216(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.cfgZeroInitSteps
  }
  private static func _or__f216(_ or0: TensorHistoryNode) -> Int32? {
    return or0.cfgZeroInitSteps
  }
  static let cfgZeroInitSteps: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f216", primaryKey: false, hasIndex: false, tableReader: _tr__f216, objectReader: _or__f216)

  private static func _tr__f218(_ table: ByteBuffer) -> Double? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.generationTime
  }
  private static func _or__f218(_ or0: TensorHistoryNode) -> Double? {
    return or0.generationTime
  }
  static let generationTime: FieldExpr<Double, TensorHistoryNode> = FieldExpr(name: "f218", primaryKey: false, hasIndex: false, tableReader: _tr__f218, objectReader: _or__f218)

  private static func _tr__f220(_ table: ByteBuffer) -> Reason? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return Reason(rawValue: tr0.reason.rawValue)!
  }
  private static func _or__f220(_ or0: TensorHistoryNode) -> Reason? {
    return or0.reason
  }
  static let reason: FieldExpr<Reason, TensorHistoryNode> = FieldExpr(name: "f220", primaryKey: false, hasIndex: false, tableReader: _tr__f220, objectReader: _or__f220)

  private static func _tr__f222(_ table: ByteBuffer) -> CompressionMethod? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return CompressionMethod(rawValue: tr0.compressionArtifacts.rawValue)!
  }
  private static func _or__f222(_ or0: TensorHistoryNode) -> CompressionMethod? {
    return or0.compressionArtifacts
  }
  static let compressionArtifacts: FieldExpr<CompressionMethod, TensorHistoryNode> = FieldExpr(name: "f222", primaryKey: false, hasIndex: false, tableReader: _tr__f222, objectReader: _or__f222)

  private static func _tr__f224(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.compressionArtifactsQuality
  }
  private static func _or__f224(_ or0: TensorHistoryNode) -> Float32? {
    return or0.compressionArtifactsQuality
  }
  static let compressionArtifactsQuality: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f224", primaryKey: false, hasIndex: false, tableReader: _tr__f224, objectReader: _or__f224)

  private static func _tr__f226(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.audio
  }
  private static func _or__f226(_ or0: TensorHistoryNode) -> Bool? {
    return or0.audio
  }
  static let audio: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f226", primaryKey: false, hasIndex: false, tableReader: _tr__f226, objectReader: _or__f226)

  private static func _tr__f228(_ table: ByteBuffer) -> ColorCalibration? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return ColorCalibration(rawValue: tr0.colorCalibration.rawValue)!
  }
  private static func _or__f228(_ or0: TensorHistoryNode) -> ColorCalibration? {
    return or0.colorCalibration
  }
  static let colorCalibration: FieldExpr<ColorCalibration, TensorHistoryNode> = FieldExpr(name: "f228", primaryKey: false, hasIndex: false, tableReader: _tr__f228, objectReader: _or__f228)

  private static func _tr__f230(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.expandPromptToJson
  }
  private static func _or__f230(_ or0: TensorHistoryNode) -> Bool? {
    return or0.expandPromptToJson
  }
  static let expandPromptToJson: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f230", primaryKey: false, hasIndex: false, tableReader: _tr__f230, objectReader: _or__f230)

  private static func _tr__f232(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.shiftForAudio
  }
  private static func _or__f232(_ or0: TensorHistoryNode) -> Float32? {
    return or0.shiftForAudio
  }
  static let shiftForAudio: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f232", primaryKey: false, hasIndex: false, tableReader: _tr__f232, objectReader: _or__f232)

  private static func _tr__f234(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.usesSolAttention
  }
  private static func _or__f234(_ or0: TensorHistoryNode) -> Bool? {
    return or0.usesSolAttention
  }
  static let usesSolAttention: FieldExpr<Bool, TensorHistoryNode> = FieldExpr(name: "f234", primaryKey: false, hasIndex: false, tableReader: _tr__f234, objectReader: _or__f234)

  private static func _tr__f236(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.solAttentionStart
  }
  private static func _or__f236(_ or0: TensorHistoryNode) -> Int32? {
    return or0.solAttentionStart
  }
  static let solAttentionStart: FieldExpr<Int32, TensorHistoryNode> = FieldExpr(name: "f236", primaryKey: false, hasIndex: false, tableReader: _tr__f236, objectReader: _or__f236)

  private static func _tr__f238(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorHistoryNode.getRootAsTensorHistoryNode(bb: table)
    return tr0.solAttentionTau
  }
  private static func _or__f238(_ or0: TensorHistoryNode) -> Float32? {
    return or0.solAttentionTau
  }
  static let solAttentionTau: FieldExpr<Float32, TensorHistoryNode> = FieldExpr(name: "f238", primaryKey: false, hasIndex: false, tableReader: _tr__f238, objectReader: _or__f238)
}
