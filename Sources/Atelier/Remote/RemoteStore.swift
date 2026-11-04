import Foundation
import Security
import Synchronization

/// Where keys and the lists around them are kept. The Keychain in the app; memory in a scripted
/// check, which leaves the user's pairings alone.
nonisolated protocol RemoteSecretStore: Sendable {
  func load(_ account: String) -> Data?
  func save(_ data: Data?, account: String)
}

/// One generic password per list, holding it whole as JSON. Reads and writes one item, which stays
/// simple and works the same in the Mac's file Keychain and on iPad.
nonisolated struct KeychainSecretStore: RemoteSecretStore {
  var service = "Atelier Compute"

  private func query(_ account: String) -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
  }

  func load(_ account: String) -> Data? {
    var query = query(account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status != errSecSuccess, status != errSecItemNotFound {
      Log.remote.error("Keychain read failed: \(status, privacy: .public)")
    }
    return result as? Data
  }

  func save(_ data: Data?, account: String) {
    let item = query(account)
    guard let data else {
      SecItemDelete(item as CFDictionary)
      return
    }
    var status = SecItemUpdate(item as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecItemNotFound {
      var new = item
      new[kSecValueData] = data
      new[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(new as CFDictionary, nil)
    }
    if status != errSecSuccess { Log.remote.error("Keychain write failed: \(status, privacy: .public)") }
  }
}

final nonisolated class MemorySecretStore: RemoteSecretStore {
  private let items = Mutex<[String: Data]>([:])

  func load(_ account: String) -> Data? { items.withLock { $0[account] } }

  func save(_ data: Data?, account: String) { items.withLock { $0[account] = data } }
}

/// A device allowed to run jobs here.
nonisolated struct RemotePairedDevice: Codable, Hashable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var key: Data
  var pairedAt: Date
  var lastSeen: Date?
}

/// A server this device can run jobs on.
nonisolated struct RemoteServerRecord: Codable, Hashable, Identifiable, Sendable {
  var id: UUID
  var name: String
  /// In the order to try them.
  var addresses: [RemoteAddress]
  var key: Data
}

/// This device, as it introduces itself to servers.
nonisolated struct RemoteDeviceIdentity: Hashable, Sendable {
  private static let idKey = "remote.deviceID"
  private static let scriptedID = UUID()

  var id: UUID
  var name: String

  /// This device's id, made once. A scripted run gets one of its own, and saves nothing.
  static var current: RemoteDeviceIdentity {
    let id: UUID
    if !SessionState.isEnabled {
      id = scriptedID
    } else if let saved = UserDefaults.standard.string(forKey: idKey).flatMap(UUID.init(uuidString:)) {
      id = saved
    } else {
      id = UUID()
      UserDefaults.standard.set(id.uuidString, forKey: idKey)
    }
    return RemoteDeviceIdentity(id: id, name: RemoteNetworkInfo.deviceName)
  }
}

nonisolated extension RemoteSecretStore {
  func loadList<T: Codable>(_ account: String) -> [T] {
    guard let data = load(account) else { return [] }
    return (try? JSONDecoder().decode([T].self, from: data)) ?? []
  }

  func saveList(_ list: [some Codable], account: String) {
    save(try? JSONEncoder().encode(list), account: account)
  }
}

nonisolated enum RemotePaths {
  /// Where Compute keeps its files. A scripted run keeps them in a temporary folder.
  static let root: URL = SessionState.isEnabled
    ? URL.applicationSupportDirectory.appending(path: "Atelier/Compute", directoryHint: .isDirectory)
    : FileManager.default.temporaryDirectory.appending(path: "atelier-compute-\(UUID())", directoryHint: .isDirectory)

  /// Where pairings are kept. A scripted run leaves the user's alone.
  static var defaultStore: any RemoteSecretStore {
    SessionState.isEnabled ? KeychainSecretStore() : scriptedStore
  }

  private static let scriptedStore = MemorySecretStore()
}

nonisolated enum RemoteAccounts {
  static let pairedDevices = "pairedDevices"
  static let servers = "servers"
  static let serverID = "serverID"
}
