import Testing
import Foundation
@testable import LeylineFeature

@Suite("SSHKeyMaterializer")
struct SSHKeyMaterializerTests {
    @Test("writes the key with 0600 perms and a trailing newline")
    func writes() throws {
        let id = UUID()
        let path = try SSHKeyMaterializer.materialize(keyID: id, privateKey: "PRIVATE-KEY-BODY")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let body = try String(contentsOfFile: path, encoding: .utf8)
        #expect(body.hasPrefix("PRIVATE-KEY-BODY"))
        #expect(body.hasSuffix("\n"))
    }
}

/// Wave 2: the key file must never exist at readable permissions, and a
/// materialized key must be removable.
@Suite("SSHKeyMaterializer lifecycle and permissions")
struct SSHKeyMaterializerLifecycleTests {

    @Test("The containing directory is 0700 even if it already existed")
    func directoryPermissionsAreReasserted() throws {
        let dir = try SSHKeyMaterializer.keysDirectory()
        // Simulate a directory left by an older build at a looser mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        _ = try SSHKeyMaterializer.keysDirectory()

        let mode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o700, "an existing keys directory kept its loose permissions")
    }

    @Test("Rematerializing over an existing file keeps 0600")
    func rewriteStaysPrivate() throws {
        let id = UUID()
        let first = try SSHKeyMaterializer.materialize(keyID: id, privateKey: "ONE")
        defer { SSHKeyMaterializer.purge(keyID: id) }
        // Loosen it the way the old `.atomic` + chmod ordering could leave it.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: first)

        let second = try SSHKeyMaterializer.materialize(keyID: id, privateKey: "TWO")

        let mode = (try FileManager.default.attributesOfItem(atPath: second)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(try String(contentsOfFile: second, encoding: .utf8).hasPrefix("TWO"))
    }

    @Test("purge removes the plaintext key from disk")
    func purgeRemovesTheFile() throws {
        let id = UUID()
        let path = try SSHKeyMaterializer.materialize(keyID: id, privateKey: "SECRET")
        #expect(FileManager.default.fileExists(atPath: path))

        SSHKeyMaterializer.purge(keyID: id)

        // Before this existed, deleting a key from the vault cleared the
        // Keychain entry and left this file behind forever.
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("purge on an absent key is a no-op, not a failure")
    func purgeIsIdempotent() {
        let id = UUID()
        SSHKeyMaterializer.purge(keyID: id)
        SSHKeyMaterializer.purge(keyID: id)
    }

    @Test("purgeAll clears every materialized key")
    func purgeAllClearsDirectory() throws {
        let ids = [UUID(), UUID(), UUID()]
        var paths: [String] = []
        for id in ids { paths.append(try SSHKeyMaterializer.materialize(keyID: id, privateKey: "K")) }

        SSHKeyMaterializer.purgeAll()

        // Parallel-safe: suites share one per-process temp root, so the
        // directory may hold other suites' keys too. Assert only our own are gone.
        for path in paths {
            #expect(!FileManager.default.fileExists(atPath: path), "our key survived purgeAll")
        }
    }
}

/// 0.1: tests must never touch the real `~/Library/Application Support/Leyline`
/// directory. This suite fails until `keysDirectory()` redirects under test runs.
@Suite("SSHKeyMaterializer isolation")
struct SSHKeyMaterializerIsolationTests {
    @Test("keysDirectory is never the real one under tests")
    func keysDirectoryIsNeverTheRealOneUnderTests() throws {
        let dir = try SSHKeyMaterializer.keysDirectory()
        let real = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Leyline")
        #expect(
            !dir.standardizedFileURL.path.hasPrefix(real.standardizedFileURL.path),
            "keysDirectory points at the real Application Support Leyline dir"
        )
        #expect(
            dir.standardizedFileURL.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path),
            "keysDirectory is not under the temporary directory"
        )
    }
}

/// Every Leyline instance (the daily host, any Debug host) shares one keys
/// directory, so closing one must purge only the keys it materialized itself.
@MainActor
@Suite("Leyline teardown key purge")
struct LeylineTeardownKeyPurgeTests {
    /// Imports a key into the instance's store and materializes it the way a connect does.
    private func materialize(on host: BasicModeHost) throws -> (keyID: UUID, path: String) {
        let store = LeylineApp.store(for: host)
        let key = store.importKey(label: "k", privateKey: "PRIVATE-\(UUID())", passphrase: nil)
        let conn = store.addConnection(label: "c", host: "h", port: 22, username: "u",
                                       authMode: .key, keyID: key.id, password: nil)
        let path = try #require(SSHIdentityResolver.resolve(conn, store: store).path)
        return (key.id, path)
    }

    @Test("tearing one instance down leaves another instance's key file")
    func teardownLeavesOtherInstancesKeys() throws {
        let a = BasicModeHost(), b = BasicModeHost()
        let keyA = try materialize(on: a), keyB = try materialize(on: b)
        defer { SSHKeyMaterializer.purge(keyID: keyA.keyID); SSHKeyMaterializer.purge(keyID: keyB.keyID) }

        LeylineApp.teardown(instance: a.instanceID)

        #expect(!FileManager.default.fileExists(atPath: keyA.path), "closing A left A's key on disk")
        #expect(FileManager.default.fileExists(atPath: keyB.path), "closing A deleted B's live key")
        LeylineApp.teardown(instance: b.instanceID)
        #expect(!FileManager.default.fileExists(atPath: keyB.path))
    }

    @Test("a key materialized by nobody in this instance is left alone")
    func teardownLeavesUnownedFiles() throws {
        let a = BasicModeHost()
        let foreign = UUID()
        let path = try SSHKeyMaterializer.materialize(keyID: foreign, privateKey: "FOREIGN")
        defer { SSHKeyMaterializer.purge(keyID: foreign) }
        _ = LeylineApp.store(for: a)
        LeylineApp.teardown(instance: a.instanceID)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("deleting a key from the vault still purges its file")
    func vaultDeleteStillPurges() throws {
        let a = BasicModeHost()
        let k = try materialize(on: a)
        defer { LeylineApp.teardown(instance: a.instanceID) }
        let store = LeylineApp.store(for: a)
        store.removeKey(try #require(store.keys.first { $0.id == k.keyID }))
        #expect(!FileManager.default.fileExists(atPath: k.path))
    }
}
