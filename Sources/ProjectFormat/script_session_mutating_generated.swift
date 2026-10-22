import Dflat
import SQLiteDflat
import SQLite3
import FlatBuffers
import Foundation

// MARK - SQLiteValue for Enumerations

// MARK - Serializer

extension ScriptSession: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __file = self.file.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    var __models = [Offset]()
    for i in models {
      __models.append(flatBufferBuilder.create(string: i))
    }
    let __vector_models = flatBufferBuilder.createVector(ofOffsets: __models)
    var __loras = [Offset]()
    for i in loras {
      __loras.append(flatBufferBuilder.create(string: i))
    }
    let __vector_loras = flatBufferBuilder.createVector(ofOffsets: __loras)
    var __controls = [Offset]()
    for i in controls {
      __controls.append(flatBufferBuilder.create(string: i))
    }
    let __vector_controls = flatBufferBuilder.createVector(ofOffsets: __controls)
    let start = zzz_DflatGen_ScriptSession.startScriptSession(&flatBufferBuilder)
    zzz_DflatGen_ScriptSession.add(id: self.id, &flatBufferBuilder)
    zzz_DflatGen_ScriptSession.add(executionGroupId: self.executionGroupId, &flatBufferBuilder)
    zzz_DflatGen_ScriptSession.add(file: __file, &flatBufferBuilder)
    zzz_DflatGen_ScriptSession.addVectorOf(models: __vector_models, &flatBufferBuilder)
    zzz_DflatGen_ScriptSession.addVectorOf(loras: __vector_loras, &flatBufferBuilder)
    zzz_DflatGen_ScriptSession.addVectorOf(controls: __vector_controls, &flatBufferBuilder)
    return zzz_DflatGen_ScriptSession.endScriptSession(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == ScriptSession {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension ScriptSession {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class ScriptSessionChangeRequest: Dflat.ChangeRequest {
  private var _o: ScriptSession?
  public typealias Element = ScriptSession
  public var _type: ChangeRequestType
  public var _rowid: Int64
  public var id: UInt64
  public var executionGroupId: UInt64
  public var file: String?
  public var models: [String]
  public var loras: [String]
  public var controls: [String]
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    id = 0
    executionGroupId = 0
    file = nil
    models = []
    loras = []
    controls = []
  }
  private init(type _type: ChangeRequestType, _ _o: ScriptSession) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    id = _o.id
    executionGroupId = _o.executionGroupId
    file = _o.file
    models = _o.models
    loras = _o.loras
    controls = _o.controls
  }
  public static func changeRequest(_ o: ScriptSession) -> ScriptSessionChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: ScriptSession.self, for: key)
    return u.map { ScriptSessionChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: ScriptSession) -> ScriptSessionChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    guard let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: ScriptSession.self, for: key) else {
      return Self.creationRequest(o)
    }
    let changeRequest = ScriptSessionChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: ScriptSession) -> ScriptSessionChangeRequest {
    let creationRequest = ScriptSessionChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> ScriptSessionChangeRequest {
    return ScriptSessionChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: ScriptSession) -> ScriptSessionChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: ScriptSession.self, for: key)
    return u.map { ScriptSessionChangeRequest(type: .deletion, $0) }
  }
  var _atom: ScriptSession {
    let atom = ScriptSession(id: id, executionGroupId: executionGroupId, file: file, models: models, loras: loras, controls: controls)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      let indexSurvey = toolbox.connection.indexSurvey(ScriptSession.indexFields, table: ScriptSession.table)
      guard let insert = toolbox.connection.prepareStaticStatement("INSERT INTO scriptsession (__pk0, p) VALUES (?1, ?2)") else { return nil }
      id.bindSQLite(insert, parameterId: 1)
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
      if indexSurvey.full.contains("f8") {
        guard let i0 = toolbox.connection.prepareStaticStatement("INSERT INTO scriptsession__f8 (rowid, f8) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i0, parameterId: 1)
        if let r0 = ScriptSession.file.evaluate(object: atom) {
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
      let indexSurvey = toolbox.connection.indexSurvey(ScriptSession.indexFields, table: ScriptSession.table)
      guard let update = toolbox.connection.prepareStaticStatement("REPLACE INTO scriptsession (__pk0, p, rowid) VALUES (?1, ?2, ?3)") else { return nil }
      id.bindSQLite(update, parameterId: 1)
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(update, 2, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      _rowid.bindSQLite(update, parameterId: 3)
      guard SQLITE_DONE == sqlite3_step(update) else { return nil }
      if indexSurvey.full.contains("f8") {
        let or0 = ScriptSession.file.evaluate(object: o)
        let r0 = ScriptSession.file.evaluate(object: atom)
        if or0 != r0 {
          guard let u0 = toolbox.connection.prepareStaticStatement("REPLACE INTO scriptsession__f8 (rowid, f8) VALUES (?1, ?2)") else { return nil }
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
      guard let deletion = toolbox.connection.prepareStaticStatement("DELETE FROM scriptsession WHERE rowid=?1") else { return nil }
      _rowid.bindSQLite(deletion, parameterId: 1)
      guard SQLITE_DONE == sqlite3_step(deletion) else { return nil }
      if let d0 = toolbox.connection.prepareStaticStatement("DELETE FROM scriptsession__f8 WHERE rowid=?1") {
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
