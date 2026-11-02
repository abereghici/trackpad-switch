import Foundation
import Security
import TrackpadSwitchCore

struct KeychainStore: SecretStore {
  private let service = Bundle.main.bundleIdentifier ?? "trackpadswitch"
  private let account = "link-secret"

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  func loadLinkSecret() -> Data? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return data
  }

  func saveLinkSecret(_ secret: Data) -> Bool {
    let values: [String: Any] = [kSecValueData as String: secret]
    switch SecItemUpdate(query as CFDictionary, values as CFDictionary) {
    case errSecSuccess:
      return true
    case errSecItemNotFound:
      return SecItemAdd(query.merging(values) { $1 } as CFDictionary, nil) == errSecSuccess
    default:
      return false
    }
  }

  func deleteLinkSecret() {
    SecItemDelete(query as CFDictionary)
  }
}
