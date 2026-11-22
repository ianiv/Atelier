import Foundation
import Observation
import SwiftUI

/// The Hugging Face token: kept in the Keychain (service "Atelier Hugging Face"), sent only to
/// huggingface.co and hf.co over HTTPS. Gated and private repos need one; public ones don't.
/// A scripted run never touches the Keychain: it keeps the token in memory, taken from the
/// `HF_TOKEN` environment variable if set.
nonisolated enum HuggingFaceAuth {
  static let service = "Atelier Hugging Face"
  static let account = "token"
  static let tokensPage = URL(string: "https://huggingface.co/settings/tokens")!
  static let whoAmI = URL(string: "https://huggingface.co/api/whoami-v2")!

  /// Exact hosts, no subdomains: downloads redirect to CDN hosts under hf.co
  /// (cdn-lfs.hf.co, cas-bridge.xethub.hf.co) with signed URLs, which must not get the token.
  static let tokenHosts: Set<String> = ["huggingface.co", "hf.co"]

  /// The headers for a request to `url`: `Authorization: Bearer` only for HTTPS to a token host.
  static func headers(for url: URL, token: String?) -> [String: String] {
    guard let token, !token.isEmpty, url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(), tokenHosts.contains(host)
    else { return [:] }
    return ["Authorization": "Bearer \(token)"]
  }

  static func makeStore() -> RemoteSecretStore {
    guard Automation.isRequested else { return KeychainSecretStore(service: service) }
    let store = MemorySecretStore()
    if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
      store.save(Data(token.utf8), account: account)
    }
    return store
  }

  /// Fetches `url` (an API call or a byte range of a file) with the token where it belongs, and
  /// turns Hugging Face's refusals into what to do about them. `limit` caps what's accepted, since
  /// a JSON file or header should be small.
  @concurrent static func data(
    _ url: URL, token: String?, range: Range<Int64>? = nil, limit: Int = 64 << 20,
    repo: String, user: String?
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    for (field, value) in headers(for: url, token: token) { request.setValue(value, forHTTPHeaderField: field) }
    if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
    request.timeoutInterval = 60
    let (data, response) = try await URLSession.shared.data(for: request, delegate: RedirectPolicy())
    guard let http = response as? HTTPURLResponse else { throw HuggingFaceError.unexpectedResponse }
    switch http.statusCode {
    case 200..<300: break
    case 401: throw token == nil ? HuggingFaceError.needsToken : HuggingFaceError.tokenRejected
    case 403: throw HuggingFaceError.gated(repo: repo, user: user)
    case 404: throw HuggingFaceError.notFound
    default: throw HuggingFaceError.server(http.statusCode)
    }
    guard data.count <= limit else { throw HuggingFaceError.tooLarge(url.lastPathComponent) }
    // A server that ignores Range sends the whole file.
    if let range, http.statusCode != 206 || data.count != range.count {
      guard data.count >= range.upperBound else { throw HuggingFaceError.unexpectedResponse }
      return (data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), http)
    }
    return (data, http)
  }

  /// Drops the token from a redirect to another host, as the engine's downloader does
  /// (`RedirectHeaderPolicy` in the fork's ResumableDownloader).
  final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      guard response.url?.host?.lowercased() != request.url?.host?.lowercased() || response.url?.scheme != request.url?.scheme
      else { return completionHandler(request) }
      var request = request
      request.setValue(nil, forHTTPHeaderField: "Authorization")
      completionHandler(request)
    }
  }
}

/// The token and who it signs in as, for Settings ▸ Models and the link sheet.
@MainActor
@Observable
final class HuggingFaceAccount {
  enum Status: Equatable {
    case none
    case checking
    case signedIn(String)
    case rejected
    case unreachable(String)
  }

  private(set) var status: Status = .none
  private(set) var token: String?
  private let store: RemoteSecretStore

  init(store: RemoteSecretStore = HuggingFaceAuth.makeStore()) {
    self.store = store
    token = store.load(HuggingFaceAuth.account).flatMap { String(data: $0, encoding: .utf8) }
  }

  var hasToken: Bool { token != nil }
  var userName: String? {
    if case .signedIn(let name) = status { name } else { nil }
  }

  func save(_ newToken: String) {
    let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    store.save(Data(trimmed.utf8), account: HuggingFaceAuth.account)
    token = trimmed
    Task { await check() }
  }

  func remove() {
    store.save(nil, account: HuggingFaceAuth.account)
    token = nil
    status = .none
  }

  /// Checks the token once it's needed (Settings, the link sheet), not at launch, so Atelier
  /// doesn't contact Hugging Face unless it's used.
  func checkIfNeeded() async {
    if token != nil, status == .none { await check() }
  }

  /// Asks Hugging Face who the token belongs to.
  func check() async {
    guard let token else {
      status = .none
      return
    }
    status = .checking
    do {
      let (data, _) = try await HuggingFaceAuth.data(HuggingFaceAuth.whoAmI, token: token, repo: "", user: nil)
      let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String
      guard self.token == token else { return }
      status = .signedIn(name ?? "unknown")
    } catch let error as HuggingFaceError where error == .tokenRejected || error == .needsToken {
      guard self.token == token else { return }
      status = .rejected
    } catch {
      guard self.token == token else { return }
      status = .unreachable(error.localizedDescription)
    }
  }

  var statusText: String {
    switch status {
    case .none: token == nil ? "No token. Public repos download without one." : "Saved, not checked yet."
    case .checking: "Checking…"
    case .signedIn(let name): "Signed in as \(name)"
    case .rejected: "Token rejected"
    case .unreachable(let message): "Couldn't check the token: \(message)"
    }
  }
}

/// Settings ▸ Models ▸ Hugging Face: the token for gated and private repos.
struct HuggingFaceTokenSection: View {
  @Environment(ModelLibrary.self) private var library
  @State private var entered = ""

  var body: some View {
    let account = library.huggingFace
    Section {
      LabeledContent("Token") {
        HStack {
          SecureField("hf_…", text: $entered)
            .labelsHidden()
            .settingsFieldWidth()
            .onSubmit(save)
          Button("Save", action: save)
            .disabled(entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Remove") { account.remove() }
            .disabled(!account.hasToken)
        }
      }
      LabeledContent("Status") {
        Text(account.statusText)
          .foregroundStyle(account.status == .rejected ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      }
    } header: {
      Text("Hugging Face")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text("For importing from gated or private repos. A read token is enough; it's kept in the Keychain and sent only to huggingface.co.")
        Link("Create a token on huggingface.co", destination: HuggingFaceAuth.tokensPage)
      }
    }
    .task { await account.checkIfNeeded() }
  }

  private func save() {
    library.huggingFace.save(entered)
    entered = ""
  }
}
