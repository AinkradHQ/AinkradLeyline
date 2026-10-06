import AinkradAppKit
import Foundation
import Testing

@testable import LeylineFeature

@Suite(
    "Leyline MCP — no published tool can reach credential material",
    .timeLimit(.minutes(1)))
@MainActor
struct LeylineMCPCredentialLeakTests {

    /// **The single most important test in this change.**
    ///
    /// Seeds the store with a recognisable fake private key, passphrase and
    /// password, then drives EVERY published tool — through the real JSON-RPC
    /// server, not the sink directly — across success paths, failure paths and
    /// hostile arguments, and asserts the marker appears in no reply.
    ///
    /// A model that can read a private key can paste it into a chat transcript,
    /// and transcripts are persisted and shareable. So the assertion covers
    /// error text and unknown-id text too, not just success content: an error
    /// message that echoes what it found is the classic way a secret escapes a
    /// surface that "doesn't return secrets".
    ///
    /// This is a backstop. The primary guarantee is structural — see
    /// `LeylineCatalog`: `LeylineMCPOperations` holds no `LeylineStore`, so
    /// `privateKey(for:)` / `passphrase(for:)` / `password(for:)` are not in
    /// scope there and cannot be called at all. This test proves the property
    /// end-to-end so a future refactor that reintroduces the store fails here.
    @Test("no published tool's output ever contains seeded secret material")
    func noToolCanEmitSecretMaterial() async throws {
        let fixture = makeMCPFixture()
        let launcher = FakeLauncher()
        let (server, failures) = makeServer(store: fixture.store, launcher: launcher)
        #expect(failures.isEmpty)

        // Sanity: the secrets really ARE in the store this server was built
        // over. Without this the test could pass by testing nothing.
        #expect(fixture.store.privateKey(for: fixture.key) == secretValues[0])
        #expect(fixture.store.passphrase(for: fixture.key) == secretValues[1])
        #expect(fixture.store.password(for: fixture.passwordConn) == secretValues[2])

        // Every published tool, crossed with arguments that cover the happy
        // path, the not-found path, the malformed path, and an attempt to talk
        // the tool into echoing a secret back.
        var calls: [(String, [String: Any])] = [
            ("list_connections", [:]),
            ("list_connections", ["query": "prod"]),
            ("list_connections", ["query": secretMarker]),
            ("list_connections", ["query": 42]),
            ("list_keys", [:]),
            ("list_keys", ["query": secretMarker]),
            ("connect", ["connection": fixture.keyConn.id.uuidString]),
            ("connect", ["connection": fixture.passwordConn.id.uuidString]),
            ("connect", ["connection": "not-a-real-id"]),
            ("connect", ["connection": secretMarker]),
            ("connect", [:]),
            ("connect", ["connection": ""]),
        ]
        // …and the same set again with every launch failure the host can
        // report, because those take different text paths.
        for outcome in [
            PluginLaunchOutcome.unknownApp("rune"),
            .disabled("rune"),
            .refused(reason: "bad payload"),
        ] {
            launcher.outcome = outcome
            for (name, arguments) in calls where name == "connect" {
                let reply = try await call(server, name, arguments)
                expectNoSecret(in: reply.text, tool: name, arguments: arguments)
            }
        }
        launcher.outcome = .opened
        calls.append(("list_connections", ["query": ""]))

        for (name, arguments) in calls {
            let reply = try await call(server, name, arguments)
            expectNoSecret(in: reply.text, tool: name, arguments: arguments)
        }

        // The tool DESCRIPTIONS and schemas go into the model's context too, so
        // they are part of the surface and get the same assertion.
        for tool in await listedTools(server) {
            let encoded = (try? JSONSerialization.data(withJSONObject: tool)) ?? Data()
            expectNoSecret(
                in: String(decoding: encoded, as: UTF8.self),
                tool: "tools/list", arguments: [:])
        }

        // The payload handed to Rune is a channel the model never sees, and
        // it now legitimately carries a materialized identity path — but it must
        // still carry no key MATERIAL.
        for opened in launcher.opened {
            expectNoSecret(in: opened.payload ?? "", tool: "launch payload", arguments: [:])
        }

        // …and the path itself must not reach the model. It names a plaintext
        // copy of the private key, so a model that learns it can read the key
        // with any file-reading tool it has. Collect the paths actually produced
        // and assert no tool reply, error or tool description contains one.
        let paths = Set(launcher.opened.compactMap { SSHLaunchPayload(json: $0.payload)?.identityFile })
        #expect(!paths.isEmpty, "the key connection should have produced an identity path")
        var surface: [String] = []
        for (name, arguments) in calls { surface.append(try await call(server, name, arguments).text) }
        for tool in await listedTools(server) {
            surface.append(
                String(
                    decoding: (try? JSONSerialization.data(withJSONObject: tool)) ?? Data(),
                    as: UTF8.self))
        }
        for text in surface {
            for path in paths {
                #expect(!text.contains(path), "a materialized key path reached tool output: \(text)")
            }
            #expect(!text.contains("Application Support"))
            #expect(!text.contains("Leyline/keys"))
        }
    }

    /// The published surface must not even NAME the credential-taking APIs, so
    /// a model cannot be coached into asking for one.
    @Test("no tool that takes or returns credential material is published")
    func credentialToolsAreNotPublished() async throws {
        let names = Set(LeylineMCPServer.tools.map(\.name))
        #expect(names == ["list_connections", "list_keys", "connect"])
        // Named explicitly rather than by pattern: these are the exact
        // `LeylineStore` entry points that read or write secret material.
        for forbidden in [
            "import_key", "set_password", "read_key", "get_password",
            "get_private_key", "add_connection", "update_connection",
            "remove_connection", "remove_key",
        ] {
            #expect(!names.contains(forbidden), "\(forbidden) must not be published")
        }
    }

    /// **The security property of the host-side bridge.**
    ///
    /// `leyline.resolve_connection` answers with `identityPath` — a filesystem
    /// path to a plaintext private key. It exists for the host's `SSHBackend`,
    /// which only host code invokes through `AgentActionRegistryHub`. If it ever
    /// became an MCP tool, a model could ask for that path and then read the key
    /// with any file-reading tool it has. Pin both halves: it is not in the
    /// published table, and the MCP sink has no operation that reaches it.
    @Test("resolve_connection is host-only and is not published as an MCP tool")
    func resolveConnectionIsNotAnMCPTool() async throws {
        let fixture = makeMCPFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        let published = Set(await listedTools(server).compactMap { $0["name"] as? String })
        #expect(published == ["list_connections", "list_keys", "connect"])
        for forbidden in [
            "resolve_connection", "leyline.resolve_connection",
            "resolveConnection", "connection_info",
        ] {
            #expect(!published.contains(forbidden), "\(forbidden) must not be published")
            #expect(!Set(LeylineMCPServer.tools.map(\.operation)).contains(forbidden))
            // Even naming the operation directly at the sink must not reach it.
            let operations = LeylineMCPOperations(
                catalog: LeylineCatalog(store: fixture.store, launcher: FakeLauncher()))
            let payload = #"{"operation":"\#(forbidden)","connection":"\#(fixture.keyConn.id.uuidString)"}"#
            let reply = await operations.run(payload)
            #expect(reply.isError)
            #expect(reply.text.contains("unknown operation"))
        }
    }

    /// The Keychain-lookup ids are not secrets, but publishing them is free
    /// reconnaissance with no benefit to the model.
    @Test("list output never includes Keychain secret ids or a materialized key path")
    func listOutputHasNoSecretIdentifiers() async throws {
        let fixture = makeMCPFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        let connections = try await call(server, "list_connections", [:]).text
        let keys = try await call(server, "list_keys", [:]).text
        for text in [connections, keys] {
            #expect(!text.contains(".password"))
            #expect(!text.contains(".private"))
            #expect(!text.contains(".passphrase"))
            #expect(!text.contains("Application Support"))
            #expect(!text.contains("Leyline/keys"))
        }
        // `hasPassphrase` is a property OF the secret and is deliberately not
        // reported; assert `list_keys` really is id + label only.
        #expect(keys == "\(fixture.key.id.uuidString)  Prod deploy key")
    }

    private func expectNoSecret(
        in text: String, tool: String, arguments: [String: Any],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            !text.contains(secretMarker),
            "\(tool)\(arguments) leaked secret material: \(text)",
            sourceLocation: sourceLocation)
        for value in secretValues {
            #expect(
                !text.contains(value),
                "\(tool)\(arguments) leaked secret material: \(text)",
                sourceLocation: sourceLocation)
        }
        #expect(
            !text.contains("BEGIN OPENSSH PRIVATE KEY"),
            "\(tool)\(arguments) leaked a private key: \(text)",
            sourceLocation: sourceLocation)
    }
}
