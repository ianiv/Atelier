@testable import Atelier
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
    #expect(TriggerWords.prompt("a park", sources: sources, disabled: [:]) == "l1r4, woman, film grain, a park")
    #expect(TriggerWords.prompt("a park", sources: sources, disabled: ["a": ["woman"]]) == "l1r4, film grain, a park")
    #expect(TriggerWords.prompt("", sources: sources, disabled: ["b": ["film grain"]]) == "l1r4, woman")
    #expect(TriggerWords.prompt("a park", sources: [], disabled: [:]) == "a park")
  }

  @Test func skipsWordsAlreadyInPromptAsWholeWords() {
    let sources = [source("a", ["L1R4", "art"])]
    #expect(TriggerWords.prompt("photo of l1r4 at a party", sources: sources, disabled: [:]) == "art, photo of l1r4 at a party")
    #expect(TriggerWords.contains("an ART deco room", word: "art"))
    #expect(!TriggerWords.contains("a party", word: "art"))
  }

  @Test func skipsIncompatibleLoRAsAndDuplicates() {
    let sources = [source("a", ["x"], applies: false), source("b", ["y", "Z"]), source("c", ["z"])]
    #expect(TriggerWords.prompt("p", sources: sources, disabled: [:]) == "y, Z, p")
  }

  @Test func leavesJSONPromptsAlone() {
    let sources = [source("a", ["l1r4"])]
    #expect(TriggerWords.prompt("  {\"caption\": \"x\"}", sources: sources, disabled: [:]) == "  {\"caption\": \"x\"}")
    #expect(TriggerWords.prompt("[{\"id\": 1}]", sources: sources, disabled: [:]) == "[{\"id\": 1}]")
    // FLUX.3's layout starts with its caption, so the words go in front.
    #expect(TriggerWords.prompt("a cat <1> [{\"id\": 1}]", sources: sources, disabled: [:]) == "l1r4, a cat <1> [{\"id\": 1}]")
    let stripped = TriggerWords.strip("{\"caption\": \"l1r4\"}", sources: sources)
    #expect(stripped.prompt == "{\"caption\": \"l1r4\"}" && stripped.disabled.isEmpty)
  }

  @Test func stripRoundTrips() {
    let sources = [source("a", ["l1r4", "woman"]), source("b", ["film grain"]), source("c", ["q"], applies: false)]
    for disabled: [String: Set<String>] in [[:], ["a": ["woman"]], ["a": ["l1r4", "woman"], "b": ["film grain"]]] {
      for prompt in ["a park", "", "woman in a park"] {
        let sent = TriggerWords.prompt(prompt, sources: sources, disabled: disabled)
        let stripped = TriggerWords.strip(sent, sources: sources)
        // Running it again gives what was sent.
        #expect(TriggerWords.prompt(stripped.prompt, sources: sources, disabled: stripped.disabled) == sent)
        #expect(stripped.prompt == prompt)
      }
    }
    // Off words come back off; the skipped LoRA's state isn't touched.
    let stripped = TriggerWords.strip("L1R4, a park", sources: sources)
    #expect(stripped.prompt == "a park")
    #expect(stripped.disabled == ["a": ["woman"], "b": ["film grain"]])
  }

  @Test func stripNeedsTheSeparator() {
    let stripped = TriggerWords.strip("l1r4 standing", sources: [source("a", ["l1r4"])])
    #expect(stripped.prompt == "l1r4 standing")
    // In the prompt, so it counts as on.
    #expect(stripped.disabled == ["a": []])
  }
}
