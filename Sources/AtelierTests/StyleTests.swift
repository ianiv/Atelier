@testable import Atelier
import Foundation
import Testing

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
