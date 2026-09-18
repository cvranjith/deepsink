//
//  KeychainStore.swift
//  DeepSink
//

import Foundation
import Security

// Minimal Keychain wrapper for exactly one secret: the router bearer
// token. yt-run's own AppSettings keeps its token in plain UserDefaults
// (fine for that app's risk profile), but DeepSink's requirement doc
// (FR-7) calls for Keychain specifically — a leaked token here would let
// someone pull real meeting transcripts, not just trigger a YouTube
// summary.
enum KeychainStore {
    private static let service = "com.ranjith.DeepSink.router"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }
}
