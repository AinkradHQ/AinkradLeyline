import Foundation

/// An imported SSH private key. The key material and passphrase live in the
/// Keychain under the derived secret ids; only non-secret metadata is persisted.
public struct LeylineKey: Codable, Equatable, Identifiable {
    public let id: UUID
    public var label: String
    public var hasPassphrase: Bool
    public var createdAt: Date

    public var privateKeySecretID: String { "key.\(id.uuidString).private" }
    public var passphraseSecretID: String { "key.\(id.uuidString).passphrase" }

    public init(id: UUID, label: String, hasPassphrase: Bool, createdAt: Date) {
        self.id = id
        self.label = label
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
    }
}
