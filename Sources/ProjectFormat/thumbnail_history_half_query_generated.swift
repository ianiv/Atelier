import Dflat
import FlatBuffers

public extension ThumbnailHistoryHalfNode {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ThumbnailHistoryHalfNode.getRootAsThumbnailHistoryHalfNode(bb: table)
    return tr0.id
  }
  private static func _or__f4(_ or0: ThumbnailHistoryHalfNode) -> Int64? {
    return or0.id
  }
  static let id: FieldExpr<Int64, ThumbnailHistoryHalfNode> = FieldExpr(name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)
}
