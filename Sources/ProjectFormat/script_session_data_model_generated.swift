import Dflat
import FlatBuffers
import Foundation
import SQLiteDflat
import SQLite3

public final class ScriptSession: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable, Equatable {
  public static func == (lhs: ScriptSession, rhs: ScriptSession) -> Bool {
    guard lhs.id == rhs.id else { return false }
    guard lhs.executionGroupId == rhs.executionGroupId else { return false }
    guard lhs.file == rhs.file else { return false }
    guard lhs.models == rhs.models else { return false }
    guard lhs.loras == rhs.loras else { return false }
    guard lhs.controls == rhs.controls else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let id: UInt64
  public let executionGroupId: UInt64
  public let file: String?
  public let models: [String]
  public let loras: [String]
  public let controls: [String]
  public init(id: UInt64, executionGroupId: UInt64? = 0, file: String? = nil, models: [String]? = [], loras: [String]? = [], controls: [String]? = []) {
    self.id = id
    self.executionGroupId = executionGroupId ?? 0
    self.file = file ?? nil
    self.models = models ?? []
    self.loras = loras ?? []
    self.controls = controls ?? []
  }
  public init(_ obj: zzz_DflatGen_ScriptSession) {
    self.id = obj.id
    self.executionGroupId = obj.executionGroupId
    self.file = obj.file
    var __models = [String]()
    for i: Int32 in 0..<obj.modelsCount {
      guard let o = obj.models(at: i) else { break }
      __models.append(String(o))
    }
    self.models = __models
    var __loras = [String]()
    for i: Int32 in 0..<obj.lorasCount {
      guard let o = obj.loras(at: i) else { break }
      __loras.append(String(o))
    }
    self.loras = __loras
    var __controls = [String]()
    for i: Int32 in 0..<obj.controlsCount {
      guard let o = obj.controls(at: i) else { break }
      __controls.append(String(o))
    }
    self.controls = __controls
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!), capacity: buffer.count)
      return Self(zzz_DflatGen_ScriptSession.getRootAsScriptSession(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_ScriptSession.getRootAsScriptSession(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_ScriptSession>.verify(&verifier, at: 0, of: zzz_DflatGen_ScriptSession.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "scriptsession" }
  public static var indexFields: [String] { ["f8"] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return }
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS scriptsession (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, p BLOB, UNIQUE(__pk0))", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS scriptsession__f8 (rowid INTEGER PRIMARY KEY, f8 TEXT)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__scriptsession__f8 ON scriptsession__f8 (f8)", nil, nil, nil)
    sqlite.clearIndexStatus(for: Self.table)
  }
  public static func insertIndex(_ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer) -> Bool {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return false }
    switch field {
    case "f8":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO scriptsession__f8 (rowid, f8) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = ScriptSession.file.evaluate(byteBuffer: table) {
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

public struct ScriptSessionBuilder {
  public var id: UInt64
  public var executionGroupId: UInt64
  public var file: String?
  public var models: [String]
  public var loras: [String]
  public var controls: [String]
  public init(from object: ScriptSession) {
    id = object.id
    executionGroupId = object.executionGroupId
    file = object.file
    models = object.models
    loras = object.loras
    controls = object.controls
  }
  public func build() -> ScriptSession {
    ScriptSession(id: id, executionGroupId: executionGroupId, file: file, models: models, loras: loras, controls: controls)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
extension ScriptSession: @unchecked Sendable {}
#endif
