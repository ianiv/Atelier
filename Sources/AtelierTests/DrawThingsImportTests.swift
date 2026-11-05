@testable import Atelier
import Foundation
@preconcurrency import Diffusion
@preconcurrency import ModelZoo
import SQLite3
import Testing

/// Reading Draw Things' custom_configs.json, and what a scan of its folder finds.
@MainActor
struct DrawThingsImportTests {
  /// The whole-file form Draw Things exports, with the fields that used to stop it importing.
  static let export = Data("""
  [
    {"name": "Krea portrait", "version": "krea2", "configuration": {
      "aestheticScore": 6, "batchCount": 1, "controls": [],
      "loras": [{"file": "style_lora_f16.ckpt", "mode": "all", "weight": 0.6}],
      "model": "krea_2_raw_i8x.ckpt", "sampler": 10, "seedMode": 2, "shift": 3.5,
      "numFrames": 81, "causalInference": 0, "cfgZeroStar": false, "shiftForAudio": 1,
      "solAttentionStart": 0, "stage2Steps": 0, "colorCalibration": "none",
      "compressionArtifacts": "disabled", "width": 1024, "height": 768, "steps": 20
    }},
    {"name": "Second", "configuration": {"steps": 8, "model": "other.ckpt"}},
    {"name": "Nothing Atelier knows", "configuration": {"controls": []}}
  ]
  """.utf8)

  func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url.appendingPathComponent("Models"), withIntermediateDirectories: true)
    return url
  }

  /// A database with `table`, in the file's real format.
  func database(at url: URL, table: String) {
    var database: OpaquePointer?
    sqlite3_open(url.path, &database)
    sqlite3_exec(database, "create table \(table) (id integer)", nil, nil, nil)
    sqlite3_close(database)
  }

  @Test func aWholeExportBecomesOnePresetPerConfiguration() throws {
    let presets = DrawThingsJSON.presets(fromFile: Self.export, named: "File")
    #expect(presets.map(\.name) == ["Krea portrait", "Second"])
    let first = try #require(presets.first)
    #expect(first.model == "krea_2_raw_i8x.ckpt")
    #expect(first.values["steps"] == .number(20))
    #expect(first.values["size"] != nil)
    #expect(first.values["sampler"] != .number(10))
    guard case .array(let loras)? = first.values["loras"], case .object(let lora)? = loras.first else {
      Issue.record("LoRAs didn't come through")
      return
    }
    #expect(lora["file"] == .string("style_lora_f16.ckpt"))
  }

  @Test func oneConfigurationOnItsOwnTakesTheFileName() {
    let presets = DrawThingsJSON.presets(fromFile: Data(#"{"steps": 8}"#.utf8), named: "File")
    #expect(presets.map(\.name) == ["File"])
  }

  @Test func pastingUsesALoneEntryButNotAWholeList() {
    #expect(DrawThingsJSON.decode(Data(#"[{"name": "One", "configuration": {"steps": 8}}]"#.utf8))?.dump["steps"] == .number(8))
    #expect(DrawThingsJSON.decode(Self.export) == nil)
  }

  @Test func aFileWithNoSettingsReadsAsNothing() {
    #expect(DrawThingsJSON.presets(fromFile: Data("[]".utf8), named: "File").isEmpty)
    #expect(DrawThingsJSON.presets(fromFile: Data("not json".utf8), named: "File").isEmpty)
  }

  @Test func aScanFindsModelsConfigurationsAndOnlyRealProjects() throws {
    let root = try folder()
    let models = root.appendingPathComponent("Models")
    try Data().write(to: models.appendingPathComponent("a_f16.ckpt"))
    try Data("[]".utf8).write(to: models.appendingPathComponent("custom.json"))
    try Self.export.write(to: models.appendingPathComponent("custom_configs.json"))
    database(at: root.appendingPathComponent("Project.sqlite3"), table: "tensorhistorynode__f86")
    database(at: root.appendingPathComponent("config.sqlite3"), table: "other")
    try Data("not a database".utf8).write(to: root.appendingPathComponent("Junk.sqlite3"))
    let contents = DrawThingsContents.scan(root)
    #expect(contents.modelsFolder?.lastPathComponent == "Models")
    #expect(contents.modelFiles == ["a_f16.ckpt"])
    #expect(contents.hasCustomModels)
    #expect(!contents.hasCustomLoRAs)
    #expect(contents.configurationsFile != nil)
    #expect(contents.projects.map(\.name) == ["Project"])
  }

  @Test func pickingTheModelsFolderStillFindsItsProjects() throws {
    let root = try folder()
    let models = root.appendingPathComponent("Models")
    try Data().write(to: models.appendingPathComponent("a_f16.ckpt"))
    database(at: root.appendingPathComponent("P.sqlite3"), table: "tensorhistorynode__f86")
    let contents = DrawThingsContents.scan(models)
    #expect(contents.modelsFolder?.lastPathComponent == "Models")
    #expect(contents.projects.map(\.name) == ["P"])
  }

  @Test func unmatchedFilesSayWhy() throws {
    let root = try folder()
    let models = root.appendingPathComponent("Models")
    try Data().write(to: models.appendingPathComponent("known.ckpt"))
    try Data("SQLite format 3\0".utf8).write(to: models.appendingPathComponent("converted.ckpt"))
    try Data("{}".utf8).write(to: models.appendingPathComponent("original.safetensors"))
    try Data().write(to: models.appendingPathComponent("listed.ckpt"))
    try Data(#"[{"file": "listed.ckpt"}]"#.utf8).write(to: models.appendingPathComponent("custom_controlnet.json"))
    let unmatched = DrawThingsContents.scan(root).unmatchedFiles(known: ["known.ckpt"])
    #expect(unmatched.map(\.name) == ["converted.ckpt", "original.safetensors"])
    #expect(unmatched.map(\.kind) == [.converted, .unconverted])
  }

  @Test func copiesLeaveOriginalsAndDoNotRepeat() async throws {
    let root = try folder()
    let source = root.appendingPathComponent("P.sqlite3")
    database(at: source, table: "tensorhistorynode__f86")
    try Data("wal".utf8).write(to: URL(fileURLWithPath: source.path + "-wal"))
    let target = root.appendingPathComponent("Copied", isDirectory: true)
    let project = try #require(DrawThingsContents.scan(root).projects.first)
    let first = await DrawThingsContents.copy([project], to: target)
    #expect(first.copied == ["P"])
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("P.sqlite3-wal").path))
    let second = await DrawThingsContents.copy([project], to: target)
    #expect(second.skipped == ["P"])
    try Data("different".utf8).write(to: target.appendingPathComponent("P.sqlite3"))
    let third = await DrawThingsContents.copy([project], to: target)
    #expect(third.copied == ["P 2"])
  }

  @Test func severalFoldersAddUpWithoutCountingAnythingTwice() throws {
    let documents = try folder()
    database(at: documents.appendingPathComponent("P.sqlite3"), table: "tensorhistorynode__f86")
    let drive = try folder().appendingPathComponent("Models")
    try Data().write(to: drive.appendingPathComponent("a_f16.ckpt"))
    try Self.export.write(to: drive.appendingPathComponent("custom_configs.json"))
    // Documents' own Models is empty, and the second pick is the same drive folder again.
    let selection = DrawThingsSelection(folders: [documents, drive, drive].map(DrawThingsContents.scan))
    #expect(selection.contains(documents))
    #expect(selection.projects.map(\.name) == ["P"])
    #expect(selection.configurationsFiles.count == 1)
    #expect(selection.modelFileCount == 1)
    #expect(selection.modelsFolders.count == 2)
    #expect(selection.foldersToShare { _ in false }.map(\.standardizedFileURL) == [drive.standardizedFileURL])
    // With the models' folder already in use, Documents' empty one isn't worth adding.
    #expect(selection.foldersToShare { $0.standardizedFileURL == drive.standardizedFileURL }.isEmpty)
    // With no model files anywhere, the empty one can still be chosen.
    let empty = DrawThingsSelection(folders: [DrawThingsContents.scan(documents)])
    #expect(empty.foldersToShare { _ in false }.count == 1)
  }

  /// A catalog model, from what the app bundle ships.
  func catalog() throws -> [ModelZoo.Specification] {
    let url = try #require(Bundle.main.url(forResource: "models", withExtension: "json"))
    return try CommunityCatalog.parse(Data(contentsOf: url))
  }

  @Test func familiesGetThePlainestModelAsTheirTemplate() throws {
    let templates = try DrawThingsImporter.templates(from: catalog())
    #expect(!templates.isEmpty)
    for (version, template) in templates {
      #expect(template.version.rawValue == version)
    }
    // A tuned variant loses to a plain model of the same family, whichever comes first.
    var turbo = try #require(templates[ModelVersion.zImage.rawValue])
    turbo.file = "z_turbo_q8p.ckpt"
    var plain = turbo
    plain.file = "z_q8p.ckpt"
    for order in [[turbo, plain], [plain, turbo]] {
      #expect(DrawThingsImporter.templates(from: order)[ModelVersion.zImage.rawValue]?.file == "z_q8p.ckpt")
    }
  }

  @Test func aChosenFamilyListsTheFileAndKeepsOtherEntries() throws {
    let root = try folder()
    let models = root.appendingPathComponent("Models")
    let existing = #"[{"file": "other.ckpt", "field_this_engine_does_not_know": 7}]"#
    try Data(existing.utf8).write(to: models.appendingPathComponent("custom.json"))
    let template = try #require(DrawThingsImporter.templates(from: catalog())[ModelVersion.zImage.rawValue])
    try ModelLibrary.addToCustomJSON(ModelLibrary.specification(for: "mine_f16.ckpt", template: template), in: models)
    // Again, as choosing another family would: it replaces the entry.
    try ModelLibrary.addToCustomJSON(ModelLibrary.specification(for: "mine_f16.ckpt", template: template), in: models)
    let data = try Data(contentsOf: models.appendingPathComponent("custom.json"))
    let raw = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(raw.compactMap { $0["file"] as? String } == ["other.ckpt", "mine_f16.ckpt"])
    #expect(raw[0]["field_this_engine_does_not_know"] as? Int == 7)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let entries = try decoder.decode([FailableDecodable<ModelZoo.Specification>].self, from: data).compactMap(\.value)
    let mine = try #require(entries.first { $0.file == "mine_f16.ckpt" })
    #expect(mine.version == .zImage)
    #expect(mine.name == "mine_f16")
    #expect(mine.textEncoder == template.textEncoder)
    #expect(mine.autoencoder == template.autoencoder)
    #expect(mine.note == nil)
    #expect(ModelLibrary.registeredFiles(in: models).contains("mine_f16.ckpt"))
  }

  /// Draw Things lists imported models in its Documents even when their files are on another drive.
  @Test func aFolderThatOnlyListsModelsIsSharedAndExplainsTheFiles() throws {
    let documents = try folder()
    try Data(#"[{"file": "fine_tune_f16.ckpt"}]"#.utf8).write(to: documents.appendingPathComponent("Models/custom.json"))
    let drive = try folder().appendingPathComponent("Models")
    try Data("SQLite format 3\0".utf8).write(to: drive.appendingPathComponent("fine_tune_f16.ckpt"))
    #expect(DrawThingsContents.scan(drive).unmatchedFiles(known: []).map(\.name) == ["fine_tune_f16.ckpt"])
    let selection = DrawThingsSelection(folders: [documents, drive].map(DrawThingsContents.scan))
    #expect(selection.unmatchedFiles(known: []).isEmpty)
    #expect(selection.registeredCount == 1)
    // The folder with the files goes first, though it was chosen second.
    let shared = selection.foldersToShare { _ in false }.map(\.standardizedFileURL)
    #expect(shared == [drive.standardizedFileURL, documents.appendingPathComponent("Models").standardizedFileURL])
    // With the drive already in use, the list is still worth adding.
    #expect(selection.foldersToShare { $0.standardizedFileURL == drive.standardizedFileURL }.count == 1)
  }

  /// models.json as the engine ships it, which the app bundle now carries, with an entry this
  /// engine can't read among the rest.
  @Test func theCatalogParserKeepsEntriesItCanRead() throws {
    let url = try #require(Bundle.main.url(forResource: "models", withExtension: "json"))
    let shipped = try Data(contentsOf: url)
    let count = CommunityCatalog.parse(shipped).count
    #expect(count > 100)
    var entries = try #require(JSONSerialization.jsonObject(with: shipped) as? [Any])
    entries.append(["broken": true])
    #expect(CommunityCatalog.parse(try JSONSerialization.data(withJSONObject: entries)).count == count)
    #expect(CommunityCatalog.parse(Data("oops".utf8)).isEmpty)
  }
}
