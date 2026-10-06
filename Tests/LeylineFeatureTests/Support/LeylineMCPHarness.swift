import AinkradAppKit
import Foundation
import Testing

@testable import LeylineFeature

/// Shared fixture and JSON-RPC helpers for the Leyline MCP suites.
/// A recognisable fake secret. Chosen so a substring search cannot produce a
/// false negative: it shares no prefix with any label, host or id in the
/// fixtures, and it is long enough that a truncated leak still matches.
let secretMarker = "AINKRAD-FAKE-SECRET-MATERIAL-DO-NOT-LEAK-8F2A"

/// Everything a leak could plausibly look like, including the shapes a real
/// private key/passphrase/password would take.
let secretValues: [String] = [
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
func makeMCPFixture() -> (
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
final class FakeLauncher: PluginAppLauncher, PluginAppLauncherResult {
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
func makeServer(store: LeylineStore, launcher: PluginAppLauncher)
    -> (MCPAppServer, [String])
{
    let operations = LeylineMCPOperations(
        catalog: LeylineCatalog(store: store, launcher: launcher))
    return LeylineMCPServer.make(appID: "leyline", perform: { await operations.run($0) })
}

@MainActor
func listedTools(_ server: MCPAppServer) async -> [[String: Any]] {
    let reply = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    guard let data = reply.data(using: .utf8),
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let result = root["result"] as? [String: Any],
        let tools = result["tools"] as? [[String: Any]]
    else { return [] }
    return tools
}

@MainActor
func call(
    _ server: MCPAppServer, _ name: String,
    _ arguments: [String: Any]
) async throws -> (text: String, isError: Bool) {
    let request: [String: Any] = [
        "jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": ["name": name, "arguments": arguments],
    ]
    let data = try JSONSerialization.data(withJSONObject: request)
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

func annotation(_ tool: [String: Any], _ key: String) -> Bool {
    (tool["annotations"] as? [String: Any])?[key] as? Bool ?? false
}
