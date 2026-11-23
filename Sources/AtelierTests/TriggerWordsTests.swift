@testable import Atelier
import CoreGraphics
import Testing

@Suite(.tags(.smoke))
struct TriggerWordsTests {
  private func source(_ file: String, _ words: [String], applies: Bool = true) -> TriggerWords.Source {
    TriggerWords.Source(file: file, words: words, applies: applies)
  }

  /// Every word of every source on, as explicit choices.
  private func allOn(_ sources: [TriggerWords.Source]) -> [String: Set<String>] {
    Dictionary(uniqueKeysWithValues: sources.map { ($0.file, Set($0.words.map { $0.lowercased() })) })
  }

  @Test func splitsPrefixOnCommas() {
    #expect(TriggerWords.words(fromPrefix: " l1r4,  woman ,,") == ["l1r4", "woman"])
    #expect(TriggerWords.words(fromPrefix: "Foo, foo, bar") == ["Foo", "bar"])
    #expect(TriggerWords.words(fromPrefix: "") == [])
    #expect(TriggerWords.words(fromPrefix: "red hat style") == ["red hat style"])
  }

  @Test func onlyTheFirstWordStartsOn() {
    let several = source("a", ["l1r4", "Woman", "beach"])
    #expect(TriggerWords.enabled(several, choices: [:]) == ["l1r4"])
    #expect(TriggerWords.isOn("L1R4", of: several, choices: [:]))
    #expect(!TriggerWords.isOn("woman", of: several, choices: [:]))
    let single = source("b", ["film grain"])
    #expect(TriggerWords.isOn("film grain", of: single, choices: [:]))
    #expect(TriggerWords.prompt("a park", sources: [several, single], choices: [:], format: nil) == "l1r4, film grain, a park")
  }

  @Test func choicesOverrideTheDefault() {
    let sources = [source("a", ["l1r4", "woman"]), source("b", ["film grain"])]
    // Choices for one LoRA leave the other on its default.
    #expect(TriggerWords.prompt("a park", sources: sources, choices: ["a": ["woman"]], format: nil) == "woman, film grain, a park")
    #expect(TriggerWords.prompt("", sources: sources, choices: ["a": ["l1r4", "woman"], "b": []], format: nil) == "l1r4, woman")
    #expect(TriggerWords.prompt("a park", sources: sources, choices: ["a": [], "b": []], format: nil) == "a park")
    #expect(TriggerWords.prompt("a park", sources: [], choices: [:], format: nil) == "a park")
  }

  @Test func skipsWordsAlreadyInPromptAsWholeWords() {
    let sources = [source("a", ["L1R4", "art"])]
    #expect(TriggerWords.prompt("photo of l1r4 at a party", sources: sources, choices: allOn(sources), format: nil) == "art, photo of l1r4 at a party")
    #expect(TriggerWords.contains("an ART deco room", word: "art"))
    #expect(!TriggerWords.contains("a party", word: "art"))
  }

  @Test func skipsIncompatibleLoRAsAndDuplicates() {
    let sources = [source("a", ["x"], applies: false), source("b", ["y", "Z"]), source("c", ["z"])]
    #expect(TriggerWords.prompt("p", sources: sources, choices: allOn(sources), format: nil) == "y, Z, p")
  }

  @Test func leavesJSONPromptsAlone() {
    let sources = [source("a", ["l1r4"])]
    #expect(TriggerWords.prompt("  {\"caption\": \"x\"}", sources: sources, choices: [:], format: .moss) == "  {\"caption\": \"x\"}")
    #expect(TriggerWords.prompt("{\"aspect_ratio\": \"1:1\"}", sources: sources, choices: [:], format: .ideogram4) == "{\"aspect_ratio\": \"1:1\"}")
    #expect(TriggerWords.prompt("[{\"label\": \"object\"}]", sources: sources, choices: [:], format: .moss) == "[{\"label\": \"object\"}]")
    // FLUX.3's layout starts with its caption, so the words go in front.
    #expect(TriggerWords.prompt("a cat <1> [{\"id\": 1}]", sources: sources, choices: [:], format: .flux3) == "l1r4, a cat <1> [{\"id\": 1}]")
    let stripped = TriggerWords.strip("{\"caption\": \"l1r4\"}", sources: sources, format: .moss)
    #expect(stripped.prompt == "{\"caption\": \"l1r4\"}" && stripped.choices.isEmpty)
  }

  @Test func stripRoundTrips() {
    let sources = [source("a", ["l1r4", "woman"]), source("b", ["film grain"]), source("c", ["q"], applies: false)]
    for choices: [String: Set<String>] in [[:], ["a": ["woman"]], allOn(sources), ["a": [], "b": []]] {
      for prompt in ["a park", "", "woman in a park"] {
        let sent = TriggerWords.prompt(prompt, sources: sources, choices: choices, format: nil)
        let stripped = TriggerWords.strip(sent, sources: sources, format: nil)
        // Running it again gives what was sent.
        #expect(TriggerWords.prompt(stripped.prompt, sources: sources, choices: stripped.choices, format: nil) == sent)
        #expect(stripped.prompt == prompt)
      }
    }
  }

  @Test func restoreSetsEveryAppliedLoRAExplicitly() {
    let sources = [source("a", ["l1r4", "woman"]), source("b", ["film grain"]), source("c", ["q"], applies: false)]
    // Words the run had on come back on, the rest off, even where that differs from the default.
    var stripped = TriggerWords.strip("woman, a park", sources: sources, format: nil)
    #expect(stripped.prompt == "a park")
    #expect(stripped.choices == ["a": ["woman"], "b": []])
    #expect(!TriggerWords.isOn("l1r4", of: sources[0], choices: stripped.choices))
    // The skipped LoRA isn't touched, so it keeps its default.
    #expect(stripped.choices["c"] == nil)
    stripped = TriggerWords.strip("L1R4, woman, film grain, a park", sources: sources, format: nil)
    #expect(stripped.choices == ["a": ["l1r4", "woman"], "b": ["film grain"]])
  }

  @Test func stripNeedsTheSeparator() {
    let stripped = TriggerWords.strip("l1r4 standing", sources: [source("a", ["l1r4", "woman"])], format: nil)
    #expect(stripped.prompt == "l1r4 standing")
    // In the prompt, so it counts as on.
    #expect(stripped.choices == ["a": ["l1r4"]])
  }

  @Test func fluxLayoutWithEmptyCaptionGetsWordsAndStillParses() {
    var layout = LayoutPrompt()
    layout.items = [LayoutPrompt.Item(name: "cat", kind: .object, rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), description: "a cat")]
    let written = layout.prompt(.flux3, width: 1024, height: 1024)
    #expect(written.hasPrefix("[{"))
    let sources = [source("a", ["l1r4", "woman"])]
    let sent = TriggerWords.prompt(written, sources: sources, choices: allOn(sources), format: .flux3)
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
    #expect(stripped.choices == ["flux": []])
    let sent = TriggerWords.prompt("l1r4, woman", sources: sources, choices: [:], format: nil)
    #expect(sent == "grain, l1r4, woman")
    #expect(TriggerWords.strip(sent, sources: sources, format: nil).prompt == "l1r4, woman")
  }

  @Test func stripIsCaseInsensitiveWhereLowercasingChangesLength() {
    // "İ" lowercases to two characters, so a count-based comparison misses it.
    let sources = [source("a", ["İstanbul"])]
    let stripped = TriggerWords.strip("İSTANBUL, a street", sources: sources, format: nil)
    #expect(stripped.prompt == "a street")
    #expect(stripped.choices == ["a": ["İstanbul".lowercased()]])
    #expect(TriggerWords.strip("istanbulx, a street", sources: sources, format: nil).prompt == "istanbulx, a street")
  }
}
