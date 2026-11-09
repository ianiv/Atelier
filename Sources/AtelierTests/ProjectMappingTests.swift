@testable import Atelier
@preconcurrency import DataModels
import Foundation
import ProjectFormat
import Testing

struct ProjectMappingTests {
  func step(lineage: Int64 = 2, time: Int64 = 3) -> ProjectMapping.Step {
    ProjectMapping.Step(
      lineage: lineage, logicalTime: time, model: "model.ckpt", prompt: "p", negativePrompt: "n", seed: 7,
      tensorId: 100, previewId: 200, wallClock: 300, generationTime: 1.5, reason: .generate)
  }

  /// The settings written to a step come back when it's read, as "Use Settings" relies on.
  @Test func settingsRoundTrip() {
    let settings: [String: JSONValue] = [
      "width": .number(1024), "height": .number(768), "steps": .number(20),
      "guidanceScale": .number(4.5), "strength": .number(0.75), "batchSize": .number(2),
      "sampler": .string(String(describing: DataModels.SamplerType.eulerA)), "hiresFix": .bool(true), "hiresFixWidth": .number(512),
      "hiresFixHeight": .number(256), "hiresFixStrength": .number(0.5), "upscaler": .string("up.ckpt"),
      "refinerModel": .string("refiner.ckpt"), "numFrames": .number(33), "maskBlur": .number(2.5),
      "usesSolAttention": .bool(true), "solAttentionStart": .number(4), "solAttentionTau": .number(0.75),
    ]
    let dump = ProjectMapping.dump(of: ProjectMapping.node(for: step(), settings: settings))
    for (key, value) in settings {
      if dump[key] != value { Issue.record("\(key): wrote \(value), read \(String(describing: dump[key]))") }
    }
  }

  /// Sol Attention is app-only (MGK lacks it), so it travels in the dump and the registry reads it
  /// back onto the configuration the engine run uses.
  @MainActor @Test func solAttentionComesBackFromADump() {
    let node = ProjectMapping.node(
      for: step(), settings: ["usesSolAttention": .bool(true), "solAttentionStart": .number(3)])
    #expect(node.usesSolAttention && node.solAttentionStart == 3 && node.solAttentionTau == 0.5)
    let dump = ProjectMapping.dump(of: node)
    #expect(SettingsRegistry.byID["usesSolAttention"]?.read(dump) == .bool(true))
    #expect(SettingsRegistry.byID["solAttentionStart"]?.read(dump) == .number(3))
  }

  @Test func theStepsOwnFieldsGoOnTheNode() {
    let node = ProjectMapping.node(for: step(), settings: [:])
    #expect(node.lineage == 2 && node.logicalTime == 3)
    #expect(node.seed == 7 && node.model == "model.ckpt")
    #expect(node.previewId == 200 && node.wallClock == 300)
    #expect(node.generated)
  }

  @Test func sizesAreStoredIn64PixelUnits() {
    let node = ProjectMapping.node(
      for: step(), settings: ["width": .number(1280), "height": .number(1000)])
    #expect(node.startWidth == 20)
    // 1000 isn't a multiple: the format can't hold it, so it rounds down.
    #expect(node.startHeight == 15)
    #expect(ProjectMapping.dump(of: node)["height"] == .number(960))
  }

  @Test func missingSettingsTakeTheDefaults() {
    let dump = ProjectMapping.dump(of: ProjectMapping.node(for: step(), settings: [:]))
    #expect(dump["width"] == .number(1024))
    #expect(dump["steps"] == .number(20))
    #expect(dump["guidanceScale"] == .number(4.5))
  }

  @Test func outOfRangeValuesClampInsteadOfTrapping() {
    let node = ProjectMapping.node(
      for: step(), settings: ["steps": .number(-5), "width": .number(100_000_000)])
    #expect(node.steps == 0)
    #expect(node.startWidth == UInt16.max)
  }

  @Test func anUnknownSamplerNameDoesNotBreakTheStep() {
    let dump = ProjectMapping.dump(
      of: ProjectMapping.node(for: step(), settings: ["sampler": .string("noSuchSampler")]))
    #expect(dump["sampler"] != .string("noSuchSampler"))
  }

  @Test func profileRoundTrip() throws {
    let profile = ProjectMapping.Profile(
      duration: 2.5, inputTensorId: 11, parentTensorId: 12, inputAudioId: 13)
    let read = try #require(ProjectMapping.Profile(profile.bytes))
    #expect(read.duration == 2.5)
    #expect(read.inputTensorId == 11 && read.parentTensorId == 12 && read.inputAudioId == 13)
  }

  /// Draw Things reads and writes the same field, as snake-case JSON.
  @Test func profileUsesDrawThingsKeys() throws {
    let text = String(decoding: ProjectMapping.Profile(duration: 1, inputTensorId: 5, parentTensorId: nil).bytes, as: UTF8.self)
    #expect(text.contains("\"input_tensor_id\":5"))
    let fromDrawThings = #"{"duration":3,"timings":[{"durations":[1],"name":"x"}],"something_new":true}"#
    let read = try #require(ProjectMapping.Profile([UInt8](fromDrawThings.utf8)))
    #expect(read.duration == 3 && read.timings.count == 1 && read.parentTensorId == nil)
  }

  @Test func anEmptyOrBrokenProfileIsNil() {
    #expect(ProjectMapping.Profile([]) == nil)
    #expect(ProjectMapping.Profile([UInt8]("not json".utf8)) == nil)
  }
}
