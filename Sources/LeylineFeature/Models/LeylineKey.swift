import Foundation

/// An imported SSH private key. The key material and passphrase live in the
/// Keychain under the derived secret ids; only non-secret metadata is persisted.
struct LeylineKey: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    var hasPassphrase: Bool
    var createdAt: Date

    var privateKeySecretID: String { "key.\(id.uuidString).private" }
    var passphraseSecretID: String { "key.\(id.uuidString).passphrase" }

    init(id: UUID, label: String, hasPassphrase: Bool, createdAt: Date) {
        self.id = id
        self.label = label
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
    }
}
