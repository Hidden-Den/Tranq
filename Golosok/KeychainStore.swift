import Foundation
import Security

public enum KeychainStore {
    private static let serviceName = Bundle.main.bundleIdentifier ?? "com.nuter.Golosok"

    /// Сохранить значение в Keychain (или обновить существующее)
    public static func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus == errSecSuccess {
                return true
            }
            AppLogger.shared.warn("Keychain", "Ошибка обновления ключа: \(updateStatus)")
            return false
        } else if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return true
            }
            AppLogger.shared.warn("Keychain", "Ошибка добавления ключа: \(addStatus)")
            return false
        } else {
            AppLogger.shared.warn("Keychain", "Ошибка поиска ключа: \(status)")
            return false
        }
    }

    /// Прочитать значение из Keychain
    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// Удалить значение из Keychain
    public static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
