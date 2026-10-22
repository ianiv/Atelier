import Dflat
import FlatBuffers

public extension TensorData {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.lineage
  }
  private static func _or__f4(_ or0: TensorData) -> Int64? {
    return or0.lineage
  }
  static let lineage: FieldExpr<Int64, TensorData> = FieldExpr(name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f6(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.logicalTime
  }
  private static func _or__f6(_ or0: TensorData) -> Int64? {
    return or0.logicalTime
  }
  static let logicalTime: FieldExpr<Int64, TensorData> = FieldExpr(name: "__pk1", primaryKey: true, hasIndex: false, tableReader: _tr__f6, objectReader: _or__f6)

  private static func _tr__f8(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.index
  }
  private static func _or__f8(_ or0: TensorData) -> Int64? {
    return or0.index
  }
  static let index: FieldExpr<Int64, TensorData> = FieldExpr(name: "__pk2", primaryKey: true, hasIndex: false, tableReader: _tr__f8, objectReader: _or__f8)

  private static func _tr__f10(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.x
  }
  private static func _or__f10(_ or0: TensorData) -> Int32? {
    return or0.x
  }
  static let x: FieldExpr<Int32, TensorData> = FieldExpr(name: "f10", primaryKey: false, hasIndex: false, tableReader: _tr__f10, objectReader: _or__f10)

  private static func _tr__f12(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.y
  }
  private static func _or__f12(_ or0: TensorData) -> Int32? {
    return or0.y
  }
  static let y: FieldExpr<Int32, TensorData> = FieldExpr(name: "f12", primaryKey: false, hasIndex: false, tableReader: _tr__f12, objectReader: _or__f12)

  private static func _tr__f14(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.width
  }
  private static func _or__f14(_ or0: TensorData) -> Int32? {
    return or0.width
  }
  static let width: FieldExpr<Int32, TensorData> = FieldExpr(name: "f14", primaryKey: false, hasIndex: false, tableReader: _tr__f14, objectReader: _or__f14)

  private static func _tr__f16(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.height
  }
  private static func _or__f16(_ or0: TensorData) -> Int32? {
    return or0.height
  }
  static let height: FieldExpr<Int32, TensorData> = FieldExpr(name: "f16", primaryKey: false, hasIndex: false, tableReader: _tr__f16, objectReader: _or__f16)

  private static func _tr__f18(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.scaleFactorBy120
  }
  private static func _or__f18(_ or0: TensorData) -> Int32? {
    return or0.scaleFactorBy120
  }
  static let scaleFactorBy120: FieldExpr<Int32, TensorData> = FieldExpr(name: "f18", primaryKey: false, hasIndex: false, tableReader: _tr__f18, objectReader: _or__f18)

  private static func _tr__f20(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.tensorId
  }
  private static func _or__f20(_ or0: TensorData) -> Int64? {
    return or0.tensorId
  }
  static let tensorId: FieldExpr<Int64, TensorData> = FieldExpr(name: "f20", primaryKey: false, hasIndex: true, tableReader: _tr__f20, objectReader: _or__f20)

  private static func _tr__f22(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.maskId
  }
  private static func _or__f22(_ or0: TensorData) -> Int64? {
    return or0.maskId
  }
  static let maskId: FieldExpr<Int64, TensorData> = FieldExpr(name: "f22", primaryKey: false, hasIndex: true, tableReader: _tr__f22, objectReader: _or__f22)

  private static func _tr__f24(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.depthMapId
  }
  private static func _or__f24(_ or0: TensorData) -> Int64? {
    return or0.depthMapId
  }
  static let depthMapId: FieldExpr<Int64, TensorData> = FieldExpr(name: "f24", primaryKey: false, hasIndex: true, tableReader: _tr__f24, objectReader: _or__f24)

  private static func _tr__f26(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.scribbleId
  }
  private static func _or__f26(_ or0: TensorData) -> Int64? {
    return or0.scribbleId
  }
  static let scribbleId: FieldExpr<Int64, TensorData> = FieldExpr(name: "f26", primaryKey: false, hasIndex: true, tableReader: _tr__f26, objectReader: _or__f26)

  private static func _tr__f28(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.poseId
  }
  private static func _or__f28(_ or0: TensorData) -> Int64? {
    return or0.poseId
  }
  static let poseId: FieldExpr<Int64, TensorData> = FieldExpr(name: "f28", primaryKey: false, hasIndex: true, tableReader: _tr__f28, objectReader: _or__f28)

  private static func _tr__f30(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.colorPaletteId
  }
  private static func _or__f30(_ or0: TensorData) -> Int64? {
    return or0.colorPaletteId
  }
  static let colorPaletteId: FieldExpr<Int64, TensorData> = FieldExpr(name: "f30", primaryKey: false, hasIndex: true, tableReader: _tr__f30, objectReader: _or__f30)

  private static func _tr__f32(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorData.getRootAsTensorData(bb: table)
    return tr0.customId
  }
  private static func _or__f32(_ or0: TensorData) -> Int64? {
    return or0.customId
  }
  static let customId: FieldExpr<Int64, TensorData> = FieldExpr(name: "f32", primaryKey: false, hasIndex: true, tableReader: _tr__f32, objectReader: _or__f32)
}
