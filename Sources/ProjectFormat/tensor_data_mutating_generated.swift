import Dflat
import SQLiteDflat
import SQLite3
import FlatBuffers
import Foundation

// MARK - SQLiteValue for Enumerations

// MARK - Serializer

extension TensorData: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let start = zzz_DflatGen_TensorData.startTensorData(&flatBufferBuilder)
    zzz_DflatGen_TensorData.add(lineage: self.lineage, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(logicalTime: self.logicalTime, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(index: self.index, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(x: self.x, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(y: self.y, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(width: self.width, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(height: self.height, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(scaleFactorBy120: self.scaleFactorBy120, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(tensorId: self.tensorId, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(maskId: self.maskId, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(depthMapId: self.depthMapId, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(scribbleId: self.scribbleId, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(poseId: self.poseId, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(colorPaletteId: self.colorPaletteId, &flatBufferBuilder)
    zzz_DflatGen_TensorData.add(customId: self.customId, &flatBufferBuilder)
    return zzz_DflatGen_TensorData.endTensorData(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == TensorData {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension TensorData {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class TensorDataChangeRequest: Dflat.ChangeRequest {
  private var _o: TensorData?
  public typealias Element = TensorData
  public var _type: ChangeRequestType
  public var _rowid: Int64
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
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    lineage = 0
    logicalTime = 0
    index = 0
    x = 0
    y = 0
    width = 0
    height = 0
    scaleFactorBy120 = 0
    tensorId = 0
    maskId = 0
    depthMapId = 0
    scribbleId = 0
    poseId = 0
    colorPaletteId = 0
    customId = 0
  }
  private init(type _type: ChangeRequestType, _ _o: TensorData) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    lineage = _o.lineage
    logicalTime = _o.logicalTime
    index = _o.index
    x = _o.x
    y = _o.y
    width = _o.width
    height = _o.height
    scaleFactorBy120 = _o.scaleFactorBy120
    tensorId = _o.tensorId
    maskId = _o.maskId
    depthMapId = _o.depthMapId
    scribbleId = _o.scribbleId
    poseId = _o.poseId
    colorPaletteId = _o.colorPaletteId
    customId = _o.customId
  }
  public static func changeRequest(_ o: TensorData) -> TensorDataChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.lineage, o.logicalTime, o.index])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: TensorData.self, for: key)
    return u.map { TensorDataChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: TensorData) -> TensorDataChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.lineage, o.logicalTime, o.index])
    guard let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: TensorData.self, for: key) else {
      return Self.creationRequest(o)
    }
    let changeRequest = TensorDataChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: TensorData) -> TensorDataChangeRequest {
    let creationRequest = TensorDataChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> TensorDataChangeRequest {
    return TensorDataChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: TensorData) -> TensorDataChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.lineage, o.logicalTime, o.index])
    let u = transactionContext.objectRepository.object(transactionContext.connection, ofType: TensorData.self, for: key)
    return u.map { TensorDataChangeRequest(type: .deletion, $0) }
  }
  var _atom: TensorData {
    let atom = TensorData(lineage: lineage, logicalTime: logicalTime, index: index, x: x, y: y, width: width, height: height, scaleFactorBy120: scaleFactorBy120, tensorId: tensorId, maskId: maskId, depthMapId: depthMapId, scribbleId: scribbleId, poseId: poseId, colorPaletteId: colorPaletteId, customId: customId)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      let indexSurvey = toolbox.connection.indexSurvey(TensorData.indexFields, table: TensorData.table)
      guard let insert = toolbox.connection.prepareStaticStatement("INSERT INTO tensordata (__pk0, __pk1, __pk2, p) VALUES (?1, ?2, ?3, ?4)") else { return nil }
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
      if indexSurvey.full.contains("f20") {
        guard let i0 = toolbox.connection.prepareStaticStatement("INSERT INTO tensordata__f20 (rowid, f20) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i0, parameterId: 1)
        if let r0 = TensorData.tensorId.evaluate(object: atom) {
          r0.bindSQLite(i0, parameterId: 2)
        } else {
          sqlite3_bind_null(i0, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i0) else { return nil }
      }
      if indexSurvey.full.contains("f22") {
        guard let i1 = toolbox.connection.prepareStaticStatement("INSERT INTO tensordata__f22 (rowid, f22) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i1, parameterId: 1)
        if let r1 = TensorData.maskId.evaluate(object: atom) {
          r1.bindSQLite(i1, parameterId: 2)
        } else {
          sqlite3_bind_null(i1, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i1) else { return nil }
      }
      if indexSurvey.full.contains("f24") {
        guard let i2 = toolbox.connection.prepareStaticStatement("INSERT INTO tensordata__f24 (rowid, f24) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i2, parameterId: 1)
        if let r2 = TensorData.depthMapId.evaluate(object: atom) {
          r2.bindSQLite(i2, parameterId: 2)
        } else {
          sqlite3_bind_null(i2, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i2) else { return nil }
      }
      if indexSurvey.full.contains("f26") {
        guard let i3 = toolbox.connection.prepareStaticStatement("INSERT INTO tensordata__f26 (rowid, f26) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i3, parameterId: 1)
        if let r3 = TensorData.scribbleId.evaluate(object: atom) {
          r3.bindSQLite(i3, parameterId: 2)
        } else {
          sqlite3_bind_null(i3, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i3) else { return nil }
      }
      if indexSurvey.full.contains("f28") {
        guard let i4 = toolbox.connection.prepareStaticStatement("INSERT INTO tensordata__f28 (rowid, f28) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i4, parameterId: 1)
        if let r4 = TensorData.poseId.evaluate(object: atom) {
          r4.bindSQLite(i4, parameterId: 2)
        } else {
          sqlite3_bind_null(i4, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i4) else { return nil }
      }
      if indexSurvey.full.contains("f30") {
        guard let i5 = toolbox.connection.prepareStaticStatement("INSERT INTO tensordata__f30 (rowid, f30) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i5, parameterId: 1)
        if let r5 = TensorData.colorPaletteId.evaluate(object: atom) {
          r5.bindSQLite(i5, parameterId: 2)
        } else {
          sqlite3_bind_null(i5, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i5) else { return nil }
      }
      if indexSurvey.full.contains("f32") {
        guard let i6 = toolbox.connection.prepareStaticStatement("INSERT INTO tensordata__f32 (rowid, f32) VALUES (?1, ?2)") else { return nil }
        _rowid.bindSQLite(i6, parameterId: 1)
        if let r6 = TensorData.customId.evaluate(object: atom) {
          r6.bindSQLite(i6, parameterId: 2)
        } else {
          sqlite3_bind_null(i6, 2)
        }
        guard SQLITE_DONE == sqlite3_step(i6) else { return nil }
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
      let indexSurvey = toolbox.connection.indexSurvey(TensorData.indexFields, table: TensorData.table)
      guard let update = toolbox.connection.prepareStaticStatement("REPLACE INTO tensordata (__pk0, __pk1, __pk2, p, rowid) VALUES (?1, ?2, ?3, ?4, ?5)") else { return nil }
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
      if indexSurvey.full.contains("f20") {
        let or0 = TensorData.tensorId.evaluate(object: o)
        let r0 = TensorData.tensorId.evaluate(object: atom)
        if or0 != r0 {
          guard let u0 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensordata__f20 (rowid, f20) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u0, parameterId: 1)
          if let ur0 = r0 {
            ur0.bindSQLite(u0, parameterId: 2)
          } else {
            sqlite3_bind_null(u0, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u0) else { return nil }
        }
      }
      if indexSurvey.full.contains("f22") {
        let or1 = TensorData.maskId.evaluate(object: o)
        let r1 = TensorData.maskId.evaluate(object: atom)
        if or1 != r1 {
          guard let u1 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensordata__f22 (rowid, f22) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u1, parameterId: 1)
          if let ur1 = r1 {
            ur1.bindSQLite(u1, parameterId: 2)
          } else {
            sqlite3_bind_null(u1, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u1) else { return nil }
        }
      }
      if indexSurvey.full.contains("f24") {
        let or2 = TensorData.depthMapId.evaluate(object: o)
        let r2 = TensorData.depthMapId.evaluate(object: atom)
        if or2 != r2 {
          guard let u2 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensordata__f24 (rowid, f24) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u2, parameterId: 1)
          if let ur2 = r2 {
            ur2.bindSQLite(u2, parameterId: 2)
          } else {
            sqlite3_bind_null(u2, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u2) else { return nil }
        }
      }
      if indexSurvey.full.contains("f26") {
        let or3 = TensorData.scribbleId.evaluate(object: o)
        let r3 = TensorData.scribbleId.evaluate(object: atom)
        if or3 != r3 {
          guard let u3 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensordata__f26 (rowid, f26) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u3, parameterId: 1)
          if let ur3 = r3 {
            ur3.bindSQLite(u3, parameterId: 2)
          } else {
            sqlite3_bind_null(u3, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u3) else { return nil }
        }
      }
      if indexSurvey.full.contains("f28") {
        let or4 = TensorData.poseId.evaluate(object: o)
        let r4 = TensorData.poseId.evaluate(object: atom)
        if or4 != r4 {
          guard let u4 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensordata__f28 (rowid, f28) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u4, parameterId: 1)
          if let ur4 = r4 {
            ur4.bindSQLite(u4, parameterId: 2)
          } else {
            sqlite3_bind_null(u4, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u4) else { return nil }
        }
      }
      if indexSurvey.full.contains("f30") {
        let or5 = TensorData.colorPaletteId.evaluate(object: o)
        let r5 = TensorData.colorPaletteId.evaluate(object: atom)
        if or5 != r5 {
          guard let u5 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensordata__f30 (rowid, f30) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u5, parameterId: 1)
          if let ur5 = r5 {
            ur5.bindSQLite(u5, parameterId: 2)
          } else {
            sqlite3_bind_null(u5, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u5) else { return nil }
        }
      }
      if indexSurvey.full.contains("f32") {
        let or6 = TensorData.customId.evaluate(object: o)
        let r6 = TensorData.customId.evaluate(object: atom)
        if or6 != r6 {
          guard let u6 = toolbox.connection.prepareStaticStatement("REPLACE INTO tensordata__f32 (rowid, f32) VALUES (?1, ?2)") else { return nil }
          _rowid.bindSQLite(u6, parameterId: 1)
          if let ur6 = r6 {
            ur6.bindSQLite(u6, parameterId: 2)
          } else {
            sqlite3_bind_null(u6, 2)
          }
          guard SQLITE_DONE == sqlite3_step(u6) else { return nil }
        }
      }
      _type = .none
      return .updated(atom)
    case .deletion:
      guard let deletion = toolbox.connection.prepareStaticStatement("DELETE FROM tensordata WHERE rowid=?1") else { return nil }
      _rowid.bindSQLite(deletion, parameterId: 1)
      guard SQLITE_DONE == sqlite3_step(deletion) else { return nil }
      if let d0 = toolbox.connection.prepareStaticStatement("DELETE FROM tensordata__f20 WHERE rowid=?1") {
        _rowid.bindSQLite(d0, parameterId: 1)
        sqlite3_step(d0)
      }
      if let d1 = toolbox.connection.prepareStaticStatement("DELETE FROM tensordata__f22 WHERE rowid=?1") {
        _rowid.bindSQLite(d1, parameterId: 1)
        sqlite3_step(d1)
      }
      if let d2 = toolbox.connection.prepareStaticStatement("DELETE FROM tensordata__f24 WHERE rowid=?1") {
        _rowid.bindSQLite(d2, parameterId: 1)
        sqlite3_step(d2)
      }
      if let d3 = toolbox.connection.prepareStaticStatement("DELETE FROM tensordata__f26 WHERE rowid=?1") {
        _rowid.bindSQLite(d3, parameterId: 1)
        sqlite3_step(d3)
      }
      if let d4 = toolbox.connection.prepareStaticStatement("DELETE FROM tensordata__f28 WHERE rowid=?1") {
        _rowid.bindSQLite(d4, parameterId: 1)
        sqlite3_step(d4)
      }
      if let d5 = toolbox.connection.prepareStaticStatement("DELETE FROM tensordata__f30 WHERE rowid=?1") {
        _rowid.bindSQLite(d5, parameterId: 1)
        sqlite3_step(d5)
      }
      if let d6 = toolbox.connection.prepareStaticStatement("DELETE FROM tensordata__f32 WHERE rowid=?1") {
        _rowid.bindSQLite(d6, parameterId: 1)
        sqlite3_step(d6)
      }
      _type = .none
      return .deleted(_rowid)
    case .none:
      preconditionFailure()
    }
  }
}
