import Dflat
import FlatBuffers

public extension ScriptSession {

  private static func _tr__f4(_ table: ByteBuffer) -> UInt64? {
    let tr0 = zzz_DflatGen_ScriptSession.getRootAsScriptSession(bb: table)
    return tr0.id
  }
  private static func _or__f4(_ or0: ScriptSession) -> UInt64? {
    return or0.id
  }
  static let id: FieldExpr<UInt64, ScriptSession> = FieldExpr(name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f6(_ table: ByteBuffer) -> UInt64? {
    let tr0 = zzz_DflatGen_ScriptSession.getRootAsScriptSession(bb: table)
    return tr0.executionGroupId
  }
  private static func _or__f6(_ or0: ScriptSession) -> UInt64? {
    return or0.executionGroupId
  }
  static let executionGroupId: FieldExpr<UInt64, ScriptSession> = FieldExpr(name: "f6", primaryKey: false, hasIndex: false, tableReader: _tr__f6, objectReader: _or__f6)

  private static func _tr__f8(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_ScriptSession.getRootAsScriptSession(bb: table)
    guard let s = tr0.file else { return nil }
    return s
  }
  private static func _or__f8(_ or0: ScriptSession) -> String? {
    guard let s = or0.file else { return nil }
    return s
  }
  static let file: FieldExpr<String, ScriptSession> = FieldExpr(name: "f8", primaryKey: false, hasIndex: true, tableReader: _tr__f8, objectReader: _or__f8)
}
