import DataModels
import Diffusion
import Foundation
import ImageGenerator
import ModelZoo

/// What Atelier needs to know about a video model: its frame rate, which frame counts it takes,
/// and which inputs and outputs it has. Read from ModelZoo, which knows a community model once
/// its pipeline has loaded.
struct VideoModel: Equatable {
  let version: ModelVersion
  /// The model's modifier, or its LoRAs' (`ImageGeneratorUtils.modifierForModel`).
  let modifier: SamplerModifier
  /// The rate the model was trained at; clips play and are written at it.
  let framesPerSecond: Double
  /// Sample rate of the audio the model makes or takes.
  let audioSampleRate: Int

  /// nil for image models.
  init?(model: String, loras: [String] = []) {
    let version = ModelZoo.versionForModel(model)
    guard ImageGeneratorUtils.isVideoModel(version) else { return nil }
    self.version = version
    modifier = ImageGeneratorUtils.modifierForModel(model, LoRAs: loras)
    framesPerSecond = ModelZoo.framesPerSecondForModel(model)
    audioSampleRate = ModelZoo.audioSampleRateForModel(model)
  }

  /// LTX and MiniMax H3 generate a soundtrack with the video.
  var makesAudio: Bool {
    version == .ltx2 || version == .ltx2_3 || version == .minimaxH3
  }

  /// Takes an audio file: H3 Ref2VA as a reference to speak or sing to, LongCat as the voice its
  /// avatar lip-syncs to (its clip keeps that audio, the model makes none).
  var takesAudio: Bool {
    (version == .minimaxH3 && modifier == .ref2va) || version == .longcatVideoAvatar1_5
  }

  /// H3 FL2VA: the canvas is the first frame and the first moodboard image the last.
  var takesLastFrame: Bool { version == .minimaxH3 && modifier == .fl2va }

  /// H3 Ref2VA: the canvas and moodboard images are Picture 1, 2, … in the prompt.
  var takesReferences: Bool { version == .minimaxH3 && modifier == .ref2va }

  /// Stable Video Diffusion only animates an image.
  var needsImage: Bool { version == .svdI2v || version == .longcatVideoAvatar1_5 }

  /// The frame counts the model's autoencoder takes: 1 + a multiple of `step` (H3: of 17, from 5).
  var frameStep: Int {
    switch version {
    case .ltx2, .ltx2_3: 8
    case .minimaxH3: 17
    case .svdI2v: 1
    default: 4
    }
  }

  /// The shortest clip: one latent frame past the first.
  var minimumFrames: Int {
    switch version {
    case .minimaxH3: 5
    case .svdI2v: 1
    default: frameStep + 1
    }
  }

  /// The nearest frame count the model takes.
  func snapped(_ frames: Int) -> Int {
    let base = version == .minimaxH3 ? 5 : 1
    let steps = (Double(max(frames, minimumFrames) - base) / Double(frameStep)).rounded()
    return max(base + Int(steps) * frameStep, minimumFrames)
  }

  /// The next frame count up or down from `frames`.
  func stepped(_ frames: Int, by direction: Int) -> Int {
    max(snapped(frames) + direction * frameStep, minimumFrames)
  }

  /// Seconds `frames` frames last.
  func seconds(_ frames: Int) -> Double {
    Double(frames) / framesPerSecond
  }
}

extension PipelineConfiguration {
  /// The video model this configuration runs, if it's one.
  var videoModel: VideoModel? {
    VideoModel(model: model, loras: loras.compactMap(\.file))
  }
}
