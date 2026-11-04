import CryptoKit
import Foundation

/// A server's files and jobs: uploads and results, by device, and who's connected to hear about
/// them. A device only ever reaches its own folder, so it can't learn what another one uploaded.
///
///     <root>/Blobs/<device>/<sha256>[.part]
///     <root>/Results/<device>/<job>.result and .json
actor RemoteJobStore {
  private struct Record: Codable {
    var deviceID: UUID
    var createdAt: Date
    /// The latest event, without its previews.
    var event: RemoteJobEvent
    /// The job in this machine's queue, while it's there.
    var queueID: UUID?
  }

  nonisolated let root: URL
  private var records: [UUID: Record] = [:]
  private var listeners: [UUID: (device: UUID, connection: RemoteConnection)] = [:]

  init(root: URL) {
    self.root = root
    records = Self.loadRecords(in: root)
  }

  private nonisolated var results: URL { root.appending(path: "Results", directoryHint: .isDirectory) }
  private nonisolated func blobs(_ device: UUID) -> URL {
    root.appending(path: "Blobs/\(device.uuidString)", directoryHint: .isDirectory)
  }

  private nonisolated func resultURL(_ device: UUID, _ job: UUID) -> URL {
    results.appending(path: "\(device.uuidString)/\(job.uuidString).result")
  }

  private nonisolated func recordURL(_ device: UUID, _ job: UUID) -> URL {
    results.appending(path: "\(device.uuidString)/\(job.uuidString).json")
  }

  /// Results from earlier runs. A job that hadn't finished when the app quit won't anymore.
  private static func loadRecords(in root: URL) -> [UUID: Record] {
    let manager = FileManager.default
    let results = root.appending(path: "Results", directoryHint: .isDirectory)
    var records: [UUID: Record] = [:]
    for device in (try? manager.contentsOfDirectory(at: results, includingPropertiesForKeys: nil)) ?? [] {
      for file in (try? manager.contentsOfDirectory(at: device, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json"
      {
        guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
              let data = try? Data(contentsOf: file),
              var record = try? JSONDecoder().decode(Record.self, from: data)
        else { continue }
        record.queueID = nil
        if !record.event.state.isFinal {
          record.event = RemoteJobEvent(jobID: id, state: .failed, message: "The server quit before the job finished.")
        }
        records[id] = record
      }
    }
    return records
  }

  // MARK: - Connections

  func addListener(_ id: UUID, device: UUID, connection: RemoteConnection) {
    listeners[id] = (device, connection)
  }

  func removeListener(_ id: UUID) { listeners[id] = nil }

  // MARK: - Uploads

  private nonisolated static func isHash(_ text: String) -> Bool {
    text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  func blobStatus(device: UUID, hashes: [String]) -> (complete: [String], partial: [String: Int]) {
    let manager = FileManager.default
    var complete: [String] = []
    var partial: [String: Int] = [:]
    for hash in hashes where Self.isHash(hash) {
      let url = blobs(device).appending(path: hash)
      if manager.fileExists(atPath: url.path) {
        complete.append(hash)
      } else if let size = Self.size(of: url.appendingPathExtension("part")) {
        partial[hash] = size
      }
    }
    return (complete, partial)
  }

  private nonisolated static func size(of url: URL) -> Int? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
  }

  /// Adds a chunk; returns how much of the blob the server now has. A chunk at the wrong offset
  /// isn't written, and the answer tells the client where to go on from. The finished file has to
  /// match its name before it's kept.
  func appendBlob(device: UUID, hash: String, offset: Int, total: Int, bytes: Data) throws -> Int {
    guard Self.isHash(hash) else { throw RemoteError.server("That isn't a valid upload.") }
    guard total <= RemoteProtocol.maxBlobSize, offset >= 0, offset + bytes.count <= total else {
      throw RemoteError.server("That upload is too large.")
    }
    let manager = FileManager.default
    let folder = blobs(device)
    let final = folder.appending(path: hash)
    if manager.fileExists(atPath: final.path) { return total }
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let part = final.appendingPathExtension("part")
    let current = Self.size(of: part) ?? 0
    guard offset == current else { return current }
    if !manager.fileExists(atPath: part.path) { manager.createFile(atPath: part.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: part)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: bytes)
    let written = offset + bytes.count
    guard written == total else { return written }
    try handle.close()
    let data = try Data(contentsOf: part, options: .mappedIfSafe)
    guard SHA256.hash(data: data).hexString == hash else {
      try? manager.removeItem(at: part)
      throw RemoteError.server("An upload arrived damaged.")
    }
    try manager.moveItem(at: part, to: final)
    return total
  }

  /// A finished upload, marked as just used so it isn't cleaned up.
  func blobURL(device: UUID, hash: String) -> URL? {
    guard Self.isHash(hash) else { return nil }
    let url = blobs(device).appending(path: hash)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    return url
  }

  // MARK: - Jobs

  /// Records a new job; false if this device already submitted it, as after a dropped connection,
  /// when the one already taken stands. A job id another device used can't be claimed.
  func registerJob(_ job: UUID, device: UUID) throws -> Bool {
    if let record = records[job] {
      guard record.deviceID == device else { throw RemoteError.server("That job can't be submitted.") }
      return false
    }
    records[job] = Record(deviceID: device, createdAt: Date(), event: RemoteJobEvent(jobID: job, state: .queued))
    save(job)
    return true
  }

  func setQueueID(_ queueID: UUID, job: UUID) { records[job]?.queueID = queueID }

  func removeJob(_ job: UUID) {
    guard let record = records.removeValue(forKey: job) else { return }
    try? FileManager.default.removeItem(at: resultURL(record.deviceID, job))
    try? FileManager.default.removeItem(at: recordURL(record.deviceID, job))
  }

  /// The queue's id for a device's own job.
  func queueID(of job: UUID, device: UUID) -> UUID? {
    guard let record = records[job], record.deviceID == device else { return nil }
    return record.queueID
  }

  /// Keeps `event` and tells the device's connections. Previews go out but aren't kept. A job that
  /// already ended stays as it ended.
  func post(_ event: RemoteJobEvent) {
    guard let record = records[event.jobID], !record.event.state.isFinal else { return }
    var kept = event
    kept.previews = nil
    let persist = record.event.state != event.state
    records[event.jobID]?.event = kept
    if event.state.isFinal { records[event.jobID]?.queueID = nil }
    if persist { save(event.jobID) }
    for listener in listeners.values where listener.device == record.deviceID {
      listener.connection.sendNow(.message(RemoteEnvelope(message: .jobEvent(event))))
    }
  }

  func latestEvent(of job: UUID, device: UUID) -> RemoteJobEvent? {
    guard let record = records[job], record.deviceID == device else { return nil }
    return record.event
  }

  func events(device: UUID) -> [RemoteJobEvent] {
    records.values.filter { $0.deviceID == device }.sorted { $0.createdAt < $1.createdAt }.map(\.event)
  }

  /// Where a job's result goes, once there's a record to keep it under.
  func resultDestination(_ job: UUID) -> URL? {
    records[job].map { resultURL($0.deviceID, job) }
  }

  func readResult(device: UUID, job: UUID, offset: Int, length: Int) throws -> (bytes: Data, total: Int) {
    guard let record = records[job], record.deviceID == device, record.event.state == .ready,
          let total = record.event.resultSize
    else { throw RemoteError.server("There's no such result.") }
    guard offset >= 0, offset <= total else { throw RemoteError.server("That's outside the result.") }
    let handle = try FileHandle(forReadingFrom: resultURL(device, job))
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    let bytes = try handle.read(upToCount: min(length, RemoteProtocol.chunkSize)) ?? Data()
    return (bytes, total)
  }

  /// The client has its result.
  func acknowledge(job: UUID, device: UUID) {
    guard records[job]?.deviceID == device else { return }
    removeJob(job)
  }

  private func save(_ job: UUID) {
    guard let record = records[job] else { return }
    let url = recordURL(record.deviceID, job)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    Log.attempt(Log.remote, "Saving a remote job") {
      try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
  }

  // MARK: - Removing

  /// A removed device: closes its connections, and forgets its jobs and files. Returns the queue's
  /// ids for the jobs of its still in this machine's queue, to cancel.
  func removeDevice(_ device: UUID) -> [UUID] {
    for (id, listener) in listeners where listener.device == device {
      listener.connection.cancel()
      listeners[id] = nil
    }
    let jobs = records.filter { $0.value.deviceID == device }
    let queued = jobs.values.compactMap(\.queueID)
    for job in jobs.keys { records[job] = nil }
    let manager = FileManager.default
    try? manager.removeItem(at: results.appending(path: device.uuidString, directoryHint: .isDirectory))
    try? manager.removeItem(at: blobs(device))
    return queued
  }

  /// Deletes what's past its time: finished jobs nobody collected, and uploads nothing has used.
  /// A job that's still running stays whatever its age.
  func purge(now: Date = Date()) {
    let cutoff = now.addingTimeInterval(-RemoteProtocol.retention)
    for (job, record) in records where record.createdAt < cutoff && record.event.state.isFinal {
      removeJob(job)
    }
    let manager = FileManager.default
    let folder = root.appending(path: "Blobs", directoryHint: .isDirectory)
    for device in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
      let files = (try? manager.contentsOfDirectory(at: device, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for file in files {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified < cutoff { try? manager.removeItem(at: file) }
      }
    }
  }
}
