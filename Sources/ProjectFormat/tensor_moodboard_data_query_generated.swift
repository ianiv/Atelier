import Dflat
import FlatBuffers

public extension TensorMoodboardData {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorMoodboardData.getRootAsTensorMoodboardData(bb: table)
    return tr0.lineage
  }
  private static func _or__f4(_ or0: TensorMoodboardData) -> Int64? {
    return or0.lineage
  }
  static let lineage: FieldExpr<Int64, TensorMoodboardData> = FieldExpr(name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f6(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorMoodboardData.getRootAsTensorMoodboardData(bb: table)
    return tr0.logicalTime
  }
  private static func _or__f6(_ or0: TensorMoodboardData) -> Int64? {
    return or0.logicalTime
  }
  static let logicalTime: FieldExpr<Int64, TensorMoodboardData> = FieldExpr(name: "__pk1", primaryKey: true, hasIndex: false, tableReader: _tr__f6, objectReader: _or__f6)

  private static func _tr__f8(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorMoodboardData.getRootAsTensorMoodboardData(bb: table)
    return tr0.index
  }
  private static func _or__f8(_ or0: TensorMoodboardData) -> Int64? {
    return or0.index
  }
  static let index: FieldExpr<Int64, TensorMoodboardData> = FieldExpr(name: "__pk2", primaryKey: true, hasIndex: false, tableReader: _tr__f8, objectReader: _or__f8)

  private static func _tr__f10(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_TensorMoodboardData.getRootAsTensorMoodboardData(bb: table)
    return tr0.shuffleId
  }
  private static func _or__f10(_ or0: TensorMoodboardData) -> Int64? {
    return or0.shuffleId
  }
  static let shuffleId: FieldExpr<Int64, TensorMoodboardData> = FieldExpr(name: "f10", primaryKey: false, hasIndex: true, tableReader: _tr__f10, objectReader: _or__f10)

  private static func _tr__f12(_ table: ByteBuffer) -> Float32? {
    let tr0 = zzz_DflatGen_TensorMoodboardData.getRootAsTensorMoodboardData(bb: table)
    return tr0.weight
  }
  private static func _or__f12(_ or0: TensorMoodboardData) -> Float32? {
    return or0.weight
  }
  static let weight: FieldExpr<Float32, TensorMoodboardData> = FieldExpr(name: "f12", primaryKey: false, hasIndex: false, tableReader: _tr__f12, objectReader: _or__f12)
}
