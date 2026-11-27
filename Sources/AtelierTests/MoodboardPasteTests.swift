@testable import Atelier
import AVFoundation
import CoreGraphics
import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers

/// The moodboard's Paste: what a clipboard item is, how items are read (images fitted to the
/// board, the first audio copied, the rest counted), the Transferable iPadOS's PasteButton reads,
/// and the Audio box keeping its clip when given a file it can't read.
@MainActor
@Suite(.tags(.smoke))
struct MoodboardPasteTests {
  private static func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "MoodboardPasteTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private static func png(width: Int = 32, height: Int = 32) throws -> Data {
    try #require(ImageTensor.png(try CanvasRefineTests.pattern(width: width, height: height)))
  }

  /// A tenth of a second of a tone, as a WAV file.
  private static func wav(in folder: URL, name: String = "tone.wav") throws -> URL {
    let url = folder.appending(path: name)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    buffer.frameLength = 4800
    let samples = try #require(buffer.floatChannelData?[0])
    for i in 0..<4800 { samples[i] = sin(Float(i) * 0.05) * 0.5 }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }

  // MARK: - What an item is

  @Test func aCopiedFilesOwnTypeBeatsItsIconTIFF() {
    let finder: [UTType] = [.fileURL, .utf8PlainText, .tiff]
    #expect(PastedMedia.kind(types: finder, fileURL: URL(filePath: "/x/song.wav")) == .audio)
    #expect(PastedMedia.kind(types: finder, fileURL: URL(filePath: "/x/photo.HEIC")) == .image)
    #expect(PastedMedia.kind(types: finder, fileURL: URL(filePath: "/x/clip.mov")) == nil)
    #expect(PastedMedia.kind(types: finder, fileURL: URL(filePath: "/x/notes.txt")) == nil)
  }

  @Test func imageAndAudioTypesAreRecognized() {
    for type in [UTType.png, .jpeg, .heic, .tiff] {
      #expect(PastedMedia.kind(types: [type], fileURL: nil) == .image)
    }
    for type in [UTType.wav, .mp3, .mpeg4Audio, .aiff] {
      #expect(PastedMedia.kind(types: [type], fileURL: nil) == .audio)
    }
    for name in ["a.wav", "a.mp3", "a.m4a", "a.aiff"] {
      #expect(PastedMedia.kind(types: [], fileURL: URL(filePath: "/x/\(name)")) == .audio)
    }
    #expect(PastedMedia.kind(types: [.quickTimeMovie], fileURL: nil) == nil)
    #expect(PastedMedia.kind(types: [.mpeg4Movie], fileURL: nil) == nil)
    #expect(PastedMedia.kind(types: [.utf8PlainText, .rtf], fileURL: nil) == nil)
    // The first type the copying app offers that's either decides.
    #expect(PastedMedia.kind(types: [.utf8PlainText, .png, .wav], fileURL: nil) == .image)
    #expect(PastedMedia.payloadType([.utf8PlainText, .jpeg, .png]) == .png)
  }

  @Test func imageDataIsReadAsATypeImageIODecodes() {
    #expect(PastedMedia.payloadType([.svg, .jpeg, .png]) == .png)
    #expect(PastedMedia.payloadType([.svg, .heic, .jpeg]) == .heic)
    #expect(PastedMedia.payloadType([.svg]) == nil)
    #expect(PastedMedia.payloadType([.utf8PlainText, .wav]) == .wav)
    #expect(PastedMedia.payloadType([.utf8PlainText, .wav], takesAudio: false) == nil)
  }

  // MARK: - Reading items

  @Test func aFileWithoutItsExtensionIsReadByItsContents() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = folder.appending(path: "picture")
    try Self.png(width: 40, height: 20).write(to: image)
    let sound = folder.appending(path: "sound")
    try FileManager.default.moveItem(at: Self.wav(in: folder), to: sound)
    let misnamed = folder.appending(path: "actually sound.png")
    try FileManager.default.copyItem(at: sound, to: misnamed)
    let batch = await PastedMedia.load(
      [ClipboardItem(types: [.fileURL], fileURL: image), ClipboardItem(types: [.fileURL], fileURL: sound)],
      takesAudio: true)
    defer { PastedMedia.removeCopies(batch.media) }
    guard batch.media.count == 2, case .image(let decoded) = batch.media[0], case .audio(let copy, _) = batch.media[1] else {
      Issue.record("an extension-less image and sound should both paste (\(batch.media.count), failed \(batch.failed))")
      return
    }
    #expect(decoded.width == 40)
    #expect(try AVAudioFile(forReading: copy).length == 4800)
    let wrong = await PastedMedia.load([ClipboardItem(types: [.fileURL], fileURL: misnamed)], takesAudio: true)
    defer { PastedMedia.removeCopies(wrong.media) }
    #expect(wrong.media.count == 1 && wrong.failed == 0)
  }

  @Test func everyImageIsReadInOrderAndFitted() async throws {
    let items = try [
      ClipboardItem(types: [.png], data: Self.png(width: 40, height: 20)),
      ClipboardItem(types: [.png], data: Self.png(width: 2000, height: 1000)),
      ClipboardItem(types: [.png], data: Self.png(width: 20, height: 40)),
    ]
    let batch = await PastedMedia.load(items, takesAudio: false)
    let sizes = batch.media.compactMap { media -> [Int]? in
      guard case .image(let image) = media else { return nil }
      return [image.width, image.height]
    }
    #expect(sizes == [[40, 20], [Moodboard.maxSide, Moodboard.maxSide / 2], [20, 40]])
    #expect(batch.failed == 0 && batch.audioLeftOut == 0 && batch.moreAudio == 0)
  }

  @Test func brokenAndUnsupportedItemsAreCounted() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let items = try [
      ClipboardItem(types: [.png], data: Data("not an image".utf8)),
      ClipboardItem(types: [.utf8PlainText], data: nil),
      ClipboardItem(types: [.fileURL, .tiff], fileURL: folder.appending(path: "missing.png")),
      ClipboardItem(types: [.png], data: Self.png()),
    ]
    let batch = await PastedMedia.load(items, takesAudio: true)
    #expect(batch.media.count == 1)
    #expect(batch.failed == 3)
  }

  @Test func audioIsLeftOutWhenTheModelTakesNone() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let wav = try Self.wav(in: folder)
    let items = try [
      ClipboardItem(types: [.fileURL], fileURL: wav),
      ClipboardItem(types: [.wav], data: Data(contentsOf: wav)),
      ClipboardItem(types: [.png], data: Self.png()),
    ]
    let batch = await PastedMedia.load(items, takesAudio: false)
    #expect(batch.media.count == 1)
    #expect(batch.audioLeftOut == 2)
    #expect(batch.failed == 0)
  }

  @Test func onlyTheFirstAudioIsCopied() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let wav = try Self.wav(in: folder, name: "voice.wav")
    let items = try [
      ClipboardItem(types: [.fileURL, .tiff], fileURL: wav),
      ClipboardItem(types: [.wav], data: Data(contentsOf: wav)),
    ]
    let batch = await PastedMedia.load(items, takesAudio: true)
    defer { PastedMedia.removeCopies(batch.media) }
    #expect(batch.moreAudio == 1)
    guard batch.media.count == 1, case .audio(let copy, let name) = batch.media[0] else {
      Issue.record("the first audio should be copied")
      return
    }
    #expect(name == "voice.wav")
    #expect(copy != wav && copy.pathExtension == "wav")
    #expect(try Data(contentsOf: copy) == Data(contentsOf: wav))
    PastedMedia.removeCopies(batch.media)
    #expect(!FileManager.default.fileExists(atPath: copy.path))
    #expect(FileManager.default.fileExists(atPath: wav.path))
  }

  @Test func audioDataGetsItsTypesExtension() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let data = try Data(contentsOf: Self.wav(in: folder))
    let batch = await PastedMedia.load([ClipboardItem(types: [.utf8PlainText, .wav], data: data)], takesAudio: true)
    defer { PastedMedia.removeCopies(batch.media) }
    guard case .audio(let copy, let name) = batch.media.first else {
      Issue.record("audio data should be written to a file")
      return
    }
    #expect(copy.pathExtension == "wav" && name == "Pasted Audio.wav")
    #expect(try AVAudioFile(forReading: copy).length == 4800)
  }

  // MARK: - The Transferable PasteButton reads

  private static func transfer<T: Transferable>(_ type: T.Type, from url: URL) async throws -> T {
    let provider = try #require(NSItemProvider(contentsOf: url))
    return try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadTransferable(type: type) { continuation.resume(with: $0) }
    }
  }

  @Test func aProviderGivesImagesFittedAndAudioAsACopy() async throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = folder.appending(path: "big.png")
    try Self.png(width: 3000, height: 1500).write(to: png)
    guard case .image(let image) = try await Self.transfer(PastedMedia.self, from: png) else {
      Issue.record("a PNG should paste as an image")
      return
    }
    #expect(image.width == Moodboard.maxSide && image.height == Moodboard.maxSide / 2)
    #expect(try await Self.transfer(PastedImage.self, from: png).image.width == Moodboard.maxSide)

    let wav = try Self.wav(in: folder, name: "line.wav")
    let media = try await Self.transfer(PastedMedia.self, from: wav)
    defer { PastedMedia.removeCopies([media]) }
    guard case .audio(let copy, let name) = media else {
      Issue.record("a WAV should paste as audio")
      return
    }
    // The file a Transferable receives may be named for its type, not the original ("CanvasDrop").
    #expect(name.hasSuffix(".wav") && copy != wav, "named \(name)")
    #expect(try Data(contentsOf: copy) == Data(contentsOf: wav))
    // Images only: audio isn't one.
    await #expect(throws: (any Error).self) { try await Self.transfer(PastedImage.self, from: wav) }
  }

  // MARK: - The Audio box

  @Test func anUnreadableFileLeavesTheAudioAsItWas() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let clip = AudioClip()
    defer { clip.clear() }
    try clip.set(Self.wav(in: folder), name: "Pasted Audio.wav")
    #expect(clip.name == "Pasted Audio.wav")
    let kept = try #require(clip.url)
    let broken = folder.appending(path: "broken.wav")
    try Data("not audio".utf8).write(to: broken)
    #expect(throws: (any Error).self) { try clip.set(broken) }
    #expect(clip.url == kept && clip.name == "Pasted Audio.wav")
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(clip.duration > 0.09)
  }

  @Test func aNewFileReplacesTheClipInPlace() throws {
    let folder = try Self.folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let clip = AudioClip()
    defer { clip.clear() }
    try clip.set(Self.wav(in: folder, name: "one.wav"))
    let first = try #require(clip.url)
    let aiff = folder.appending(path: "two.aiff")
    let source = try AVAudioFile(forReading: Self.wav(in: folder, name: "three.wav"))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4800))
    try source.read(into: buffer)
    try AVAudioFile(forWriting: aiff, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true])
      .write(from: buffer)
    try clip.set(aiff)
    let second = try #require(clip.url)
    #expect(clip.name == "two.aiff" && second.pathExtension == "aiff")
    #expect(FileManager.default.fileExists(atPath: second.path))
    // The previous clip, with its other extension, is gone, and no copy in progress is left.
    #expect(!FileManager.default.fileExists(atPath: first.path))
    let left = try FileManager.default.contentsOfDirectory(atPath: second.deletingLastPathComponent().path)
    #expect(!left.contains { $0.hasPrefix("incoming-") })
  }
}
