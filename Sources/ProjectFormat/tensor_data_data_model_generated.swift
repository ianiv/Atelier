import Dflat
import FlatBuffers
import Foundation
import SQLiteDflat
import SQLite3

public final class TensorData: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable, Equatable {
  public static func == (lhs: TensorData, rhs: TensorData) -> Bool {
    guard lhs.lineage == rhs.lineage else { return false }
    guard lhs.logicalTime == rhs.logicalTime else { return false }
    guard lhs.index == rhs.index else { return false }
    guard lhs.x == rhs.x else { return false }
    guard lhs.y == rhs.y else { return false }
    guard lhs.width == rhs.width else { return false }
    guard lhs.height == rhs.height else { return false }
    guard lhs.scaleFactorBy120 == rhs.scaleFactorBy120 else { return false }
    guard lhs.tensorId == rhs.tensorId else { return false }
    guard lhs.maskId == rhs.maskId else { return false }
    guard lhs.depthMapId == rhs.depthMapId else { return false }
    guard lhs.scribbleId == rhs.scribbleId else { return false }
    guard lhs.poseId == rhs.poseId else { return false }
    guard lhs.colorPaletteId == rhs.colorPaletteId else { return false }
    guard lhs.customId == rhs.customId else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let lineage: Int64
  public let logicalTime: Int64
  public let index: Int64
  public let x: Int32
  public let y: Int32
  public let width: Int32
  public let height: Int32
  public let scaleFactorBy120: Int32
  public let tensorId: Int64
  public let maskId: Int64
  public let depthMapId: Int64
  public let scribbleId: Int64
  public let poseId: Int64
  public let colorPaletteId: Int64
  public let customId: Int64
  public init(lineage: Int64, logicalTime: Int64, index: Int64, x: Int32? = 0, y: Int32? = 0, width: Int32? = 0, height: Int32? = 0, scaleFactorBy120: Int32? = 0, tensorId: Int64? = 0, maskId: Int64? = 0, depthMapId: Int64? = 0, scribbleId: Int64? = 0, poseId: Int64? = 0, colorPaletteId: Int64? = 0, customId: Int64? = 0) {
    self.lineage = lineage
    self.logicalTime = logicalTime
    self.index = index
    self.x = x ?? 0
    self.y = y ?? 0
    self.width = width ?? 0
    self.height = height ?? 0
    self.scaleFactorBy120 = scaleFactorBy120 ?? 0
    self.tensorId = tensorId ?? 0
    self.maskId = maskId ?? 0
    self.depthMapId = depthMapId ?? 0
    self.scribbleId = scribbleId ?? 0
    self.poseId = poseId ?? 0
    self.colorPaletteId = colorPaletteId ?? 0
    self.customId = customId ?? 0
  }
  public init(_ obj: zzz_DflatGen_TensorData) {
    self.lineage = obj.lineage
    self.logicalTime = obj.logicalTime
    self.index = obj.index
    self.x = obj.x
    self.y = obj.y
    self.width = obj.width
    self.height = obj.height
    self.scaleFactorBy120 = obj.scaleFactorBy120
    self.tensorId = obj.tensorId
    self.maskId = obj.maskId
    self.depthMapId = obj.depthMapId
    self.scribbleId = obj.scribbleId
    self.poseId = obj.poseId
    self.colorPaletteId = obj.colorPaletteId
    self.customId = obj.customId
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!), capacity: buffer.count)
      return Self(zzz_DflatGen_TensorData.getRootAsTensorData(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_TensorData.getRootAsTensorData(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_TensorData>.verify(&verifier, at: 0, of: zzz_DflatGen_TensorData.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "tensordata" }
  public static var indexFields: [String] { ["f20", "f22", "f24", "f26", "f28", "f30", "f32"] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return }
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensordata (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, __pk1 INTEGER, __pk2 INTEGER, p BLOB, UNIQUE(__pk0, __pk1, __pk2))", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensordata__f20 (rowid INTEGER PRIMARY KEY, f20 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensordata__f20 ON tensordata__f20 (f20)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensordata__f22 (rowid INTEGER PRIMARY KEY, f22 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensordata__f22 ON tensordata__f22 (f22)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensordata__f24 (rowid INTEGER PRIMARY KEY, f24 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensordata__f24 ON tensordata__f24 (f24)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensordata__f26 (rowid INTEGER PRIMARY KEY, f26 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensordata__f26 ON tensordata__f26 (f26)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensordata__f28 (rowid INTEGER PRIMARY KEY, f28 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensordata__f28 ON tensordata__f28 (f28)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensordata__f30 (rowid INTEGER PRIMARY KEY, f30 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensordata__f30 ON tensordata__f30 (f30)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE TABLE IF NOT EXISTS tensordata__f32 (rowid INTEGER PRIMARY KEY, f32 INTEGER)", nil, nil, nil)
    sqlite3_exec(sqlite.sqlite, "CREATE INDEX IF NOT EXISTS index__tensordata__f32 ON tensordata__f32 (f32)", nil, nil, nil)
    sqlite.clearIndexStatus(for: Self.table)
  }
  public static func insertIndex(_ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer) -> Bool {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else { return false }
    switch field {
    case "f20":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensordata__f20 (rowid, f20) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorData.tensorId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f22":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensordata__f22 (rowid, f22) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorData.maskId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f24":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensordata__f24 (rowid, f24) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorData.depthMapId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f26":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensordata__f26 (rowid, f26) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorData.scribbleId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f28":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensordata__f28 (rowid, f28) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorData.poseId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f30":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensordata__f30 (rowid, f30) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorData.colorPaletteId.evaluate(byteBuffer: table) {
        retval.bindSQLite(insert, parameterId: 2)
      } else {
        sqlite3_bind_null(insert, 2)
      }
      guard SQLITE_DONE == sqlite3_step(insert) else { return false }
    case "f32":
      guard let insert = sqlite.prepareStaticStatement("INSERT INTO tensordata__f32 (rowid, f32) VALUES (?1, ?2)") else { return false }
      rowid.bindSQLite(insert, parameterId: 1)
      if let retval = TensorData.customId.evaluate(byteBuffer: table) {
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

public struct TensorDataBuilder {
  public var lineage: Int64
  public var logicalTime: Int64
  public var index: Int64
  public var x: Int32
  public var y: Int32
  public var width: Int32
  public var height: Int32
  public var scaleFactorBy120: Int32
  public var tensorId: Int64
  public var maskId: Int64
  public var depthMapId: Int64
  public var scribbleId: Int64
  public var poseId: Int64
  public var colorPaletteId: Int64
  public var customId: Int64
  public init(from object: TensorData) {
    lineage = object.lineage
    logicalTime = object.logicalTime
    index = object.index
    x = object.x
    y = object.y
    width = object.width
    height = object.height
    scaleFactorBy120 = object.scaleFactorBy120
    tensorId = object.tensorId
    maskId = object.maskId
    depthMapId = object.depthMapId
    scribbleId = object.scribbleId
    poseId = object.poseId
    colorPaletteId = object.colorPaletteId
    customId = object.customId
  }
  public func build() -> TensorData {
    TensorData(lineage: lineage, logicalTime: logicalTime, index: index, x: x, y: y, width: width, height: height, scaleFactorBy120: scaleFactorBy120, tensorId: tensorId, maskId: maskId, depthMapId: depthMapId, scribbleId: scribbleId, poseId: poseId, colorPaletteId: colorPaletteId, customId: customId)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
extension TensorData: @unchecked Sendable {}
#endif
