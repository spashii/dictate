import Foundation
import Security
import VoiceCore

/// The activation record in the login Keychain as one generic password, so deleting that item
/// (`security delete-generic-password -s in.firstversion.dictate.activation`) resets Dictate
/// to a fresh install. Not synchronised: each Mac activates on its own.
final class KeychainActivationStore: ActivationStore {
    static let service = "in.firstversion.dictate.activation"
    /// Shown in Keychain Access as the item's name.
    private static let label = "Dictate activation"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "activation",
         kSecAttrSynchronizable as String: false]
    }

    func load() -> ActivationRecord {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
              let record = try? JSONDecoder().decode(ActivationRecord.self, from: data) else { return ActivationRecord() }
        return record
    }

    func save(_ record: ActivationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = Self.label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
