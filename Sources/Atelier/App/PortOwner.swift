#if os(macOS)
import Darwin
import Foundation

/// Who is listening on a TCP port, so "port in use" can name the app. Looks through every process's
/// sockets with libproc, as `lsof -iTCP -sTCP:LISTEN` does: `proc_listpids`, then each process's
/// descriptors (`PROC_PIDLISTFDS`) and each socket's details (`PROC_PIDFDSOCKETINFO`). Processes of
/// other users (system services) can't be looked into, so they're never found. That's a few
/// thousand system calls, so it's only done after a listener failed with EADDRINUSE, off the main
/// actor.
nonisolated enum PortOwner {
  struct Owner: Equatable, Sendable {
    var pid: pid_t
    /// The enclosing app's name, or the process's own.
    var name: String?
  }

  static func lookup(port: UInt16) -> Owner? {
    let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard size > 0 else { return nil }
    // Room for processes started between the two calls.
    var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 64)
    let listed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
    guard listed > 0 else { return nil }
    // This process first: the likeliest holder when it's one of Atelier's own servers.
    let own = getpid()
    let candidates = [own] + pids.prefix(Int(listed) / MemoryLayout<pid_t>.stride).filter { $0 > 0 && $0 != own }
    for pid in candidates where listens(pid: pid, port: port) {
      return Owner(pid: pid, name: name(of: pid))
    }
    return nil
  }

  /// Whether `pid` has a TCP socket listening on `port`, on any address.
  private static func listens(pid: pid_t, port: UInt16) -> Bool {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return false }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
    let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
    guard listed > 0 else { return false }
    for fd in fds.prefix(Int(listed) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var info = socket_fdinfo()
      let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
      guard read == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
      // The local port is kept in network byte order.
      if UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port { return true }
    }
    return false
  }

  /// The app the process belongs to (the outermost .app around its executable, so a helper is
  /// named after its app), or the process's own name.
  private static func name(of pid: pid_t) -> String? {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
      let components = URL(fileURLWithPath: String(cString: path)).pathComponents
      if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
        let app = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
        let info = Bundle(url: app)?.infoDictionary
        if let name = (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String, !name.isEmpty { return name }
        return app.deletingPathExtension().lastPathComponent
      }
    }
    var name = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
    let text = String(cString: name)
    return text.isEmpty ? nil : text
  }
}
#endif
