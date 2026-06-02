import Foundation
import Security

protocol KeychainStoring {
  @discardableResult
  static func save(_ data: Data, forKey key: String) -> Bool
  static func load(forKey key: String) -> Data?
  static func delete(forKey key: String)
  static func deleteAll()
}

enum KeychainHelper: KeychainStoring {
  private static let service = Bundle.main.bundleIdentifier ?? "com.birch"

  @discardableResult
  static func save(_ data: Data, forKey key: String) -> Bool {
    delete(forKey: key)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
  }

  static func load(forKey key: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
      return nil
    }
    return result as? Data
  }

  static func delete(forKey key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(query as CFDictionary)
  }

  static func deleteAll() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
