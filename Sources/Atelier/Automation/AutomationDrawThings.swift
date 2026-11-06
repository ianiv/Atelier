#if os(macOS)
import Foundation
import SwiftUI

/// Fails the catalog fetch while it's registered, as a network failure at launch would.
final nonisolated class FailingCatalogProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "models.drawthings.ai"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }

  override func stopLoading() {}
}

extension Automation {
  /// Whether this launch is `--catalog-retry-check`, whose failure has to be in place before the
  /// first listing.
  nonisolated static var failsFirstCatalogFetch: Bool {
    CommandLine.arguments.contains("--catalog-retry-check")
  }

  /// `--catalog-retry-check`: fails the models.drawthings.ai fetch, then checks that the shipped copy
  /// supplies the community models, and that Refresh switches to the real list once the network is
  /// back. Needs the network, and writes nothing.
  ///
  ///   Atelier --catalog-retry-check [--expect-model FILE] [--snapshot-sheet FILE] [-AtelierDrawThingsFolders '(A, B)'] \
  ///     [-AtelierShow drawThingsImport] [--quit]
  ///
  /// With the other two, it also opens the Draw Things import sheet on those folders and renders it to FILE.
  static func catalogRetryCheck(_ model: CreateModel, library: ModelLibrary) {
    let args = CommandLine.arguments
    Task { @MainActor in
      func check(_ passed: Bool, _ message: String) {
        print("\(passed ? "PASS" : "FAIL") \(message)")
        fflush(stdout)
      }
      await library.refresh()
      let before = library.catalog.count
      print("while failing: \(before) in the catalog, \(model.models.count) installed listed")
      check(library.catalog.contains { $0.file == "flux_3_klein_q8p.ckpt" }, "the shipped copy supplies the community models")
      check(CommunityCatalog.fallback.count == CommunityCatalog.shipped.count, "the fallback is the shipped copy")
      await library.refresh()
      check(library.catalog.count == before, "Refresh with the network down changes nothing")
      check(CommunityCatalog.generation == 1, "the shipped copy goes in once")
      URLProtocol.unregisterClass(FailingCatalogProtocol.self)
      await library.refresh()
      print("after retry: \(library.catalog.count) in the catalog, \(model.models.count) installed listed")
      check(CommunityCatalog.generation == 2, "Refresh replaces it once the network is back")
      await library.refresh()
      check(CommunityCatalog.generation == 2, "a later Refresh doesn't fetch again")
      if let index = args.firstIndex(of: "--snapshot-sheet"), index + 1 < args.count {
        // Long enough for the sheet's scan and its own catalog lookup.
        try? await Task.sleep(for: .seconds(4))
        check(AutomationWindows.snapshotSheet(to: URL(fileURLWithPath: args[index + 1])), "rendered the import sheet")
      }
      if let paths = UserDefaults.standard.stringArray(forKey: "AtelierDrawThingsFolders") {
        let known = await DrawThingsImporter.knownFiles(community: CommunityCatalog.specifications() ?? [])
        let selection = DrawThingsSelection(folders: paths.map { DrawThingsContents.scan(URL(fileURLWithPath: $0)) })
        for file in selection.unmatchedFiles(known: known) {
          print("unmatched: \(file.name) \(file.size) bytes \(file.kind)")
        }
      }
      if let index = args.firstIndex(of: "--expect-model"), index + 1 < args.count {
        check(model.models.contains { $0.file == args[index + 1] }, "\(args[index + 1]) is listed")
      }
      if args.contains("--quit") { AppLifecycle.quit() }
    }
  }
}
#endif
