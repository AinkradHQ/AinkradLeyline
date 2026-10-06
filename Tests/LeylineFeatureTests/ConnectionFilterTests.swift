import Foundation
import Testing

@testable import LeylineFeature

@Suite("ConnectionFilter")
struct ConnectionFilterTests {
    private let items = [
        LeylineConnection(
            id: UUID(), label: "Prod Web", host: "web.acme.io", port: 22,
            username: "deploy", authMode: .key, keyID: nil, createdAt: Date()),
        LeylineConnection(
            id: UUID(), label: "DB", host: "db.internal", port: 22,
            username: "postgres", authMode: .password, keyID: nil, createdAt: Date()),
    ]

    @Test("empty query returns everything")
    func emptyReturnsAll() {
        #expect(ConnectionFilter.matching("   ", in: items).count == 2)
    }

    @Test("matches label case-insensitively")
    func matchesLabel() {
        #expect(ConnectionFilter.matching("prod", in: items).map(\.label) == ["Prod Web"])
    }

    @Test("matches host and username")
    func matchesHostAndUser() {
        #expect(ConnectionFilter.matching("internal", in: items).map(\.label) == ["DB"])
        #expect(ConnectionFilter.matching("deploy", in: items).map(\.label) == ["Prod Web"])
    }
}
