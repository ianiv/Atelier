@testable import Atelier
@preconcurrency import Diffusion
import Foundation
@preconcurrency import NNC
import Testing

/// Extract Depth Map's pure parts: the estimate as an image (`DepthMap.rgb`), what a step and a
/// saved queue keep of it, and reading those back from untrusted files.
@Suite(.tags(.smoke))
struct DepthMapTests {
  /// A `[1, 1, n, 1]` estimate of `values`.
  func depth(_ values: [Float]) -> Tensor<FloatType> {
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, 1, values.count, 1))
    for (index, value) in values.enumerated() { tensor[0, 0, index, 0] = FloatType(value) }
    return tensor
  }

  /// Near (1) is white and far (-1) black, the same in R, G and B, as Draw Things' depth hint.
  @Test func nearIsWhiteFarIsBlackInGrey() throws {
    let rgb = try #require(DepthMap.rgb(depth: depth([-1, 0, 1])))
    #expect(rgb.shape == [1, 1, 3, 3])
    for x in 0..<3 {
      #expect(rgb[0, 0, x, 0] == rgb[0, 0, x, 1] && rgb[0, 0, x, 1] == rgb[0, 0, x, 2])
    }
    let image = try #require(ImageTensor.cgImage(from: rgb))
    let pixels = try #require(ColorMatch.rgba(image))
    #expect(pixels[0] == 0)
    #expect((127...128).contains(pixels[4]))
    #expect(pixels[8] == 255)
  }

  /// An estimate out of range (a flat image isn't scaled) is clamped, and a non-finite value counts as far.
  @Test func outOfRangeAndNonFiniteValuesAreClamped() throws {
    let rgb = try #require(DepthMap.rgb(depth: depth([-7, 3.5, .nan, .infinity])))
    #expect(Float(rgb[0, 0, 0, 0]) == -1)
    #expect(Float(rgb[0, 0, 1, 0]) == 1)
    #expect(Float(rgb[0, 0, 2, 0]) == -1)
    #expect(Float(rgb[0, 0, 3, 0]) == -1)
    #expect(DepthMap.clamped(-.infinity) == -1)
    #expect(DepthMap.clamped(0.25) == 0.25)
  }

  /// Only the first channel is the estimate, whatever else comes along.
  @Test func takesTheFirstChannel() throws {
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, 2, 1, 2))
    tensor[0, 0, 0, 0] = 0.5
    tensor[0, 0, 0, 1] = -1
    tensor[0, 1, 0, 0] = -0.5
    tensor[0, 1, 0, 1] = 1
    let rgb = try #require(DepthMap.rgb(depth: tensor))
    #expect(rgb.shape == [1, 2, 1, 3])
    #expect(Float(rgb[0, 0, 0, 2]) == 0.5)
    #expect(Float(rgb[0, 1, 0, 1]) == -0.5)
  }

  @Test func aTensorOfAnotherShapeIsNoImage() {
    #expect(DepthMap.rgb(depth: Tensor<FloatType>(.CPU, .C(4))) == nil)
  }

  /// The step's `profile_data` keeps `depth_map` with the model's name, and reads it back.
  @Test func theStepRecordsItInItsProfile() throws {
    let profile = ProjectMapping.Profile(
      duration: 1, inputTensorId: 5, parentTensorId: 5, depthMap: DepthMap.Record(model: DepthMap.modelFile))
    let text = try #require(String(bytes: profile.bytes, encoding: .utf8))
    #expect(text.contains(#""depth_map":{"model":"depth_anything_v2.0_f16.ckpt"}"#))
    let read = try #require(ProjectMapping.Profile(profile.bytes))
    #expect(read.depthMap == DepthMap.Record(model: DepthMap.modelFile))
    #expect(read.inputTensorId == 5)
  }

  /// A profile is untrusted: a model name that's no plain file name falls back to the known one,
  /// and a `depth_map` that doesn't read leaves the rest of the profile.
  @Test func aBadRecordInAProfileIsLenient() throws {
    let path = #"{"duration":1,"input_tensor_id":5,"depth_map":{"model":"../../etc/passwd"}}"#
    #expect(ProjectMapping.Profile(Array(path.utf8))?.depthMap?.model == DepthMap.modelFile)
    let long = #"{"duration":1,"depth_map":{"model":"\#(String(repeating: "a", count: 300))"}}"#
    #expect(ProjectMapping.Profile(Array(long.utf8))?.depthMap?.model == DepthMap.modelFile)
    let broken = #"{"duration":1,"input_tensor_id":5,"depth_map":7}"#
    let read = try #require(ProjectMapping.Profile(Array(broken.utf8)))
    #expect(read.depthMap == nil)
    #expect(read.inputTensorId == 5)
  }

  /// After the model download: queue only when nothing was stopped, the model is in, the sheet
  /// still shows that image and its project is still the open one.
  @Test func aFinishedDownloadQueuesOnlyForTheSameSheetAndProject() {
    func outcome(stopped: Bool = false, installed: Bool = true, sheet: Int64? = 7, open: String = "P") -> DepthModelDownload.Outcome {
      DepthModelDownload.outcome(stopped: stopped, installed: installed, sheetTensorId: sheet, tensorId: 7, openProject: open, project: "P")
    }
    #expect(outcome() == .queue)
    #expect(outcome(stopped: true) == .nothing)
    #expect(outcome(installed: false) == .nothing)
    #expect(outcome(sheet: nil) == .nothing)
    #expect(outcome(sheet: 8) == .nothing)
    #expect(outcome(open: "Q") == .projectChanged)
    #expect(outcome(stopped: true, open: "Q") == .nothing)
  }

  @Test func theSameImageIsTheSameJob() throws {
    let job = DepthMap.Job(project: "P", sourceTensorId: 12)
    #expect(job.isSameJob(as: DepthMap.Job(project: "P", sourceTensorId: 12)))
    #expect(!job.isSameJob(as: DepthMap.Job(project: "P", sourceTensorId: 13)))
    #expect(!job.isSameJob(as: DepthMap.Job(project: "Q", sourceTensorId: 12)))
    #expect(try JSONDecoder().decode(DepthMap.Job.self, from: JSONEncoder().encode(job)) == job)
    #expect(job.record == DepthMap.Record(model: DepthMap.modelFile))
  }

  /// A saved Extract Depth Map job names its project, so it comes back in any, after the same step.
  @Test func aSavedJobComesBackInAnyProject() throws {
    try withTestFolder { folder in
      let entry = """
      [{"id":"\(UUID().uuidString)","model":"m.ckpt","prompt":"p","negativePrompt":"n","seed":5,\
      "settings":{"steps":{"number":{"_0":4}}},"project":"P","parentTensorId":9,\
      "hasCanvas":false,"canvasIsImported":false,"moodboardWeights":[],\
      "depthMap":{"project":"P","sourceTensorId":9}}]
      """
      try entry.write(to: folder.appending(path: "index.json"), atomically: true, encoding: .utf8)
      let jobs = SavedQueue.load(project: "Other", from: folder)
      #expect(jobs.count == 1)
      #expect(jobs.first?.depthMap == DepthMap.Job(project: "P", sourceTensorId: 9))
      #expect(jobs.first?.parentTensorId == 9)
    }
  }
}
