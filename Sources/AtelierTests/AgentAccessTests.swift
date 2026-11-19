@testable import Atelier
import Foundation
import Network
import Testing

@Suite(.tags(.smoke))
struct AgentAccessTests {
  @Test func loopbackPeers() {
    #expect(AgentAuth.isLoopback(RemoteIP("127.0.0.1")))
    #expect(AgentAuth.isLoopback(RemoteIP("127.4.5.6")))
    #expect(AgentAuth.isLoopback(RemoteIP("::1")))
    #expect(AgentAuth.isLoopback(RemoteIP("::ffff:127.0.0.1")), "a dual-stack listener's IPv4 loopback")
    #expect(!AgentAuth.isLoopback(RemoteIP("192.168.1.5")))
    #expect(!AgentAuth.isLoopback(RemoteIP("100.100.1.2")))
    #expect(!AgentAuth.isLoopback(nil))
  }

  @Test func peerFilter() {
    let filter = AgentAccess.networkFilter
    #expect(filter.allows(RemoteIP("127.0.0.1")), "loopback counts as local")
    #expect(filter.allows(RemoteIP("::1")))
    #expect(filter.allows(RemoteIP("192.168.1.20")))
    #expect(filter.allows(RemoteIP("10.0.0.3")))
    #expect(filter.allows(RemoteIP("100.101.102.103")), "Tailscale")
    #expect(!filter.allows(RemoteIP("8.8.8.8")))
    #expect(!filter.allows(RemoteIP("2001:4860:4860::8888")))
    #expect(!filter.allows(NWEndpoint.hostPort(host: "17.253.144.10", port: 7862)))
    #expect(filter.allows(NWEndpoint.hostPort(host: "192.168.0.2", port: 7862)))
  }

  @Test func authorization() {
    let token = "abc123"
    #expect(AgentAuth.isAuthorized(peerIsLoopback: true, requireToken: true, authorization: nil, token: token))
    #expect(AgentAuth.isAuthorized(peerIsLoopback: true, requireToken: true, authorization: "Bearer abc123", token: token))
    #expect(AgentAuth.isAuthorized(peerIsLoopback: true, requireToken: true, authorization: "Bearer wrong", token: token), "this Mac never needs it")
    #expect(!AgentAuth.isAuthorized(peerIsLoopback: false, requireToken: true, authorization: nil, token: token))
    #expect(!AgentAuth.isAuthorized(peerIsLoopback: false, requireToken: true, authorization: "Bearer abc12", token: token))
    #expect(!AgentAuth.isAuthorized(peerIsLoopback: false, requireToken: true, authorization: "Bearer abc1234", token: token))
    #expect(!AgentAuth.isAuthorized(peerIsLoopback: false, requireToken: true, authorization: "Basic abc123", token: token))
    #expect(!AgentAuth.isAuthorized(peerIsLoopback: false, requireToken: true, authorization: "Bearer ", token: ""))
    #expect(!AgentAuth.isAuthorized(peerIsLoopback: false, requireToken: true, authorization: "Bearer abc123", token: nil))
    #expect(AgentAuth.isAuthorized(peerIsLoopback: false, requireToken: true, authorization: "bearer  abc123 ", token: token))
    #expect(AgentAuth.isAuthorized(peerIsLoopback: false, requireToken: false, authorization: nil, token: nil))
  }

  @Test func constantTimeCompare() {
    #expect(AgentAuth.constantTimeEquals("", ""))
    #expect(AgentAuth.constantTimeEquals("same", "same"))
    #expect(!AgentAuth.constantTimeEquals("same", "Same"))
    #expect(!AgentAuth.constantTimeEquals("same", "sam"))
    #expect(!AgentAuth.constantTimeEquals("", "a"))
  }

  @Test func tokens() {
    let token = AgentAuth.makeToken()
    #expect(token.count == 43, "32 bytes in base64url without padding")
    #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    #expect(token != AgentAuth.makeToken())

    let store = AgentTokenStore(secrets: MemorySecretStore())
    #expect(store.load() == nil)
    let made = store.ensure()
    #expect(store.load() == made && store.ensure() == made, "made once, then kept")
    let new = store.regenerate()
    #expect(new != made && store.load() == new)
  }

  @Test func hostAndOrigin() {
    #expect(AgentAuth.isLoopback(host: "127.0.0.1:7862"))
    #expect(AgentAuth.isLoopback(host: "localhost"))
    #expect(AgentAuth.isLoopback(host: "[::1]:7862"))
    #expect(!AgentAuth.isLoopback(host: "evil.example:7862"))
    #expect(!AgentAuth.isLoopback(host: nil))
    #expect(AgentAuth.isLoopback(origin: "http://localhost:3000"))
    #expect(!AgentAuth.isLoopback(origin: "http://evil.example"))

    let own = AgentAuth.ownHosts(addresses: ["192.168.1.5", "fe80::1", "100.64.1.2"], hostName: "Studio.local")
    #expect(AgentAuth.allowsRemote(origin: nil, ownHosts: own, port: 7862), "clients that aren't browsers")
    #expect(AgentAuth.allowsRemote(origin: "http://192.168.1.5:7862", ownHosts: own, port: 7862))
    #expect(AgentAuth.allowsRemote(origin: "http://studio.local:7862", ownHosts: own, port: 7862))
    #expect(AgentAuth.allowsRemote(origin: "http://[fe80::1]:7862", ownHosts: own, port: 7862))
    #expect(AgentAuth.allowsRemote(origin: "http://127.0.0.1:7862", ownHosts: own, port: 7862))
    #expect(!AgentAuth.allowsRemote(origin: "https://example.com", ownHosts: own, port: 7862))
    #expect(!AgentAuth.allowsRemote(origin: "http://192.168.1.6", ownHosts: own, port: 7862))
    #expect(!AgentAuth.allowsRemote(origin: "null", ownHosts: own, port: 7862))
    #expect(!AgentAuth.ownHosts(addresses: [], hostName: "vimeswifi.home").contains("vimeswifi.home"))
    // Another web server on this Mac is another site: the page must be on the server's port.
    #expect(!AgentAuth.allowsRemote(origin: "http://192.168.1.5:8080", ownHosts: own, port: 7862))
    #expect(!AgentAuth.allowsRemote(origin: "http://192.168.1.5", ownHosts: own, port: 7862), "http's default port is 80")
    #expect(AgentAuth.allowsRemote(origin: "http://192.168.1.5", ownHosts: own, port: 80))
    #expect(AgentAuth.allowsRemote(origin: "https://studio.local", ownHosts: own, port: 443))
    #expect(!AgentAuth.allowsRemote(origin: "http://127.0.0.1:3000", ownHosts: own, port: 7862))
  }

  @Test func pathGuard() {
    #expect(AgentPathGuard.refusal(for: ["save_to": "/tmp/x.png"], isRemote: false) == nil)
    #expect(AgentPathGuard.refusal(for: ["save_to": "/tmp/x.png"], isRemote: true) == AgentPathGuard.saveToMessage)
    #expect(AgentPathGuard.refusal(for: ["save_to": ""], isRemote: true) == nil)
    #expect(AgentPathGuard.refusal(for: ["audio": "~/a.wav"], isRemote: true) == AgentPathGuard.fileMessage)
    for key in ["lut_path", "profile_path", "save_profile_to"] {
      #expect(AgentPathGuard.refusal(for: [key: "/tmp/x"], isRemote: true)?.hasPrefix("File paths are only for agents on this Mac") == true, "\(key)")
      #expect(AgentPathGuard.refusal(for: [key: "/tmp/x"], isRemote: false) == nil, "\(key) from this Mac")
    }
    #expect(AgentPathGuard.refusal(for: ["prompt": "a cat"], isRemote: true) == nil)
    #expect(AgentPathGuard.allowsImageSource("data:image/png;base64,AAAA", isRemote: true))
    #expect(!AgentPathGuard.allowsImageSource("/Users/me/a.png", isRemote: true))
    #expect(AgentPathGuard.allowsImageSource("/Users/me/a.png", isRemote: false))
  }

  @Test func pathsRefusedThroughLoadImage() async {
    let remote = ToolContext(isRemote: true)
    await ToolContext.$current.withValue(remote) {
      #expect(throws: AgentTools.ToolError.self) { try AgentTools.loadImage("/nonexistent/a.png") }
      do {
        _ = try AgentTools.loadImage("/nonexistent/a.png")
      } catch {
        #expect(error.localizedDescription == AgentPathGuard.pathMessage)
      }
      // Seen by work a call starts too.
      let inner = await Task { ToolContext.current.isRemote }.value
      #expect(inner)
    }
    do {
      _ = try AgentTools.loadImage("/nonexistent/a.png")
    } catch {
      #expect(error.localizedDescription.hasPrefix("Couldn't read an image"))
    }
  }

  @Test func remoteJobResults() {
    let result: [String: Any] = [
      "content": [["type": "text", "text": "Saved to Atelier project “P” (step 3) and /Users/me/T/P 3-7.png.\nModel m."], ["type": "image", "data": "AA"]],
      "structuredContent": ["path": "/Users/me/T/P 3-7.png", "history_step": 3, "saved_profile": "/Users/me/a.grain.json"],
    ]
    let stripped = AgentPathGuard.strippingPaths(result)
    let structured = stripped["structuredContent"] as? [String: Any] ?? [:]
    #expect(structured["path"] == nil && structured["saved_profile"] == nil && structured["history_step"] as? Int == 3)
    let text = ((stripped["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    #expect(text == "Saved to Atelier project “P” (step 3).\nModel m.")
    #expect((stripped["content"] as? [[String: Any]])?.count == 2)
  }

  @Test func refusedBeforeTheBody() {
    let open = AgentAuth.Gate(networkOpen: true, requireToken: true, token: "TOK")
    let lan = RemoteIP("192.168.1.9")
    #expect(AgentAuth.earlyRefusal(peer: RemoteIP("127.0.0.1"), authorization: nil, gate: open) == nil)
    #expect(AgentAuth.earlyRefusal(peer: RemoteIP("127.0.0.1"), authorization: nil, gate: AgentAuth.Gate()) == nil, "this Mac, network closed")
    #expect(AgentAuth.earlyRefusal(peer: lan, authorization: nil, gate: open) == 401)
    #expect(AgentAuth.earlyRefusal(peer: lan, authorization: "Bearer nope", gate: open) == 401)
    #expect(AgentAuth.earlyRefusal(peer: lan, authorization: "Bearer TOK", gate: open) == nil)
    #expect(AgentAuth.earlyRefusal(peer: lan, authorization: nil, gate: AgentAuth.Gate(networkOpen: true, requireToken: false)) == nil)
    // Access went back to This Mac only after the old listener took the connection.
    #expect(AgentAuth.earlyRefusal(peer: lan, authorization: "Bearer TOK", gate: AgentAuth.Gate(networkOpen: false, requireToken: true, token: "TOK")) == 403)
    #expect(AgentAuth.earlyRefusal(peer: lan, authorization: nil, gate: AgentAuth.Gate(networkOpen: false, requireToken: false)) == 403)
    #expect(AgentAuth.earlyRefusal(peer: nil, authorization: nil, gate: open) == 401, "an unknown peer isn't this Mac")

    // The headers are there before the body is.
    let head = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer TOK\r\nContent-Length: 100000000\r\n\r\n{\"a\":".utf8)
    let headers = LoopbackHTTPServer.headers(in: head)
    #expect(headers?["authorization"] == "Bearer TOK" && headers?["content-length"] == "100000000")
    #expect(LoopbackHTTPServer.headers(in: Data("POST /mcp HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
  }

  @Test func redactsPaths() {
    let home = "/Users/someone"
    #expect(AgentPathGuard.redactingPaths("Couldn't read an image at /Users/someone/My Pictures/a b.png.", home: home) == "Couldn't read an image at ….")
    #expect(AgentPathGuard.redactingPaths("No audio file at ~/Music/x.wav", home: home) == "No audio file at …")
    #expect(AgentPathGuard.redactingPaths("Couldn't save the profile to /tmp/p.grain.json: disk full", home: home) == "Couldn't save the profile to …: disk full")
    #expect(AgentPathGuard.redactingPaths("Couldn't read “/Volumes/External 2TB/x.png”.", home: home) == "Couldn't read “…”.")
    #expect(AgentPathGuard.redactingPaths("a, /Users/someone/x, y", home: home) == "a, …, y")
    #expect(AgentPathGuard.redactingPaths("in /Users/someone/a, b/c.png", home: home).contains(home) == false)
    let untouched = "Step 3 of 8 at 1/2 size; see http://example.com/x and JIT Always/Always (Partial)."
    #expect(AgentPathGuard.redactingPaths(untouched, home: home) == untouched)
  }

  @Test func endpoints() {
    #expect(AgentAuth.endpoint(host: "192.168.1.5", port: 7862) == "http://192.168.1.5:7862/mcp")
    #expect(AgentAuth.endpoint(host: "fd7a:115c:a1e0::1", port: 7862) == "http://[fd7a:115c:a1e0::1]:7862/mcp")
  }

  @Test func clientSnippets() {
    let url = "http://192.168.1.5:7862/mcp"
    for client in AgentClient.allCases {
      #expect(!client.setup(url).contains("Authorization"), "\(client.title) without a token")
      #expect(client.setup(url, token: "TOK").contains("Bearer TOK"), "\(client.title) with a token")
      #expect(client.setup(url, token: "TOK").contains(url))
    }
    #expect(AgentClient.claudeCode.setup(url, token: "TOK") == "claude mcp add --transport http atelier \(url) --header \"Authorization: Bearer TOK\"")
    #expect(AgentClient.gemini.setup(url, token: "TOK") == "gemini mcp add --transport http --header \"Authorization: Bearer TOK\" atelier \(url)")
    #expect(AgentClient.codex.setup(url) == "codex mcp add atelier --url \(url)")
    #expect(AgentClient.codex.setup(url, token: "TOK").hasPrefix("[mcp_servers.atelier]"))
    let vsCode = AgentClient.vsCode.setup(url, token: "TOK")
    let json = vsCode.dropFirst("code --add-mcp '".count).dropLast()
    let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    #expect((parsed?["headers"] as? [String: String])?["Authorization"] == "Bearer TOK")
    let cursor = try? JSONSerialization.jsonObject(with: Data(AgentClient.cursor.setup(url, token: "TOK").utf8)) as? [String: Any]
    let entry = (cursor?["mcpServers"] as? [String: Any])?["atelier"] as? [String: Any]
    #expect((entry?["headers"] as? [String: String])?["Authorization"] == "Bearer TOK")
  }
}
