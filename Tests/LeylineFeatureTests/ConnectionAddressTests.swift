import Foundation
import Testing

@testable import LeylineFeature

@Suite("ConnectionAddress")
struct ConnectionAddressTests {
    private func conn(_ label: String, host: String = "h.example.com") -> LeylineConnection {
        LeylineConnection(
            id: UUID(), label: label, host: host, port: 22, username: "u", authMode: .password, keyID: nil,
            createdAt: Date())
    }

    private func matched(_ match: ConnectionAddress.Match) -> LeylineConnection? {
        if case .one(let c) = match { return c }
        return nil
    }

    @Test("an id matches case-insensitively")
    func idMatches() {
        let a = conn("A")
        let all = [a, conn("B")]
        #expect(matched(ConnectionAddress.resolve(a.id.uuidString, in: all)) == a)
        #expect(matched(ConnectionAddress.resolve(a.id.uuidString.lowercased(), in: all)) == a)
    }

    @Test("a unique label matches case-insensitively")
    func uniqueLabelMatches() {
        let a = conn("Prod Web")
        #expect(matched(ConnectionAddress.resolve("prod web", in: [a, conn("DB")])) == a)
    }

    @Test("an exact id beats a label that mimics it")
    func idBeatsLabel() {
        let a = conn("A")
        let decoy = conn(a.id.uuidString)
        #expect(matched(ConnectionAddress.resolve(a.id.uuidString, in: [decoy, a])) == a)
    }

    @Test("a shared label is ambiguous and names the stored label and count")
    func sharedLabelIsAmbiguous() {
        let match = ConnectionAddress.resolve("prod", in: [conn("Prod"), conn("PROD"), conn("x")])
        guard case .ambiguous(let label, let count) = match else {
            Issue.record("expected ambiguous, got \(match)")
            return
        }
        #expect(label == "Prod")
        #expect(count == 2)
        #expect(
            ConnectionAddress.ambiguityMessage(label: label, count: count)
                .hasPrefix("2 saved connections share the label \"Prod\""))
    }

    @Test("a host, an empty string or an unknown name is not found")
    func notFound() {
        let all = [conn("A", host: "web.example.com"), conn("")]
        for identifier in ["web.example.com", "", "nope"] {
            guard case .notFound = ConnectionAddress.resolve(identifier, in: all) else {
                Issue.record("\(identifier) should not resolve")
                continue
            }
        }
    }
}
