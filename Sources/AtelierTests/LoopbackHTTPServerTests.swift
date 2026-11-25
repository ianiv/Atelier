@testable import Atelier
import Foundation
import Synchronization
import Testing

/// How the MCP endpoint notices a client that's gone (`LoopbackHTTPServer.watchForClose`): a
/// half-close (FIN after the request) isn't a hang-up, so a slow call still gets its answer; a
/// client that closed the socket is noticed when a keep-alive write to it fails, which is what
/// cancels a 2026-07-28 call's wait (`AgentServer.callTool`'s `onClientClose`).
struct LoopbackHTTPServerTests {
  /// A server on a free loopback port (the bridge binding takes port 0) running `handler`.
  private static func start(_ handler: @escaping LoopbackHTTPServer.Handler) async throws -> (LoopbackHTTPServer, UInt16) {
    let server = LoopbackHTTPServer(port: 0, binding: .tailnetBridge, handler: handler)
    let failure = await withCheckedContinuation { continuation in
      let once = Mutex(false)
      server.start { failure in
        if once.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: failure) }
      }
    }
    #expect(failure == nil)
    return (server, try #require(server.boundPort))
  }

  /// A socket connected to the server that has sent one POST.
  private static func connectAndPost(port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    let request = Array("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
    _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    return fd
  }

  /// Reads until the server closes (or `until` appears), as text.
  private static func read(_ fd: Int32, until marker: String? = nil) -> String {
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      guard count > 0 else { break }
      reply.append(contentsOf: buffer[0..<count])
      if let marker, String(decoding: reply, as: UTF8.self).contains(marker) { break }
    }
    return String(decoding: reply, as: UTF8.self)
  }

  @Test func failedKeepAliveWriteReportsTheClientGone() async throws {
    let closed = Mutex(false)
    let (server, port) = try await Self.start { _, responder in
      responder.onClientClose { closed.withLock { $0 = true } }
      responder.startEvents()
      Task.detached {
        // A call that runs long, sending keep-alives as `callTool` does (every 15 s there).
        for _ in 0..<200 where !closed.withLock({ $0 }) {
          try? await Task.sleep(for: .milliseconds(25))
          responder.sendKeepAlive()
        }
      }
    }
    defer { server.stop() }
    let head = await Task.detached {
      let fd = Self.connectAndPost(port: port)
      let head = Self.read(fd, until: "\r\n\r\n")
      // An ordinary close: a FIN, which alone isn't taken as hanging up; the writes after it fail.
      Darwin.close(fd)
      return head
    }.value
    #expect(head.contains("200 OK") && head.contains("text/event-stream"))
    let deadline = ContinuousClock.now + .seconds(5)
    while !closed.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(closed.withLock { $0 }, "a keep-alive write to a closed socket fails and reports the client gone")
  }

  @Test func halfCloseIsNotHangingUp() async throws {
    let closed = Mutex(false)
    let (server, port) = try await Self.start { _, responder in
      responder.onClientClose { closed.withLock { $0 = true } }
      Task.detached {
        // Slow enough that the FIN has long arrived before the answer.
        try? await Task.sleep(for: .milliseconds(800))
        responder.send(status: 200, contentType: "application/json", body: Data(#"{"answer":true}"#.utf8))
      }
    }
    defer { server.stop() }
    let reply = await Task.detached {
      let fd = Self.connectAndPost(port: port)
      defer { Darwin.close(fd) }
      shutdown(fd, SHUT_WR)
      return Self.read(fd)
    }.value
    #expect(reply.contains("200 OK") && reply.contains(#"{"answer":true}"#), "the whole answer after a half-close")
    #expect(!closed.withLock { $0 }, "a FIN after the request isn't a hang-up")
  }
}
