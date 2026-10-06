import Foundation

/// The path of a private key `SSHKeyMaterializer` wrote to disk.
///
/// A `String` would do the job, and that is exactly the problem: a bare string
/// interpolates into any message a future edit writes, and this one names a
/// plaintext copy of the user's private key. Wrapping it means `"\(identity)"`
/// yields a redaction rather than the path, so a leak has to be deliberate —
/// someone has to reach for `.path` — instead of accidental.
struct MaterializedIdentity: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The 0600 file `ssh -i` should read. Only two callers may touch it: the
    /// `SSHLaunchPayload` handed to Rune, and the host-only
    /// `leyline.resolve_connection` bridge. Never tool output.
    let path: String

    var description: String { "<materialized identity>" }
    var debugDescription: String { description }
}

/// How one connection authenticates, once its key (if any) has been made
/// readable by the system `ssh` binary.
enum SSHIdentityResolution: Equatable {
    /// Key auth, key on disk at 0600.
    case identity(MaterializedIdentity)
    /// The connection authenticates with a password; `ssh` will prompt.
    case passwordAuth
    /// Key auth is configured but no key is selected.
    case noKeySelected
    /// A key is selected but its material is not in the vault (deleted key, or
    /// a Keychain entry the host could not read).
    case keyUnavailable
    /// The key exists but could not be written at 0600, so it was not written
    /// at all. Carries no path — see `MaterializedIdentity`.
    case materializationFailed

    /// The `-i` path, or nil when there is nothing to pass.
    var path: String? {
        if case .identity(let identity) = self { return identity.path }
        return nil
    }

    /// Why a key connection can't hand ssh a key, in the one wording `connect`
    /// and the host bridge both use; nil for `.identity` and `.passwordAuth`.
    /// A materialization failure's underlying error names the file, so it is
    /// deliberately not described. See `MaterializedIdentity`.
    func keyFailureMessage(label: String) -> String? {
        switch self {
        case .identity, .passwordAuth:
            return nil
        case .noKeySelected:
            return "Connection \"\(label)\" uses key authentication but has no key selected. "
                + "Pick one in the Leyline app, then try again."
        case .keyUnavailable:
            return "Connection \"\(label)\" uses key authentication but its key is no longer in "
                + "Leyline's vault. Re-import it in the Leyline app."
        case .materializationFailed:
            return "Couldn't connect to \(label): Leyline could not write a protected copy of its key "
                + "for ssh to read."
        }
    }
}

/// Turns a connection into the `-i` argument `ssh` needs — **the single
/// implementation**, shared by the Connect button and by agent-initiated
/// connects.
///
/// It used to exist only inside `LeylineRootView.connect`, and the MCP `connect`
/// tool deliberately passed `identityFile: nil` instead of calling it. That
/// conflated two different risks. The model *seeing* key material is genuinely
/// dangerous: tool results land in a persisted, shareable transcript. The app
/// *writing* a key file because the model named a saved connection id is not —
/// the human approves the call, `connect` is `destructive: true`, and no byte of
/// the key (nor the path it landed at) crosses back into the transcript. Only
/// the first needed preventing, so the second no longer is: an agent-initiated
/// connect authenticates exactly like a clicked one, and stops failing with
/// `Permission denied` on hosts the user has a key for.
@MainActor
enum SSHIdentityResolver {
    static func resolve(_ conn: LeylineConnection, store: LeylineStore) -> SSHIdentityResolution {
        guard conn.authMode == .key else { return .passwordAuth }
        guard let keyID = conn.keyID else { return .noKeySelected }
        guard let key = store.keys.first(where: { $0.id == keyID }),
            let material = store.privateKey(for: key)
        else { return .keyUnavailable }
        // `materialize` throws rather than shipping a key it could not protect.
        // The thrown error carries the path, so it never reaches the result:
        // it is logged at the default private privacy and nowhere else.
        do {
            return .identity(MaterializedIdentity(path: try store.materialize(keyID: keyID, privateKey: material)))
        } catch {
            Log.keys.error("could not materialize key \(keyID, privacy: .public): \(error)")
            return .materializationFailed
        }
    }
}
