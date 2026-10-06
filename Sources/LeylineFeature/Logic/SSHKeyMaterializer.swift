import Foundation

/// Writes a Keychain-held private key to a 0600 file so the system `ssh` binary
/// (spawned by Rune) can read it. Lives in Application Support; a rebuildable
/// cache — the Keychain remains source of truth.
///
/// ## Two things this must get right
///
/// **The file must never exist at readable permissions, not even briefly.**
/// The previous implementation wrote with `.atomic` and *then* chmod'd to
/// 0600. `.atomic` writes a temporary file at the process umask (typically
/// 0644) and renames it into place, so between the rename and the
/// `setAttributes` call the user's private key sat world-readable on disk. A
/// window that small is still a window, and any local process watching that
/// directory wins it. Permissions are now set at creation, before a single
/// byte of key material is written.
///
/// **Materialized keys must be removable.** They are a cache of secrets, and a
/// cache of secrets with no eviction is a plaintext key store with extra steps.
/// `purge(keyID:)` runs when the key is deleted from the vault.
enum SSHKeyMaterializer {

    enum MaterializerError: Error, Equatable {
        case couldNotCreateFile(String)
        case wrongPermissions(String, Int)
    }

    /// `~/Library/Application Support/Leyline/keys`, held at 0700.
    ///
    /// Under a test run this redirects to a per-process directory under the
    /// temporary directory (see `root()`): the test target is unhosted, so no
    /// sandbox redirects Application Support, and the suite chmods, purges
    /// and deletes through this function. Tests must never touch real keys.
    static func keysDirectory() throws -> URL {
        let base = try root().appendingPathComponent("Leyline/keys", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // `createDirectory`'s attributes apply only when it actually creates
        // the directory. A directory left by an older build — or one a user's
        // umask made group-readable — would keep its old mode forever, so
        // re-assert it unconditionally.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        return base
    }

    static func materialize(keyID: UUID, privateKey: String) throws -> String {
        let base = try keysDirectory()
        let url = base.appendingPathComponent(keyID.uuidString)

        var body = privateKey
        if !body.hasSuffix("\n") { body.append("\n") }        // ssh requires a trailing newline

        // Create the file EMPTY at 0600, then write into it. `createFile`
        // applies its attributes at creation, so there is no instant at which
        // key material exists under looser permissions.
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MaterializerError.couldNotCreateFile(url.path)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(body.utf8))

        // Verify what actually landed rather than trusting the attribute
        // request. `ssh` refuses an over-permissive key anyway ("UNPROTECTED
        // PRIVATE KEY FILE"), so failing loudly here beats a confusing ssh
        // error later — and a key we can't protect is deleted, not shipped.
        let mode = FileManager.default.attributesOfItemPosixPermissions(atPath: url.path)
        guard mode == 0o600 else {
            try? FileManager.default.removeItem(at: url)
            throw MaterializerError.wrongPermissions(url.path, mode ?? -1)
        }
        return url.path
    }

    /// Removes the materialized copy of one key. Safe to call when absent.
    static func purge(keyID: UUID) {
        guard let base = try? keysDirectory() else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent(keyID.uuidString))
    }
}

private extension FileManager {
    func attributesOfItemPosixPermissions(atPath path: String) -> Int? {
        (try? attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    }
}

/// The directory `keysDirectory()` builds `Leyline/keys` under.
///
/// Tests must never touch the real `~/Library/Application Support/Leyline`
/// directory: the suite chmods it, purges it and deletes through this path,
/// and the test target is an unhosted `bundle.unit-test` so no sandbox
/// container redirects Application Support. Under a test run — detected the
/// same way the host does in `AppEnvironment.swift` and
/// `LaunchHomeResolver.swift`, via `XCTestConfigurationFilePath` — return a
/// per-process directory under the temporary directory instead, so every
/// caller (`materialize`, `purge`, teardown) is redirected through
/// the one function they all route through. A test written later cannot get
/// it wrong.
fileprivate func root() throws -> URL {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "LeylineTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
    return try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
}
