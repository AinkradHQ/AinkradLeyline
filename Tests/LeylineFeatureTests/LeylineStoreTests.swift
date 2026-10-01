import Testing
import Foundation
import AinkradAppKit
@testable import LeylineFeature

@Suite("LeylineStore")
@MainActor
struct LeylineStoreTests {
    @Test("empty store loads no connections or keys")
    func empty() {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        #expect(store.connections.isEmpty)
        #expect(store.keys.isEmpty)
    }

    @Test("adding a password connection persists metadata and reloads")
    func addPasswordConnectionPersists() {
        let docs = FakeDocs(); let secrets = FakeSecrets()
        let store = LeylineStore(documents: docs, secrets: secrets)
        let c = store.addConnection(label: "Prod", host: "10.0.0.1", port: 2222,
                                    username: "deploy", authMode: .password, keyID: nil, password: "hunter2")
        let reloaded = LeylineStore(documents: docs, secrets: secrets)
        #expect(reloaded.connections.count == 1)
        #expect(reloaded.connections.first?.host == "10.0.0.1")
        #expect(reloaded.connections.first?.port == 2222)
        #expect(reloaded.password(for: c) == "hunter2")
    }

    @Test("password is stored in secrets, never in the document JSON")
    func passwordNeverInJSON() {
        let docs = FakeDocs(); let secrets = FakeSecrets()
        let store = LeylineStore(documents: docs, secrets: secrets)
        _ = store.addConnection(label: "Prod", host: "h", port: 22,
                                username: "u", authMode: .password, keyID: nil, password: "s3cret")
        let json = String(data: docs.storage[LeylineDocument.documentID]!, encoding: .utf8)!
        #expect(!json.contains("s3cret"))
        #expect(secrets.storage.values.contains("s3cret"))
    }

    @Test("importing a key stores material + passphrase in secrets and records hasPassphrase")
    func importKey() {
        let docs = FakeDocs(); let secrets = FakeSecrets()
        let store = LeylineStore(documents: docs, secrets: secrets)
        let k = store.importKey(label: "id_ed25519", privateKey: "-----BEGIN-----", passphrase: "pp")
        #expect(k.hasPassphrase)
        #expect(store.privateKey(for: k) == "-----BEGIN-----")
        #expect(store.passphrase(for: k) == "pp")
        let json = String(data: docs.storage[LeylineDocument.documentID]!, encoding: .utf8)!
        #expect(!json.contains("BEGIN"))
    }

    @Test("removing a key clears its secrets and detaches referencing connections")
    func removeKeyDetaches() {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let k = store.importKey(label: "k", privateKey: "PK", passphrase: nil)
        let c = store.addConnection(label: "c", host: "h", port: 22,
                                    username: "u", authMode: .key, keyID: k.id, password: nil)
        store.removeKey(k)
        #expect(store.keys.isEmpty)
        #expect(store.privateKey(for: k) == nil)
        #expect(store.connections.first(where: { $0.id == c.id })?.keyID == nil)
    }

    @Test("removing a connection clears its password secret")
    func removeConnection() {
        let secrets = FakeSecrets()
        let store = LeylineStore(documents: FakeDocs(), secrets: secrets)
        let c = store.addConnection(label: "c", host: "h", port: 22,
                                    username: "u", authMode: .password, keyID: nil, password: "pw")
        store.removeConnection(c)
        #expect(store.connections.isEmpty)
        #expect(store.password(for: c) == nil)
    }

    @Test("corrupt document is set aside, not overwritten")
    func corruptDocumentIsSetAsideNotOverwritten() {
        let seed = Data("{not json".utf8)
        let docs = FakeDocs()
        docs.setData(seed, forKey: LeylineDocument.documentID)
        let store = LeylineStore(documents: docs, secrets: FakeSecrets())
        _ = store.addConnection(label: "c", host: "h", port: 22,
                                username: "u", authMode: .password, keyID: nil, password: "pw")
        let backups = docs.storage.keys.filter {
            $0.hasPrefix("\(LeylineDocument.documentID).corrupt-")
        }
        #expect(backups.count == 1, "corrupt bytes were not set aside")
        #expect(docs.storage[backups.first ?? ""] == seed, "backup does not hold the seed bytes")
    }

    @Test("unverifiable set-aside keeps the original and stops saving")
    func unverifiableSetAsideKeepsOriginalAndStopsSaving() {
        let seed = Data("{not json".utf8)
        let docs = RejectingCorruptDocs()
        docs.setData(seed, forKey: LeylineDocument.documentID)
        let store = LeylineStore(documents: docs, secrets: FakeSecrets())
        _ = store.addConnection(label: "c", host: "h", port: 22,
                                username: "u", authMode: .password, keyID: nil, password: "pw")
        #expect(
            docs.storage[LeylineDocument.documentID] == seed,
            "the only copy of the user's data was overwritten")
    }
}

/// In-memory document store whose `setData` ignores backup keys, simulating a
/// failed verification read-back after the set-aside write.
final class RejectingCorruptDocs: PluginDocumentStore {
    var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) {
        if key.contains(".corrupt-") { return }
        storage[key] = data
    }
}
