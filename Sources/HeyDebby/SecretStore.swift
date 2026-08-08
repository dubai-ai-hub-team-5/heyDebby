import Foundation
import Security

enum SecretKey: String, CaseIterable, Hashable, Sendable {
    case anthropic = "anthropic-api-key"
    case openAI = "openai-api-key"
    case gemini = "gemini-api-key"
    case assemblyAI = "assemblyai-api-key"
    case demoHandoff = "demo-handoff-token"

    /// Names used by the pre-Keychain settings implementation.
    var legacyUserDefaultsKey: String {
        switch self {
        case .anthropic: return "apiKey"
        case .openAI: return "openaiApiKey"
        case .gemini: return "geminiApiKey"
        case .assemblyAI: return "assemblyAIApiKey"
        case .demoHandoff: return "demoHandoffToken"
        }
    }

    var environmentVariableNames: [String] {
        switch self {
        case .anthropic: return ["ANTHROPIC_API_KEY"]
        case .openAI: return ["OPENAI_API_KEY"]
        case .gemini: return ["GOOGLE_API_KEY", "GEMINI_API_KEY"]
        case .assemblyAI: return ["ASSEMBLYAI_API_KEY"]
        case .demoHandoff: return ["DEBBY_DEMO_HANDOFF_TOKEN"]
        }
    }
}

protocol SecretStoring: AnyObject {
    func value(for key: SecretKey) throws -> String?
    func setValue(_ value: String, for key: SecretKey) throws
    func removeValue(for key: SecretKey) throws
}

enum SecretStoreError: Error, Equatable, LocalizedError {
    case keychain(operation: String, status: OSStatus)
    case invalidStoredValue(SecretKey)
    case verificationFailed(SecretKey)

    var errorDescription: String? {
        switch self {
        case .keychain(let operation, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain \(operation) failed (\(status)): \(detail ?? "unknown error")"
        case .invalidStoredValue(let key):
            return "The Keychain value for \(key.rawValue) is not valid UTF-8"
        case .verificationFailed(let key):
            return "Could not verify the Keychain write for \(key.rawValue)"
        }
    }
}

/// Security.framework-backed API-key storage. Values are local to this Mac and available only
/// while the user session is unlocked. No secret value is included in an error or log message.
final class SecretStore: SecretStoring, @unchecked Sendable {
    static let defaultService = "local.heydebby.clone.api-keys"
    static let shared = SecretStore()

    let service: String
    private let lock = NSRecursiveLock()

    init(service: String = defaultService) {
        precondition(!service.isEmpty, "Keychain service must not be empty")
        self.service = service
    }

    func value(for key: SecretKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(operation: "read", status: status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.invalidStoredValue(key)
        }
        return value
    }

    /// Upserts and then reads the value back. Returning successfully therefore means callers can
    /// safely remove a legacy copy; an unverified Security.framework status is never sufficient.
    func setValue(_ value: String, for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !value.isEmpty else {
            try removeValue(for: key)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(for: key)
        let updatedAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        var status = SecItemUpdate(query as CFDictionary, updatedAttributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            // Another writer may have inserted the same account between update and add.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, updatedAttributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(operation: "write", status: status)
        }
        guard try self.value(for: key) == value else {
            throw SecretStoreError.verificationFailed(key)
        }
    }

    func removeValue(for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }

        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(operation: "delete", status: status)
        }
        guard try value(for: key) == nil else {
            throw SecretStoreError.verificationFailed(key)
        }
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// Lock-protected drop-in seam for deterministic tests, previews, and migration dry runs.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String]

    init(values: [SecretKey: String] = [:]) {
        self.values = values
    }

    func value(for key: SecretKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func setValue(_ value: String, for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        if value.isEmpty {
            values.removeValue(forKey: key)
        } else {
            values[key] = value
        }
    }

    func removeValue(for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

protocol LegacySecretStoring: AnyObject {
    func value(forLegacyKey key: String) throws -> String?
    func removeValue(forLegacyKey key: String) throws
}

final class UserDefaultsLegacySecretStore: LegacySecretStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func value(forLegacyKey key: String) throws -> String? {
        defaults.string(forKey: key)
    }

    func removeValue(forLegacyKey key: String) throws {
        defaults.removeObject(forKey: key)
    }
}

final class InMemoryLegacySecretStore: LegacySecretStoring {
    private let lock = NSLock()
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func value(forLegacyKey key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func removeValue(forLegacyKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

struct LegacySecretMapping: Equatable, Sendable {
    let legacyKey: String
    let secretKey: SecretKey

    init(legacyKey: String, secretKey: SecretKey) {
        self.legacyKey = legacyKey
        self.secretKey = secretKey
    }
}

enum LegacySecretMigrationResult: Equatable, Sendable {
    case noLegacyValue
    case migrated
    case verifiedDuplicateRemoved
    /// A different destination value is never overwritten and the legacy value is retained.
    case conflict
}

enum LegacySecretMigration {
    static let userDefaultsMappings: [LegacySecretMapping] = SecretKey.allCases.map {
        LegacySecretMapping(legacyKey: $0.legacyUserDefaultsKey, secretKey: $0)
    }

    /// Writes, reads back, and only then removes the legacy value. If writing or verification
    /// throws, the removal line is never reached. A conflicting destination also leaves both
    /// values untouched so migration can be resolved without losing either secret.
    @discardableResult
    static func migrate(_ mapping: LegacySecretMapping,
                        from legacyStore: LegacySecretStoring,
                        to secretStore: SecretStoring) throws -> LegacySecretMigrationResult {
        guard let legacyValue = try legacyStore.value(forLegacyKey: mapping.legacyKey),
              !legacyValue.isEmpty else {
            return .noLegacyValue
        }

        let destinationValue = try secretStore.value(for: mapping.secretKey)
        if let destinationValue, !destinationValue.isEmpty, destinationValue != legacyValue {
            return .conflict
        }

        // Write even when an identical destination exists. This guarantees this migration run
        // has completed a verified write before it is permitted to remove the old storage.
        try secretStore.setValue(legacyValue, for: mapping.secretKey)
        guard try secretStore.value(for: mapping.secretKey) == legacyValue else {
            throw SecretStoreError.verificationFailed(mapping.secretKey)
        }

        try legacyStore.removeValue(forLegacyKey: mapping.legacyKey)
        return destinationValue == legacyValue ? .verifiedDuplicateRemoved : .migrated
    }

    static func migrateUserDefaults(
        _ legacyStore: LegacySecretStoring = UserDefaultsLegacySecretStore(),
        to secretStore: SecretStoring = SecretStore.shared
    ) throws -> [SecretKey: LegacySecretMigrationResult] {
        var results: [SecretKey: LegacySecretMigrationResult] = [:]
        for mapping in userDefaultsMappings {
            results[mapping.secretKey] = try migrate(
                mapping,
                from: legacyStore,
                to: secretStore
            )
        }
        return results
    }
}
