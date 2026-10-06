import Foundation

/// A saved SSH host. Secrets (the password) are NOT stored here; they live in
/// the Keychain under `passwordSecretID`. Key-auth connections reference a
/// `LeylineKey` by `keyID` instead of carrying key material.
struct LeylineConnection: Codable, Equatable, Identifiable {
    enum AuthMode: String, Codable { case password, key }

    let id: UUID
    var label: String
    var host: String
    var port: Int
    var username: String
    var authMode: AuthMode
    var keyID: UUID?
    var createdAt: Date

    /// Keychain id for this connection's password (password auth only).
    var passwordSecretID: String { "conn.\(id.uuidString).password" }

    init(
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
