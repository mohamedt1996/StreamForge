import Foundation
import Security

/// JSON file persistence in Application Support. Small, explicit, and identical on iOS and tvOS.
/// tvOS has no persistent Application Support guarantee, so it uses Caches there and syncs
/// small settings through UserDefaults.
enum FileStore {
    static var directory: URL = {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        let dir = base.appendingPathComponent("StreamForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else {
            // Small documents are mirrored to UserDefaults so tvOS survives cache purges.
            if let data = UserDefaults.standard.data(forKey: "store." + name) {
                return try? JSONDecoder().decode(T.self, from: data)
            }
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String, mirrorToDefaults: Bool = false) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
        if mirrorToDefaults, data.count < 400_000 {
            UserDefaults.standard.set(data, forKey: "store." + name)
        }
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
        UserDefaults.standard.removeObject(forKey: "store." + name)
    }
}

/// Credentials live in the Keychain, never in JSON files.
enum Keychain {
    private static let service = "com.mohamedt.streamforge"

    static func set(_ value: String?, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
