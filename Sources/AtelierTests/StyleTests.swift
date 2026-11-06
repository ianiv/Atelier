@testable import Atelier
import CoreGraphics
import Foundation
import Testing

@MainActor
struct StyleLibraryStoreTests {
  /// Thumbnail size, so only the square is kept and not a full image beside it.
  private func image() -> CGImage {
    let context = CGContext(
      data: nil, width: StyleStore.thumbnailSize, height: StyleStore.thumbnailSize, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return context.makeImage()!
  }

  private func files(_ folder: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
  }

  @Test func existingStylesBecomeTheFirstLibraryWhereTheyAre() throws {
    try withTestFolder { root in
      let old = Style(name: "Old", category: "C", template: "{{SUBJECT}}")
      let oldFile = root.appending(path: "Styles.json")
      let data = try JSONEncoder().encode([old])
      try data.write(to: oldFile)
      let thumbnails = root.appending(path: "StyleThumbnails", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
      touch(thumbnails.appending(path: old.id.uuidString + ".jpg"))

      let store = StyleStore(root: root)
      #expect(store.libraries.map(\.id) == [StyleStore.mainLibraryID])
      #expect(store.styles == [old])
      #expect(try Data(contentsOf: oldFile) == data, "nothing is rewritten")
      #expect(files(thumbnails) == [old.id.uuidString + ".jpg"])
    }
  }

  @Test func librariesKeepTheirOwnFilesAndComeBack() throws {
    try withTestFolder { root in
      let store = StyleStore(root: root)
      let main = Style(name: "Main", template: "{{SUBJECT}}")
      store.save(main)
      let film = store.createLibrary(named: "Film")
      let kodak = Style(name: "Kodak", template: "{{SUBJECT}}, film")
      store.importStyles([kodak], into: film)
      store.setThumbnail(image(), for: kodak.id)

      let imported = store.library(ofStyle: store.libraries[1].styles[0].id)
      #expect(imported?.id == film)
      let keptID = store.libraries[1].styles[0].id
      #expect(files(store.thumbnailsFolder(ofLibrary: film)) == [keptID.uuidString + ".jpg"])
      #expect(files(store.thumbnailsFolder(ofLibrary: StyleStore.mainLibraryID)).isEmpty)

      let again = StyleStore(root: root)
      #expect(again.libraries.map(\.name) == ["My Styles", "Film"])
      #expect(again.libraries[0].styles.map(\.name) == ["Main"])
      #expect(again.libraries[1].styles.map(\.name) == ["Kodak"])
      #expect(again.style(id: keptID)?.name == "Kodak", "found from any library")
      #expect(files(again.thumbnailsFolder(ofLibrary: film)) == [keptID.uuidString + ".jpg"], "a library's thumbnails aren't orphans")
    }
  }

  @Test func importingReplacesOnlyWithinTheLibrary() throws {
    try withTestFolder { root in
      let store = StyleStore(root: root)
      let style = Style(name: "Same", category: "C", template: "one")
      store.importStyles([style])
      let other = store.createLibrary(named: "Other")
      #expect(store.importStyles([style], into: other).added == 1)
      #expect(store.importStyles([Style(name: "same", category: "c", template: "two")], into: other).replaced == 1)
      #expect(store.libraries[0].styles.map(\.template) == ["one"])
      #expect(store.libraries[1].styles.map(\.template) == ["two"])
    }
  }

  @Test func movingAndCopyingTakeThumbnails() throws {
    try withTestFolder { root in
      let store = StyleStore(root: root)
      let main = store.currentLibraryID
      let other = store.createLibrary(named: "Other")
      let style = Style(name: "S", category: "C", template: "t")
      store.save(style)
      store.setThumbnail(image(), for: style.id)
      let name = style.id.uuidString + ".jpg"

      store.copy([style.id], toLibrary: other)
      let copy = try #require(store.libraries[1].styles.first)
      #expect(copy.id != style.id && copy.name == style.name)
      #expect(files(store.thumbnailsFolder(ofLibrary: other)) == [copy.id.uuidString + ".jpg"])
      #expect(files(store.thumbnailsFolder(ofLibrary: main)) == [name])

      store.move([style.id], toLibrary: other)
      #expect(store.libraries[0].styles.isEmpty)
      #expect(Set(store.libraries[1].styles.map(\.id)) == [style.id, copy.id])
      #expect(files(store.thumbnailsFolder(ofLibrary: main)).isEmpty)
      #expect(files(store.thumbnailsFolder(ofLibrary: other)) == [name, copy.id.uuidString + ".jpg"])

      let again = StyleStore(root: root)
      #expect(again.libraries[0].styles.isEmpty && again.libraries[1].styles.count == 2)
      #expect(files(again.thumbnailsFolder(ofLibrary: other)).count == 2)
    }
  }

  @Test func deletingALibraryRemovesItsFilesButNeverTheLast() throws {
    try withTestFolder { root in
      let store = StyleStore(root: root)
      let other = store.createLibrary(named: "Other")
      store.selectLibrary(other)
      let style = Style(name: "S", template: "t")
      store.save(style)
      store.setThumbnail(image(), for: style.id)
      store.screenSelection = [style.id]
      let folder = store.thumbnailsFolder(ofLibrary: other).deletingLastPathComponent()
      #expect(FileManager.default.fileExists(atPath: folder.path))

      store.deleteLibrary(other)
      #expect(store.libraries.map(\.id) == [StyleStore.mainLibraryID])
      #expect(store.currentLibraryID == StyleStore.mainLibraryID)
      #expect(store.screenSelection.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: folder.path))

      store.deleteLibrary(StyleStore.mainLibraryID)
      #expect(store.libraries.count == 1, "the last library stays")
      #expect(StyleStore(root: root).libraries.count == 1)
    }
  }

  @Test func namesStayDistinct() throws {
    try withTestFolder { root in
      let store = StyleStore(root: root)
      let one = store.createLibrary(named: "Film")
      let two = store.createLibrary(named: "film")
      #expect(store.libraries.first { $0.id == two }?.name == "film 2")
      store.renameLibrary(two, to: "Film")
      #expect(store.libraries.first { $0.id == two }?.name == "Film 2")
      store.renameLibrary(one, to: "  Film  ")
      #expect(store.libraries.first { $0.id == one }?.name == "Film")
    }
  }

  @Test func aLibraryPageGivesItsTitle() throws {
    let html = try StyleLibrary.html(title: "Film Cameras", styles: [Style(name: "S", template: "t")]) { _ in nil }
    #expect(StyleLibrary.title(html) == "Film Cameras")
    #expect(StyleLibrary.title("# Just markdown") == nil)
  }
}

struct StyleTests {
  func style(_ template: String, negative: String = "") -> Style {
    Style(name: "S", template: template, negative: negative)
  }

  @Test func tagsComeInOrderOfFirstAppearance() {
    #expect(style("{{MOOD}} {{SUBJECT}} at {{SETTING}}, {{MOOD}}").tags == ["MOOD", "SUBJECT", "SETTING"])
  }

  @Test func aTemplateWithoutSubjectGetsItInFront() {
    #expect(style("oil painting of {{SETTING}}").tags == ["SUBJECT", "SETTING"])
    #expect(style("oil painting").apply(["SUBJECT": "a fox"], negativePrompt: "").prompt == "a fox oil painting")
  }

  @Test func aSubjectWithADefaultCountsAsHavingOne() {
    #expect(style("{{SUBJECT:a cat}} sleeps").tags == ["SUBJECT"])
    #expect(style("{{SUBJECT:a cat}} sleeps").apply([:], negativePrompt: "").prompt == "a cat sleeps")
  }

  @Test func defaultsComeFromTheFirstThatHasOne() {
    let defaults = style("{{SUBJECT}} {{MOOD}} {{MOOD:warm}} {{MOOD:cold}} {{EMPTY: }}").defaults
    #expect(defaults == ["MOOD": "warm"])
  }

  @Test func applyFillsTagsAndClosesGaps() {
    let result = style("{{SUBJECT}} in {{SETTING:a garden}} {{MOOD}} light").apply(
      ["SUBJECT": " a fox "], negativePrompt: "")
    #expect(result.prompt == "a fox in a garden light")
  }

  @Test func applyKeepsLineBreaks() {
    #expect(style("{{SUBJECT}}\n\n{{X}}\nend").apply(["SUBJECT": "a"], negativePrompt: "").prompt == "a\n\n\nend")
  }

  @Test func negativePromptsJoinYoursFirst() {
    let styled = style("{{SUBJECT}}", negative: "blurry")
    #expect(styled.apply([:], negativePrompt: "dark").negativePrompt == "dark, blurry")
    #expect(styled.apply([:], negativePrompt: " ").negativePrompt == "blurry")
    #expect(style("{{SUBJECT}}").apply([:], negativePrompt: "").negativePrompt == "")
  }

  @Test func somethingThatIsNotATagStaysAsText() {
    #expect(style("{{SUBJECT}} {{1BAD}} {single}").apply(["SUBJECT": "a"], negativePrompt: "").prompt == "a {{1BAD}} {single}")
  }

  /// `match` undoes `apply`, which is how a reused image brings its style back.
  @Test func matchFindsTheValuesApplyUsed() throws {
    let styled = style("A photo of {{SUBJECT}} at {{SETTING}}.", negative: "blurry")
    let values = ["SUBJECT": "a fox", "SETTING": "dusk"]
    let written = styled.apply(values, negativePrompt: "dark")
    let found = try #require(styled.match(prompt: written.prompt, negativePrompt: written.negativePrompt))
    #expect(found.values == values)
    #expect(found.negativePrompt == "dark")
  }

  @Test func matchGivesAnEmptyBoxForADefault() throws {
    let styled = style("{{SUBJECT}} in {{MOOD:warm}} light")
    let written = styled.apply(["SUBJECT": "a fox"], negativePrompt: "")
    let found = try #require(styled.match(prompt: written.prompt, negativePrompt: ""))
    #expect(found.values == ["SUBJECT": "a fox", "MOOD": ""])
  }

  @Test func matchRefusesOtherPromptsAndAnEmptySubject() {
    let styled = style("A photo of {{SUBJECT}}.")
    #expect(styled.match(prompt: "A drawing of a fox.", negativePrompt: "") == nil)
    #expect(styled.match(prompt: "A photo of .", negativePrompt: "") == nil)
  }

  @Test func matchTreatsRegexCharactersAsText() throws {
    let styled = style("(best) [quality] {{SUBJECT}} 100%?")
    let found = try #require(styled.match(prompt: "(best) [quality] a fox 100%?", negativePrompt: ""))
    #expect(found.values["SUBJECT"] == "a fox")
  }

  @Test func labelsReadAsWords() {
    #expect(Style.label("CAMERA_ANGLE") == "Camera angle")
    #expect(Style.label("SUBJECT") == "Subject")
  }

  @Test func aStyleFileIsParsed() throws {
    let styles = StyleFile.parse(
      """
      # Title with nothing under it

      # Photo

      ## Portrait

      ### Soft
      TEMPLATE:
      A photo of {{SUBJECT}}
      in soft light
      NEGATIVE:
      blurry
      NOTES:
      A note

      ### No template
      NOTES:
      Skipped

      # Art

      ### Ink
      TEMPLATE: Ink drawing of {{SUBJECT}}
      """)
    #expect(styles.map(\.name) == ["Soft", "Ink"])
    let soft = try #require(styles.first)
    #expect(soft.category == "Photo" && soft.subcategory == "Portrait")
    #expect(soft.template == "A photo of {{SUBJECT}}\nin soft light")
    #expect(soft.negative == "blurry" && soft.notes == "A note")
    #expect(styles[1].category == "Art" && styles[1].subcategory == "")
  }

  @Test func aStyleWithoutASubcategoryAfterOneWithIsReadBackTheSame() {
    let styles = [
      Style(name: "A", category: "One", subcategory: "Sub", template: "{{SUBJECT}}"),
      Style(name: "B", category: "One", template: "{{SUBJECT}}"),
    ]
    #expect(StyleFile.parse(StyleFile.write(styles)).map(\.subcategory) == ["Sub", ""])
  }

  @Test func writingAStyleFileReadsBackTheSame() {
    let styles = [
      Style(name: "B", category: "One", template: "x {{SUBJECT}}"),
      Style(name: "A", category: "One", subcategory: "Sub", template: "{{SUBJECT}}\nline two", negative: "n", notes: "note"),
      Style(name: "C", category: "Two", template: "{{SUBJECT:d}}"),
    ]
    let read = StyleFile.parse(StyleFile.write(styles))
    #expect(read.map(\.name) == styles.map(\.name))
    #expect(read.map(\.category) == styles.map(\.category))
    #expect(read.map(\.subcategory) == styles.map(\.subcategory))
    #expect(read.map(\.template) == styles.map(\.template))
    #expect(read.map(\.negative) == styles.map(\.negative))
    #expect(read.map(\.notes) == styles.map(\.notes))
  }
}
