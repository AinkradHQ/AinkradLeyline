import AinkradAppKit
import Foundation
import Observation

/// Owns the connection + key lists and mediates their secrets. Metadata is
/// persisted as one document via `host.documents`; secrets go to `host.secrets`
/// (Keychain) only — never into the document JSON or logs.
@MainActor
@Observable
final class LeylineStore {
    private(set) var connections: [LeylineConnection]
    private(set) var keys: [LeylineKey]
    private let documents: PluginDocumentStore
    private let secrets: PluginSecretStore
    private var canSave = true
    /// Keys THIS instance wrote to the shared keys directory. Every host shares
    /// that directory, so teardown must purge only these, never the directory.
    private var materializedKeyIDs: Set<UUID> = []

    init(documents: PluginDocumentStore, secrets: PluginSecretStore) {
        self.documents = documents
        self.secrets = secrets
        let loaded = loadDocument(
            LeylineDocument.self, key: LeylineDocument.documentID, from: documents)
        self.connections = loaded.value?.connections ?? []
        self.keys = loaded.value?.keys ?? []
        self.canSave = loaded.canSave
    }

    // MARK: Keys

    @discardableResult
    func importKey(label: String, privateKey: String, passphrase: String?) -> LeylineKey {
        let hasPassphrase = !(passphrase ?? "").isEmpty
        let key = LeylineKey(id: UUID(), label: label, hasPassphrase: hasPassphrase, createdAt: Date())
        secrets.setSecret(privateKey, forKey: key.privateKeySecretID)
        if hasPassphrase { secrets.setSecret(passphrase, forKey: key.passphraseSecretID) }
        keys.append(key)
        persist()
        return key
    }

    /// Materializes `keyID` for `ssh` and remembers it for `purgeMaterializedKeys()`.
    func materialize(keyID: UUID, privateKey: String) throws -> String {
        let path = try SSHKeyMaterializer.materialize(keyID: keyID, privateKey: privateKey)
        materializedKeyIDs.insert(keyID)
        return path
    }

    /// Deletes the plaintext copies this instance wrote; other instances' files stay.
    func purgeMaterializedKeys() {
        for id in materializedKeyIDs { SSHKeyMaterializer.purge(keyID: id) }
        materializedKeyIDs.removeAll()
    }

    func privateKey(for key: LeylineKey) -> String? { secrets.secret(forKey: key.privateKeySecretID) }
    func passphrase(for key: LeylineKey) -> String? { secrets.secret(forKey: key.passphraseSecretID) }

    func removeKey(_ key: LeylineKey) {
        secrets.setSecret(nil, forKey: key.privateKeySecretID)
        secrets.setSecret(nil, forKey: key.passphraseSecretID)
        // Deleting a key from the vault must also delete the plaintext copy
        // `SSHKeyMaterializer` wrote to Application Support for `ssh` to read.
        // Previously "delete key" cleared the Keychain entry and left the
        // actual private key on disk indefinitely — the vault showed no key
        // while the key was still there.
        SSHKeyMaterializer.purge(keyID: key.id)
        materializedKeyIDs.remove(key.id)
        keys.removeAll { $0.id == key.id }
        for i in connections.indices where connections[i].keyID == key.id {
            connections[i].keyID = nil
        }
        persist()
    }

    // MARK: Connections

    @discardableResult
    func addConnection(
        label: String, host: String, port: Int, username: String,
        authMode: LeylineConnection.AuthMode, keyID: UUID?,
        password: String?
    ) -> LeylineConnection {
        let conn = LeylineConnection(
            id: UUID(), label: label, host: host, port: port,
            username: username, authMode: authMode, keyID: keyID, createdAt: Date())
        if authMode == .password, let password, !password.isEmpty {
            secrets.setSecret(password, forKey: conn.passwordSecretID)
        }
        connections.append(conn)
        persist()
        return conn
    }

    /// The connection editor's Save: adds a connection, or edits `existing`.
    /// A key is kept only for key auth and a password only for password auth,
    /// so switching an edited connection to key auth clears its stored password.
    @discardableResult
    func saveConnection(
        existing: LeylineConnection?, label: String, host: String, port: Int, username: String,
        authMode: LeylineConnection.AuthMode, keyID: UUID?, password: String?
    ) -> LeylineConnection {
        let keyID = authMode == .key ? keyID : nil
        let password = authMode == .password ? password : nil
        guard var conn = existing else {
            return addConnection(
                label: label, host: host, port: port, username: username, authMode: authMode, keyID: keyID,
                password: password)
        }
        conn.label = label
        conn.host = host
        conn.port = port
        conn.username = username
        conn.authMode = authMode
        conn.keyID = keyID
        updateConnection(conn)
        setPassword(password, for: conn)
        return conn
    }

    func updateConnection(_ conn: LeylineConnection) {
        guard let idx = connections.firstIndex(where: { $0.id == conn.id }) else { return }
        connections[idx] = conn
        persist()
    }

    func password(for conn: LeylineConnection) -> String? { secrets.secret(forKey: conn.passwordSecretID) }

    func setPassword(_ password: String?, for conn: LeylineConnection) {
        let value = (password?.isEmpty ?? true) ? nil : password
        secrets.setSecret(value, forKey: conn.passwordSecretID)
    }

    func removeConnection(_ conn: LeylineConnection) {
        secrets.setSecret(nil, forKey: conn.passwordSecretID)
        connections.removeAll { $0.id == conn.id }
        persist()
    }

    private func persist() {
        guard canSave else {
            Log.persistence.error("saving is off: the loaded document did not decode and could not be set aside")
            return
        }
        let doc = LeylineDocument(connections: connections, keys: keys)
        guard let data = try? JSONEncoder().encode(doc) else {
            Log.persistence.error("could not encode leyline document; not saving")
            return
        }
        documents.setData(data, forKey: LeylineDocument.documentID)
    }
}
