@testable import Atelier
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC
import SQLite3
import Testing

/// Giving project files' free pages back: incremental mode for new files, `incremental_vacuum`
/// clean-ups, and Compact Project…'s `VACUUM`, on scratch databases with ~50 MB of blobs deleted.
struct ProjectCompactionTests {
  static let blobCount = 50
  static let blobBytes = 1_000_000

  func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compaction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("Project.sqlite3")
  }

  func exec(_ url: URL, _ sql: String) {
    var database: OpaquePointer?
    sqlite3_open(url.path, &database)
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
  }

  /// A file holding ~50 MB of blobs, then their deletion: its pages stay on the freelist.
  func fillAndDelete(_ url: URL) {
    exec(url, "CREATE TABLE blobs (id INTEGER PRIMARY KEY, data BLOB)")
    exec(url, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(Self.blobCount)) INSERT INTO blobs (data) SELECT randomblob(\(Self.blobBytes)) FROM n")
    exec(url, "CREATE TABLE kept (id INTEGER PRIMARY KEY, data BLOB); INSERT INTO kept (data) VALUES (randomblob(100000))")
    exec(url, "DELETE FROM blobs")
  }

  func legacy() throws -> URL {
    let url = try scratch()
    exec(url, "PRAGMA auto_vacuum = NONE; CREATE TABLE setup (id INTEGER)")
    return url
  }

  @Test func aNewFileIsIncremental() throws {
    let url = try scratch()
    ProjectCompaction.createDatabase(at: url)
    let stats = try #require(ProjectCompaction.stats(at: url))
    #expect(stats.mode == .incremental)
    #expect(stats.journalMode == "wal")
  }

  @Test func aNewProjectIsIncrementalOnceDflatAndTheStoreHaveWritten() async throws {
    let url = try scratch()
    let project = Project(url: url)
    project.output = ProjectOutput(saves: true, folder: nil)
    project.declinedCompaction = true
    await project.close()
    let stats = try #require(ProjectCompaction.stats(at: url))
    #expect(stats.mode == .incremental)
    let reopened = Project(url: url)
    #expect(reopened.declinedCompaction)
    await reopened.close()
  }

  @Test func deletingLeavesFreePagesThatACleanUpGivesBack() throws {
    let url = try scratch()
    ProjectCompaction.createDatabase(at: url)
    fillAndDelete(url)
    let before = try #require(ProjectCompaction.stats(at: url))
    #expect(before.freeBytes > 45_000_000)
    #expect(ProjectCompaction.needsCleanUp(before))
    let outcome = try #require(ProjectCompaction.cleanUp(at: url))
    let after = try #require(ProjectCompaction.stats(at: url))
    #expect(after.freePages == 0)
    #expect(outcome.bytesAfter < outcome.bytesBefore - 45_000_000)
    #expect(ProjectCompaction.fileBytes(url) < 5_000_000)
  }

  @Test func aCleanUpStopsWhenAsked() throws {
    let url = try scratch()
    ProjectCompaction.createDatabase(at: url)
    fillAndDelete(url)
    let before = try #require(ProjectCompaction.stats(at: url))
    ProjectCompaction.cleanUp(at: url, shouldStop: { true })
    #expect(ProjectCompaction.stats(at: url)?.freePages == before.freePages)
  }

  @Test func aCleanUpLeavesOtherModesAlone() throws {
    let url = try legacy()
    fillAndDelete(url)
    let before = try #require(ProjectCompaction.stats(at: url))
    #expect(before.mode == .none)
    #expect(before.freePages > 0)
    #expect(ProjectCompaction.cleanUp(at: url) == nil)
    #expect(ProjectCompaction.stats(at: url)?.freePages == before.freePages)
  }

  @Test func compactingShrinksALegacyFileAndMakesItIncremental() throws {
    let url = try legacy()
    fillAndDelete(url)
    let size = ProjectCompaction.fileBytes(url)
    let outcome = try ProjectCompaction.compactNow(at: url)
    let after = try #require(ProjectCompaction.stats(at: url))
    #expect(outcome.mode == .incremental)
    #expect(after.mode == .incremental)
    #expect(after.freePages == 0)
    #expect(outcome.bytesBefore == size)
    #expect(outcome.bytesAfter < size - 45_000_000)
  }

  @Test func compactingAWALFileTruncatesItsWAL() throws {
    let url = try legacy()
    exec(url, "PRAGMA journal_mode = WAL")
    fillAndDelete(url)
    _ = try ProjectCompaction.compactNow(at: url)
    let after = try #require(ProjectCompaction.stats(at: url))
    #expect(after.journalMode == "wal")
    #expect(after.mode == .incremental)
    #expect(after.freePages == 0)
    let wal = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
    #expect(wal == 0)
  }

  @Test func compactingRefusesWithoutTwiceTheFileFree() throws {
    let url = try legacy()
    fillAndDelete(url)
    let before = try #require(ProjectCompaction.stats(at: url))
    let needed = 2 * ProjectCompaction.fileBytes(url)
    #expect(throws: ProjectCompaction.Failure.notEnoughSpace(needed: needed, available: needed - 1)) {
      try ProjectCompaction.compactNow(at: url, available: needed - 1)
    }
    #expect(ProjectCompaction.stats(at: url) == before)
  }

  @Test func nothingOpensAFileThatIsGone() throws {
    let url = try scratch()
    #expect(ProjectCompaction.stats(at: url) == nil)
    #expect(ProjectCompaction.cleanUp(at: url) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func thresholds() {
    let mb: Int64 = 1_000_000
    func stats(total: Int64, free: Int64) -> ProjectCompaction.Stats {
      .init(pageSize: 4096, pageCount: total * mb / 4096, freePages: free * mb / 4096, mode: .incremental, journalMode: "wal")
    }
    // Clean-up: over 20% or over 200 MB.
    #expect(!ProjectCompaction.needsCleanUp(stats(total: 1000, free: 0)))
    #expect(!ProjectCompaction.needsCleanUp(stats(total: 1000, free: 150)))
    #expect(ProjectCompaction.needsCleanUp(stats(total: 100, free: 25)))
    #expect(ProjectCompaction.needsCleanUp(stats(total: 10000, free: 250)))
    // Offer: over 25% and over 500 MB.
    #expect(ProjectCompaction.offersCompaction(stats(total: 11400, free: 8900)))
    #expect(!ProjectCompaction.offersCompaction(stats(total: 1000, free: 400)))
    #expect(!ProjectCompaction.offersCompaction(stats(total: 10000, free: 2000)))
  }

  // MARK: - Copying a project's file alone

  /// A step of its own, as a run would save.
  func generate(_ project: Project, _ n: Int) async throws {
    let tensor = try #require(ImageTensor.tensor(from: CanvasRefineTests.pattern(width: 8 + n, height: 8)))
    _ = try await project.append(
      tensor: tensor, model: "m", prompt: "run \(n)", negativePrompt: "", seed: UInt32(n), settings: [:],
      createdAt: Date(), duration: 1, after: nil)
  }

  /// The .sqlite3 alone in a folder of its own, as someone sent it or Finder copied it.
  func copyAlone(_ url: URL) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("copied-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent(url.lastPathComponent)
    try FileManager.default.copyItem(at: url, to: copy)
    return copy
  }

  /// Header bytes 18-19 are 2 in WAL mode: what a copy keeps.
  func isWALFile(_ url: URL) throws -> Bool {
    let header = try Data(contentsOf: url).prefix(20)
    return header.count == 20 && header[18] == 2 && header[19] == 2
  }

  /// A WAL-mode file without its -wal and -shm opens with what it holds (read-only connections
  /// alone found nothing), and only a step not yet checkpointed into it is missing.
  @Test func aFileCopiedWithoutItsWALOpens() async throws {
    let url = try scratch()
    let project = Project(url: url)
    try await generate(project, 1)
    #expect(ProjectCompaction.checkpoint(at: url, timeout: 5))
    try await generate(project, 2)
    let copy = try copyAlone(url)
    #expect(try isWALFile(copy))
    #expect(!FileManager.default.fileExists(atPath: copy.path + "-wal"))
    let opened = Project(url: copy)
    #expect(FileManager.default.fileExists(atPath: copy.path + "-wal"))
    #expect(FileManager.default.fileExists(atPath: copy.path + "-shm"))
    #expect(opened.items().map(\.sidecar.prompt) == ["run 1"])
    await opened.close()
    await project.close()
  }

  /// Once let go, a project's file alone holds every step, and stays in WAL mode.
  @Test func aLetGoProjectIsCompleteInItsFile() async throws {
    let url = try scratch()
    weak var released: Project?
    do {
      let project = Project(url: url)
      released = project
      try await generate(project, 1)
      try await generate(project, 2)
    }
    #expect(released == nil)
    // `deinit` shuts down and checkpoints on a background queue: the -wal empties when it's done.
    let deadline = Date().addingTimeInterval(10)
    let wal = url.path + "-wal"
    while Date() < deadline, (try? FileManager.default.attributesOfItem(atPath: wal)[.size] as? NSNumber)?.int64Value ?? 0 != 0 {
      try await Task.sleep(for: .milliseconds(50))
    }
    let copy = try copyAlone(url)
    #expect(try isWALFile(copy))
    let opened = Project(url: copy)
    #expect(Set(opened.items().map(\.sidecar.prompt)) == ["run 1", "run 2"])
    await opened.close()
  }

  /// The quit-time checkpoint (`HistoryStore.checkpointBeforeQuit`) works while the project is
  /// still open, as it is when the app exits.
  @Test func aCheckpointWhileOpenCompletesTheFile() async throws {
    let url = try scratch()
    let project = Project(url: url)
    try await generate(project, 1)
    try await generate(project, 2)
    _ = project.items()
    #expect(ProjectCompaction.checkpoint(at: url, timeout: 5))
    let copy = try copyAlone(url)
    let opened = Project(url: copy)
    #expect(Set(opened.items().map(\.sidecar.prompt)) == ["run 1", "run 2"])
    await opened.close()
    await project.close()
  }
}
