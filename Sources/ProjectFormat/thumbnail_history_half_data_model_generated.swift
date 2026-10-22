import Dflat
import FlatBuffers
import Foundation
import SQLiteDflat
import SQLite3

public final class ThumbnailHistoryHalfNode: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable, Equatable {
  public static func == (lhs: ThumbnailHistoryHalfNode, rhs: ThumbnailHistoryHalfNode) -> Bool {
    guard lhs.id == rhs.id else { return false }
    guard lhs.data == rhs.data else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let id: Int64
  public let data: [UInt8]
  public init(id: Int64, data: [UInt8]? = []) {
    self.id = id
    self.data = data ?? []
  }
  public init(_ obj: zzz_DflatGen_ThumbnailHistoryHalfNode) {
    self.id = obj.id
    self.data = obj.data
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!), capacity: buffer.count)
      return Self(zzz_DflatGen_ThumbnailHistoryHalfNode.getRootAsThumbnailHistoryHalfNode(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_ThumbnailHistoryHalfNode.getRootAsThumbnailHistoryHalfNode(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_ThumbnailHistoryHalfNode>.verify(&verifier, at: 0, of: zzz_DflatGen_ThumbnailHistoryHalfNode.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "thumbnailhistoryhalfnode" }
  public static var indexFields: [String] { [] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return }
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS thumbnailhistoryhalfnode (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, p BLOB, UNIQUE(__pk0))", nil, nil, nil)
  }
  public static func insertIndex(_ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer) -> Bool {
    return true
  }
}

public struct ThumbnailHistoryHalfNodeBuilder {
  public var id: Int64
  public var data: [UInt8]
  public init(from object: ThumbnailHistoryHalfNode) {
    id = object.id
    data = object.data
  }
  public func build() -> ThumbnailHistoryHalfNode {
    ThumbnailHistoryHalfNode(id: id, data: data)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
extension ThumbnailHistoryHalfNode: @unchecked Sendable {}
#endif
