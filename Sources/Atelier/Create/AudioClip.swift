import AVFoundation
import Foundation
import NNC
import SwiftUI
import UniformTypeIdentifiers

/// The audio file video models that take one are given (MiniMax H3 Ref2VA as a reference to
/// speak or sing to, LongCat as the voice to lip-sync). Like the moodboard, a copy is kept across
/// launches, in ~/Library/Application Support/Atelier/Audio/; each queued job takes the file as
/// it was then.
@MainActor
@Observable
final class AudioClip {
  /// Atelier's copy of the file.
  private(set) var url: URL?
  /// The name it was added under.
  private(set) var name = ""
  private(set) var duration: Double = 0
  /// Loudness in 48 bins, 0 to 1, for the waveform.
  private(set) var waveform: [Float] = []

  private static var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Atelier/Audio", directoryHint: .isDirectory)
  }

  init() {
    guard SessionState.isEnabled,
      let file = try? FileManager.default.contentsOfDirectory(
        at: Self.folder, includingPropertiesForKeys: nil
      ).first(where: { $0.deletingPathExtension().lastPathComponent == "current" })
    else { return }
    load(file, name: UserDefaults.standard.string(forKey: "audioClipName") ?? file.lastPathComponent)
  }

  /// Copies `source` in as the audio file. Jobs already queued keep the copy they took.
  func set(_ source: URL) throws {
    let access = source.startAccessingSecurityScopedResource()
    defer { if access { source.stopAccessingSecurityScopedResource() } }
    let target = Self.folder.appending(path: "current").appendingPathExtension(source.pathExtension)
    try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    removeFile()
    try FileManager.default.copyItem(at: source, to: target)
    load(target, name: source.lastPathComponent)
    UserDefaults.standard.set(name, forKey: "audioClipName")
  }

  /// Puts back the audio a run took (as the project keeps it: PCM in [channels, samples] order).
  func set(samples: Tensor<Float>, sampleRate: Int, name: String) throws {
    try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    removeFile()
    let target = Self.folder.appending(path: "current.wav")
    try Self.writeWAV(samples, sampleRate: sampleRate, to: target)
    load(target, name: name)
    UserDefaults.standard.set(name, forKey: "audioClipName")
  }

  func clear() {
    removeFile()
    url = nil
    name = ""
    duration = 0
    waveform = []
  }

  /// A copy of the file for a queued job, so changing the audio later doesn't change the job.
  func snapshot() -> URL? {
    guard let url else { return nil }
    let jobs = Self.folder.appending(path: "Jobs", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
    let copy = jobs.appending(path: UUID().uuidString).appendingPathExtension(url.pathExtension)
    return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil
  }

  /// Removes the copies queued jobs took, except `keeping`'s.
  static func removeSnapshots(keeping: [URL]) {
    let jobs = folder.appending(path: "Jobs", directoryHint: .isDirectory)
    let kept = Set(keeping.map(\.standardizedFileURL))
    for file in (try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil)) ?? []
    where !kept.contains(file.standardizedFileURL) {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private func removeFile() {
    if let url { try? FileManager.default.removeItem(at: url) }
  }

  private func load(_ file: URL, name: String) {
    url = file
    self.name = name
    guard let audio = try? AVAudioFile(forReading: file) else {
      duration = 0
      waveform = []
      return
    }
    duration = Double(audio.length) / audio.processingFormat.sampleRate
    waveform = Self.waveform(of: audio, bins: 48)
  }

  private static func waveform(of file: AVAudioFile, bins: Int) -> [Float] {
    let format = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0]
    else { return [] }
    let count = Int(buffer.frameLength)
    let perBin = max(count / bins, 1)
    var levels = (0..<bins).map { bin -> Float in
      let start = bin * perBin
      guard start < count else { return 0 }
      var peak: Float = 0
      for i in start..<min(start + perBin, count) { peak = max(peak, abs(channel[i])) }
      return peak
    }
    let top = levels.max() ?? 1
    if top > 0 { levels = levels.map { $0 / top } }
    return levels
  }

  /// 32-bit float WAV, the samples as they are.
  private static func writeWAV(_ samples: Tensor<Float>, sampleRate: Int, to url: URL) throws {
    let channels = samples.shape[0], count = samples.shape[1]
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
        channels: AVAudioChannelCount(channels), interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
      let data = buffer.floatChannelData
    else { throw CocoaError(.fileWriteUnknown) }
    buffer.frameLength = AVAudioFrameCount(count)
    for channel in 0..<channels {
      for i in 0..<count { data[channel][i] = samples[channel, i] }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }
}

/// The audio file in the moodboard column, for models that take one: its name, length and
/// waveform; drop a file on it, or choose one.
struct AudioClipChip: View {
  @Environment(CreateModel.self) private var model
  @Environment(FileDialogs.self) private var fileDialogs
  @State private var isTargeted = false
  @State private var failure: String?
  let width: CGFloat

  var body: some View {
    let audio = model.audio
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Image(systemName: "waveform")
        Text("Audio").font(.caption.weight(.semibold))
        Spacer(minLength: 0)
        if audio.url != nil {
          Button("Remove Audio", systemImage: "xmark.circle.fill") { audio.clear() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove the audio file")
        }
      }
      .foregroundStyle(.secondary)
      if audio.url != nil {
        HStack(alignment: .center, spacing: 1) {
          ForEach(Array(audio.waveform.enumerated()), id: \.offset) { _, level in
            Capsule().fill(.secondary).frame(width: 1, height: max(2, CGFloat(level) * 24))
          }
        }
        .frame(width: width, height: 26)
        Text(audio.name).font(.caption2).lineLimit(1).truncationMode(.middle)
        Text(Duration.seconds(audio.duration).formatted(.time(pattern: .minuteSecond)))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      } else {
        Button("Choose Audio…") { choose() }
          .font(.caption)
          .frame(width: width, height: 40)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
      }
      if let failure {
        Text(failure).font(.caption2).foregroundStyle(.red).frame(width: width, alignment: .leading)
      }
    }
    .frame(width: width)
    .contentShape(.rect)
    .overlay {
      if isTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2) }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first else { return false }
      add(url)
      return true
    } isTargeted: { isTargeted = $0 }
    .contextMenu {
      Button("Choose Audio…") { choose() }
      Button("Remove Audio") { audio.clear() }.disabled(audio.url == nil)
    }
    .help(help)
  }

  private var help: String {
    guard let video = model.videoModel else { return "An audio file for the video." }
    return video.takesReferences
      ? "Audio for the video to follow: refer to it in the prompt as <Audio 1>."
      : "The voice the avatar lip-syncs to. The clip keeps it as its sound."
  }

  private func choose() {
    fileDialogs.open = FileDialogs.Open(types: [.audio]) { urls in
      if let url = urls.first { add(url) }
    }
  }

  private func add(_ url: URL) {
    do {
      try model.audio.set(url)
      failure = nil
    } catch {
      failure = error.localizedDescription
    }
  }
}
