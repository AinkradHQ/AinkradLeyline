import AinkradAppKit
import Foundation

/// The sink behind Leyline's MCP tools: decodes one `{"operation": ..., ...}`
/// payload and answers it from the `LeylineCatalog`.
///
/// ## The hard constraint
///
/// **No code in this file can reach credential material.** Not by discipline —
/// by construction: this type holds a `LeylineCatalog`, which is three closures
/// over value types, and never a `LeylineStore`. `privateKey(for:)`,
/// `passphrase(for:)` and `password(for:)` are not in scope here, so no
/// success text, error text or diagnostic can be derived from them. See
/// `LeylineCatalog` for the full argument.
///
/// The published surface is correspondingly small, and the omissions are
/// deliberate rather than unfinished:
///
/// - No `add_connection` / `update_connection` / `remove_connection`, and no
///   key management. Editing the connection store is the user's job through the
///   UI. The value of the MCP surface is letting the assistant *find* a host and
///   offer to connect to it.
/// - Nothing that takes credential material as an ARGUMENT (`importKey`,
///   `setPassword`). Tool-call arguments land in the transcript exactly as tool
///   results do, so an "import this key" tool would leak by a different door.
/// - `connect` DOES materialize a private key, through `catalog.identity` —
///   the same `SSHIdentityResolver` the Connect button uses. It previously sent
///   `identityFile: nil` on the theory that an agent decision must not cause a
///   key file to be written, and that was wrong: it conflated the model *seeing*
///   key material (dangerous — transcripts persist) with the app *writing* a key
///   file because the model named a saved connection id (not dangerous — the
///   human approves, and neither the key nor its path comes back). The result
///   was a tool that opened Rune and then failed with `Permission denied`
///   for every host whose key lives only in Leyline's vault. What stays true is
///   the part that mattered: no key material, passphrase, password **or
///   materialized path** appears in any result, error or argument echo.
@MainActor
struct LeylineMCPOperations {
    let catalog: LeylineCatalog

    /// What `connect` and `list_connections` say when nothing is saved yet.
    ///
    /// This is the fresh-install state and the assistant WILL hit it. No tool
    /// can fix it — adding a connection is deliberately not published — so the
    /// only useful answer names what is missing and who can supply it.
    static let noConnectionsMessage =
        "Leyline has no saved connections. Open the Leyline app and add a host with the "
        + "+ button (connections and credentials are managed there, not from here)."

    func run(_ json: String) async -> AgentActionResult {
        guard let data = json.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let operation = object["operation"] as? String
        else {
            return .failure("Leyline: malformed request")
        }
        switch operation {
        case "listConnections": return listConnections(object)
        case "listKeys": return listKeys()
        case "connect": return connect(object)
        default: return .failure("Leyline: unknown operation \"\(operation)\"")
        }
    }

    // MARK: - read

    /// Id, label, host, port, username — and nothing else.
    ///
    /// Explicitly NOT included: any secret, and any materialized key path. The
    /// key path is the subtle one: it is a filesystem path, so it looks like
    /// harmless metadata, but it names a plaintext copy of a private key and
    /// hands any tool with filesystem read a one-step route to the key itself.
    /// `authMode` and the key's *label* are safe and genuinely useful — they
    /// tell the model whether a password prompt is coming — so those are in.
    private func listConnections(_ object: [String: Any]) -> AgentActionResult {
        let all = catalog.connections()
        guard !all.isEmpty else { return .success(Self.noConnectionsMessage) }
        let query = (object["query"] as? String) ?? ""
        // Reuses the app's own filter so search from the assistant and search
        // in the sidebar can never disagree about what matches.
        let matches = ConnectionFilter.matching(query, in: all)
        guard !matches.isEmpty else {
            // The query is deliberately NOT echoed back — see `connect` below
            // for the reasoning. The caller knows what it asked for.
            return .success(
                "No saved connection matches that query. "
                    + "Call list_connections with no query to see all \(all.count).")
        }
        let keyLabels = Dictionary(uniqueKeysWithValues: catalog.keys().map { ($0.id, $0.label) })
        let rows = matches.map { conn -> String in
            var line = "\(conn.id.uuidString)  \(conn.label.isEmpty ? "(unlabelled)" : conn.label)"
            line += "  —  \(conn.username.isEmpty ? "" : "\(conn.username)@")\(conn.host):\(conn.port)"
            line += "  [\(describeKeyAuth(conn, keyLabels: keyLabels))]"
            return line
        }
        return .success(rows.joined(separator: "\n"))
    }

    /// Id and label — and nothing else.
    ///
    /// Not `hasPassphrase`: whether a key is passphrase-protected is a property
    /// OF the secret, and publishing it tells an attacker which key is the
    /// cheap one to steal. It buys the model nothing, because it cannot use a
    /// key either way.
    private func listKeys() -> AgentActionResult {
        let keys = catalog.keys()
        guard !keys.isEmpty else {
            return .success(
                "Leyline has no imported SSH keys. Import one from the key vault "
                    + "in the Leyline app (key material cannot be handled from here).")
        }
        return .success(
            keys
                .map { "\($0.id.uuidString)  \($0.label.isEmpty ? "(unlabelled)" : $0.label)" }
                .joined(separator: "\n"))
    }

    /// A short, secret-free description of how a connection authenticates.
    private func describeKeyAuth(
        _ conn: LeylineConnection,
        keyLabels: [UUID: String]
    ) -> String {
        switch conn.authMode {
        case .password:
            return "password auth"
        case .key:
            guard let keyID = conn.keyID else { return "key auth, no key selected" }
            let label = keyLabels[keyID].flatMap { $0.isEmpty ? nil : $0 } ?? keyID.uuidString
            return "key auth: \(label)"
        }
    }

    // MARK: - connect

    private func connect(_ object: [String: Any]) -> AgentActionResult {
        guard
            let identifier = (object["connection"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty
        else {
            return .failure(
                "connect requires a \"connection\" (an id or label from "
                    + "list_connections).")
        }
        let all = catalog.connections()
        guard !all.isEmpty else { return .failure(Self.noConnectionsMessage) }
        // Id, or a label naming exactly one connection — decided by
        // `ConnectionAddress`, the same type the host bridge uses, so both
        // surfaces answer the same string identically. A hostname is still not
        // addressable: it is not a user-chosen name, and two connections to one
        // host with different usernames are normal rather than a mistake.
        let conn: LeylineConnection
        switch ConnectionAddress.resolve(identifier, in: all) {
        case .one(let match):
            conn = match
        case .ambiguous(let label, let count):
            // Never a silent pick — that was the whole objection to matching on
            // anything but an id, and this is the answer to it.
            return .failure(ConnectionAddress.ambiguityMessage(label: label, count: count))
        case .notFound:
            // The rejected identifier is deliberately NOT echoed back.
            //
            // This looks like lost actionability, and it costs almost nothing:
            // the caller supplied the value, so it already knows it. What it
            // buys is that "no tool output ever contains secret material"
            // becomes an UNCONDITIONAL property of this file. An error that
            // echoes its input is the classic way a secret escapes a surface
            // that "doesn't return secrets" — it only takes one caller passing
            // a credential into the wrong field, and reflecting arbitrary
            // caller text also gives a prompt-injection payload a free ride
            // back into the transcript. `LeylineMCPCredentialLeakTests` calls
            // every tool with the seeded secret as its argument and pins this.
            return .failure(
                "No saved connection has that id or label. "
                    + "Call list_connections to get the id of the host you mean.")
        }

        // Materialize the stored key exactly as the Connect button does. The
        // failure modes are reported as failures rather than silently degraded
        // to "try ssh-agent and hope": a connect that opens Rune and then
        // says Permission denied is the bug this replaces.
        let resolution = catalog.identity(conn)
        switch resolution {
        case .identity, .passwordAuth:
            break
        case .noKeySelected:
            return .failure(
                "Connection \"\(label(conn))\" uses key authentication but has no key "
                    + "selected. Pick one in the Leyline app, then try again.")
        case .keyUnavailable:
            return .failure(
                "Connection \"\(label(conn))\" uses key authentication but its key is "
                    + "no longer in Leyline's vault. Re-import it in the Leyline app.")
        case .materializationFailed:
            // The underlying error names the file; it is deliberately not
            // described here. See `MaterializedIdentity`.
            return .failure(
                "Couldn't connect to \(label(conn)): Leyline could not write a "
                    + "protected copy of its key for ssh to read.")
        }
        // `resolution.path` is the ONLY read of the materialized path in this
        // file, and it goes straight into the payload Rune receives — a
        // channel the model never sees.
        let payload = SSHLaunchPayload(
            host: conn.host, port: conn.port,
            username: conn.username, identityFile: resolution.path)
        // Validate before launching. Every field lands in an `ssh` argv, and
        // `ssh`'s option surface (`-o ProxyCommand=…`) runs shell commands, so
        // a hostile hostname is code execution. The same guard the UI applies.
        guard let safe = try? payload.validated() else {
            return .failure(
                "Connection \"\(label(conn))\" has an unsafe host, username or port "
                    + "and was not opened. Fix it in the Leyline app.")
        }

        // Surface the outcome instead of discarding it, and say what the user
        // can DO about each one — a tool result the model relays as "couldn't
        // connect" with no reason is a dead end for the person reading it.
        switch catalog.launch(safe) {
        case .opened:
            var text =
                "Opened a terminal session in Rune to \(label(conn)) "
                + "(\(conn.username.isEmpty ? "" : "\(conn.username)@")\(conn.host):\(conn.port))."
            // Say which credential is in play, without naming where it lives.
            if resolution.path != nil {
                text += " It authenticates with the SSH key stored in Leyline."
            } else {
                // Password auth is fine here: a human is sitting at the Rune
                // window `ssh` is about to prompt in. (It is NOT fine for
                // background execution — see `LeylineConnectionBridge`.)
                text +=
                    " This connection uses password authentication, so Rune will prompt "
                    + "for the password."
            }
            return .success(text)
        case .unknownApp:
            return .failure(
                "Couldn't connect to \(label(conn)): the Rune app isn't installed. "
                    + "Install it from Ainkrad's App Store, then try again.")
        case .disabled:
            return .failure(
                "Couldn't connect to \(label(conn)): the Rune app is disabled. "
                    + "Enable it in Ainkrad's App Store, then try again.")
        case .refused(let why):
            return .failure(
                "Couldn't connect to \(label(conn)): the host refused to open "
                    + "Rune — \(why)")
        // `PluginLaunchOutcome` lives in a resilient module, so a newer SDK may
        // add a case this build has never seen. Treat unknown as FAILURE: a
        // false "connected" is worse than a false "didn't".
        @unknown default:
            return .failure(
                "Couldn't connect to \(label(conn)): the host reported an "
                    + "unrecognised launch outcome.")
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
