@testable import Atelier
import Darwin
import Network
import Testing

/// Finding who listens on a port, with a real listening socket in this process.
struct PortOwnerTests {
  @Test func findsThisProcess() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0)
    try #require(listen(fd, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    let port = UInt16(bigEndian: address.sin_port)
    let owner = PortOwner.lookup(port: port)
    #expect(owner?.pid == getpid())
    #expect(owner?.name?.isEmpty == false)
    #expect(ListenFailure.describe(.posix(.EADDRINUSE), port: Int(port)).message == "Another of Atelier's servers is using port \(port).")
  }

  @Test func unusedPort() throws {
    // A port just let go of is free.
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    close(fd)
    let port = UInt16(bigEndian: address.sin_port)
    #expect(PortOwner.lookup(port: port) == nil)
    #expect(ListenFailure.describe(.posix(.EADDRINUSE), port: Int(port)).message == "Another app or system service is using port \(port).")
  }

  @Test func permissionMessages() {
    #expect(ListenFailure.describe(.posix(.EACCES), port: 80) == ListenFailure("macOS didn't allow port 80.", isPortError: true))
    #expect(ListenFailure.describe(.posix(.EPERM), port: 80).isPortError)
    #expect(!ListenFailure.describe(.posix(.ENETDOWN), port: 80).isPortError)
  }
}
