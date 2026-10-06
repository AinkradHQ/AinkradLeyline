import AinkradAppKit
import Foundation
import Testing

@testable import LeylineFeature

/// A local mirror of the host's `SSHConnectionInfo`
/// (`Sources/Ainkrad/Core/AgentKit/Sandbox/SSHConnectionInfo.swift`). The point
/// of the bridge's contract is that the host side is a straight decode, so the
/// test decodes with the host's exact field names and nothing else.
private struct SSHConnectionInfo: Codable, Equatable {
    var host: String
    var user: String
    var port: Int?
    var identityPath: String?
    var remoteWorkingDir: String?
}

/// Builds a bridge over an in-memory store. **Never touches the user's real
/// Leyline store or Keychain**: `FakeDocs` is in-memory and `FakeSecrets` stands
/// in for the host's Keychain-backed store.
@MainActor
private func makeFixture() -> (
    bridge: LeylineConnectionBridge, store: LeylineStore,
    keyConn: LeylineConnection, passwordConn: LeylineConnection,
    key: LeylineKey, lockedConn: LeylineConnection,
    lockedKey: LeylineKey
) {
    let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
    let key = store.importKey(
        label: "Prod deploy key",
        privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n\(secretMarker)\n"
            + "-----END OPENSSH PRIVATE KEY-----",
        passphrase: nil)
    let keyConn = store.addConnection(
        label: "Prod web", host: "web.example.com", port: 2222,
        username: "deploy", authMode: .key, keyID: key.id,
        password: nil)
    let passwordConn = store.addConnection(
        label: "Legacy box", host: "legacy.example.com",
        port: 22, username: "root", authMode: .password,
        keyID: nil, password: "password-\(secretMarker)")
    // A passphrase-protected key: same headless dead end as a password, since
    // `BatchMode=yes` disables the passphrase prompt too.
    let lockedKey = store.importKey(
        label: "Locked key",
        privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n\(secretMarker)\n"
            + "-----END OPENSSH PRIVATE KEY-----",
        passphrase: "passphrase-\(secretMarker)")
    let lockedConn = store.addConnection(
        label: "Staging box", host: "staging.example.com",
        port: 22, username: "deploy", authMode: .key,
        keyID: lockedKey.id, password: nil)
    let bridge = LeylineConnectionBridge(
        connections: { store.connections },
        keys: { store.keys },
        identity: { SSHIdentityResolver.resolve($0, store: store) })
    return (bridge, store, keyConn, passwordConn, key, lockedConn, lockedKey)
}

@MainActor
private func resolve(_ bridge: LeylineConnectionBridge, _ id: String) throws -> AgentActionResult {
    let payload = try JSONSerialization.data(withJSONObject: ["connection": id])
    return bridge.resolve(String(decoding: payload, as: UTF8.self))
}

@Suite(
    "leyline.resolve_connection — the host-side connection bridge",
    .timeLimit(.minutes(1)))
@MainActor
struct LeylineConnectionBridgeTests {

    @Test("a key-backed connection resolves to decodable SSHConnectionInfo")
    func keyBackedConnectionResolves() throws {
        let fixture = makeFixture()
        let reply = try resolve(fixture.bridge, fixture.keyConn.id.uuidString)
        #expect(!reply.isError)

        let info = try JSONDecoder().decode(SSHConnectionInfo.self, from: Data(reply.text.utf8))
        #expect(info.host == "web.example.com")
        #expect(info.user == "deploy")
        #expect(info.port == 2222)
        // Leyline stores no remote working directory; the field is optional and
        // absent, which must decode rather than fail.
        #expect(info.remoteWorkingDir == nil)

        // The identity is a real, owner-only file — otherwise `ssh` refuses it
        // ("UNPROTECTED PRIVATE KEY FILE") and the headless run fails.
        let path = try #require(info.identityPath)
        #expect(FileManager.default.fileExists(atPath: path))
        let mode = (try FileManager.default.attributesOfItem(atPath: path))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // The response references the key; it never carries it.
        #expect(!reply.text.contains(secretMarker))
    }

    /// The constraint this change surfaces rather than papers over: the host's
    /// `SSHArgsBuilder` bakes in `BatchMode=yes`, so no prompt can ever be
    /// answered. Handing back a password connection would fail later as an
    /// opaque `Permission denied`.
    @Test("a password-only connection is refused, naming the BatchMode limitation")
    func passwordOnlyConnectionIsRefused() throws {
        let fixture = makeFixture()
        let reply = try resolve(fixture.bridge, fixture.passwordConn.id.uuidString)
        #expect(reply.isError)
        #expect(reply.text.contains("BatchMode=yes"))
        #expect(reply.text.contains("password"))
        // Actionable, not just a refusal: it says what to do instead.
        #expect(reply.text.contains("Leyline app"))
        #expect(reply.text.contains("connect"))
        #expect(reply.text.contains("Legacy box"))
        // And it is a refusal, not a connection that will fail later.
        #expect(!reply.text.contains("identityPath"))
        #expect(!reply.text.contains(secretMarker))
    }

    /// The same dead end as a password, one layer down: `BatchMode=yes` also
    /// disables the "Enter passphrase for key" prompt, so a locked key cannot
    /// be unlocked in a headless run. Without this it resolved happily and the
    /// user saw a `ConnectTimeout` ten seconds later with no cause named.
    @Test("a passphrase-protected key is refused, naming the BatchMode limitation")
    func passphraseProtectedKeyIsRefused() throws {
        let fixture = makeFixture()
        let reply = try resolve(fixture.bridge, fixture.lockedConn.id.uuidString)
        #expect(reply.isError)
        #expect(reply.text.contains("BatchMode=yes"))
        #expect(reply.text.contains("passphrase"))
        // Actionable: it names the key and says what to do instead.
        #expect(reply.text.contains("Locked key"))
        #expect(reply.text.contains("Staging box"))
        #expect(reply.text.contains("connect"))
        // A refusal, not a connection that will time out later.
        #expect(!reply.text.contains("identityPath"))
        // And the passphrase itself never crosses the boundary — only the bool.
        #expect(!reply.text.contains(secretMarker))
    }

    /// The counterpart: the refusal is scoped to *locked* keys. A bare key is
    /// exactly what headless execution wants and must keep resolving.
    @Test("a bare (unprotected) key still resolves")
    func bareKeyStillResolves() throws {
        let fixture = makeFixture()
        let reply = try resolve(fixture.bridge, fixture.keyConn.id.uuidString)
        #expect(!reply.isError)
        let info = try JSONDecoder().decode(SSHConnectionInfo.self, from: Data(reply.text.utf8))
        #expect(info.host == "web.example.com")
        #expect(info.identityPath != nil)
    }

    @Test("an unknown id is a clear error and resolves nothing")
    func unknownID() throws {
        let fixture = makeFixture()
        let reply = try resolve(fixture.bridge, UUID().uuidString)
        #expect(reply.isError)
        #expect(reply.text.contains("no saved connection has that id"))
        #expect(!reply.text.contains("identityPath"))
    }

    @Test("malformed, missing and empty input are refused by name")
    func malformedInput() throws {
        let fixture = makeFixture()
        #expect(fixture.bridge.resolve("not json").isError)
        #expect(fixture.bridge.resolve("{}").isError)
        #expect(fixture.bridge.resolve("{}").text.contains("\"connection\""))
        #expect(try resolve(fixture.bridge, "   ").isError)
        // The caller's own text is never reflected back — this reply can reach
        // the host's logs, and a credential pasted into the wrong field must not
        // ride along.
        let reply = try resolve(fixture.bridge, secretMarker)
        #expect(reply.isError)
        #expect(!reply.text.contains(secretMarker))
    }

    @Test("a key-auth connection whose key is gone is refused, not silently downgraded")
    func keyRemovedFromVault() throws {
        let fixture = makeFixture()
        fixture.store.removeKey(fixture.key)
        let reply = try resolve(fixture.bridge, fixture.keyConn.id.uuidString)
        #expect(reply.isError)
        #expect(reply.text.contains("no key selected") || reply.text.contains("no longer in Leyline's vault"))
    }

    /// Revisits the earlier "id only" rule. Labels ARE addressable now — the
    /// host's approval card prints this identifier verbatim, and a UUID there
    /// defeats the gate — but the ambiguity that motivated the old rule is
    /// answered by erroring rather than by refusing labels outright. Hosts are
    /// still not addressable.
    @Test("ids and unique labels match case-insensitively; hosts never do")
    func matchesByIDOrUniqueLabel() throws {
        let fixture = makeFixture()
        #expect(try !resolve(fixture.bridge, fixture.keyConn.id.uuidString.lowercased()).isError)
        #expect(try !resolve(fixture.bridge, "Prod web").isError)
        #expect(try !resolve(fixture.bridge, "PROD WEB").isError)
        // A hostname is not a user-chosen name, and two connections to one host
        // with different usernames are normal.
        #expect(try resolve(fixture.bridge, "web.example.com").isError)
    }

    @Test("an exact id wins even when another connection is LABELLED with that id")
    func idBeatsLabel() throws {
        let fixture = makeFixture()
        // A label that mimics another connection's id: user-typed text must
        // never outrank Leyline's own unforgeable name for a connection.
        _ = fixture.store.addConnection(
            label: fixture.keyConn.id.uuidString,
            host: "decoy.example.com", port: 22, username: "root",
            authMode: .key, keyID: fixture.key.id, password: nil)
        let reply = try resolve(fixture.bridge, fixture.keyConn.id.uuidString)
        #expect(!reply.isError)
        let info = try JSONDecoder().decode(SSHConnectionInfo.self, from: Data(reply.text.utf8))
        #expect(info.host == "web.example.com")
    }

    @Test("an ambiguous label is refused, naming the ambiguity, and resolves nothing")
    func ambiguousLabelRefused() throws {
        let fixture = makeFixture()
        _ = fixture.store.addConnection(
            label: "Prod web", host: "web2.example.com", port: 22,
            username: "deploy", authMode: .key, keyID: fixture.key.id,
            password: nil)
        let reply = try resolve(fixture.bridge, "prod web")
        #expect(reply.isError)
        #expect(reply.text.contains("2 saved connections share the label \"Prod web\""))
        #expect(reply.text.contains("pass the id"))
        // Refused, not silently narrowed to one of them.
        #expect(!reply.text.contains("web.example.com"))
    }

    @Test("an identifier matching no id and no label is a clear error")
    func unknownIdentifier() throws {
        let reply = try resolve(makeFixture().bridge, "no-such-machine")
        #expect(reply.isError)
        #expect(reply.text.contains("no saved connection has that id or label"))
    }

    /// The bridge's identity is a namespaced action id, in the style of
    /// `terminal.echo` and `gitmage.git_op` — never an MCP tool name.
    @Test("the action id is namespaced to Leyline")
    func actionIDIsNamespaced() throws {
        #expect(LeylineConnectionBridge.actionID == "leyline.resolve_connection")
        #expect(!LeylineMCPServer.tools.map(\.name).contains(LeylineConnectionBridge.actionID))
    }
}
