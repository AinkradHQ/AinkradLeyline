import AinkradAppKit
import Foundation

@testable import LeylineFeature

/// In-memory document store: encodes on set, decodes on get — same Codable path as disk.
final class FakeDocs: PluginDocumentStore {
    var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) { storage[key] = data }
}

/// In-memory secret store standing in for the host's Keychain-backed store.
final class FakeSecrets: PluginSecretStore {
    var storage: [String: String] = [:]
    func secret(forKey key: String) -> String? { storage[key] }
    func setSecret(_ value: String?, forKey key: String) { storage[key] = value }
}
