@testable import Atelier
import CoreGraphics
import Testing

@Suite(.tags(.smoke))
struct TriggerWordsTests {
  private func source(_ file: String, _ words: [String], applies: Bool = true) -> TriggerWords.Source {
    TriggerWords.Source(file: file, words: words, applies: applies)
  }

  @Test func splitsPrefixOnCommas() {
    #expect(TriggerWords.words(fromPrefix: " l1r4,  woman ,,") == ["l1r4", "woman"])
    #expect(TriggerWords.words(fromPrefix: "Foo, foo, bar") == ["Foo", "bar"])
    #expect(TriggerWords.words(fromPrefix: "") == [])
    #expect(TriggerWords.words(fromPrefix: "red hat style") == ["red hat style"])
  }

  @Test func prependsWordsTurnedOn() {
    let sources = [source("a", ["l1r4", "woman"]), source("b", ["film grain"])]
    #expect(TriggerWords.prompt("a park", sources: sources, disabled: [:], format: nil) == "l1r4, woman, film grain, a park")
    #expect(TriggerWords.prompt("a park", sources: sources, disabled: ["a": ["woman"]], format: nil) == "l1r4, film grain, a park")
    #expect(TriggerWords.prompt("", sources: sources, disabled: ["b": ["film grain"]], format: nil) == "l1r4, woman")
    #expect(TriggerWords.prompt("a park", sources: [], disabled: [:], format: nil) == "a park")
  }

  @Test func skipsWordsAlreadyInPromptAsWholeWords() {
    let sources = [source("a", ["L1R4", "art"])]
    #expect(TriggerWords.prompt("photo of l1r4 at a party", sources: sources, disabled: [:], format: nil) == "art, photo of l1r4 at a party")
    #expect(TriggerWords.contains("an ART deco room", word: "art"))
    #expect(!TriggerWords.contains("a party", word: "art"))
  }

  @Test func skipsIncompatibleLoRAsAndDuplicates() {
    let sources = [source("a", ["x"], applies: false), source("b", ["y", "Z"]), source("c", ["z"])]
    #expect(TriggerWords.prompt("p", sources: sources, disabled: [:], format: nil) == "y, Z, p")
  }

  @Test func leavesJSONPromptsAlone() {
    let sources = [source("a", ["l1r4"])]
    #expect(TriggerWords.prompt("  {\"caption\": \"x\"}", sources: sources, disabled: [:], format: .moss) == "  {\"caption\": \"x\"}")
    #expect(TriggerWords.prompt("{\"aspect_ratio\": \"1:1\"}", sources: sources, disabled: [:], format: .ideogram4) == "{\"aspect_ratio\": \"1:1\"}")
    #expect(TriggerWords.prompt("[{\"label\": \"object\"}]", sources: sources, disabled: [:], format: .moss) == "[{\"label\": \"object\"}]")
    // FLUX.3's layout starts with its caption, so the words go in front.
    #expect(TriggerWords.prompt("a cat <1> [{\"id\": 1}]", sources: sources, disabled: [:], format: .flux3) == "l1r4, a cat <1> [{\"id\": 1}]")
    let stripped = TriggerWords.strip("{\"caption\": \"l1r4\"}", sources: sources, format: .moss)
    #expect(stripped.prompt == "{\"caption\": \"l1r4\"}" && stripped.disabled.isEmpty)
  }

  @Test func stripRoundTrips() {
    let sources = [source("a", ["l1r4", "woman"]), source("b", ["film grain"]), source("c", ["q"], applies: false)]
    for disabled: [String: Set<String>] in [[:], ["a": ["woman"]], ["a": ["l1r4", "woman"], "b": ["film grain"]]] {
      for prompt in ["a park", "", "woman in a park"] {
        let sent = TriggerWords.prompt(prompt, sources: sources, disabled: disabled, format: nil)
        let stripped = TriggerWords.strip(sent, sources: sources, format: nil)
        // Running it again gives what was sent.
        #expect(TriggerWords.prompt(stripped.prompt, sources: sources, disabled: stripped.disabled, format: nil) == sent)
        #expect(stripped.prompt == prompt)
      }
    }
    // Off words come back off; the skipped LoRA's state isn't touched.
    let stripped = TriggerWords.strip("L1R4, a park", sources: sources, format: nil)
    #expect(stripped.prompt == "a park")
    #expect(stripped.disabled == ["a": ["woman"], "b": ["film grain"]])
  }

  @Test func stripNeedsTheSeparator() {
    let stripped = TriggerWords.strip("l1r4 standing", sources: [source("a", ["l1r4"])], format: nil)
    #expect(stripped.prompt == "l1r4 standing")
    // In the prompt, so it counts as on.
    #expect(stripped.disabled == ["a": []])
  }

  @Test func fluxLayoutWithEmptyCaptionGetsWordsAndStillParses() {
    var layout = LayoutPrompt()
    layout.items = [LayoutPrompt.Item(name: "cat", kind: .object, rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), description: "a cat")]
    let written = layout.prompt(.flux3, width: 1024, height: 1024)
    #expect(written.hasPrefix("[{"))
    let sources = [source("a", ["l1r4", "woman"])]
    let sent = TriggerWords.prompt(written, sources: sources, disabled: [:], format: .flux3)
    #expect(sent == "l1r4, woman, " + written)
    let parsed = LayoutPrompt(prompt: sent, format: .flux3, width: 1024, height: 1024)
    let boxes = { (layout: LayoutPrompt?) in layout?.items.map { "\($0.name) \($0.rect) \($0.description)" } }
    #expect(boxes(parsed) != nil && boxes(parsed) == boxes(LayoutPrompt(prompt: written, format: .flux3, width: 1024, height: 1024)))
    #expect(parsed?.caption == "l1r4, woman,")
    let stripped = TriggerWords.strip(sent, sources: sources, format: .flux3)
    #expect(stripped.prompt == written)
  }

  @Test func stripLeavesWordsOfSkippedLoRAs() {
    // An SDXL LoRA on a FLUX run: its word was never added, so text matching it is the user's.
    let sources = [source("sdxl", ["l1r4"], applies: false), source("flux", ["grain"])]
    let stripped = TriggerWords.strip("l1r4, woman on a beach", sources: sources, format: nil)
    #expect(stripped.prompt == "l1r4, woman on a beach")
    #expect(stripped.disabled == ["flux": ["grain"]])
    let sent = TriggerWords.prompt("grain, l1r4, woman", sources: sources, disabled: [:], format: nil)
    #expect(TriggerWords.strip(sent, sources: sources, format: nil).prompt == "l1r4, woman")
  }

  @Test func stripIsCaseInsensitiveWhereLowercasingChangesLength() {
    // "İ" lowercases to two characters, so a count-based comparison misses it.
    let sources = [source("a", ["İstanbul"])]
    let stripped = TriggerWords.strip("İSTANBUL, a street", sources: sources, format: nil)
    #expect(stripped.prompt == "a street")
    #expect(stripped.disabled == ["a": []])
    #expect(TriggerWords.strip("istanbulx, a street", sources: sources, format: nil).prompt == "istanbulx, a street")
  }
}
