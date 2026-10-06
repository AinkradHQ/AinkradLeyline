import AinkradAppKit
import Foundation

/// Resolves a saved connection into everything the **host** needs to run a
/// command on that machine headlessly — host, user, port and the path of a
/// materialized private key.
///
/// ## This is host↔plugin plumbing, not a tool
///
/// The host has an `SSHBackend` in its `ExecutionRouter` that has been wired
/// with `connection: nil` since it was written, because "Leyline/AinkradSSH has
/// no host-side connection bridge". This is that bridge. Once it answers, the
/// assistant can run a command on a remote host through the host's own gating —
/// approvals, `CommandRisk`, streaming, timeouts — with no Rune window.
///
/// **It is registered on `AgentActionProvider`, and it must never become an MCP
/// tool.** The two surfaces look similar and are not: `MCPAppServer.addTool`
/// publishes a name into the model's context, while `host.actions.register`
/// hands a closure to `AgentActionRegistryHub`, which only host code can
/// `invoke`. The distinction matters here more than anywhere else in Leyline,
/// because this response contains `identityPath` — a filesystem path to a
/// plaintext private key. A model that can read that path can read the key with
/// any file-reading tool it has.
///
/// So: nothing in this file is referenced by `LeylineMCPServer.tools`, and
/// `LeylineMCPOperations.run` has no case for it — an MCP call naming this
/// operation falls through to "unknown operation". Both are pinned by tests.
///
/// ## Password-only connections cannot work here, and the error says so
///
/// The host's `SSHArgsBuilder` bakes in `BatchMode=yes`, which disables every
/// interactive prompt — that is what makes a headless run unable to hang
/// forever waiting for a password nobody will type. The consequence is that a
/// password-only connection can never authenticate in background execution.
/// Returning it anyway would produce a confusing `Permission denied` several
/// layers away from the cause, so it is refused here with the reason.
///
/// ## Neither can a passphrase-protected key, for the same reason
///
/// `BatchMode=yes` disables *every* prompt, not just the password one — "Enter
/// passphrase for key" is suppressed too. A locked key therefore fails headless
/// exactly like a password connection, but less legibly: it used to resolve
/// happily and surface ten seconds later as an unexplained `ConnectTimeout`. So
/// it gets its own refusal here.
///
/// That check needs one extra fact from the store — `LeylineKey.hasPassphrase`
/// — which is why this type takes a `keys` closure alongside `connections`. It
/// is a `Bool` *describing* a secret, not the secret: the passphrase itself is
/// readable only through `LeylineStore.passphrase(for:)`, which nothing here
/// can reach, and `LeylineKey` is the same pure-metadata value type the MCP
/// catalog already hands across its boundary.
@MainActor
struct LeylineConnectionBridge {
    /// The namespaced action id, in the style of `terminal.echo` and
    /// `gitmage.git_op`.
    static let actionID = "leyline.resolve_connection"

    /// Saved connections, metadata only.
    let connections: @MainActor () -> [LeylineConnection]
    /// Imported keys, metadata only — read for `hasPassphrase` and nothing else.
    /// Never key material and never the passphrase.
    let keys: @MainActor () -> [LeylineKey]
    /// The same materialization the Connect button and the `connect` tool use.
    let identity: @MainActor (LeylineConnection) -> SSHIdentityResolution

    /// Answers `{"connection": "<uuid>"}` with a JSON object shaped for the
    /// host's `SSHConnectionInfo` — `host`, `user`, `port`, `identityPath` — so
    /// the host side is a straight `JSONDecoder` decode. `remoteWorkingDir` is
    /// omitted: Leyline does not store one, and the field is optional.
    func resolve(_ json: String) -> AgentActionResult {
        guard let data = json.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failure("\(Self.actionID): malformed input")
        }
        guard
            let identifier = (object["connection"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty
        else {
            return .failure("\(Self.actionID): requires a \"connection\" id or label.")
        }
        // Id or unique label, matched case-insensitively — the same rule
        // `connect` uses, decided by the same type so the two surfaces cannot
        // drift apart. A readable identifier matters most HERE: the host's
        // approval card prints this string verbatim above the command it gates,
        // and a UUID there defeats the point of showing it.
        let conn: LeylineConnection
        switch ConnectionAddress.resolve(identifier, in: connections()) {
        case .one(let match):
            conn = match
        case .ambiguous(let label, let count):
            return .failure(
                "\(Self.actionID): "
                    + ConnectionAddress.ambiguityMessage(label: label, count: count))
        case .notFound:
            // The caller's own text is not echoed back, matching
            // `LeylineMCPOperations`: this response can reach the host's logs,
            // and reflecting caller-supplied text is how a credential pasted
            // into the wrong field escapes.
            return .failure("\(Self.actionID): no saved connection has that id or label.")
        }

        // Checked BEFORE `identity`, deliberately: materializing writes a
        // plaintext copy of the key to disk, and there is no reason to write
        // one for a connection we are about to refuse. Scoped to `.key` so a
        // password connection still gets its own, more specific message; a
        // missing key still falls through to `.keyUnavailable` below.
        if conn.authMode == .key,
            let keyID = conn.keyID,
            let key = keys().first(where: { $0.id == keyID }), key.hasPassphrase
        {
            return .failure(
                "Connection \"\(label(conn))\" uses key \"\(key.label)\", which is "
                    + "passphrase-protected, and background execution runs ssh with "
                    + "BatchMode=yes — which disables every interactive prompt, including "
                    + "\"Enter passphrase for key\". A locked key can never be unlocked for a "
                    + "background command; left to run it would fail as an unexplained "
                    + "connection timeout. Attach a key with no passphrase to this connection "
                    + "in the Leyline app, or open an interactive terminal session in Rune with the "
                    + "connect tool instead.")
        }

        switch identity(conn) {
        case .identity(let materialized):
            let info: [String: Any] = [
                "host": conn.host,
                "user": conn.username,
                "port": conn.port,
                "identityPath": materialized.path,
            ]
            guard let encoded = try? JSONSerialization.data(withJSONObject: info) else {
                return .failure("\(Self.actionID): could not encode the connection.")
            }
            return .success(String(decoding: encoded, as: UTF8.self))

        case .passwordAuth:
            return .failure(
                "Connection \"\(label(conn))\" authenticates with a password, and background "
                    + "execution runs ssh with BatchMode=yes — which disables every interactive "
                    + "prompt, so a password can never be supplied. Password-only connections "
                    + "cannot be used for background commands at all. Attach an SSH key to this "
                    + "connection in the Leyline app, or open an interactive terminal session in Rune with "
                    + "the connect tool instead.")

        case .noKeySelected:
            return .failure(
                "Connection \"\(label(conn))\" uses key authentication but has no key "
                    + "selected. Pick one in the Leyline app.")
        case .keyUnavailable:
            return .failure(
                "Connection \"\(label(conn))\" uses key authentication but its key is "
                    + "no longer in Leyline's vault. Re-import it in the Leyline app.")
        case .materializationFailed:
            return .failure(
                "Connection \"\(label(conn))\": Leyline could not write a protected "
                    + "copy of its key for ssh to read.")
        }
    }

    private func label(_ conn: LeylineConnection) -> String {
        conn.label.isEmpty ? conn.host : conn.label
    }
}

extension AgentActionResult {
    fileprivate static func success(_ text: String) -> AgentActionResult { .init(text: text, isError: false) }
    fileprivate static func failure(_ text: String) -> AgentActionResult { .init(text: text, isError: true) }
}
