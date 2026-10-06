import Foundation
import Testing

@testable import LeylineFeature

/// The connection editor's Save, which lives on the store so it is testable
/// without SwiftUI.
@MainActor
@Suite("Connection editor save")
struct ConnectionEditorSaveTests {
    @Test("a new password connection keeps its password and drops a stray key")
    func newPasswordConnection() {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let c = store.saveConnection(
            existing: nil, label: "l", host: "h", port: 2222, username: "u", authMode: .password,
            keyID: UUID(), password: "pw")
        #expect(store.connections == [c])
        #expect(c.keyID == nil)
        #expect(c.port == 2222)
        #expect(store.password(for: c) == "pw")
    }

    @Test("a new key connection keeps its key and stores no password")
    func newKeyConnection() {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let keyID = UUID()
        let c = store.saveConnection(
            existing: nil, label: "l", host: "h", port: 22, username: "u", authMode: .key, keyID: keyID,
            password: "pw")
        #expect(c.keyID == keyID)
        #expect(store.password(for: c) == nil)
    }

    @Test("editing keeps the id and replaces every field")
    func editReplacesFields() {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let original = store.saveConnection(
            existing: nil, label: "l", host: "h", port: 22, username: "u", authMode: .password, keyID: nil,
            password: "pw")
        let edited = store.saveConnection(
            existing: original, label: "L2", host: "h2", port: 2200, username: "u2", authMode: .password,
            keyID: nil, password: "pw2")
        #expect(edited.id == original.id)
        #expect(store.connections == [edited])
        #expect(edited.label == "L2" && edited.host == "h2" && edited.port == 2200 && edited.username == "u2")
        #expect(store.password(for: edited) == "pw2")
    }

    @Test("switching an edited connection to key auth clears its password")
    func switchToKeyClearsPassword() {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let original = store.saveConnection(
            existing: nil, label: "l", host: "h", port: 22, username: "u", authMode: .password, keyID: nil,
            password: "pw")
        let keyID = UUID()
        let edited = store.saveConnection(
            existing: original, label: "l", host: "h", port: 22, username: "u", authMode: .key, keyID: keyID,
            password: "pw")
        #expect(edited.authMode == .key)
        #expect(edited.keyID == keyID)
        #expect(store.password(for: edited) == nil)
    }

    @Test("switching an edited connection to password auth drops its key")
    func switchToPasswordDropsKey() {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let original = store.saveConnection(
            existing: nil, label: "l", host: "h", port: 22, username: "u", authMode: .key, keyID: UUID(),
            password: nil)
        let edited = store.saveConnection(
            existing: original, label: "l", host: "h", port: 22, username: "u", authMode: .password,
            keyID: original.keyID, password: "")
        #expect(edited.keyID == nil)
        #expect(store.password(for: edited) == nil)
    }
}
