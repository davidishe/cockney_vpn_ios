import Foundation
import Security

public final class ProfileSecretStore {
    private let service = "community.openlibre.olcrtc.profile"
    private let bundledSecretsAccount = "__profiles.secrets.v1"
    private let keyHexField = "keyHex"
    private let socksPassField = "socksPass"
    private let accessTokenField = "accessToken"
    private let carrierAuthTokenField = "carrierAuthToken"

    public init() {}

    public func loadSecrets(into profile: inout ConnectionProfile) {
        var secrets = readBundledSecrets()
        if secrets[profile.id] == nil {
            let legacySecrets = readSecretsIndividually(for: [profile.id])
            secrets.merge(legacySecrets) { current, legacy in
                current.merging(legacy) { existing, _ in existing }
            }
            saveBundledSecrets(secrets)
        }

        apply(secrets[profile.id], to: &profile)
    }

    public func loadSecrets(into profiles: inout [ConnectionProfile]) {
        var secrets = readBundledSecrets()
        let missingProfileIDs = profiles
            .map(\.id)
            .filter { secrets[$0] == nil }

        if !missingProfileIDs.isEmpty {
            var legacySecrets = readAllLegacySecrets()
            if legacySecrets.isEmpty {
                legacySecrets = readSecretsIndividually(for: missingProfileIDs)
            }

            if !legacySecrets.isEmpty {
                secrets.merge(legacySecrets) { current, legacy in
                    current.merging(legacy) { existing, _ in existing }
                }
                saveBundledSecrets(secrets)
            }
        }

        guard !secrets.isEmpty else {
            return
        }

        for index in profiles.indices {
            apply(secrets[profiles[index].id], to: &profiles[index])
        }
    }

    public func saveSecrets(from profile: ConnectionProfile) {
        saveSecrets(from: [profile])
    }

    public func saveSecrets(from profiles: [ConnectionProfile]) {
        var secrets = readBundledSecrets()
        var didChange = false

        for profile in profiles {
            let fields = secretFields(from: profile)
            guard !fields.isEmpty else {
                continue
            }

            secrets[profile.id, default: [:]].merge(fields) { _, new in new }
            didChange = true
        }

        guard didChange else {
            return
        }
        saveBundledSecrets(secrets)
    }

    public func deleteSecrets(profileID: UUID) {
        var secrets = readBundledSecrets()
        secrets.removeValue(forKey: profileID)
        saveBundledSecrets(secrets)

        delete(profileID: profileID, field: keyHexField)
        delete(profileID: profileID, field: socksPassField)
        delete(profileID: profileID, field: accessTokenField)
        delete(profileID: profileID, field: carrierAuthTokenField)
    }

    private func read(profileID: UUID, field: String) -> String? {
        var query = baseQuery(profileID: profileID, field: field)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func readBundledSecrets() -> [UUID: [String: String]] {
        guard let data = read(account: bundledSecretsAccount),
              let stored = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }

        var secrets: [UUID: [String: String]] = [:]
        for (idValue, fields) in stored {
            guard let profileID = UUID(uuidString: idValue) else {
                continue
            }
            secrets[profileID] = fields
        }
        return secrets
    }

    private func saveBundledSecrets(_ secrets: [UUID: [String: String]]) {
        let stored = Dictionary(uniqueKeysWithValues: secrets.map { id, fields in
            (id.uuidString, fields)
        })
        guard let data = try? JSONEncoder().encode(stored) else {
            return
        }
        save(data, account: bundledSecretsAccount)
    }

    private func readAllLegacySecrets() -> [UUID: [String: String]] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return [:]
        }

        let items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let item = result as? [String: Any] {
            items = [item]
        } else {
            return [:]
        }

        var secrets: [UUID: [String: String]] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let (profileID, field) = parseAccount(account),
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                continue
            }
            secrets[profileID, default: [:]][field] = value
        }
        return secrets
    }

    private func readSecretsIndividually(
        for profileIDs: [UUID]
    ) -> [UUID: [String: String]] {
        var secrets: [UUID: [String: String]] = [:]
        for profileID in profileIDs {
            if let keyHex = read(profileID: profileID, field: keyHexField) {
                secrets[profileID, default: [:]][keyHexField] = keyHex
            }
            if let socksPass = read(profileID: profileID, field: socksPassField) {
                secrets[profileID, default: [:]][socksPassField] = socksPass
            }
            if let accessToken = read(profileID: profileID, field: accessTokenField) {
                secrets[profileID, default: [:]][accessTokenField] = accessToken
            }
            if let carrierAuthToken = read(profileID: profileID, field: carrierAuthTokenField) {
                secrets[profileID, default: [:]][carrierAuthTokenField] = carrierAuthToken
            }
        }
        return secrets
    }

    private func apply(_ secrets: [String: String]?, to profile: inout ConnectionProfile) {
        guard let secrets else {
            return
        }
        profile.keyHex = secrets[keyHexField] ?? profile.keyHex
        profile.socksPass = secrets[socksPassField] ?? profile.socksPass
        profile.accessToken = secrets[accessTokenField] ?? profile.accessToken
        profile.carrierAuthToken = secrets[carrierAuthTokenField] ?? profile.carrierAuthToken
    }

    private func secretFields(from profile: ConnectionProfile) -> [String: String] {
        var fields: [String: String] = [:]
        if !profile.keyHex.isEmpty {
            fields[keyHexField] = profile.keyHex
        }
        if !profile.socksPass.isEmpty {
            fields[socksPassField] = profile.socksPass
        }
        if !profile.accessToken.isEmpty {
            fields[accessTokenField] = profile.accessToken
        }
        if !profile.carrierAuthToken.isEmpty {
            fields[carrierAuthTokenField] = profile.carrierAuthToken
        }
        return fields
    }

    private func save(_ value: String, profileID: UUID, field: String) {
        if value.isEmpty {
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(profileID: profileID, field: field)
        let update = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func read(account: String) -> Data? {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private func save(_ data: Data, account: String) {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = account
        let update = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private func delete(profileID: UUID, field: String) {
        SecItemDelete(baseQuery(profileID: profileID, field: field) as CFDictionary)
    }

    private func baseQuery(profileID: UUID, field: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = account(profileID: profileID, field: field)
        return query
    }

    private func serviceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    private func account(profileID: UUID, field: String) -> String {
        "\(profileID.uuidString).\(field)"
    }

    private func parseAccount(_ account: String) -> (UUID, String)? {
        guard let separatorIndex = account.lastIndex(of: ".") else {
            return nil
        }

        let idValue = String(account[..<separatorIndex])
        let field = String(account[account.index(after: separatorIndex)...])
        guard [keyHexField, socksPassField, accessTokenField, carrierAuthTokenField].contains(field),
              let profileID = UUID(uuidString: idValue) else {
            return nil
        }
        return (profileID, field)
    }
}
