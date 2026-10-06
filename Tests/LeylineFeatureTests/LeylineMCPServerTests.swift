import AinkradAppKit
import Foundation
import Testing

@testable import LeylineFeature

@Suite("Leyline MCP server", .timeLimit(.minutes(1)))
@MainActor
struct LeylineMCPServerTests {

    @Test("the three tools carry the intended annotations")
    func annotations() async throws {
        let fixture = makeMCPFixture()
        let (server, failures) = makeServer(store: fixture.store, launcher: FakeLauncher())
        #expect(failures.isEmpty)
        let tools = Dictionary(
            uniqueKeysWithValues: await listedTools(server)
                .map { ($0["name"] as? String ?? "", $0) })
        #expect(tools.count == 3)

        for name in ["list_connections", "list_keys"] {
            #expect(annotation(try #require(tools[name]), "readOnlyHint"))
            #expect(!annotation(try #require(tools[name]), "destructiveHint"))
        }
        // The judgement call: connect is not irreversible locally, but it opens
        // an authenticated session to a REMOTE machine on the user's behalf.
        #expect(annotation(try #require(tools["connect"]), "destructiveHint"))
        #expect(!annotation(try #require(tools["connect"]), "readOnlyHint"))

        // `requiresLiveApp` is false everywhere — Leyline's store is headless,
        // and connect opens TERMINAL's window, not Leyline's. Setting it would
        // pop an unrelated Leyline window on every assistant connect.
        for tool in tools.values {
            #expect(!annotation(tool, "ainkrad/requiresLiveApp"))
        }
    }

    @Test("list_connections reports id, label, user, host and port")
    func listConnections() async throws {
        let fixture = makeMCPFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        let reply = try await call(server, "list_connections", [:])
        #expect(!reply.isError)
        #expect(reply.text.contains(fixture.keyConn.id.uuidString))
        #expect(reply.text.contains("Prod web"))
        #expect(reply.text.contains("deploy@web.example.com:2222"))
        #expect(reply.text.contains("key auth: Prod deploy key"))
        #expect(reply.text.contains("root@legacy.example.com:22"))
        #expect(reply.text.contains("password auth"))
    }

    @Test("list_connections filters with the app's own matcher")
    func listConnectionsFiltered() async throws {
        let fixture = makeMCPFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        let reply = try await call(server, "list_connections", ["query": "LEGACY"])
        #expect(reply.text.contains("Legacy box"))
        #expect(!reply.text.contains("Prod web"))
    }

    @Test("connect hands Rune a validated ssh payload for the right host")
    func connectOpensTerminal() async throws {
        let fixture = makeMCPFixture()
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let reply = try await call(server, "connect", ["connection": fixture.keyConn.id.uuidString])
        #expect(!reply.isError)
        #expect(launcher.opened.count == 1)
        #expect(launcher.opened[0].appID == "rune")
        let payload = SSHLaunchPayload(json: launcher.opened[0].payload)
        #expect(payload?.host == "web.example.com")
        #expect(payload?.port == 2222)
        #expect(payload?.username == "deploy")
        // THE regression: an agent-initiated connect used to send
        // `identityFile: nil`, so ssh never saw the stored key and the user got
        // Permission denied. It now materializes exactly as the button does.
        let identity = try #require(payload?.identityFile)
        #expect(identity.contains(fixture.key.id.uuidString))
        // …and the file it points at is only readable by its owner.
        let mode = (try FileManager.default.attributesOfItem(atPath: identity))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // The result says which credential is in play, and never where it lives.
        #expect(reply.text.contains("SSH key stored in Leyline"))
        #expect(!reply.text.contains(identity))
    }

    @Test("connect on a password connection says a prompt is coming")
    func connectPasswordConnection() async throws {
        let fixture = makeMCPFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        let reply = try await call(server, "connect", ["connection": fixture.passwordConn.id.uuidString])
        #expect(!reply.isError)
        #expect(reply.text.contains("prompt for the password"))
    }

    /// Revisits the earlier "id only" rule, in step with the host bridge. A
    /// label is addressable because the approval card the user reads shows the
    /// identifier verbatim; the ambiguity that motivated "id only" is answered
    /// by erroring on it (below), not by refusing every label.
    @Test("connect matches ids and unique labels case-insensitively, hosts never")
    func connectMatchesByIdOrUniqueLabel() async throws {
        let fixture = makeMCPFixture()
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let lowered = try await call(
            server, "connect",
            ["connection": fixture.keyConn.id.uuidString.lowercased()])
        #expect(!lowered.isError)
        let byLabel = try await call(server, "connect", ["connection": "PROD WEB"])
        #expect(!byLabel.isError)
        #expect(launcher.opened.count == 2)
        #expect(SSHLaunchPayload(json: launcher.opened[1].payload)?.host == "web.example.com")
        // A hostname stays unaddressable: it is not a user-chosen name, and two
        // connections to one host with different usernames are normal.
        let byHost = try await call(server, "connect", ["connection": "web.example.com"])
        #expect(byHost.isError)
        #expect(byHost.text.contains("list_connections"))
        #expect(launcher.opened.count == 2)
    }

    @Test("connect prefers an exact id over a connection LABELLED with that id")
    func connectIdBeatsLabel() async throws {
        let fixture = makeMCPFixture()
        let launcher = FakeLauncher()
        _ = fixture.store.addConnection(
            label: fixture.keyConn.id.uuidString,
            host: "decoy.example.com", port: 22, username: "root",
            authMode: .key, keyID: fixture.key.id, password: nil)
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let reply = try await call(server, "connect", ["connection": fixture.keyConn.id.uuidString])
        #expect(!reply.isError)
        #expect(SSHLaunchPayload(json: launcher.opened[0].payload)?.host == "web.example.com")
    }

    @Test("connect refuses an ambiguous label instead of guessing a machine")
    func connectAmbiguousLabel() async throws {
        let fixture = makeMCPFixture()
        let launcher = FakeLauncher()
        _ = fixture.store.addConnection(
            label: "Prod web", host: "web2.example.com", port: 22,
            username: "deploy", authMode: .key, keyID: fixture.key.id,
            password: nil)
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let reply = try await call(server, "connect", ["connection": "prod web"])
        #expect(reply.isError)
        #expect(reply.text.contains("2 saved connections share the label \"Prod web\""))
        #expect(reply.text.contains("pass the id"))
        // Nothing opened — ambiguity must never silently pick.
        #expect(launcher.opened.isEmpty)
    }
}
