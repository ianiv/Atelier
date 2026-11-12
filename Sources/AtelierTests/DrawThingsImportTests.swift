@testable import Atelier
@preconcurrency import Diffusion
import Foundation
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

  func lora(_ name: String, _ file: String, prefix: String = "", version: String = "krea_2", here: Bool = true) -> ModelLibrary.LoRA {
    ModelLibrary.LoRA(name: name, file: file, prefix: prefix, version: version, size: here ? 1 : nil, registry: URL(fileURLWithPath: "/"))
  }

  /// Draw Things' 8-bit conversion deletes the original, whose entry keeps the trigger words.
  @Test func anEightBitCopyTakesOverFromItsDeletedOriginal() {
    let byFile = ModelLibrary.linkingLoRACopies([
      lora("Style", "style_lora_f16.ckpt", prefix: "in style ", here: false),
      lora("Style Small", "style_lora_q8p.ckpt"),
    ])
    #expect(byFile.map(\.file) == ["style_lora_q8p.ckpt"])
    #expect(byFile[0].prefix == "in style ")
    let byName = ModelLibrary.linkingLoRACopies([
      lora("Style (Krea 2)", "style_lora_f16.ckpt", prefix: "in style ", here: false),
      lora("Style (Krea 2) (8-bit)", "converted.ckpt"),
    ])
    #expect(byName.map(\.file) == ["converted.ckpt"])
    #expect(byName[0].prefix == "in style ")
  }

  /// As one user's custom_lora.json shows them.
  @Test func aRealEightBitCopyGetsItsOriginalsNameAndTriggerWords() {
    for original in ["age_slider_v1_krea_lora_f16.ckpt", "renamed_on_import_lora_f16.ckpt"] {
      let linked = ModelLibrary.linkingLoRACopies([
        lora("Age Slider v1 Krea", original, prefix: "age slider ", here: false),
        lora("age_slider_v1_krea_lora_q8p", "age_slider_v1_krea_lora_q8p.ckpt"),
      ])
      #expect(linked.map(\.file) == ["age_slider_v1_krea_lora_q8p.ckpt"])
      #expect(linked[0].prefix == "age slider ")
      #expect(linked[0].name == "Age Slider v1 Krea")
    }
    // A name its owner chose stays.
    let named = ModelLibrary.linkingLoRACopies([
      lora("Style", "style_lora_f16.ckpt", here: false),
      lora("My Style Small", "style_lora_q8p.ckpt"),
    ])
    #expect(named[0].name == "My Style Small")
  }

  @Test func onlyARealCopyTakesOver() {
    // Its own trigger words stay.
    let own = ModelLibrary.linkingLoRACopies([
      lora("Style", "style_lora_f16.ckpt", prefix: "old ", here: false),
      lora("Style", "style_lora_q8p.ckpt", prefix: "new "),
    ])
    #expect(own.map(\.prefix) == ["new "])
    // Another family, or another name, leaves the missing one showing its warning.
    let others = ModelLibrary.linkingLoRACopies([
      lora("Style", "style_lora_f16.ckpt", prefix: "old ", here: false),
      lora("Style", "style_lora_q8p.ckpt", version: "flux2"),
      lora("Other", "other_lora_q8p.ckpt"),
    ])
    #expect(others.count == 3)
    #expect(others.first { $0.file == "style_lora_f16.ckpt" }?.isDownloaded == false)
    #expect(others.first { $0.file == "style_lora_q8p.ckpt" }?.prefix == "")
    // Both files here: two LoRAs.
    #expect(ModelLibrary.linkingLoRACopies([
      lora("Style", "style_lora_f16.ckpt", prefix: "old "),
      lora("Style", "style_lora_q8p.ckpt"),
    ]).count == 2)
  }

  /// These families and files are only in the community list, so they vanish without it.
  @Test func theShippedCatalogCoversWhatOnlyTheDownloadHad() {
    let files = Set(CommunityCatalog.shipped.map(\.file))
    #expect(files.isSuperset(of: ["fasth3_omni_i8x.ckpt", "flux_3_klein_i8x.ckpt", "minimax_h3_ref2va_i8x.ckpt", "qwen_image_2.1_q8p.ckpt"]))
    let templates = DrawThingsImporter.templates(from: CommunityCatalog.shipped)
    for version in [ModelVersion.minimaxH3, .flux3_5b, .qwenImage2_1, .krea2] {
      #expect(templates[version.rawValue] != nil)
    }
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

/// Importing presets again: the name is the identity, as in Draw Things'
/// `ConfigurationZoo.appendCustomSpecification`. Every store lives in a temporary folder, removed
/// when the test ends.
@MainActor
final class PresetImportTests {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func store() -> PresetStore {
    PresetStore(directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true))
  }

  /// `DrawThingsImportTests.export` with Krea portrait's steps changed.
  static let edited = Data(String(decoding: DrawThingsImportTests.export, as: UTF8.self)
    .replacingOccurrences(of: #""steps": 20"#, with: #""steps": 30"#).utf8)

  func imported(_ data: Data) -> [Preset] {
    DrawThingsJSON.presets(fromFile: data, named: "File")
  }

  /// A store with the export imported once.
  func storeWithExport() throws -> PresetStore {
    let presets = store()
    let result = try presets.apply(presets.importPlan(imported(DrawThingsImportTests.export)), resolutions: [:])
    #expect(result.added == ["Krea portrait", "Second"])
    return presets
  }

  /// From a fresh store, as after a relaunch: what was saved must decode to what the file gives.
  @Test func importingTheSameFileAgainAddsNothing() throws {
    let presets = try PresetStore(directory: storeWithExport().directory)
    #expect(presets.presets.map(\.name) == ["Krea portrait", "Second"])
    let plan = try presets.importPlan(imported(DrawThingsImportTests.export))
    #expect(plan.added.isEmpty)
    #expect(plan.conflicts.isEmpty)
    #expect(plan.unchanged.count == 2)
    #expect(try presets.apply(plan, resolutions: [:]).summary == nil)
    #expect(presets.presets.count == 2)
  }

  /// A default for one model mustn't keep pointing at a preset replaced by one for another model.
  @Test func replacingWithAnotherModelClearsTheOldDefault() throws {
    let presets = try storeWithExport()
    let existing = try #require(presets.presets.first { $0.name == "Second" })
    presets.setDefault(existing, for: "other.ckpt")
    presets.setDefault(existing, for: "third.ckpt")
    let file = Data(#"[{"name": "Second", "configuration": {"steps": 8, "model": "third.ckpt"}}]"#.utf8)
    let plan = try presets.importPlan(imported(file))
    try presets.apply(plan, resolutions: ["Second": .replace])
    #expect(presets.defaultPreset(for: "other.ckpt") == nil)
    #expect(presets.defaultPreset(for: "third.ckpt")?.model == "third.ckpt")
  }

  @Test func anEditedEntryIsOneConflict() throws {
    let presets = try storeWithExport()
    let plan = try presets.importPlan(imported(Self.edited))
    #expect(plan.added.isEmpty)
    #expect(plan.conflicts.map(\.id) == ["Krea portrait"])
    #expect(plan.conflicts.first?.differingSettings == ["steps"])
    #expect(plan.conflicts.first?.modelDiffers == false)
  }

  @Test func replaceOverwritesInPlace() throws {
    let presets = try storeWithExport()
    let plan = try presets.importPlan(imported(Self.edited))
    let result = try presets.apply(plan, resolutions: ["Krea portrait": .replace])
    #expect(result.replaced == ["Krea portrait"])
    #expect(presets.presets.count == 2)
    #expect(presets.presets.first { $0.name == "Krea portrait" }?.values["steps"] == .number(30))
    #expect(PresetStore(directory: presets.directory).presets.first { $0.name == "Krea portrait" }?.values["steps"] == .number(30))
  }

  @Test func keepBothAddsANumberedCopy() throws {
    let presets = try storeWithExport()
    let plan = try presets.importPlan(imported(Self.edited))
    let result = try presets.apply(plan, resolutions: ["Krea portrait": .keepBoth])
    #expect(result.keptBoth == ["Krea portrait 2"])
    #expect(presets.presets.map(\.name) == ["Krea portrait", "Krea portrait 2", "Second"])
    #expect(presets.presets.first { $0.name == "Krea portrait" }?.values["steps"] == .number(20))
    #expect(presets.presets.first { $0.name == "Krea portrait 2" }?.values["steps"] == .number(30))
  }

  @Test func skipLeavesItUnchanged() throws {
    let presets = try storeWithExport()
    let before = presets.presets
    let plan = try presets.importPlan(imported(Self.edited))
    let result = try presets.apply(plan, resolutions: ["Krea portrait": .skip])
    #expect(result.skipped == ["Krea portrait"])
    #expect(presets.presets == before)
  }

  /// A setting Atelier learned since the first import (Sol Attention) makes a conflict, not a copy.
  @Test func aNewlyKnownSettingIsAConflict() throws {
    let presets = store()
    var old = try #require(imported(DrawThingsImportTests.export).first)
    old.values["solAttentionStart"] = nil
    try presets.save(old)
    let plan = try presets.importPlan(imported(DrawThingsImportTests.export))
    #expect(plan.conflicts.map(\.id) == ["Krea portrait"])
    #expect(plan.conflicts.first?.differingSettings == ["solAttentionStart"])
    #expect(plan.added.map(\.name) == ["Second"])
  }

  @Test func aNameListedTwiceKeepsTheLastEntry() throws {
    let file = Data("""
    [
      {"name": "Twice", "configuration": {"steps": 8}},
      {"name": "Twice", "configuration": {"steps": 12}}
    ]
    """.utf8)
    let presets = store()
    let plan = try presets.importPlan(imported(file))
    #expect(plan.added.count == 1)
    #expect(plan.added.first?.values["steps"] == .number(12))
    try presets.apply(plan, resolutions: [:])
    #expect(presets.presets.map(\.name) == ["Twice"])
  }

  /// "Do this for all remaining conflicts" applies the choice to the one shown and every one after.
  @Test func oneResolutionForAllRemainingConflicts() throws {
    let presets = try storeWithExport()
    let file = Data("""
    [
      {"name": "Krea portrait", "configuration": {"steps": 4}},
      {"name": "Second", "configuration": {"steps": 5, "model": "other.ckpt"}}
    ]
    """.utf8)
    let plan = try presets.importPlan(imported(file))
    #expect(plan.conflicts.count == 2)
    var resolutions: [String: PresetConflictResolution] = [:]
    #expect(plan.resolve(at: 0, as: .replace, forRemaining: true, in: &resolutions) == 2)
    #expect(resolutions == ["Krea portrait": .replace, "Second": .replace])
    var oneAtATime: [String: PresetConflictResolution] = [:]
    #expect(plan.resolve(at: 0, as: .skip, forRemaining: false, in: &oneAtATime) == 1)
    #expect(oneAtATime == ["Krea portrait": .skip])
    let result = try presets.apply(plan, resolutions: resolutions)
    #expect(result.replaced == ["Krea portrait", "Second"])
    #expect(presets.presets.map { $0.values["steps"] } == [.number(4), .number(5)])
    #expect(result.summary == "Replaced 2.")
  }
}
