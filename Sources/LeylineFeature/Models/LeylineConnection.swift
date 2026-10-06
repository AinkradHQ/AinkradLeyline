import Foundation

/// A saved SSH host. Secrets (the password) are NOT stored here; they live in
/// the Keychain under `passwordSecretID`. Key-auth connections reference a
/// `LeylineKey` by `keyID` instead of carrying key material.
public struct LeylineConnection: Codable, Equatable, Identifiable {
    public enum AuthMode: String, Codable { case password, key }

    public let id: UUID
    public var label: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMode: AuthMode
    public var keyID: UUID?
    public var createdAt: Date

    /// Keychain id for this connection's password (password auth only).
    public var passwordSecretID: String { "conn.\(id.uuidString).password" }

    public init(
        id: UUID, label: String, host: String, port: Int, username: String,
        authMode: AuthMode, keyID: UUID?, createdAt: Date
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.username = username
        self.authMode = authMode
        self.keyID = keyID
        self.createdAt = createdAt
    }
}
