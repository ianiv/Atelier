@testable import Atelier
import Testing

/// Which of Atelier's own servers may take a port, at the default ports (scripted checks only ever
/// use random ones).
@Suite(.tags(.smoke))
struct PortClaimsTests {
  /// MCP at 7862 and Compute at 7863, both on.
  private func defaults(https: PortClaims.HTTPSPort? = nil, mcp: Int = 7862, compute: Int = 7863) -> PortClaims {
    var claims = PortClaims()
    claims.claimMCP(isOn: true, port: mcp)
    claims.claimCompute(isOn: true, port: compute)
    claims.claimMCPHTTPS(isOn: https != nil, https, plainPort: mcp)
    return claims
  }

  @Test func automaticHTTPSSkipsAteliersPorts() {
    #expect(defaults().automaticHTTPSPort(for: 7862) == 7864, "two past the server's, past Compute's default")
    #expect(defaults(compute: 7864).automaticHTTPSPort(for: 7862) == 7865, "Compute moved onto it")
    #expect(defaults(mcp: 7861).automaticHTTPSPort(for: 7861) == 7864, "Compute's port skipped")
    var computeOff = defaults(compute: 7864)
    computeOff.claimCompute(isOn: false, port: 7864)
    #expect(computeOff.automaticHTTPSPort(for: 7862) == 7864, "Compute off: its port is free")
    #expect(PortClaims.automaticHTTPSPort(for: 65534, avoiding: []) == nil)
    let automatic = defaults(https: .automatic, compute: 7864)
    #expect(automatic.mcpHTTPS == 7865)
    #expect(defaults(https: .tailnet).mcpHTTPS == 443)
    #expect(defaults(https: .explicit(9443)).mcpHTTPS == 9443)
  }

  @Test func clashesAreRefused() {
    let claims = defaults(https: .explicit(9443))
    #expect(claims.conflict(port: 7863, for: .mcp) == "Port 7863 is Compute's (Settings ▸ Compute).")
    #expect(claims.conflict(port: 7862, for: .compute) == "Port 7862 is the MCP server's (Settings ▸ Agents).")
    #expect(
      claims.conflict(port: 9443, for: .compute) == "Port 9443 is the MCP server's HTTPS (Settings ▸ Agents ▸ Encryption).",
      "an explicit HTTPS port wins")
    #expect(claims.conflict(port: 7863, for: .mcpHTTPS) != nil)
    #expect(claims.conflict(port: 7862, for: .mcpHTTPS) != nil, "HTTPS can't take the server's own plain port")
    #expect(claims.conflict(port: 7863, for: .compute) == nil, "its own port")
    #expect(claims.conflict(port: 8000, for: .compute) == nil)
  }

  @Test func automaticHTTPSGivesWay() {
    let claims = defaults(https: .automatic)
    #expect(claims.mcpHTTPS == 7864)
    #expect(claims.conflict(port: 7864, for: .compute) == nil, "it moves instead")
    #expect(claims.conflict(port: 7864, for: .mcp) == nil)
  }

  @Test func tailnetHTTPSAndCompute() {
    #expect(defaults(https: .tailnet).conflict(port: 443, for: .compute) == "Port 443 is the MCP server's HTTPS (Settings ▸ Agents ▸ Encryption).")
    #expect(defaults(compute: 443).conflict(port: 443, for: .mcpHTTPS) == "Port 443 is Compute's (Settings ▸ Compute).")
  }

  @Test func offServersClaimNothing() {
    var claims = PortClaims()
    claims.claimMCP(isOn: false, port: 7862)
    claims.claimMCPHTTPS(isOn: false, .explicit(9443), plainPort: 7862)
    claims.claimCompute(isOn: false, port: 7863)
    #expect(claims == PortClaims())
    for (port, role) in [(7862, PortClaims.Role.compute), (9443, .compute), (7863, .mcp), (7863, .mcpHTTPS)] {
      #expect(claims.conflict(port: port, for: role) == nil)
    }
    claims.claimCompute(isOn: true, port: 0)
    #expect(claims.compute == nil, "a port not yet picked")
  }

  @Test func outOfRange() {
    let claims = PortClaims()
    for role in [PortClaims.Role.mcp, .mcpHTTPS, .compute] {
      #expect(claims.conflict(port: 0, for: role) == PortClaims.invalidMessage)
      #expect(claims.conflict(port: 65536, for: role) == PortClaims.invalidMessage)
      #expect(claims.conflict(port: 1, for: role) == nil)
      #expect(claims.conflict(port: 65535, for: role) == nil)
    }
  }
}
