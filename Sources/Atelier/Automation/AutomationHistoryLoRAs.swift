#if os(macOS)
import Foundation
import SwiftUI

/// `--history-loras-check --project NAME [--snapshot-dir DIR] [--quit]` checks the LoRAs row of
/// History's detail panel, as PASS/FAIL lines: it finds the project's steps that used LoRAs, one
/// whose LoRAs are all installed and one with a LoRA this device doesn't have (when the project
/// has them), logs the rows the panel lists for each, and checks installed ones carry the
/// library's name and missing ones their file name. It makes each the current step and opens
/// History, so the panel shows it; `--snapshot-dir` saves `history-loras.png` and
/// `history-loras-missing.png`, each with a `-panel.png` of the detail panel alone (the window
/// shot leaves the inspector blank). Without a missing LoRA in the project it renders
/// `history-loras-added-missing-panel.png` from an in-memory copy of a step with one added. It
/// writes nothing to the project, but run it on a scratch copy
/// anyway (`--project` with a copy of the `.sqlite3`, `-wal` and `-shm`).
extension Automation {
  static func historyLoRAsCheck(
    _ model: CreateModel, navigation: Navigation, layouts: LayoutStore, presets: PresetStore,
    library: ModelLibrary
  ) {
    let args = CommandLine.arguments
    func value(_ name: String) -> String? {
      guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    let snapshotDir = value("--snapshot-dir").map { URL(fileURLWithPath: $0) }
    // The window shot leaves the inspector column blank, so the panel is also rendered on its own.
    @MainActor func renderPanel(_ item: HistoryItem, to url: URL) -> Bool {
      let size = CGSize(width: 380, height: 3200)
      let detail = HistoryDetail(item: item, use: {}, rerun: {}, export: {}, delete: {})
        .environment(model)
        .environment(model.history)
        .environment(model.timelines)
        .environment(library)
        .frame(width: size.width, height: size.height)
      return AutomationWindows.snapshot(detail, size: size, to: url)
    }
    Task { @MainActor in
      var failures = 0
      func log(_ message: String) {
        print(message)
        fflush(stdout)
      }
      func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(message)")
      }
      while !model.history.isLoaded || model.models.isEmpty || model.isBusy {
        try? await Task.sleep(for: .milliseconds(100))
      }
      await library.reloadLoRAsIfRegistriesChanged()
      ensureWindow(model, navigation: navigation, layouts: layouts, presets: presets)
      let withLoRAs = model.history.items.compactMap { item -> (HistoryItem, [HistoryLoRA])? in
        let rows = HistoryLoRA.rows(of: item.sidecar.configuration, installed: library.loras)
        return rows.isEmpty ? nil : (item, rows)
      }
      log("project \(model.history.project.name): \(withLoRAs.count) of \(model.history.items.count) steps used LoRAs")
      check(!withLoRAs.isEmpty, "the project has steps with LoRAs")
      let installed = withLoRAs.first { $0.1.allSatisfy(\.isInstalled) }
      let missing = withLoRAs.first { $0.1.contains { !$0.isInstalled } }
      for (label, found, shot) in [("installed", installed, "history-loras.png"), ("not installed", missing, "history-loras-missing.png")] {
        guard let (item, rows) = found else {
          log("no step with \(label) LoRAs")
          continue
        }
        for row in rows {
          log("  \(item.tensorId): \(row.name) \(row.weight) [\(row.file)]\(row.isInstalled ? "" : " not installed")")
          let named = library.loras.first { $0.file == row.file }?.name ?? row.file
          check(row.name == named, "\(row.file) is listed as \(named)")
        }
        // History selects the current step when it opens, so show the step, then open History.
        navigation.section = .create
        model.show(item)
        try? await Task.sleep(for: .milliseconds(300))
        navigation.section = .history
        try? await Task.sleep(for: .seconds(2))
        if let snapshotDir {
          try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
          snapshot(to: snapshotDir.appendingPathComponent(shot))
          let panel = shot.replacingOccurrences(of: ".png", with: "-panel.png")
          check(renderPanel(item, to: snapshotDir.appendingPathComponent(panel)), "rendered \(panel)")
          log("saved \(shot)")
        }
      }
      // With no step using a LoRA this device lacks, render the panel for an in-memory copy of a
      // step with one added (nothing is written), to see how a missing LoRA looks.
      if missing == nil, let snapshotDir, var item = installed?.0,
         case .array(var entries)? = item.sidecar.configuration["loras"]
      {
        entries.append(.object(["file": .string("not_on_this_device_lora_f16.ckpt"), "weight": .number(0.75), "mode": .string("all")]))
        item.sidecar.configuration["loras"] = .array(entries)
        let rows = HistoryLoRA.rows(of: item.sidecar.configuration, installed: library.loras)
        check(rows.last == HistoryLoRA(file: "not_on_this_device_lora_f16.ckpt", name: "not_on_this_device_lora_f16.ckpt", weight: 0.75, isInstalled: false), "a LoRA this device lacks shows its file name, not installed")
        check(renderPanel(item, to: snapshotDir.appendingPathComponent("history-loras-added-missing-panel.png")), "rendered history-loras-added-missing-panel.png")
      }
      log(failures == 0 ? "history loras check: all passed" : "history loras check: \(failures) failed")
      if args.contains("--quit") { AppLifecycle.quit() }
    }
  }
}
#endif
