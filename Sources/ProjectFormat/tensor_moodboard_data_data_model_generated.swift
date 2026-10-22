import Dflat
import FlatBuffers
import Foundation
import SQLiteDflat
import SQLite3

public final class TensorMoodboardData: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable, Equatable {
  public static func == (lhs: TensorMoodboardData, rhs: TensorMoodboardData) -> Bool {
    guard lhs.lineage == rhs.lineage else { return false }
    guard lhs.logicalTime == rhs.logicalTime else { return false }
    guard lhs.index == rhs.index else { return false }
    guard lhs.shuffleId == rhs.shuffleId else { return false }
    guard lhs.weight == rhs.weight else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let lineage: Int64
  public let logicalTime: Int64
  public let index: Int64
  public let shuffleId: Int64
  public let weight: Float32
  public init(lineage: Int64, logicalTime: Int64, index: Int64, shuffleId: Int64? = 0, weight: Float32? = 0.0) {
    self.lineage = lineage
    self.logicalTime = logicalTime
    self.index = index
    self.shuffleId = shuffleId ?? 0
    self.weight = weight ?? 0.0
  }
  public init(_ obj: zzz_DflatGen_TensorMoodboardData) {
    self.lineage = obj.lineage
    self.logicalTime = obj.logicalTime
    self.index = obj.index
    self.shuffleId = obj.shuffleId
    self.weight = obj.weight
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!), capacity: buffer.count)
      return Self(zzz_DflatGen_TensorMoodboardData.getRootAsTensorMoodboardData(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_TensorMoodboardData.getRootAsTensorMoodboardData(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_TensorMoodboardData>.verify(&verifier, at: 0, of: zzz_DflatGen_TensorMoodboardData.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "tensormoodboarddata" }
  public static var indexFields: [String] { ["f10"] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return }
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensormoodboarddata (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, __pk1 INTEGER, __pk2 INTEGER, p BLOB, UNIQUE(__pk0, __pk1, __pk2))", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensormoodboarddata__f10 (rowid INTEGER PRIMARY KEY, f10 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensormoodboarddata__f10 ON tensormoodboarddata__f10 (f10)", nil, nil, nil)
    sqlite.clearIndexStatus(for: Self.table)
  }
  public static func insertIndex(_ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer) -> Bool {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return false }
    switch field {
    case "f10":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensormoodboarddata__f10 (rowid, f10) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorMoodboardData.shuffleId.evaluate(byteBuffer: table) {
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

public struct TensorMoodboardDataBuilder {
  public var lineage: Int64
  public var logicalTime: Int64
  public var index: Int64
  public var shuffleId: Int64
  public var weight: Float32
  public init(from object: TensorMoodboardData) {
    lineage = object.lineage
    logicalTime = object.logicalTime
    index = object.index
    shuffleId = object.shuffleId
    weight = object.weight
  }
  public func build() -> TensorMoodboardData {
    TensorMoodboardData(lineage: lineage, logicalTime: logicalTime, index: index, shuffleId: shuffleId, weight: weight)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
extension TensorMoodboardData: @unchecked Sendable {}
#endif
