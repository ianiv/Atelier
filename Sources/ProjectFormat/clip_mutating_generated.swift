import Dflat
import SQLiteDflat
import SQLite3
import FlatBuffers
import Foundation

// MARK - SQLiteValue for Enumerations

// MARK - Serializer

extension Clip: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let start = zzz_DflatGen_Clip.startClip(&flatBufferBuilder)
    zzz_DflatGen_Clip.add(clipId: self.clipId, &flatBufferBuilder)
    zzz_DflatGen_Clip.add(count: self.count, &flatBufferBuilder)
    zzz_DflatGen_Clip.add(framesPerSecond: self.framesPerSecond, &flatBufferBuilder)
    zzz_DflatGen_Clip.add(width: self.width, &flatBufferBuilder)
    zzz_DflatGen_Clip.add(height: self.height, &flatBufferBuilder)
    zzz_DflatGen_Clip.add(audioId: self.audioId, &flatBufferBuilder)
    return zzz_DflatGen_Clip.endClip(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == Clip {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension Clip {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class ClipChangeRequest: Dflat.ChangeRequest {
  private var _o: Clip?
  public typealias Element = Clip
  public var _type: ChangeRequestType
  public var _rowid: Int64
  public var clipId: Int64
  public var count: Int32
  public var framesPerSecond: Double
  public var width: Int32
  public var height: Int32
  public var audioId: Int64
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    clipId = 0
    count = 0
    framesPerSecond = 0.0
    width = 0
    height = 0
    audioId = 0
  }
  private init(type _type: ChangeRequestType, _ _o: Clip) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    clipId = _o.clipId
    count = _o.count
    framesPerSecond = _o.framesPerSecond
    width = _o.width
    height = _o.height
    audioId = _o.audioId
  }
  public static func changeRequest(_ o: Clip) -> ClipChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.clipId])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: Clip.self, for: key)
    return u.map { ClipChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: Clip) -> ClipChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.clipId])
    guard let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: Clip.self, for: key) else {
      return Self.creationRequest(o)
    }
    let changeRequest = ClipChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: Clip) -> ClipChangeRequest {
    let creationRequest = ClipChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> ClipChangeRequest {
    return ClipChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: Clip) -> ClipChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.clipId])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: Clip.self, for: key)
    return u.map { ClipChangeRequest(type: .deletion, $0) }
  }
  var _atom: Clip {
    let atom = Clip(clipId: clipId, count: count, framesPerSecond: framesPerSecond, width: width, height: height, audioId: audioId)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      let indexSurvey = toolbox.connection.indexSurvey(Clip.indexFields, table: Clip.table)
      guard let insert = toolbox.connection.prepareStaticStatement("INSERT INTO clip (__pk0, p) VALUES (?1, ?2)") else { return nil }
      clipId.bindSQLite(insert, parameterId: 1)
      let atom = self._atom
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(insert, 2, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      guard SQLITE_DONE == sqlite3_step(insert) else { return nil }
      _rowid = sqlite3_last_insert_rowid(toolbox.connection.sqlite)
      if indexSurvey.full.contains("f14") {
        guard let i0 = toolbox.connection.prepareStaticStatement("INSERT INTO clip__f14 (rowid, f14) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i0, parameterId: 1)
        if let r0 = Clip.audioId.evaluate(object: atom) {
          r0.bindSQLite(i0, parameterId: 2)
        } else {
          sqlite3_bind_null(i0, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i0) else { return nil }
      }
      _type = .none
      atom._rowid = _rowid
      return .inserted(atom)
    case .update:
      guard let o = _o else { return nil }
      let atom = self._atom
      guard atom != o else {
        _type = .none
        return .identity(atom)
      }
      let indexSurvey = toolbox.connection.indexSurvey(Clip.indexFields, table: Clip.table)
      guard let update = toolbox.connection.prepareStaticStatement("REPLACE INTO clip (__pk0, p, rowid) VALUES (?1, ?2, ?3)") else { return nil }
      clipId.bindSQLite(update, parameterId: 1)
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(update, 2, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      _rowid.bindSQLite(update, parameterId: 3)
      guard SQLITE_DONE == sqlite3_step(update) else { return nil }
      if indexSurvey.full.contains("f14") {
        let or0 = Clip.audioId.evaluate(object: o)
        let r0 = Clip.audioId.evaluate(object: atom)
        if or0 != r0 {
          guard let u0 = toolbox.connection.prepareStaticStatement("REPLACE INTO clip__f14 (rowid, f14) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u0, parameterId: 1)
          if let ur0 = r0 {
            ur0.bindSQLite(u0, parameterId: 2)
          } else {
            sqlite3_bind_null(u0, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u0) else { return nil }
        }
      }
      _type = .none
      return .updated(atom)
    case .deletion:
      guard let deletion = toolbox.connection.prepareStaticStatement("DELETE FROM clip WHERE rowid=?1") else { return nil }
      _rowid.bindSQLite(deletion, parameterId: 1)
      guard SQLITE_DONE == sqlite3_step(deletion) else { return nil }
      if let d0 = toolbox.connection.prepareStaticStatement("DELETE FROM clip__f14 WHERE rowid=?1") {
        _rowid.bindSQLite(d0, parameterId: 1)
        sqlite3_step(d0)
      }
      _type = .none
      return .deleted(_rowid)
    case .none:
      preconditionFailure()
    }
  }
}
