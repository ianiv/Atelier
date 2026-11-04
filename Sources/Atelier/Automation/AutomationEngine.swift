#if os(macOS)
import Foundation

/// `--engine-check --project NAME [--model M] [--steps N] [--quit]` runs a tiny generation (N steps,
/// default 2, with the selected model or M) and checks that every engine field `GenerationEngine`
/// reads by reflection still resolves, as PASS/FAIL lines. Run it after moving to a new engine
/// revision. The image isn't saved to the project.
extension Automation {
  static func engineCheck(_ model: CreateModel) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    Task { @MainActor in
      func log(_ message: String) {
        print(message)
        fflush(stdout)
      }
      while !model.history.isLoaded || model.models.isEmpty || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard let file = value("--model") ?? model.selectedModel else {
        log("FAIL no --model and no model selected")
        if args.contains("--quit") { AppLifecycle.quit() }
        return
      }
      let steps = value("--steps").flatMap(Int.init) ?? 2
      var failures = 0
      do {
        log("running \(steps) steps with \(file)")
        let fields = try await model.engine.checkReflectedFields(model: file, steps: steps)
        for field in fields {
          if !field.found { failures += 1 }
          log("\(field.found ? "PASS" : "FAIL") \(field.name)")
        }
      } catch {
        failures += 1
        log("FAIL the run: \(error.localizedDescription)")
      }
      log(failures == 0 ? "engine check: all passed" : "engine check: \(failures) failed")
      if args.contains("--quit") { AppLifecycle.quit() }
    }
  }
}
#endif
