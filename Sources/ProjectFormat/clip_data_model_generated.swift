import Dflat
import FlatBuffers
import Foundation
import SQLiteDflat
import SQLite3

public final class Clip: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable, Equatable {
  public static func == (lhs: Clip, rhs: Clip) -> Bool {
    guard lhs.clipId == rhs.clipId else { return false }
    guard lhs.count == rhs.count else { return false }
    guard lhs.framesPerSecond == rhs.framesPerSecond else { return false }
    guard lhs.width == rhs.width else { return false }
    guard lhs.height == rhs.height else { return false }
    guard lhs.audioId == rhs.audioId else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let clipId: Int64
  public let count: Int32
  public let framesPerSecond: Double
  public let width: Int32
  public let height: Int32
  public let audioId: Int64
  public init(clipId: Int64, count: Int32? = 0, framesPerSecond: Double? = 0.0, width: Int32? = 0, height: Int32? = 0, audioId: Int64? = 0) {
    self.clipId = clipId
    self.count = count ?? 0
    self.framesPerSecond = framesPerSecond ?? 0.0
    self.width = width ?? 0
    self.height = height ?? 0
    self.audioId = audioId ?? 0
  }
  public init(_ obj: zzz_DflatGen_Clip) {
    self.clipId = obj.clipId
    self.count = obj.count
    self.framesPerSecond = obj.framesPerSecond
    self.width = obj.width
    self.height = obj.height
    self.audioId = obj.audioId
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!), capacity: buffer.count)
      return Self(zzz_DflatGen_Clip.getRootAsClip(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_Clip.getRootAsClip(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_Clip>.verify(&verifier, at: 0, of: zzz_DflatGen_Clip.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "clip" }
  public static var indexFields: [String] { ["f14"] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return }
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS clip (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, p BLOB, UNIQUE(__pk0))", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS clip__f14 (rowid INTEGER PRIMARY KEY, f14 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__clip__f14 ON clip__f14 (f14)", nil, nil, nil)
    sqlite.clearIndexStatus(for: Self.table)
  }
  public static func insertIndex(_ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer) -> Bool {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return false }
    switch field {
    case "f14":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO clip__f14 (rowid, f14) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = Clip.audioId.evaluate(byteBuffer: table) {
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

public struct ClipBuilder {
  public var clipId: Int64
  public var count: Int32
  public var framesPerSecond: Double
  public var width: Int32
  public var height: Int32
  public var audioId: Int64
  public init(from object: Clip) {
    clipId = object.clipId
    count = object.count
    framesPerSecond = object.framesPerSecond
    width = object.width
    height = object.height
    audioId = object.audioId
  }
  public func build() -> Clip {
    Clip(clipId: clipId, count: count, framesPerSecond: framesPerSecond, width: width, height: height, audioId: audioId)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
extension Clip: @unchecked Sendable {}
#endif
