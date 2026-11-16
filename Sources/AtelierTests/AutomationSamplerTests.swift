#if os(macOS)
@testable import Atelier
@preconcurrency import DataModels
import Testing

/// `--sampler`'s case-name table (`Automation.samplerCaseNames`) is written out by hand, because
/// `SamplerType` describes itself by title; this keeps it in step with the engine's cases.
@MainActor
struct AutomationSamplerTests {
  @Test func caseNamesCoverEverySampler() {
    let named = Automation.samplerCaseNames.map(\.1)
    #expect(Set(named) == Set(DataModels.SamplerType.allCases))
    #expect(named.count == DataModels.SamplerType.allCases.count)
    let names = Automation.samplerCaseNames.map { $0.0.lowercased() }
    #expect(Set(names).count == names.count)
    #expect(Automation.samplerNames["ddimtrailing"] == .dDIMTrailing)
    #expect(Automation.samplerNames["ddim trailing"] == .dDIMTrailing)
  }
}
#endif
