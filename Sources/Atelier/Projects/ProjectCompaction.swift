import Foundation
import SQLite3
import Synchronization

/// Giving a project file's free pages back to the disk. Deleting steps and tensors leaves their
/// pages on SQLite's freelist, and the file never shrinks by itself: dflat and s4nnc both ask for
/// `auto_vacuum=incremental` when they open a file (`SQLiteWorkspace.newConnection`,
/// `DynamicGraph.openStore`), but nothing ever runs `incremental_vacuum` (dflat's
/// `incremental_vaccum(2)` is misspelled, which SQLite ignores), and a file that was made in
/// another mode (an old Draw Things project) can only change mode with a full `VACUUM`.
///
/// Three things use it:
/// - `cleanUp`: after a project closes, and when the app is idle after a delete, frees the pages
///   with `incremental_vacuum` when there are enough of them (`needsCleanUp`). Incremental files
///   only; on any other mode the pragma does nothing.
/// - `compact`: Compact Project…, a full `VACUUM`, which also turns any file incremental.
/// - `offersCompaction`: whether opening a project should offer Compact Project….
///
/// Each uses its own connection, the way `DrawThingsImport` reads a project, beside dflat's and
/// s4nnc's; SQLite's locks keep them apart. Clean-ups and compactions run one at a time on one
/// queue, and a compaction stops any clean-up still running.
nonisolated enum ProjectCompaction {
  /// What `PRAGMA auto_vacuum` reports.
  enum Mode: Int32, Sendable {
    case none = 0, full = 1, incremental = 2
  }

  /// A project file's pages, as its own pragmas report them.
  struct Stats: Equatable, Sendable {
    var pageSize: Int64
    var pageCount: Int64
    var freePages: Int64
    var mode: Mode
    /// `PRAGMA journal_mode`, lowercased ("wal", "delete", …).
    var journalMode: String

    var databaseBytes: Int64 { pageSize * pageCount }
    var freeBytes: Int64 { pageSize * freePages }
    var freeFraction: Double { pageCount == 0 ? 0 : Double(freePages) / Double(pageCount) }
  }

  /// A finished compaction: the file's size before and after, the -wal file included.
  struct Outcome: Equatable, Sendable {
    var bytesBefore: Int64
    var bytesAfter: Int64
    var mode: Mode
  }

  enum Failure: LocalizedError, Equatable {
    case cannotOpen(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case sqlite(String)

    var errorDescription: String? {
      switch self {
      case .cannotOpen(let message):
        "The project file couldn't be opened (\(message))."
      case .notEnoughSpace(let needed, let available):
        "Compacting needs \(ProjectCompaction.format(needed)) free on the disk the project is on (twice the file's size) while it works, and only \(ProjectCompaction.format(available)) is free."
      case .sqlite(let message):
        "SQLite stopped with an error: \(message). The project is unchanged."
      }
    }
  }

  // MARK: - Thresholds

  /// Free pages worth a clean-up: over 20% of the file, or over 200 MB.
  static func needsCleanUp(_ stats: Stats) -> Bool {
    stats.freePages > 0 && (stats.freeFraction > 0.2 || stats.freeBytes > 200 * megabyte)
  }

  /// Free pages worth offering Compact Project… for when a project opens: over 25% of the file
  /// and over 500 MB.
  static func offersCompaction(_ stats: Stats) -> Bool {
    stats.freeFraction > 0.25 && stats.freeBytes > 500 * megabyte
  }

  static let megabyte: Int64 = 1_000_000
  /// How long one `incremental_vacuum` transaction aims to hold the write lock, which the app's own
  /// writes wait on (up to dflat's 30 s busy timeout). Its cost per page grows with the freelist:
  /// SQLite walks the freelist's trunk pages to take out each page it frees (`incrVacuumStep`,
  /// `allocateBtreePage` with `BTALLOC_EXACT`), about 1.2 ms a page with 8.9 GB free (2.2 million
  /// pages), so the chunk is sized from how long the last one took rather than fixed.
  static let cleanUpTransactionSeconds = 0.25
  /// The most work one clean-up does before leaving the rest for the next. A freelist of many GB
  /// would take most of an hour this way, where Compact Project… (`VACUUM`) takes seconds, so a
  /// file like that is left to the offer (`offersCompaction`) and frees a little each time.
  static let cleanUpBudgetSeconds = 120.0
  /// The pages one transaction may free at most.
  static let cleanUpChunkBytes: Int64 = 64 * megabyte

  // MARK: - Creating

  /// Makes a new, empty project file in incremental mode: `auto_vacuum` only takes effect before
  /// the first table, so it's set here, before dflat or s4nnc create theirs, rather than relying on
  /// whichever of them opens the file first. WAL is the mode dflat puts every file in
  /// (`SQLiteWorkspace.newConnection`); setting it here also writes the header, which keeps the
  /// `auto_vacuum` setting. Nothing happens when the file exists.
  static func createDatabase(at url: URL) {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: url.path) else { return }
    #if os(iOS)
      // What `SQLiteWorkspace.setUpFilePathWithProtectionLevel` gives the files it creates (see
      // `Project.init`): it leaves files that already exist as they are.
      for suffix in ["", "-wal", "-shm"] {
        fileManager.createFile(
          atPath: url.path + suffix, contents: nil,
          attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
      }
    #endif
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
      Log.project.error("Creating \(url.lastPathComponent, privacy: .public) failed: \(message(database), privacy: .public)")
      sqlite3_close(database)
      return
    }
    defer { sqlite3_close(database) }
    sqlite3_exec(database, "PRAGMA auto_vacuum = INCREMENTAL", nil, nil, nil)
    sqlite3_exec(database, "PRAGMA journal_mode = WAL", nil, nil, nil)
  }

  /// Makes an existing file readable by read-only connections, which every read here uses (dflat's
  /// reader pool, `SQLiteConnectionPool`, and the tensor store's `openStore(flags: [.readOnly])`).
  /// A file in WAL mode keeps that mode in its header, so one copied without its -wal and -shm (sent
  /// by someone, copied in Finder, from Draw Things, or still being copied in while Atelier lists
  /// it) needs them to be read, and a read-only
  /// connection can't make them: its open succeeds but every statement fails with
  /// SQLITE_CANTOPEN, which dflat's queries turn into no rows (`SQLiteQueryBuilder`), and its
  /// read-write fallback only follows a failed open (`SQLiteConnection.init`). One read-write
  /// read makes SQLite create them; the WAL is kept persistent so closing doesn't remove them again
  /// (Apple's SQLite already does that by default). Nothing happens when both are there, or when
  /// there's no file (`createDatabase` makes one).
  static func makeReadable(at url: URL) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return }
    let missing = ["-wal", "-shm"].filter { !fileManager.fileExists(atPath: url.path + $0) }
    guard !missing.isEmpty else { return }
    #if os(iOS)
      // As `createDatabase`: SQLite would give the files it creates no protection.
      for suffix in missing {
        fileManager.createFile(
          atPath: url.path + suffix, contents: nil,
          attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
      }
    #endif
    let database: OpaquePointer
    do {
      database = try open(url)
    } catch {
      Log.project.error("Preparing \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    defer { sqlite3_close(database) }
    // Opening a project shouldn't wait 30 s on a file something else is still writing.
    sqlite3_busy_timeout(database, 5000)
    var persist: Int32 = 1
    sqlite3_file_control(database, "main", SQLITE_FCNTL_PERSIST_WAL, &persist)
    guard integer(database, "SELECT count(*) FROM sqlite_master") != nil else {
      Log.project.error("Reading \(url.lastPathComponent, privacy: .public) failed: \(message(database), privacy: .public)")
      return
    }
    if missing.contains("-wal"), text(database, "PRAGMA journal_mode")?.lowercased() == "wal" {
      // A file closed by Atelier (`checkpoint`) or Draw Things holds everything; one copied while
      // it was open may lack its newest changes.
      Log.project.info("\(url.lastPathComponent, privacy: .public) opened without its -wal: changes not yet checkpointed into it are missing")
    }
  }

  /// Moves everything in the file's -wal into the file itself (a TRUNCATE checkpoint, from a
  /// connection of its own), so the .sqlite3 alone holds the whole project: what someone copying
  /// it in Finder gets. It stays in WAL mode, unlike dflat's `shutdown(flags: [.truncate])`, which
  /// also switches to `journal_mode=DELETE`. Waits up to `timeout` for a write in progress; when
  /// that runs out (or a reader is mid-transaction) the checkpoint is only partial, which is fine:
  /// the -wal still has the rest. The timeout bounds waiting for locks, not the copy itself, so
  /// `maxWALBytes` skips a -wal larger than that (for quitting, which has a deadline). False when it
  /// didn't complete.
  @discardableResult
  static func checkpoint(at url: URL, timeout: TimeInterval, maxWALBytes: Int64? = nil) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    if let maxWALBytes,
       let walBytes = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.int64Value,
       walBytes > maxWALBytes
    {
      return false
    }
    guard let database = try? open(url) else { return false }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, Int32(max(0, min(timeout, 30)) * 1000))
    guard text(database, "PRAGMA journal_mode")?.lowercased() == "wal" else { return true }
    return sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK
  }

  // MARK: - Reading

  /// The file's pages, or nil when it can't be opened (it never creates one).
  static func stats(at url: URL) -> Stats? {
    guard let database = try? open(url) else { return nil }
    defer { sqlite3_close(database) }
    return stats(database)
  }

  private static func stats(_ database: OpaquePointer) -> Stats? {
    guard let pageSize = integer(database, "PRAGMA page_size"),
          let pageCount = integer(database, "PRAGMA page_count"),
          let freePages = integer(database, "PRAGMA freelist_count"),
          let mode = integer(database, "PRAGMA auto_vacuum").flatMap({ Mode(rawValue: Int32($0)) })
    else { return nil }
    let journal = text(database, "PRAGMA journal_mode")?.lowercased() ?? ""
    return Stats(pageSize: pageSize, pageCount: pageCount, freePages: freePages, mode: mode, journalMode: journal)
  }

  /// The file's size on disk with its -wal.
  static func fileBytes(_ url: URL) -> Int64 {
    ["", "-wal"].reduce(0) { total, suffix in
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? NSNumber)?.int64Value
      return total + (size ?? 0)
    }
  }

  // MARK: - Clean-up

  /// Projects open in the app, by path, counted per `Project`: a clean-up after one closes stops
  /// when it opens again.
  private static let openProjects = Mutex<[String: Int]>([:])

  static func didOpen(_ url: URL) {
    openProjects.withLock { $0[url.path, default: 0] += 1 }
  }

  static func didClose(_ url: URL) {
    openProjects.withLock {
      let count = ($0[url.path] ?? 1) - 1
      $0[url.path] = count > 0 ? count : nil
    }
  }

  static func isOpen(_ url: URL) -> Bool {
    openProjects.withLock { $0[url.path] != nil }
  }

  /// Clean-ups and compactions, one at a time.
  private static let queue = DispatchQueue(label: "Atelier.ProjectCompaction", qos: .utility)
  /// Bumped by each compaction, so a clean-up queued or running before it stops.
  private static let generation = Mutex(0)

  /// Queues `cleanUp` for after a project closes (`whileOpen` false: it stops if the project opens
  /// again) or while it's open and the app is idle (`whileOpen` true).
  static func scheduleCleanUp(at url: URL, whileOpen: Bool) {
    let started = generation.withLock { $0 }
    queue.async {
      let outcome = cleanUp(at: url) {
        generation.withLock { $0 } != started || (!whileOpen && isOpen(url))
      }
      if let outcome {
        Log.project.info(
          "Cleaned up \(url.lastPathComponent, privacy: .public): \(format(outcome.bytesBefore), privacy: .public) → \(format(outcome.bytesAfter), privacy: .public)")
      }
    }
  }

  /// Frees the file's free pages with `incremental_vacuum`, in short transactions
  /// (`cleanUpTransactionSeconds`) with a pause between them for the app's writes, when it's in
  /// incremental mode and `needsCleanUp`; `shouldStop` is asked between them, and it stops after
  /// `budget` seconds. When nothing else has the file open, a WAL file is then checkpointed and
  /// truncated, so the -wal the moved pages went through doesn't keep the space. Nil when there was
  /// nothing to do (or it couldn't open).
  @discardableResult
  static func cleanUp(at url: URL, budget: TimeInterval = cleanUpBudgetSeconds, shouldStop: () -> Bool = { false }) -> Outcome? {
    guard FileManager.default.fileExists(atPath: url.path), let database = try? open(url) else { return nil }
    defer { sqlite3_close(database) }
    guard var stats = stats(database), stats.mode == .incremental, needsCleanUp(stats) else { return nil }
    let before = fileBytes(url)
    let started = Date()
    let largest = max(1, cleanUpChunkBytes / max(stats.pageSize, 1))
    var chunk = min(256, largest)
    while stats.freePages > 0, !shouldStop(), Date().timeIntervalSince(started) < budget {
      let transaction = Date()
      let result = sqlite3_exec(database, "PRAGMA incremental_vacuum(\(chunk))", nil, nil, nil)
      guard result == SQLITE_OK else {
        // Busy past the timeout (the app writing a lot) is fine: what's freed so far stays freed.
        Log.project.info("Clean-up of \(url.lastPathComponent, privacy: .public) stopped: \(message(database), privacy: .public)")
        break
      }
      let took = max(Date().timeIntervalSince(transaction), 0.001)
      guard let next = Self.stats(database), next.freePages < stats.freePages else { break }
      stats = next
      chunk = min(largest, max(16, Int64(Double(chunk) * cleanUpTransactionSeconds / took)))
      usleep(20_000)
    }
    if stats.journalMode == "wal", !isOpen(url) {
      sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }
    return Outcome(bytesBefore: before, bytesAfter: fileBytes(url), mode: stats.mode)
  }

  // MARK: - Compacting

  /// The space a compaction needs: twice the file, for the copy `VACUUM` builds and the journal
  /// (or WAL) it writes back through.
  static func spaceNeeded(for url: URL) -> Int64 { 2 * fileBytes(url) }

  /// Free space on the disk holding `url`, counting what the system would purge for it.
  static func availableSpace(for url: URL) -> Int64? {
    let folder = url.deletingLastPathComponent()
    let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
  }

  /// Rewrites the file with `VACUUM`, after `auto_vacuum = INCREMENTAL` so a file in another mode
  /// comes out incremental (the mode only changes through a `VACUUM`). Then, in WAL mode, the WAL
  /// is checkpointed and truncated. Refuses when the disk has less than `spaceNeeded` free.
  /// `VACUUM` takes the whole database: the caller closes its own connections first and keeps
  /// edits away until it's done (`HistoryStore.compactCurrent`). Waits for a clean-up running on
  /// the queue, which it stops between chunks.
  static func compact(at url: URL) async throws -> Outcome {
    generation.withLock { $0 += 1 }
    return try await withCheckedThrowingContinuation { continuation in
      queue.async(qos: .userInitiated) {
        continuation.resume(with: Result { try compactNow(at: url) })
      }
    }
  }

  /// `compact`'s work, on the calling thread. `available` stands in for the disk's free space in
  /// tests.
  static func compactNow(at url: URL, available: Int64? = nil) throws -> Outcome {
    let before = fileBytes(url)
    let needed = 2 * before
    if let available = available ?? availableSpace(for: url), available < needed {
      throw Failure.notEnoughSpace(needed: needed, available: available)
    }
    let database = try open(url)
    defer { sqlite3_close(database) }
    sqlite3_exec(database, "PRAGMA auto_vacuum = INCREMENTAL", nil, nil, nil)
    guard sqlite3_exec(database, "VACUUM", nil, nil, nil) == SQLITE_OK else {
      throw Failure.sqlite(message(database))
    }
    if text(database, "PRAGMA journal_mode")?.lowercased() == "wal" {
      sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }
    let mode = integer(database, "PRAGMA auto_vacuum").flatMap { Mode(rawValue: Int32($0)) } ?? .none
    return Outcome(bytesBefore: before, bytesAfter: fileBytes(url), mode: mode)
  }

  // MARK: - SQLite

  /// A read-write connection to an existing file, never creating one (a project trashed or renamed
  /// meanwhile isn't brought back empty). Waits up to 30 s for a lock, as dflat's do.
  private static func open(_ url: URL) throws -> OpaquePointer {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
      let error = message(database)
      sqlite3_close(database)
      throw Failure.cannotOpen(error)
    }
    sqlite3_busy_timeout(database, 30_000)
    sqlite3_exec(database, "PRAGMA trusted_schema=OFF", nil, nil, nil)
    return database
  }

  private static func integer(_ database: OpaquePointer, _ sql: String) -> Int64? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(statement, 0)
  }

  private static func text(_ database: OpaquePointer, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: text)
  }

  private static func message(_ database: OpaquePointer?) -> String {
    database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
  }

  /// "8.9 GB", in the file sizes Finder shows.
  static func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
