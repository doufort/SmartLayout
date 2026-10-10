import Foundation
import Security

/// Хранение API-ключа в Связке ключей macOS.
enum Keychain {
    private static let service = "SmartLayout"
    private static let account = "ai-api-key"

    /// Ключ читается из Связки один раз и дальше хранится в памяти,
    /// чтобы не обращаться к ней на каждое нажатие клавиши.
    private static var cached: String?

    static func load() -> String {
        if let cached { return cached }
        let value = loadFromKeychain()
        cached = value
        return value
    }

    private static func loadFromKeychain() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ value: String) {
        cached = value
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
