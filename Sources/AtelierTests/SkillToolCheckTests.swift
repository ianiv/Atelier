@testable import Atelier
import Foundation
import Testing

@Suite(.tags(.smoke))
struct SkillToolCheckTests {
  private let known: Set<String> = ["list_models", "generate", "use_app_settings", "history_step"]

  @Test func callLikeWordsAreFound() {
    let text = """
    First `list_models`, then `generte_image(prompt)` and maybe make_thumbnail(image).
    Call fetch_styles to begin, or use fancy_tool. Run it with use_app_settings on.
    """
    let result = SkillToolCheck.scan([text], known: known)
    #expect(result.found == ["fancy_tool", "fetch_styles", "generte_image", "list_models", "make_thumbnail", "use_app_settings"])
    #expect(result.unknown == ["fancy_tool", "fetch_styles", "generte_image", "make_thumbnail"])
  }

  @Test func plainProseIsLeftAlone() {
    let text = "Snake_case words in prose like some_thing or file_name.png aren't tools, nor is `Not_A_Tool` or `plain`."
    #expect(SkillToolCheck.scan([text], known: known).found.isEmpty)
  }

  @Test func fencedCodeIsSkipped() {
    let text = """
    Use `list_models`.
    ```python
    call_something_else()
    ```
    ~~~
    use another_one
    ~~~
    """
    #expect(SkillToolCheck.scan([text], known: known).found == ["list_models"])
  }

  @Test @MainActor func argumentNamesAreKnown() {
    let known = SkillToolCheck.knownNames(AgentTools.definitions)
    #expect(known.contains("generate") && known.contains("list_skills") && known.contains("read_skill"))
    #expect(known.contains("use_app_settings") && known.contains("history_step"), "inputSchema properties count")
    #expect(SkillToolCheck.scan(["Call generate with use_app_settings."], known: known).unknown.isEmpty)
  }

  @Test func ignoreList() throws {
    let frontmatter = try SkillFrontmatter.parse("name: a\ndescription: b\nmetadata:\n  atelier-ignore-tools: \"foo_bar, baz_qux\"\n")
    let ignored = SkillToolCheck.ignored(frontmatter: frontmatter)
    #expect(ignored == ["foo_bar", "baz_qux"])
    let result = SkillToolCheck.scan(["Call `foo_bar` and `baz_qux` and `other_one`."], known: known, ignored: ignored)
    #expect(result.found == ["baz_qux", "foo_bar", "other_one"] && result.unknown == ["other_one"])
    #expect(SkillToolCheck.ignored(frontmatter: nil).isEmpty)
  }
}
