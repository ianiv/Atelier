import Dflat
import SQLiteDflat
import SQLite3
import FlatBuffers
import Foundation

// MARK - SQLiteValue for Enumerations

// MARK - Serializer

extension TensorMoodboardData: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let start = zzz_DflatGen_TensorMoodboardData.startTensorMoodboardData(&flatBufferBuilder)
    zzz_DflatGen_TensorMoodboardData.add(lineage: self.lineage, &flatBufferBuilder)
    zzz_DflatGen_TensorMoodboardData.add(logicalTime: self.logicalTime, &flatBufferBuilder)
    zzz_DflatGen_TensorMoodboardData.add(index: self.index, &flatBufferBuilder)
    zzz_DflatGen_TensorMoodboardData.add(shuffleId: self.shuffleId, &flatBufferBuilder)
    zzz_DflatGen_TensorMoodboardData.add(weight: self.weight, &flatBufferBuilder)
    return zzz_DflatGen_TensorMoodboardData.endTensorMoodboardData(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == TensorMoodboardData {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension TensorMoodboardData {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class TensorMoodboardDataChangeRequest: Dflat.ChangeRequest {
  private var _o: TensorMoodboardData?
  public typealias Element = TensorMoodboardData
  public var _type: ChangeRequestType
  public var _rowid: Int64
  public var lineage: Int64
  public var logicalTime: Int64
  public var index: Int64
  public var shuffleId: Int64
  public var weight: Float32
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    lineage = 0
    logicalTime = 0
    index = 0
    shuffleId = 0
    weight = 0.0
  }
  private init(type _type: ChangeRequestType, _ _o: TensorMoodboardData) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    lineage = _o.lineage
    logicalTime = _o.logicalTime
    index = _o.index
    shuffleId = _o.shuffleId
    weight = _o.weight
  }
  public static func changeRequest(_ o: TensorMoodboardData) -> TensorMoodboardDataChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.lineage, o.logicalTime, o.index])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: TensorMoodboardData.self, for: key)
    return u.map { TensorMoodboardDataChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: TensorMoodboardData) -> TensorMoodboardDataChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.lineage, o.logicalTime, o.index])
    guard let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: TensorMoodboardData.self, for: key) else {
      return Self.creationRequest(o)
    }
    let changeRequest = TensorMoodboardDataChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: TensorMoodboardData) -> TensorMoodboardDataChangeRequest {
    let creationRequest = TensorMoodboardDataChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> TensorMoodboardDataChangeRequest {
    return TensorMoodboardDataChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: TensorMoodboardData) -> TensorMoodboardDataChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.lineage, o.logicalTime, o.index])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: TensorMoodboardData.self, for: key)
    return u.map { TensorMoodboardDataChangeRequest(type: .deletion, $0) }
  }
  var _atom: TensorMoodboardData {
    let atom = TensorMoodboardData(lineage: lineage, logicalTime: logicalTime, index: index, shuffleId: shuffleId, weight: weight)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      let indexSurvey = toolbox.connection.indexSurvey(TensorMoodboardData.indexFields, table: TensorMoodboardData.table)
      guard let insert = toolbox.connection.prepareStaticStatement("INSERT INTO tensormoodboarddata (__pk0, __pk1, __pk2, p) VALUES (?1, ?2, ?3, ?4)") else { return nil }
      lineage.bindSQLite(insert, parameterId: 1)
      logicalTime.bindSQLite(insert, parameterId: 2)
      index.bindSQLite(insert, parameterId: 3)
      let atom = self._atom
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(insert, 4, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      guard SQLITE_DONE == sqlite3_step(insert) else { return nil }
      _rowid = sqlite3_last_insert_rowid(toolbox.connection.sqlite)
      if indexSurvey.full.contains("f10") {
        guard let i0 = toolbox.connection.prepareStaticStatement("INSERT INTO tensormoodboarddata__f10 (rowid, f10) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i0, parameterId: 1)
        if let r0 = TensorMoodboardData.shuffleId.evaluate(object: atom) {
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
      let indexSurvey = toolbox.connection.indexSurvey(TensorMoodboardData.indexFields, table: TensorMoodboardData.table)
      guard let update = toolbox.connection.prepareStaticStatement("REPLACE INTO tensormoodboarddata (__pk0, __pk1, __pk2, p, rowid) VALUES (?1, ?2, ?3, ?4, ?5)") else { return nil }
      lineage.bindSQLite(update, parameterId: 1)
      logicalTime.bindSQLite(update, parameterId: 2)
      index.bindSQLite(update, parameterId: 3)
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(update, 4, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      _rowid.bindSQLite(update, parameterId: 5)
      guard SQLITE_DONE == sqlite3_step(update) else { return nil }
      if indexSurvey.full.contains("f10") {
        let or0 = TensorMoodboardData.shuffleId.evaluate(object: o)
        let r0 = TensorMoodboardData.shuffleId.evaluate(object: atom)
        if or0 != r0 {
          guard let u0 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensormoodboarddata__f10 (rowid, f10) VALUES (?1, ?2)") else { return nil }
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
      guard let deletion = toolbox.connection.prepareStaticStatement("DELETE FROM tensormoodboarddata WHERE rowid=?1") else { return nil }
      _rowid.bindSQLite(deletion, parameterId: 1)
      guard SQLITE_DONE == sqlite3_step(deletion) else { return nil }
      if let d0 = toolbox.connection.prepareStaticStatement("DELETE FROM tensormoodboarddata__f10 WHERE rowid=?1") {
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
