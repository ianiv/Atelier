import Dflat
import FlatBuffers

public extension Clip {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_Clip.getRootAsClip(bb: table)
    return tr0.clipId
  }
  private static func _or__f4(_ or0: Clip) -> Int64? {
    return or0.clipId
  }
  static let clipId: FieldExpr<Int64, Clip> = FieldExpr(name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f6(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_Clip.getRootAsClip(bb: table)
    return tr0.count
  }
  private static func _or__f6(_ or0: Clip) -> Int32? {
    return or0.count
  }
  static let count: FieldExpr<Int32, Clip> = FieldExpr(name: "f6", primaryKey: false, hasIndex: false, tableReader: _tr__f6, objectReader: _or__f6)

  private static func _tr__f8(_ table: ByteBuffer) -> Double? {
    let tr0 = zzz_DflatGen_Clip.getRootAsClip(bb: table)
    return tr0.framesPerSecond
  }
  private static func _or__f8(_ or0: Clip) -> Double? {
    return or0.framesPerSecond
  }
  static let framesPerSecond: FieldExpr<Double, Clip> = FieldExpr(name: "f8", primaryKey: false, hasIndex: false, tableReader: _tr__f8, objectReader: _or__f8)

  private static func _tr__f10(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_Clip.getRootAsClip(bb: table)
    return tr0.width
  }
  private static func _or__f10(_ or0: Clip) -> Int32? {
    return or0.width
  }
  static let width: FieldExpr<Int32, Clip> = FieldExpr(name: "f10", primaryKey: false, hasIndex: false, tableReader: _tr__f10, objectReader: _or__f10)

  private static func _tr__f12(_ table: ByteBuffer) -> Int32? {
    let tr0 = zzz_DflatGen_Clip.getRootAsClip(bb: table)
    return tr0.height
  }
  private static func _or__f12(_ or0: Clip) -> Int32? {
    return or0.height
  }
  static let height: FieldExpr<Int32, Clip> = FieldExpr(name: "f12", primaryKey: false, hasIndex: false, tableReader: _tr__f12, objectReader: _or__f12)

  private static func _tr__f14(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_Clip.getRootAsClip(bb: table)
    return tr0.audioId
  }
  private static func _or__f14(_ or0: Clip) -> Int64? {
    return or0.audioId
  }
  static let audioId: FieldExpr<Int64, Clip> = FieldExpr(name: "f14", primaryKey: false, hasIndex: true, tableReader: _tr__f14, objectReader: _or__f14)
}
