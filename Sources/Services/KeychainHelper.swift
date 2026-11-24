import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.projectnobel.app"
    private static let apiKeyAccounts = ["cloud_api_key", "vision_api_key"]
    
    static func get(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }
    
    static func set(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(account: account)
            return
        }
        guard let data = trimmed.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            _ = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
    
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
    
    static func migrateAPIKeysIfNeeded() {
        let legacyDefaults = UserDefaults(suiteName: "com.projectnobel.macOS-Native")
        for account in apiKeyAccounts {
            let existingKeychain = get(account: account)
            if existingKeychain.isEmpty {
                let stdVal = (UserDefaults.standard.string(forKey: account) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let legacyVal = (legacyDefaults?.string(forKey: account) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let migrated = !stdVal.isEmpty ? stdVal : legacyVal
                if !migrated.isEmpty {
                    set(migrated, account: account)
                }
            }
            if UserDefaults.standard.object(forKey: account) != nil {
                UserDefaults.standard.removeObject(forKey: account)
            }
        }
    }
}
